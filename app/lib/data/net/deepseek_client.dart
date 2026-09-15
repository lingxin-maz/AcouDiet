// app/lib/data/net/deepseek_client.dart
//
// ADR-44 -- THE egress point. This is the only file in `app/lib` that opens a socket, and
// `tool/check_network_boundary.py` fails the build if a second one appears (`R-OUT-4`).
//
// What is deliberately NOT here:
//   * no `http` / `dio` / `url_launcher` dependency. `dart:io` is enough, and
//     `tool/run_offline_tests.py` resolves packages from a local pub cache that does not
//     contain them (PLAN-G-01 section 6).
//   * no tool loop, no prompt building, no history trimming -- those are `G-02`, and keeping
//     them out means the request body has exactly ONE construction site, which is what makes
//     the `FF-26d` / `FF-26e` audit a single-point review.
//   * no credential storage -- `AgentCredentialsStore` owns that.
//
// Failure contract (`SPEC-G-01` section 6): `send()` never throws. It always ends with exactly
// one `AgentFinished` or one `AgentFailed`. That is what lets `G-02` and `U-07` handle every
// case without a try/catch at each call site, and it is what keeps the agent path from
// escaping into the detection / records / report stacks (`FF-26f`).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/errors.dart';
import '../../core/feature_config.g.dart' as cfg;
import 'agent_credentials.dart';
import 'agent_protocol.dart';
import 'agent_transport.dart';
import 'sse_decoder.dart';

class DeepSeekClient implements AgentTransport {
  DeepSeekClient({
    required this.credentials,
    this.baseUrlOverride,
    this.modelOverride,
    this.connectTimeoutMs,
    this.readTimeoutMs,
    this.maxRequestBytes,
    this.maxOutputTokens,
    this.temperature,
    this.versionText = 'v1.0',
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();

  final AgentCredentialsStore credentials;

  /// User-supplied endpoint override. `null` -> the SSOT default.
  final String? baseUrlOverride;
  final String? modelOverride;

  final int? connectTimeoutMs;
  final int? readTimeoutMs;
  final int? maxRequestBytes;
  final int? maxOutputTokens;
  final double? temperature;

  /// `User-Agent: AcouDiet/<versionText>` -- the ONLY outbound identifier, and it identifies
  /// the app, not the device (`API-05` section 13.1.4).
  final String versionText;

  final HttpClient _http;
  bool _cancelled = false;
  bool _disposed = false;

  int get _connectTimeout => connectTimeoutMs ?? cfg.FeatureConfig.agentConnectTimeoutMs;
  int get _readTimeout => readTimeoutMs ?? cfg.FeatureConfig.agentReadTimeoutMs;
  int get _maxBytes => maxRequestBytes ?? cfg.FeatureConfig.agentMaxRequestBytes;
  String get _model => modelOverride ?? cfg.FeatureConfig.agentModel;

  @override
  Stream<AgentDelta> send(AgentRequest request) async* {
    _cancelled = false;
    var attempts = 0;
    var receivedDelta = false;

    while (true) {
      attempts++;
      var sawDelta = false;
      try {
        await for (final delta in _attempt(request, onDelta: () => sawDelta = true)) {
          if (sawDelta) receivedDelta = true;
          yield delta;
        }
        return;
      } on AcouDietError catch (e) {
        if (!shouldRetry(
          code: e.code,
          attempts: attempts - 1,
          receivedDelta: receivedDelta,
        )) {
          yield AgentFailed(e);
          return;
        }
        await Future<void>.delayed(_backoffFor(e));
      } catch (e) {
        yield AgentFailed(_mapThrown(e));
        return;
      }
    }
  }

  Duration _backoffFor(AcouDietError e) {
    final after = e.detail?['retry_after_seconds'];
    if (after is num && after >= 0 && after <= 30) {
      return Duration(milliseconds: (after * 1000).round());
    }
    return e.code == Codes.agentServerError
        ? const Duration(seconds: 1)
        : const Duration(seconds: 2);
  }

  /// One HTTP round trip. Yields deltas as they arrive; throws `AcouDietError` on failure so
  /// `send()` can apply the retry gate in exactly one place.
  Stream<AgentDelta> _attempt(
    AgentRequest request, {
    required void Function() onDelta,
  }) async* {
    final creds = await credentials.read();
    if (creds == null) {
      throw Errors.agent(Codes.agentNoKey, detail: <String, Object?>{'reason': 'no credential'});
    }
    final base = normalizeBaseUrl(baseUrlOverride ?? creds.baseUrl ?? cfg.FeatureConfig.agentBaseUrl);
    if (!isSecureBaseUrl(base)) {
      throw Errors.agent(Codes.agentNoKey, detail: <String, Object?>{'reason': 'base url is not https'});
    }
    final uri = Uri.parse('$base/chat/completions');

    _http.connectionTimeout = Duration(milliseconds: _connectTimeout);
    _http.userAgent = 'AcouDiet/$versionText';

    final body = buildRequestBody(
      model: _model,
      messages: request.messages,
      tools: request.tools,
      maxTokens: maxOutputTokens ?? cfg.FeatureConfig.agentMaxOutputTokens,
      temperature: temperature ?? cfg.FeatureConfig.agentTemperature,
      maxRequestBytes: _maxBytes,
    );

    HttpClientResponse response;
    try {
      final req = await _http.openUrl('POST', uri);
      req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${creds.apiKey}');
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      req.add(utf8.encode(body));
      response = await req.close();
    } on SocketException catch (e) {
      throw _offline(e);
    } on HandshakeException catch (e) {
      throw _offline(e);
    } on TimeoutException {
      throw Errors.agent(Codes.agentTimeout);
    }

    if (response.statusCode != 200) {
      final retryAfter = response.headers.value('retry-after');
      final err = httpStatusError(response.statusCode);
      // Drain the body so the socket can be reused/closed cleanly. Both encodings are read
      // because this project has been bitten twice by a binary/UTF-16 assumption.
      try {
        await response.drain<void>();
      } catch (_) {}
      throw retryAfter == null
          ? err
          : AcouDietError(err.code, err.message,
              detail: <String, Object?>{
                ...?err.detail,
                'retry_after_seconds': num.tryParse(retryAfter) ?? 0,
              },
              retryable: err.retryable);
    }

    final decoder = SseDecoder(maxLineBytes: _maxBytes);
    final partials = <int, AgentPartialToolCall>{};
    var finished = false;

    try {
      await for (final chunk in response.timeout(Duration(milliseconds: _readTimeout))) {
        if (_cancelled) break;
        for (final payload in decoder.feed(chunk)) {
          final deltas = parseSsePayload(payload, partials: partials);
          for (final d in deltas) {
            onDelta();
            if (d is AgentFinished) finished = true;
            yield d;
          }
        }
        if (decoder.done || finished) break;
      }
    } on FormatException catch (e) {
      // Malformed JSON in a `data:` line means the stream itself is not trustworthy.
      throw Errors.agent(Codes.agentStreamBroken,
          detail: <String, Object?>{'reason': 'malformed SSE payload', 'detail': '$e'});
    } on StateError catch (e) {
      throw Errors.agent(Codes.agentStreamBroken,
          detail: <String, Object?>{'reason': '$e'});
    } on TimeoutException {
      throw Errors.agent(Codes.agentTimeout);
    } on HttpException catch (e) {
      throw Errors.agent(Codes.agentStreamBroken,
          detail: <String, Object?>{'reason': 'connection closed mid-stream', 'detail': '$e'});
    }

    if (!finished && !_cancelled) {
      // The socket closed without `[DONE]` or a `finish_reason`. The partial text is kept --
      // discarding what the model already said would be worse -- but the turn is flagged
      // incomplete, and there is NO retry (a second answer cannot be spliced onto the first).
      throw Errors.agent(Codes.agentStreamBroken,
          detail: <String, Object?>{'reason': 'stream ended without a finish signal'});
    }
  }

  AcouDietError _offline(Object cause) => Errors.agent(
        Codes.agentOffline,
        detail: <String, Object?>{'cause': cause.runtimeType.toString()},
      );

  /// Maps an arbitrary thrown object to a code. `SocketException` and friends reach here when
  /// they are wrapped by the stream machinery rather than raised directly.
  AcouDietError _mapThrown(Object e) {
    if (e is AcouDietError) return e;
    if (e is SocketException || e is HandshakeException || e is HttpException) return _offline(e);
    if (e is TimeoutException) return Errors.agent(Codes.agentTimeout);
    if (e is FormatException) {
      return Errors.agent(Codes.agentStreamBroken, detail: <String, Object?>{'detail': '$e'});
    }
    return Errors.agent(Codes.agentStreamBroken, detail: <String, Object?>{'detail': '$e'});
  }

  @override
  void cancel() {
    _cancelled = true;
    // `close(force: true)` is the only way to abandon an in-flight response: the response
    // stream is consumed by an `await for` inside `_attempt`, so there is no subscription
    // handle to cancel. Closing the client tears the socket down and the loop exits.
    _http.close(force: true);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelled = true;
    _http.close(force: true);
  }
}
