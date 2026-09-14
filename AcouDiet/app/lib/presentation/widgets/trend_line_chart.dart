// app/lib/presentation/widgets/trend_line_chart.dart
//
// `TrendLineChart` -- the seven-day trend of U-04, drawn with a `CustomPainter` (no chart
// package in this build; PLAN-U-06 section 6 designates the self-drawn fallback).
//
// The one rule that matters (SPEC-U-04 section 2.2 step 2): a day without records keeps `null`
// and the line **breaks** there. Interpolating or drawing a zero would be fabricating data, and
// the acceptance criterion counts spots against non-null points. The chart also always carries a
// text equivalent (U-06 section 8).

import 'package:flutter/material.dart';

import '../presenters/report_presenter.dart';
import '../theme/acou_theme.dart';

class TrendLineChart extends StatelessWidget {
  const TrendLineChart({
    super.key,
    required this.data,
    this.height = AcouTheme.chartSize,
  });

  final TrendChartData data;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (!data.hasAnyValue) {
      return Semantics(
        label: '${data.textEquivalent}；本周没有可用数据',
        container: true,
        child: const ExcludeSemantics(
          child: SizedBox(
            height: AcouTheme.chartSize,
            child: Center(child: Text('暂无足够数据', style: AcouTheme.bodyMuted)),
          ),
        ),
      );
    }
    return Semantics(
      label: data.textEquivalent,
      container: true,
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _TrendPainter(
              data: data,
              line: AcouTheme.seed,
              grid: AcouTheme.outline,
            ),
          ),
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.data,
    required this.line,
    required this.grid,
  });

  final TrendChartData data;
  final Color line;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final points = data.points;
    if (points.isEmpty) return;

    const leftInset = 34.0;
    const rightInset = 8.0;
    const topInset = 10.0;
    const bottomInset = 22.0;

    final plot = Rect.fromLTRB(
      leftInset,
      topInset,
      size.width - rightInset,
      size.height - bottomInset,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    final values = points.where((p) => p.hasValue).map((p) => p.value!).toList();
    if (values.isEmpty) return;
    var min = values.reduce((a, b) => a < b ? a : b);
    var max = values.reduce((a, b) => a > b ? a : b);
    if (max - min < 1e-6) {
      // A flat series still needs a band, or the line would sit exactly on the axis.
      min = min - 1;
      max = max + 1;
    }

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;

    // Three horizontal grid lines with their value labels.
    for (var i = 0; i <= 2; i++) {
      final t = i / 2;
      final y = plot.bottom - plot.height * t;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      final value = min + (max - min) * t;
      final tp = TextPainter(
        text: TextSpan(
          text: value.round().toString(),
          style: const TextStyle(fontSize: 10, color: AcouTheme.inkMuted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(2, y - tp.height / 2));
    }
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, axisPaint);

    double xAt(int index) => points.length == 1
        ? plot.center.dx
        : plot.left + plot.width * index / (points.length - 1);
    double yAt(double value) =>
        plot.bottom - plot.height * ((value - min) / (max - min)).clamp(0.0, 1.0);

    final linePaint = Paint()
      ..color = line
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Consecutive non-null points are joined; a null day breaks the polyline (never a zero).
    Path? current;
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      if (!p.hasValue) {
        if (current != null) {
          canvas.drawPath(current, linePaint);
          current = null;
        }
        continue;
      }
      final o = Offset(xAt(i), yAt(p.value!));
      if (current == null) {
        current = Path()..moveTo(o.dx, o.dy);
      } else {
        current.lineTo(o.dx, o.dy);
      }
    }
    if (current != null) canvas.drawPath(current, linePaint);

    // Vertices plus the abscissa labels.
    final dotPaint = Paint()..color = line;
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final tp = TextPainter(
        text: TextSpan(
          text: p.label,
          style: const TextStyle(fontSize: 10, color: AcouTheme.inkMuted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset((xAt(i) - tp.width / 2).clamp(0.0, size.width - tp.width),
            plot.bottom + 4),
      );
      if (!p.hasValue) continue;
      final o = Offset(xAt(i), yAt(p.value!));
      canvas.drawCircle(o, 3, dotPaint);
      // A lone day (a single filled slot) would otherwise be invisible.
      if (points.where((x) => x.hasValue).length == 1) {
        canvas.drawCircle(o, 5, Paint()..color = line..style = PaintingStyle.stroke);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.data != data || old.line != line;
}
