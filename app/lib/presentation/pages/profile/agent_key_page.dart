// app/lib/presentation/pages/profile/agent_key_page.dart
//
// U-05 · the API-key row of 我的 / 设置 (`SPEC-U-07` section 3, `API-07` section 2).
//
// WHY THE KEY IS TYPED HERE AND NOWHERE ELSE
// ------------------------------------------
// `FF-26b` fixes the product stance: the key is the USER's, AcouDiet neither provides credit nor
// resells it, and the app must not pretend otherwise. The two consequences this screen carries:
//
//   * the page states, in the user's own reading path, that the key comes from their own DeepSeek
//     account and that no credit is bundled;
//   * once stored, the key is NEVER rendered in plaintext -- only `maskApiKey(...)` is shown, and
//     the entry field is cleared on success. `FF-26b` also forbids writing it to a log or to a
//     diagnostic snapshot; this file logs nothing and exports nothing.
//
// The shape check is local and offline (`isWellFormedKey`): validating a key against the service
// would spend the user's credit the moment they press Save (`API-07` section 2), so it is
// deliberately NOT done here.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/errors.dart';
import '../../../data/net/agent_credentials.dart';
import '../../presenters/ui_strings.dart';
import '../../state/acou_scope.dart';
import '../../state/app_services.dart';
import '../../theme/acou_theme.dart';
import '../../widgets/acou_app_bar.dart';

class AgentKeyPage extends StatefulWidget {
  const AgentKeyPage({super.key});

  @override
  State<AgentKeyPage> createState() => _AgentKeyPageState();
}

class _AgentKeyPageState extends State<AgentKeyPage> {
  final TextEditingController _field = TextEditingController();

  AgentRuntime? _agent;
  String? _storedMask;
  String? _message;
  bool _isError = false;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _agent = AcouScope.readServices(context).agent;
    if (_loaded) return;
    _loaded = true;
    // Synchronous: the runtime already holds the MASKED key (`AgentRuntime.refresh`), so this page
    // never reads the credential file, and the plaintext is never in this widget's memory at all.
    _syncFromRuntime();
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _syncFromRuntime() {
    final agent = _agent;
    final mask = agent == null || agent.keyMask.isEmpty ? null : agent.keyMask;
    setState(() => _storedMask = mask);
  }

  Future<void> _save() async {
    final agent = _agent;
    if (agent == null) return;
    final key = _field.text.trim();
    if (!isWellFormedKey(key)) {
      setState(() {
        _isError = true;
        _message = UiStrings.apiKeyInvalidShape;
      });
      return;
    }
    try {
      await agent.credentials.write(AgentCredentials(
        apiKey: key,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
      await agent.refresh();
    } on AcouDietError {
      if (!mounted) return;
      setState(() {
        _isError = true;
        _message = UiStrings.saveFailed;
      });
      return;
    }
    if (!mounted) return;
    // The field is cleared the instant the write succeeds: keeping the plaintext on screen would
    // put it in the next screenshot, which is exactly what `FF-26b` forbids.
    _field.clear();
    setState(() {
      _isError = false;
      _message = UiStrings.apiKeySaved;
      _storedMask = agent.keyMask.isEmpty ? null : agent.keyMask;
    });
  }

  Future<void> _clear() async {
    final agent = _agent;
    if (agent == null) return;
    await agent.credentials.clear();
    await agent.refresh();
    if (!mounted) return;
    setState(() {
      _isError = false;
      _message = UiStrings.apiKeyCleared;
      _storedMask = null;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        extendBodyBehindAppBar: true,
        appBar: const AcouPageHeader(title: UiStrings.apiKeyTitle),
        body: DecoratedBox(
          decoration: AcouTheme.pageGradientDecoration(),
          child: ListView(
            padding: EdgeInsets.only(
              top: kToolbarHeight + MediaQuery.paddingOf(context).top + AcouTheme.spaceMd,
              left: AcouTheme.spacePage,
              right: AcouTheme.spacePage,
              bottom: AcouTheme.spaceXl + AcouTheme.bottomInset(context),
            ),
            children: [
              Container(
                padding: const EdgeInsets.all(AcouTheme.spaceMd),
                decoration: AcouTheme.cardDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(UiStrings.apiKeyExplanation, style: AcouTheme.bodyMuted),
                    const SizedBox(height: AcouTheme.spaceSm),
                    Semantics(
                      container: true,
                      label:
                          '${UiStrings.apiKeyEntry}：${_storedMask ?? UiStrings.apiKeyNone}',
                      child: Text(
                        _storedMask ?? UiStrings.apiKeyNone,
                        style: AcouTheme.metric,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AcouTheme.spaceMd),
              TextField(
                controller: _field,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: UiStrings.apiKeyFieldLabel),
                onSubmitted: (_) => unawaited(_save()),
              ),
              const SizedBox(height: AcouTheme.spaceSm),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                child: FilledButton(
                  onPressed: () => unawaited(_save()),
                  child: const Text(UiStrings.apiKeySave),
                ),
              ),
              const SizedBox(height: AcouTheme.spaceSm),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                child: OutlinedButton(
                  onPressed: _storedMask == null ? null : () => unawaited(_clear()),
                  child: const Text(UiStrings.apiKeyClear),
                ),
              ),
              if (_message != null) ...[
                const SizedBox(height: AcouTheme.spaceSm),
                Text(
                  _message!,
                  style: _isError ? AcouTheme.caption : AcouTheme.bodyMuted,
                ),
              ],
            ],
          ),
        ),
      );
}
