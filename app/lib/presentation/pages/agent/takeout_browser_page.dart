// app/lib/presentation/pages/agent/takeout_browser_page.dart
//
// ADR-45 -- "see the takeout options WITH IMAGES" (user requirement).
//
// WHY A WEB VIEW, AND WHY THAT IS THE HONEST ANSWER
// -------------------------------------------------
// The request was to display takeout options that carry pictures. Pictures of other people's
// dishes can only come from one of three places, and only one of them is legitimate:
//
//   1. **a platform API** -- does not exist for third-party consumer apps (`FF-26i` records the
//      same finding for ordering: Meituan / Eleme / Taobao open platforms require ISV or merchant
//      qualifications). Not reachable.
//   2. **bundled photos** -- would need sourcing and licensing for every dish, and would still be
//      a stale, arbitrary list. Not honest.
//   3. **the platform's own result page** -- real dishes, real photos, live prices, and no data
//      licensing problem, because it is THEIR page rendered for OUR user. ✅ This one.
//
// So the App does not invent a menu. It shows the platform's page, and labels it as such, because
// a user who believes the App built this list will also believe it can place the order.
//
// FLAVOUR
// -------
// Reachable only from the `agent` flavour (`acouIsOffline` gates the button that pushes it). The
// `offline` build must not contain a web view at all: it is the build whose entire privacy claim
// is "this package declares no network permission", and a renderer for remote pages in it would
// be both dead code and a contradiction.

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../presenters/ui_strings.dart';
import '../../theme/acou_theme.dart';
import '../../widgets/acou_app_bar.dart';

/// Renders one platform's own search-results page, at the keyword the agent proposed.
class TakeoutBrowserPage extends StatefulWidget {
  const TakeoutBrowserPage({
    super.key,
    required this.platformLabel,
    required this.url,
  });

  /// The platform's display name, for the title and the note.
  final String platformLabel;

  /// The **web** search URL. The app-scheme form is what the "open in app" button uses; a scheme
  /// cannot be loaded by a web view, only handed to the OS.
  final String url;

  @override
  State<TakeoutBrowserPage> createState() => _TakeoutBrowserPageState();
}

class _TakeoutBrowserPageState extends State<TakeoutBrowserPage> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // A real mobile UA: these pages serve a desktop layout (or a risk-control page) to a client
      // that does not look like a phone browser.
      ..setUserAgent(_mobileUserAgent)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (!mounted) return;
          setState(() {
            _loading = true;
            _failed = false;
          });
        },
        onPageFinished: (_) {
          if (!mounted) return;
          setState(() => _loading = false);
        },
        onWebResourceError: (_) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _failed = true;
          });
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  static const String _mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0.0.0 Mobile Safari/537.36';

  @override
  Widget build(BuildContext context) => AcouScrollEdge(
        child: Scaffold(
          backgroundColor: AcouTheme.surfaceMuted,
          appBar: AcouPageHeader(
            title: UiStrings.agentBrowserTitle(widget.platformLabel),
          ),
          // The bar is a `preferredSize` widget, so the body is inset by the shell's own bottom
          // padding exactly like every other page (`AcouTheme.bottomInset`).
          body: SafeArea(
            top: false,
            child: Column(
              children: <Widget>[
                _note(),
                Expanded(child: _body()),
              ],
            ),
          ),
        ),
      );

  /// The honesty line. It is not decoration: it is the sentence that keeps the user from
  /// attributing the platform's list to this App -- and therefore from expecting this App to be
  /// able to order from it.
  Widget _note() => Padding(
        padding: const EdgeInsets.fromLTRB(
          AcouTheme.spaceMd,
          AcouTheme.spaceSm,
          AcouTheme.spaceMd,
          AcouTheme.spaceSm,
        ),
        child: Semantics(
          label: UiStrings.agentBrowserNote,
          child: ExcludeSemantics(
            child: Text(
              UiStrings.agentBrowserNote,
              style: AcouTheme.bodyMuted,
            ),
          ),
        ),
      );

  Widget _body() {
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AcouTheme.spaceLg),
          child: Text(
            UiStrings.agentBrowserFailed,
            style: AcouTheme.body,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Stack(
      children: <Widget>[
        WebViewWidget(controller: _controller),
        if (_loading)
          const Center(child: CircularProgressIndicator())
      ],
    );
  }
}
