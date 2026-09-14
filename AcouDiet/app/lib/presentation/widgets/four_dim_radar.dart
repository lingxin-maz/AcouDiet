// app/lib/presentation/widgets/four_dim_radar.dart
//
// `FourDimRadar` -- the four-axis behaviour radar of U-01 / U-04, drawn with a `CustomPainter`
// because this build ships no chart package (FF-23 names `fl_chart`, and PLAN-U-06 section 6
// already designates the self-drawn radar as the fallback).
//
// Contract points:
//  * exactly four axes, equal 90 degrees apart, labelled from `DimensionScore.label`
//    (U-06 criterion 2: 饮食规律性 / 食物结构 / 零食控制 / 进食速度 -- never a nutrient axis);
//  * a score of 0 or `max` must neither collapse to a point nor leave the frame, and an axis
//    with no computable basis collapses to the centre while its label still reads `--`;
//  * the chart is **not** the only carrier of information: the whole series is exposed through
//    `Semantics` as a sentence (U-06 section 8).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../presenters/score_view.dart';
import '../theme/acou_theme.dart';

class FourDimRadar extends StatelessWidget {
  const FourDimRadar({super.key, required this.score, this.size = AcouTheme.chartSize});

  final ScoreView score;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: score.radarSemantics,
      container: true,
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _RadarPainter(
              axes: score.axes,
              outline: AcouTheme.outline,
              fill: AcouTheme.seedSoft,
              stroke: AcouTheme.seed,
              // ADR-38: the labels used to be built inside the painter from a bare
              // `TextStyle(fontSize: 11, color: ink)` -- the one piece of text in the app that came
              // from no token and, because a `CustomPainter` has no `DefaultTextStyle`, the one
              // piece that ignored the reader's text scale. Both now arrive from the widget, which
              // is the only place that has a `BuildContext`.
              labelStyle: AcouTheme.chartAxisLabel,
              textScaler: MediaQuery.textScalerOf(context),
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.axes,
    required this.outline,
    required this.fill,
    required this.stroke,
    required this.labelStyle,
    required this.textScaler,
  });

  final List<ScoreAxisView> axes;
  final Color outline;
  final Color fill;
  final Color stroke;
  final TextStyle labelStyle;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    if (axes.isEmpty) return;
    final centre = Offset(size.width / 2, size.height / 2);

    // Leave room for the axis labels around the polygon.
    final labelInset = 34.0;
    final radius = math.max(8.0, math.min(size.width, size.height) / 2 - labelInset);

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..color = outline
      ..strokeWidth = 1;

    // Three concentric rings plus the four spokes.
    for (var ring = 1; ring <= 3; ring++) {
      final r = radius * ring / 3;
      final path = Path();
      for (var i = 0; i < axes.length; i++) {
        final p = _pointAt(centre, r, i, axes.length);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(path, grid);
    }
    for (var i = 0; i < axes.length; i++) {
      canvas.drawLine(centre, _pointAt(centre, radius, i, axes.length), grid);
    }

    // The data polygon. An axis without a basis plots at the centre (`radarValue == 0`).
    final dataPath = Path();
    for (var i = 0; i < axes.length; i++) {
      final axis = axes[i];
      final max = axis.max == 0 ? 1 : axis.max;
      final ratio = (axis.radarValue / max).clamp(0.0, 1.0);
      final p = _pointAt(centre, radius * ratio, i, axes.length);
      if (i == 0) {
        dataPath.moveTo(p.dx, p.dy);
      } else {
        dataPath.lineTo(p.dx, p.dy);
      }
    }
    dataPath.close();
    canvas.drawPath(dataPath, Paint()..style = PaintingStyle.fill..color = fill);
    canvas.drawPath(
      dataPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = stroke
        ..strokeWidth = 2,
    );

    // Vertices, so a single-point axis is still visible.
    final dot = Paint()..color = stroke;
    for (var i = 0; i < axes.length; i++) {
      final axis = axes[i];
      final max = axis.max == 0 ? 1 : axis.max;
      final ratio = (axis.radarValue / max).clamp(0.0, 1.0);
      canvas.drawCircle(_pointAt(centre, radius * ratio, i, axes.length), 3, dot);
    }

    // Axis labels, clamped inside the canvas so they can never be cut off.
    for (var i = 0; i < axes.length; i++) {
      final axis = axes[i];
      final anchor = _pointAt(centre, radius + 16, i, axes.length);
      final painter = TextPainter(
        text: TextSpan(
          text: axis.displayable ? axis.label : '${axis.label} --',
          style: labelStyle,
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout(maxWidth: 92);
      // `.clamp` is declared on `num` and returns `num`, so the result must be narrowed back to
      // `double` before it can go into an `Offset`. (The analyzer caught this; nothing before it
      // could -- the file had never been compiled.)
      final double dx = (anchor.dx - painter.width / 2)
          .clamp(0.0, math.max(0.0, size.width - painter.width))
          .toDouble();
      final double dy = (anchor.dy - painter.height / 2)
          .clamp(0.0, math.max(0.0, size.height - painter.height))
          .toDouble();
      painter.paint(canvas, Offset(dx, dy));
    }
  }

  /// Axis `index` of `count`, starting at the top and going clockwise.
  Offset _pointAt(Offset centre, double radius, int index, int count) {
    final angle = -math.pi / 2 + 2 * math.pi * index / count;
    return Offset(
      centre.dx + radius * math.cos(angle),
      centre.dy + radius * math.sin(angle),
    );
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.axes != axes ||
      old.stroke != stroke ||
      old.fill != fill ||
      old.labelStyle != labelStyle ||
      old.textScaler != textScaler;
}
