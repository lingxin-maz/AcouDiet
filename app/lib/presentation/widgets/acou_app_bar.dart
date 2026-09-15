// app/lib/presentation/widgets/acou_app_bar.dart
//
// ADR-38 · the shared top bar of the four top-level pages.
//
// Every delivered mockup (`软件UI界面设计图/2.png` 报告, `3.png` / `10.png` 检测, `8.png` 记录,
// `9.png` 我的) draws the same header:
//
//     [ brand wordmark / back ]     page title (centred)     [ page actions ]
//
// floating on the mint gradient rather than on an opaque bar. ADR-24 adopted the gradient but left
// each page to build its own `AppBar`, so every page kept a **left-aligned** title and its own
// hand-rolled action list -- the one piece of the mockups' chrome that was never actually rebuilt.
// This is that piece: one widget, and the pages stop disagreeing about their own headers.
//
// The title is centred **exactly**, not approximately. The bar's title slot is a three-segment row
// whose two side segments share one `Expanded` flex, so they are always the same width and the
// middle child lands on the true centre of the bar no matter how wide the wordmark is or how many
// actions a page passes in.

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../presenters/ui_strings.dart';
import '../theme/acou_theme.dart';

/// ADR-39: Apple's **scroll-edge material**.
///
/// A page that extends its body behind the app bar (`extendBodyBehindAppBar`) has its content
/// scrolling *under* the title. That is what Apple does too -- and Apple's answer is the material:
/// while content is underneath the bar the bar frosts and a hairline appears; at the very top of
/// the page both go away and the bar is simply the page's own background.
///
/// The visible defect this fixes is not theoretical. Scrolled, the records page painted a card's
/// body text straight through the centred title 「饮食记录」 (the `visual_capture` screenshot
/// `shell_records_scrolled.png` records it), because the list's top inset scrolls away with the
/// content and nothing separated the two. That is precisely the case Apple's scroll-edge
/// appearance exists for.
///
/// Wrap the page's `Scaffold` in this, and the page's own [AcouPageHeader] picks the state up on
/// its own (it reads the [AcouScrollEdge] it is inside), so a page needs no `bool` threaded through
/// it and no page has to remember to wire anything.
///
/// The `ScrollNotification` is caught here rather than inside the bar because the body and the app
/// bar are siblings -- a notification from the list bubbles up through the `Scaffold`, never
/// sideways into the app bar.
class AcouScrollEdge extends StatefulWidget {
  const AcouScrollEdge({super.key, required this.child});

  final Widget child;

  /// The state of the nearest [AcouScrollEdge]; `false` outside one (a page pumped on its own in a
  /// test, or a route with no scrolling body).
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ScrollEdgeScope>()?.scrolled ?? false;

  @override
  State<AcouScrollEdge> createState() => _AcouScrollEdgeState();
}

class _AcouScrollEdgeState extends State<AcouScrollEdge> {
  bool _scrolled = false;

  /// A few pixels of slack: a list dragged by two pixels has not scrolled under anything, and a bar
  /// that flickers on a rubber-band overscroll is worse than one that is slightly late.
  static const double _slack = 4;

  bool _onNotification(ScrollNotification n) {
    final next = n.metrics.pixels > _slack;
    if (next != _scrolled) setState(() => _scrolled = next);
    // Never absorb the notification: `RefreshIndicator` and everything else upstream still needs it.
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollNotification>(
        onNotification: _onNotification,
        child: _ScrollEdgeScope(scrolled: _scrolled, child: widget.child),
      );
}

class _ScrollEdgeScope extends InheritedWidget {
  const _ScrollEdgeScope({required this.scrolled, required super.child});

  final bool scrolled;

  @override
  bool updateShouldNotify(_ScrollEdgeScope old) => old.scrolled != scrolled;
}

/// The frosted band drawn behind a bar's content. Empty (and free) when [visible] is false.
class AcouChromeMaterial extends StatelessWidget {
  const AcouChromeMaterial({super.key, required this.visible, this.edge = true});

  final bool visible;

  /// Whether to draw the hairline along the bottom edge. The tab bar always wants one; a page
  /// header only wants it while something is passing underneath.
  final bool edge;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: AcouTheme.materialBlurSigma,
          sigmaY: AcouTheme.materialBlurSigma,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AcouTheme.chromeMaterialTint,
            border: edge ? const Border(bottom: AcouTheme.chromeEdge) : null,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// The brand wordmark of the mockups' top-left corner: a mint rounded tile with the sound glyph,
/// then the product name. Home draws the full frozen name ([UiStrings.appTitle]); the four inner
/// pages have only half a bar's width to spare, so they draw [UiStrings.appBrandShort] -- the same
/// mark, without the locale suffix, which is what the mockups' 「EatSense」 wordmark does too.
class AcouBrandMark extends StatelessWidget {
  const AcouBrandMark({super.key, this.fullName = false, this.iconSize = 30});

  final bool fullName;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: iconSize,
            height: iconSize,
            decoration: BoxDecoration(
              color: AcouTheme.mintDeep,
              borderRadius: BorderRadius.circular(AcouTheme.radiusSm),
            ),
            child: Icon(Icons.graphic_eq, size: iconSize * 0.6, color: AcouTheme.onMint),
          ),
          const SizedBox(width: AcouTheme.spaceSm),
          Flexible(
            child: Text(
              fullName ? UiStrings.appTitle : UiStrings.appBrandShort,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fullName ? 19 : 16,
                fontWeight: FontWeight.w800,
                color: AcouTheme.ink,
              ),
            ),
          ),
        ],
      );
}

/// The shared top bar. Drop it into `Scaffold.appBar` and keep `extendBodyBehindAppBar: true`, so
/// the page gradient runs behind it (the mockups have no opaque chrome anywhere).
class AcouPageHeader extends StatelessWidget implements PreferredSizeWidget {
  const AcouPageHeader({
    super.key,
    required this.title,
    this.actions = const <Widget>[],
  });

  /// The frozen page title. Centred; never abbreviated to fit.
  final String title;

  /// The page's own affordances, drawn right. One or two, as in the mockups.
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    // A pushed page keeps its way back. The mockups' pushed screens (2.png, 3.png) put a back
    // arrow in this same slot; only a page with nothing above it shows the wordmark.
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    // ADR-39: read the page's scroll-edge state from the `AcouScrollEdge` this bar sits inside, so
    // no page has to thread a `bool` into its own header.
    final scrolled = AcouScrollEdge.of(context);
    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: 0,
      // `flexibleSpace` paints behind `leading` / `title` / `actions`, which is the whole bar.
      flexibleSpace: AcouChromeMaterial(visible: scrolled),
      title: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AcouTheme.spaceSm),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: canPop ? const BackButton() : const AcouBrandMark(),
              ),
            ),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AcouTheme.ink,
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: actions,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
