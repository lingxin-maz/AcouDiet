// app/lib/data/net/sse_decoder.dart
//
// ADR-44 -- the Server-Sent-Events line decoder. Pure Dart, no `dart:io` needed.
//
// WHY THIS IS ITS OWN FILE (`PLAN-G-01` section 3.2)
// --------------------------------------------------
// This is the only place in the connection layer that holds real incremental state, and it is
// the only place with a class of bug that survives every "it worked on my machine" test:
//
//   * TCP gives you BYTES, not characters. A Chinese character is 3 bytes in UTF-8 and the
//     network is free to split it 1 + 2. Calling `utf8.decode` on each chunk then throws
//     `FormatException: Unexpected end of input`, intermittently, under load.
//   * SSE gives you LINES, and the network is free to split a line anywhere.
//
// So the buffer holds BYTES, lines are cut BYTES, and decoding happens only on a line that is
// known to be complete. That ordering is the whole point; `API-05` section 13.1.6 states it as
// a contract. `agent_tests.dart` has a negative control that decodes per chunk and MUST throw.

import 'dart:convert';
import 'dart:typed_data';

/// A streaming decoder for the `text/event-stream` framing used by the chat completions API.
///
/// Only the subset the contract needs is implemented (`API-07` section 5.3):
///   * lines beginning with `data:` carry JSON payloads;
///   * the payload `[DONE]` terminates the stream;
///   * blank lines and lines beginning with `:` (SSE comments) are ignored;
///   * every other field name is ignored rather than fatal -- an unknown field is how a
///     server adds a feature, and treating it as an error turns a server upgrade into an app
///     crash (`API-07` section 8).
class SseDecoder {
  SseDecoder({this.maxLineBytes = 1 << 20});

  /// Hard cap on a single line. Without it a server that never sends `\n` grows the buffer
  /// until the process dies -- an out-of-memory crash with no error code and no message
  /// (`SPEC-G-01` section 2.4).
  final int maxLineBytes;

  final BytesBuilder _buffer = BytesBuilder(copy: false);

  /// Set when the `[DONE]` sentinel has been seen. After that, further input is ignored.
  bool get done => _done;
  bool _done = false;

  /// Feeds an arbitrary chunk of BODY BYTES and returns whatever complete payloads it
  /// completed. A chunk may complete zero, one, or several payloads.
  ///
  /// Throws [StateError] when the buffer exceeds [maxLineBytes] or after [done].
  List<String> feed(List<int> chunk) {
    if (_done) return const <String>[];
    _buffer.add(chunk);
    final bytes = _buffer.toBytes();
    _buffer.clear();

    final out = <String>[];
    var start = 0;

    while (true) {
      final newline = _indexOfNewline(bytes, start);
      if (newline < 0) break;

      // `\r\n` and `\n` are both accepted; strip the `\r` so the JSON payload is clean.
      var end = newline;
      if (end > start && bytes[end - 1] == 0x0D) end -= 1;

      // Decode ONLY a complete line. This is the line that must not be split.
      final line = utf8.decode(bytes.sublist(start, end), allowMalformed: false);
      final payload = _payloadOf(line);
      if (payload != null) {
        if (payload == '[DONE]') {
          _done = true;
          start = newline + 1;
          break;
        }
        out.add(payload);
      }
      start = newline + 1;
    }

    // Anything left over is an incomplete line: keep the BYTES for the next chunk.
    if (start < bytes.length) {
      final rest = bytes.sublist(start);
      if (rest.length > maxLineBytes) {
        throw StateError('ACD-AGENT-008: SSE line exceeds $maxLineBytes bytes without a '
            'newline -- refusing to grow the buffer further');
      }
      _buffer.add(rest);
    }
    return out;
  }

  /// Bytes still waiting for their newline. Exposed so tests can assert the buffer really
  /// holds bytes rather than a guessed-at string.
  int get pendingBytes => _buffer.length;

  static int _indexOfNewline(Uint8List bytes, int from) {
    for (var i = from; i < bytes.length; i++) {
      if (bytes[i] == 0x0A) return i;
    }
    return -1;
  }

  /// The payload of one line, or `null` when the line carries no data.
  static String? _payloadOf(String line) {
    if (line.isEmpty) return null;
    if (line.startsWith(':')) return null; // SSE comment / keep-alive
    if (!line.startsWith('data:')) return null; // event:, id:, retry: -- ignored on purpose
    var payload = line.substring(5);
    // The spec allows exactly one optional space after the colon. Not trimming would put a
    // leading space in front of every `{`, which `jsonDecode` rejects.
    if (payload.startsWith(' ')) payload = payload.substring(1);
    return payload;
  }
}

/// The accumulation rules for a single tool call while it is still streaming.
///
/// Kept next to the SSE decoder because it is the other half of the same mistake: the API
/// sends `function.arguments` as a FRAGMENTED JSON STRING. Concatenate it; never parse a
/// fragment (`API-05` section 13.3.2). `operator +` exists so the merge rule reads as one
/// sentence instead of being re-derived at every call site.
class AgentPartialToolCall {
  AgentPartialToolCall({required this.index, this.id = '', this.name = '', this.arguments = ''});

  final int index;
  String id;
  String name;
  String arguments;

  /// Merges one streamed fragment. `id` / `name` arrive once (or repeat identically), so the
  /// last non-empty value wins; `arguments` always appends.
  void merge({String? id, String? name, String? argumentsFragment}) {
    if (id != null && id.isNotEmpty) this.id = id;
    if (name != null && name.isNotEmpty) this.name = name;
    if (argumentsFragment != null) arguments += argumentsFragment;
  }

  bool get isComplete => id.isNotEmpty && name.isNotEmpty;
}
