// app/lib/presentation/state/async_value.dart
//
// The Riverpod-free loading/error/ready wrapper (FF-23 names Riverpod, but this build ships
// dependency-free equivalents behind the same frozen contracts -- see
// `docs/reports/c04_dependency_deviation.md`). The notifiers in `notifiers.dart` publish these
// values; the widgets render them through `StateView`.
//
// PURE DART (no Flutter import), so the state machine is unit-testable without a Flutter
// binding.
//
// Error discipline (API-05 section 8 / `AcouDietError.retryable`): the UI offers a retry
// affordance **only** when `retryable == true`; the error's `code` is always available to the
// page so it can render the mapped sentence instead of a generic failure.

import '../../core/errors.dart';

/// The four-plus-one render states shared by every page (SPEC-U-06 section 2.3).
enum ViewStatus {
  /// Nothing requested yet.
  idle,

  /// A request is in flight; the page shows a skeleton, never a `0` value.
  loading,

  /// Data is present and non-empty.
  ready,

  /// The request succeeded and the answer is genuinely empty (a different state from `error`).
  empty,

  /// The request failed; the page shows the readable sentence and, when retryable, a retry.
  error,
}

/// A minimal `AsyncValue<T>`.
class AsyncValue<T> {
  const AsyncValue._(this.status, this.data, this.error);

  const AsyncValue.idle() : this._(ViewStatus.idle, null, null);

  /// A refresh keeps the previous value so the page can dim it instead of flashing white.
  const AsyncValue.loading([T? previous]) : this._(ViewStatus.loading, previous, null);

  const AsyncValue.ready(T value) : this._(ViewStatus.ready, value, null);

  /// `previous` (when given) is the last good value: the page keeps showing it while the error
  /// banner explains what failed.
  const AsyncValue.error(AcouDietError failure, [T? previous])
      : this._(ViewStatus.error, previous, failure);

  final ViewStatus status;
  final T? data;
  final AcouDietError? error;

  bool get isLoading => status == ViewStatus.loading;
  bool get hasValue => data != null;
  bool get hasError => status == ViewStatus.error;

  /// Only a retryable code may show a retry button (never a speculative one).
  bool get canRetry => error?.retryable ?? false;

  /// The code shown next to the message, for support and for the machine-checkable tests.
  String get errorCode => error?.code ?? '';

  /// The user-facing sentence: the domain message, never a raw exception dump.
  String get errorMessage => error?.message ?? '';

  AsyncValue<T> toLoading() => AsyncValue<T>.loading(data);

  AsyncValue<R> map<R>(R Function(T value) transform) => switch (status) {
        ViewStatus.ready => AsyncValue<R>.ready(transform(data as T)),
        ViewStatus.error => AsyncValue<R>.error(error!, null),
        ViewStatus.loading => AsyncValue<R>.loading(),
        ViewStatus.idle => AsyncValue<R>.idle(),
        ViewStatus.empty => AsyncValue<R>._(ViewStatus.empty, null, null),
      };

  /// Folds the value into whatever the caller needs; kept tiny on purpose.
  R when<R>({
    required R Function() idle,
    required R Function(T? previous) loading,
    required R Function(T value) ready,
    required R Function(AcouDietError failure, T? previous) error,
    R Function()? empty,
  }) =>
      switch (status) {
        ViewStatus.idle => idle(),
        ViewStatus.loading => loading(data),
        ViewStatus.ready => ready(data as T),
        ViewStatus.empty => empty == null ? idle() : empty(),
        ViewStatus.error => error(this.error!, data),
      };

  /// The status a widget should render for a list-like value: an empty list is `empty`, not
  /// `ready` (U-06 section 2.3).
  static ViewStatus statusForList<T>(AsyncValue<List<T>> v) {
    if (v.status != ViewStatus.ready) return v.status;
    final list = v.data;
    if (list == null || list.isEmpty) return ViewStatus.empty;
    return ViewStatus.ready;
  }

  @override
  String toString() => 'AsyncValue(${status.name}, data=$data, error=$errorCode)';
}

/// Convenience constructors used by the notifiers.
abstract final class Async {
  Async._();

  static AsyncValue<T> idle<T>() => AsyncValue<T>.idle();
  static AsyncValue<T> loading<T>([T? previous]) => AsyncValue<T>.loading(previous);
  static AsyncValue<T> ready<T>(T value) => AsyncValue<T>.ready(value);
  static AsyncValue<T> failed<T>(AcouDietError e, [T? previous]) =>
      AsyncValue<T>.error(e, previous);

  /// Wraps an awaited call, converting a thrown `AcouDietError` into the error state and
  /// re-throwing anything else (a non-domain exception is a programming defect, not a state).
  static Future<AsyncValue<T>> guard<T>(Future<T> Function() body, {T? previous}) async {
    try {
      return AsyncValue<T>.ready(await body());
    } on AcouDietError catch (e) {
      return AsyncValue<T>.error(e, previous);
    }
  }
}
