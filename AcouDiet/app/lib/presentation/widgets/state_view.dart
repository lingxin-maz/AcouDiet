// app/lib/presentation/widgets/state_view.dart
//
// `StateView` -- the one loading / empty / error / idle presentation every page uses
// (SPEC-U-06 section 1.2 item 4). It consumes the pure [ViewStatus] and [AsyncValue] from
// `state/async_value.dart` and re-exports them, so a page needs a single import.
//
// Two rules from the contracts are encoded here:
//  * an error state shows the **domain message and code**, and offers a retry affordance
//    **only** when `AcouDietError.retryable == true` (API-05 section 8) -- a speculative retry
//    button on a non-retryable configuration mismatch would invite the user into a loop;
//  * the empty state shows a sentence, never a `0` skeleton (a zero would be read as data).

import 'package:flutter/material.dart';

import '../state/async_value.dart';
import '../theme/acou_theme.dart';

export '../state/async_value.dart' show AsyncValue, ViewStatus;

/// Pull-to-refresh around a page body that is **not** already scrollable.
///
/// Why it exists: `RefreshIndicator` only reacts to a scrollable descendant, so a page whose
/// loading / empty / error branch renders a centred panel could not be pulled at all -- exactly
/// the state in which a user most wants to retry. The panel is therefore given a one-item
/// `ListView` with `AlwaysScrollableScrollPhysics`, and stretched to the viewport height so it
/// still looks centred.
class RefreshableBody extends StatelessWidget {
  const RefreshableBody({super.key, required this.onRefresh, required this.child});

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: onRefresh,
        child: LayoutBuilder(
          builder: (context, constraints) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            // ADR-39: the shell runs the body under the tab bar and puts the bar's height into the
            // bottom inset, so the centred panel keeps its trailing space clear of the bar.
            padding: EdgeInsets.only(bottom: AcouTheme.bottomInset(context)),
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: child,
              ),
            ],
          ),
        ),
      );
}

/// The shared state panel.
class StateView extends StatelessWidget {
  const StateView({
    super.key,
    required this.status,
    this.message,
    this.onRetry,
    this.code,
    this.compact = false,
  });

  final ViewStatus status;

  /// The sentence to show; defaults are supplied per status.
  final String? message;

  /// Only rendered when the status is [ViewStatus.error] **and** the caller decided the failure
  /// was retryable.
  final VoidCallback? onRetry;

  /// The `AcouDietError.code`, shown as small print so a现场 report can quote it.
  final String? code;

  /// `true` for an inline region (a card-sized area) instead of a full page.
  final bool compact;

  /// The sentence of each status when the caller passes none.
  static String defaultMessage(ViewStatus status) => switch (status) {
        ViewStatus.idle => '尚未加载',
        ViewStatus.loading => '正在加载…',
        ViewStatus.ready => '',
        ViewStatus.empty => '暂无数据',
        ViewStatus.error => '数据读取失败',
      };

  /// Builds the panel from an `AsyncValue`, offering a retry only for a retryable error.
  static StateView of<T>(
    AsyncValue<T> value, {
    String? emptyMessage,
    String? loadingMessage,
    String? errorMessage,
    VoidCallback? onRetry,
    bool compact = false,
  }) {
    if (value.status == ViewStatus.error) {
      return StateView(
        status: ViewStatus.error,
        message: errorMessage ?? value.errorMessage,
        code: value.errorCode,
        onRetry: value.canRetry ? onRetry : null,
        compact: compact,
      );
    }
    return StateView(
      status: value.status,
      message: value.status == ViewStatus.empty ? emptyMessage : loadingMessage,
      compact: compact,
    );
  }

  /// `true` when this status should replace the page body entirely.
  bool get isBlocking =>
      status == ViewStatus.error || status == ViewStatus.loading || status == ViewStatus.empty;

  @override
  Widget build(BuildContext context) {
    final text = message ?? defaultMessage(status);
    final icon = switch (status) {
      ViewStatus.idle => Icons.hourglass_empty,
      ViewStatus.loading => Icons.downloading,
      ViewStatus.empty => Icons.inbox_outlined,
      ViewStatus.error => Icons.error_outline,
      ViewStatus.ready => Icons.check_circle_outline,
    };
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (status == ViewStatus.loading)
          const Padding(
            padding: EdgeInsets.only(bottom: AcouTheme.spaceSm),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else
          Icon(icon, color: AcouTheme.inkMuted, size: 28),
        const SizedBox(height: AcouTheme.spaceSm),
        Text(
          text,
          textAlign: TextAlign.center,
          style: AcouTheme.bodyMuted,
        ),
        if (code != null && code!.isNotEmpty) ...[
          const SizedBox(height: AcouTheme.spaceXs),
          Text(code!, style: AcouTheme.caption),
        ],
        if (onRetry != null) ...[
          const SizedBox(height: AcouTheme.spaceSm),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
            child: TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ),
        ],
      ],
    );

    return Semantics(
      label: switch (status) {
        ViewStatus.idle => '尚未加载',
        ViewStatus.loading => '正在加载',
        ViewStatus.empty => '暂无数据',
        ViewStatus.error => '出错：$text',
        ViewStatus.ready => '已完成加载',
      },
      container: true,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(compact ? AcouTheme.spaceMd : AcouTheme.spaceXl),
          child: body,
        ),
      ),
    );
  }
}
