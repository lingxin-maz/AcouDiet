// app/lib/core/flavour.dart
//
// ADR-44 -- the two build flavours, resolved at COMPILE time.
//
//   * `offline` -- the build this project's strongest privacy evidence belongs to. Its release
//     manifest has **no `INTERNET` permission at all**, and that is what `SPEC-C-01` section 7
//     item 1a points at: `aapt dump badging` on the offline APK is the one artifact that proves
//     the claim in a single line, because a package that never declares the permission cannot
//     open a socket no matter what the Dart code does.
//   * `agent`   -- the same offline core plus the optional cloud agent (default OFF, user's own
//     key, audio never uploaded). This flavour DOES declare `INTERNET`, which is exactly why the
//     generic claim "本应用不申请网络权限" is only true of `offline` (FF-24 item 4 as amended by
//     ADR-44) and why every user-visible sentence that makes it is selected by flavour.
//
// WHY A CONSTANT AND NOT A RUNTIME FLAG
// -------------------------------------
// `FF-24` item 4 is a packaging statement, not a setting: an `offline` build must not contain the
// agent page, the network permission or the tab that reaches them. Reading the flavour from a
// `const` lets the tree-shaker drop that code from the offline binary, which is the difference
// between "the button is hidden" and "the code is not there".

/// The two packaging flavours (`SPEC-C-01` section 7, `FF-24` item 4).
enum AcouFlavour {
  /// No network permission, no agent page: the build the permission evidence is taken from.
  offline,

  /// The offline core plus the opt-in cloud agent.
  agent,
}

/// The build-time flavour name. `ACOUDIET_FLAVOUR=offline` selects [AcouFlavour.offline]; anything
/// else (including the default) selects [AcouFlavour.agent].
const String acouFlavourName =
    String.fromEnvironment('ACOUDIET_FLAVOUR', defaultValue: 'agent');

/// `true` in the `offline` build. Declared as a `const bool` (not only as the getter below) so
/// that it can drive `const` conditional lists -- the tab set and the `IndexedStack` children are
/// compile-time branches, not run-time filters.
const bool acouIsOffline = acouFlavourName == 'offline';

/// The resolved flavour.
const AcouFlavour acouFlavour =
    acouIsOffline ? AcouFlavour.offline : AcouFlavour.agent;

/// Whether this build is the `offline` flavour.
///
/// `offline` is the build that keeps the "no `INTERNET` permission" evidence chain
/// (`SPEC-C-01` section 7 item 1a): it is the APK whose `aapt dump badging` output carries no
/// `android.permission.INTERNET` line, so the privacy claim needs no code review to verify.
bool get isOfflineFlavour => acouIsOffline;
