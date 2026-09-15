// app/lib/data/net/agent_credentials.dart
//
// ADR-44 -- where the user's own DeepSeek API key lives (`FF-26b`).
//
// THE RULE, in one line: the key is in `<filesDir>/agent/credentials.json`, mode 0600, and
// nowhere else. Not in SQLite (no new table, no new column), not in SharedPreferences, not in
// assets, not in a log line, not in a diagnostic snapshot, not in a screenshot. The UI may only
// ever render `maskApiKey(...)`.
//
// Why a file rather than a Keystore-backed store: the project's existing privacy posture
// already relies on device-level file-based encryption for the SQLite database
// (`API-05` section 5.7), and adding `androidx.security:security-crypto` would pull a new
// Gradle dependency through an offline toolchain (`PLAN-G-01` section 6). The honest statement
// is therefore "0600 inside the app sandbox on a device whose FBE is on", not "hardware-backed
// key store" -- and `SPEC-C-06` reports it exactly that way.

import 'dart:convert';
import 'dart:io';

import '../../core/errors.dart';
import 'agent_protocol.dart';
import 'agent_transport.dart';

/// The credential triple. `baseUrl` is nullable because "use the SSOT default" is the normal
/// case; an override exists only because the user may need a different endpoint.
class AgentCredentials {
  const AgentCredentials({required this.apiKey, this.baseUrl, this.savedAtMs = 0});

  final String apiKey;
  final String? baseUrl;
  final int savedAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'apiKey': apiKey,
        if (baseUrl != null) 'baseUrl': baseUrl,
        'savedAtMs': savedAtMs,
      };
}

/// Reads and writes the credential file. Never throws on read: a corrupt file must present as
/// "not configured" (`SPEC-G-01` section 2.4), because the alternative -- a parse exception at
/// start-up -- would let a damaged file stop the app from opening at all.
class AgentCredentialsStore {
  AgentCredentialsStore(this.directory);

  /// `<filesDir>/agent`. Injected by the composition root so this class never guesses a path.
  final Directory directory;

  File get file => File('${directory.path}${Platform.pathSeparator}credentials.json');

  Future<AgentCredentials?> read() async {
    try {
      if (!file.existsSync()) return null;
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final key = decoded['apiKey'];
      if (key is! String || !isWellFormedKey(key)) return null;
      final base = decoded['baseUrl'];
      return AgentCredentials(
        apiKey: key,
        baseUrl: base is String && base.isNotEmpty ? base : null,
        savedAtMs: (decoded['savedAtMs'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Writes the credential file. Uses write-then-rename so a crash mid-write can never leave a
  /// half-written file that `read()` would then treat as "not configured" (which would silently
  /// discard the user's key).
  Future<void> write(AgentCredentials creds) async {
    if (!isWellFormedKey(creds.apiKey)) {
      throw Errors.agent(Codes.agentNoKey, detail: <String, Object?>{
        'reason': 'key is not well formed (non-empty, no whitespace, length >= 16)',
      });
    }
    final base = creds.baseUrl;
    if (base != null && base.isNotEmpty && !isSecureBaseUrl(base)) {
      throw Errors.agent(Codes.agentNoKey, detail: <String, Object?>{
        'reason': 'base url must be https',
      });
    }
    if (!directory.existsSync()) await directory.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(creds.toJson()), flush: true);
    await _restrict(tmp);
    await tmp.rename(file.path);
    await _restrict(file);
  }

  Future<void> clear() async {
    for (final f in <File>[file, File('${file.path}.tmp')]) {
      try {
        if (f.existsSync()) await f.delete();
      } on FileSystemException {
        // A cleanup failure never blocks the caller (`ACD-IO-001` semantics).
      }
    }
  }

  /// Best effort, and deliberately not fatal. `Dart`'s `chmod` is a no-op on Windows, and some
  /// Android filesystems ignore it too -- so the mode is attempted, not asserted. `SPEC-C-06`
  /// reports whether it took effect instead of claiming a guarantee it cannot keep.
  Future<void> _restrict(File f) async {
    try {
      final result = await Process.run('chmod', <String>['600', f.path]);
      if (result.exitCode != 0) return;
    } catch (_) {
      // No `chmod` (Windows): fall through.
    }
  }
}

/// `FF-26b`'s shape check. Deliberately NOT an online check: validating a key over the network
/// would spend the user's credit the moment they press Save.
bool isWellFormedKey(String key) {
  if (key.length < 16) return false;
  if (key.trim() != key) return false;
  return !RegExp(r'\s').hasMatch(key);
}

/// The consent flag (`FF-26c`, `SPEC-C-06`). Stored next to the credential, in the same private
/// directory, for the same reason: it is user-scoped state that must not travel with the
/// database and must not survive a "clear all data" (`ADR-44` makes `clearAllData` include this
/// directory -- a cleared app must come back unconsented).
class AgentConsentStore {
  AgentConsentStore(this.directory);

  final Directory directory;

  File get file => File('${directory.path}${Platform.pathSeparator}consent.json');

  /// Defaults to `false`. A missing or unreadable file means "not consented": failing open here
  /// would be the single worst default in the whole feature.
  Future<bool> read() async {
    try {
      if (!file.existsSync()) return false;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return false;
      return decoded['consented'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> write(bool consented, {int decidedAtMs = 0}) async {
    if (!directory.existsSync()) await directory.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(<String, Object?>{'consented': consented, 'decidedAtMs': decidedAtMs}),
      flush: true,
    );
    await tmp.rename(file.path);
  }

  Future<void> clear() async {
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Never blocks the caller.
    }
  }
}

/// The file-backed [`AgentGate`]. Composed at the root; read synchronously by the UI state so a
/// page can decide what to render without an `await` in `build`.
///
/// `enabled` comes from the base class: consent AND a usable key. There is no third condition,
/// and in particular no "is the network up" check -- an offline device is not a reason to deny
/// a capability, it is a reason to report `ACD-AGENT-001` when the request is attempted.
class FileAgentGate implements AgentGate {
  FileAgentGate({required this.credentials, required this.consent});

  final AgentCredentialsStore credentials;
  final AgentConsentStore consent;

  @override
  bool consented = false;

  @override
  bool hasKey = false;

  @override
  bool get enabled => consented && hasKey;

  /// Refreshes both flags from disk. Called after the user toggles consent or saves a key.
  Future<void> refresh() async {
    consented = await consent.read();
    hasKey = (await credentials.read()) != null;
  }
}
