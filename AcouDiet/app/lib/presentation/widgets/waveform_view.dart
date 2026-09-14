// app/lib/presentation/widgets/waveform_view.dart
//
// `WaveformView` -- the live waveform of U-02, driven by the `level` events' RMS (10 Hz,
// API-01 section 3.2).
//
// Contract points:
//  * pure visual: `rms` never drives a business decision (API-01 section 3.2), and the widget
//    owns no detection state;
//  * the animation repaints **only** the custom-paint layer -- the level stream is pushed into a
//    [ValueNotifier] and the painter listens to it, so no page-level `setState` runs at 10 Hz
//    (U-06 section 8, performance);
//  * silence renders a flat baseline, and the semantic label says "collecting" without ever
//    announcing a number (U-02 section 8).

import 'dart:math' as math;

// `ValueListenable` is not re-exported by `material.dart`, so it needs `foundation` explicitly.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/acou_theme.dart';

class WaveformView extends StatefulWidget {
  const WaveformView({
    super.key,
    this.level,
    this.barCount = 48,
    this.height = 120,
    this.semanticLabel = '正在采集进食声音',
    this.silentAfter,
    this.stroke,
    this.baseline,
    this.idleSilhouette,
  });

  /// The live RMS (`0..1`). `null` renders the silent baseline.
  final ValueListenable<double>? level;

  final int barCount;
  final double height;
  final String semanticLabel;

  /// Optional: when the last event is older than this, the view falls back to the baseline.
  /// The page owns the timing (it holds the subscription); the widget only asks the getter.
  final DateTime? silentAfter;

  /// Bar / baseline paint. Defaults to the brand green on the outline; [WaveCircle] overrides
  /// them with white-on-mint, which is what the mockups' detection screen shows.
  final Color? stroke;
  final Color? baseline;

  /// ADR-38: the **idle hero motif** of the detection disc -- a fixed, symmetric standing wave in
  /// this colour, painted only while there is no live sample at all.
  ///
  /// Why it exists: the mockups' detection screen is a large mint disc with a waveform across it,
  /// and a `null` level (or the first frames after the microphone opens) used to render that disc
  /// as an empty green circle with a hairline through the middle -- the one screen of the six that
  /// did not look like its own design.
  ///
  /// Why it is not a fake measurement: it is **static** (it never moves, so no two frames differ),
  /// it is drawn at low alpha, and it disappears the instant a real sample arrives. It carries no
  /// value, exactly like `AcouTheme.starGold`; the status line beside it still says 「当前静默」
  /// and the semantic label is unchanged. `null` (the default) paints nothing, so every other
  /// caller of [WaveformView] keeps the strictly live rendering.
  final Color? idleSilhouette;

  /// ADR-38: the one predicate that decides whether the idle motif is painted.
  ///
  /// It is a named function rather than an inline `&&` so the rule is testable without a raster:
  /// the motif appears **only** when the caller asked for one, **no** sample has arrived, and the
  /// live level is at zero -- i.e. only when there is genuinely nothing to draw. Any live sample
  /// takes over immediately.
  static bool showsIdleSilhouette({
    required bool hasSamples,
    required double rms,
    required Color? idle,
  }) =>
      idle != null && !hasSamples && rms <= 0;

  @override
  State<WaveformView> createState() => _WaveformViewState();
}

class _WaveformViewState extends State<WaveformView> {
  final List<double> _history = <double>[];
  double _rms = 0;

  @override
  void initState() {
    super.initState();
    widget.level?.addListener(_onLevel);
  }

  @override
  void didUpdateWidget(covariant WaveformView old) {
    super.didUpdateWidget(old);
    if (old.level != widget.level) {
      old.level?.removeListener(_onLevel);
      widget.level?.addListener(_onLevel);
    }
  }

  @override
  void dispose() {
    widget.level?.removeListener(_onLevel);
    super.dispose();
  }

  void _onLevel() {
    final value = (widget.level?.value ?? 0).clamp(0.0, 1.0);
    _history.add(value);
    while (_history.length > widget.barCount) {
      _history.removeAt(0);
    }
    setState(() => _rms = value);
  }

  @override
  Widget build(BuildContext context) {
    // Silently fall back to the baseline when no level event has arrived recently.
    final silent = widget.silentAfter != null &&
        DateTime.now().difference(widget.silentAfter!) > const Duration(seconds: 2);
    final bars = silent ? const <double>[] : _history;
    return Semantics(
      label: widget.semanticLabel,
      container: true,
      child: ExcludeSemantics(
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: CustomPaint(
            painter: _WavePainter(
              bars: bars,
              barCount: widget.barCount,
              level: silent ? 0 : _rms,
              stroke: widget.stroke ?? AcouTheme.seed,
              baseline: widget.baseline ?? AcouTheme.outline,
              // The motif stands in for "nothing to draw yet" and nothing else.
              idleSilhouette: WaveformView.showsIdleSilhouette(
                hasSamples: bars.isNotEmpty,
                rms: _rms,
                idle: widget.idleSilhouette,
              )
                  ? widget.idleSilhouette
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.bars,
    required this.barCount,
    required this.level,
    required this.stroke,
    required this.baseline,
    this.idleSilhouette,
  });

  final List<double> bars;
  final int barCount;
  final double level;
  final Color stroke;
  final Color baseline;
  final Color? idleSilhouette;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = baseline
        ..strokeWidth = 1,
    );

    final slot = size.width / barCount;
    final barWidth = math.max(1.5, slot * 0.5);
    final paint = Paint()
      ..color = stroke
      ..strokeWidth = barWidth
      ..strokeCap = StrokeCap.round;

    // The idle motif: one period of a standing wave, tapering to the baseline at both ends. It is
    // computed from the slot index alone, so it is identical on every frame and cannot be read as
    // a reading. See [WaveformView.idleSilhouette].
    final motif = idleSilhouette;
    if (motif != null) {
      final idle = Paint()
        ..color = motif
        ..strokeWidth = barWidth
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < barCount; i++) {
        final t = barCount == 1 ? 0.5 : i / (barCount - 1);
        final envelope = math.sin(math.pi * t);
        final ripple = 0.45 + 0.55 * math.sin(t * 6 * math.pi).abs();
        final half = (size.height / 2 - 4) * (0.10 + 0.80 * envelope * ripple);
        final x = slot * i + slot / 2;
        canvas.drawLine(Offset(x, mid - half), Offset(x, mid + half), idle);
      }
    }

    for (var i = 0; i < barCount; i++) {
      // Newest sample on the right; unfilled slots stay on the baseline.
      final index = bars.length - barCount + i;
      final value = index >= 0 && index < bars.length ? bars[index] : 0.0;
      final half = (size.height / 2 - 4) * value.clamp(0.0, 1.0);
      final x = slot * i + slot / 2;
      if (half <= 0.5) continue;
      canvas.drawLine(Offset(x, mid - half), Offset(x, mid + half), paint);
    }

    // The instantaneous level, as a thin marker so ten samples a second are readable.
    final markerX = size.width - 2;
    final markerHalf = (size.height / 2 - 4) * level.clamp(0.0, 1.0);
    if (markerHalf > 0.5) {
      canvas.drawLine(
        Offset(markerX, mid - markerHalf),
        Offset(markerX, mid + markerHalf),
        Paint()..color = stroke..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.level != level ||
      old.bars.length != bars.length ||
      old.bars != bars ||
      old.idleSilhouette != idleSilhouette;
}

/// The mockups' detection visual: one large mint disc with the live waveform inside it.
///
/// It is the same [WaveformView] (same `level` stream, same silence handling, same semantics) on
/// a circular gradient -- the disc carries no extra state, so "the waveform stopped" and "the
/// session stopped" cannot drift apart.
class WaveCircle extends StatelessWidget {
  const WaveCircle({
    super.key,
    this.level,
    this.size = 220,
    this.semanticLabel = '正在采集进食声音',
  });

  final ValueListenable<double>? level;
  final double size;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
        label: semanticLabel,
        container: true,
        child: ExcludeSemantics(
          child: Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AcouTheme.mint, AcouTheme.mintDeep],
              ),
              boxShadow: [
                BoxShadow(
                  color: Color(0x3345C9A5),
                  blurRadius: 28,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            padding: EdgeInsets.all(size * 0.16),
            child: WaveformView(
              level: level,
              barCount: 26,
              height: size * 0.62,
              semanticLabel: semanticLabel,
              stroke: AcouTheme.onMint,
              // The mockup has no baseline line inside the disc: silence is the flat middle.
              baseline: const Color(0x33FFFFFF),
              // ADR-38: before the first sample the disc shows the mockups' standing-wave motif
              // instead of an empty circle. Literal alpha, because `withOpacity` / `withValues`
              // are spelled differently across Flutter releases (same reason as `AcouTheme.seedSoft`).
              idleSilhouette: const Color(0x4DFFFFFF),
            ),
          ),
        ),
      );
}

/// A tiny circular level indicator, used beside the detection status line. Text plus shape, so
/// it never relies on colour alone.
class LevelIndicator extends StatelessWidget {
  const LevelIndicator({super.key, required this.level, this.size = 16});

  final double level;
  final double size;

  @override
  Widget build(BuildContext context) {
    final active = level > 0.02;
    return Semantics(
      label: active ? '检测到声音' : '当前静默',
      child: ExcludeSemantics(
        child: Icon(
          active ? Icons.graphic_eq : Icons.linear_scale,
          size: size,
          color: active ? AcouTheme.seed : AcouTheme.inkMuted,
        ),
      ),
    );
  }
}
