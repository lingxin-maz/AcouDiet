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
  });

  final List<double> bars;
  final int barCount;
  final double level;
  final Color stroke;
  final Color baseline;

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
    final paint = Paint()
      ..color = stroke
      ..strokeWidth = math.max(1.5, slot * 0.5)
      ..strokeCap = StrokeCap.round;

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
      old.level != level || old.bars.length != bars.length || old.bars != bars;
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
