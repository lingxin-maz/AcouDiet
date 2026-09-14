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

import 'package:flutter/material.dart';

import '../presenters/ui_strings.dart';
import '../theme/acou_theme.dart';

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
    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: 0,
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
                fontSize: 18,
                fontWeight: FontWeight.w700,
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
