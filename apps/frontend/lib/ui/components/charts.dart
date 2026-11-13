import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/expense.dart';
import '../theme.dart';

class SpendingSparkline extends StatelessWidget {
  const SpendingSparkline(this.values, {super.key, this.height = 68});
  final List<int> values;
  final double height;
  @override
  Widget build(BuildContext context) => SizedBox(height: height, width: double.infinity,
      child: CustomPaint(painter: _SparkPainter(values)));
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values);
  final List<int> values;
  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var total = 0;
    final cumulative = values.map((value) => total += value).toList();
    final maximum = cumulative.fold<int>(1, (value, next) => value > next ? value : next);
    final path = Path();
    for (var index = 0; index < cumulative.length; index++) {
      final x = size.width * index / (cumulative.length - 1);
      final y = size.height - 6 - cumulative[index] / maximum * (size.height - 16);
      if (index == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
    }
    final area = Path.from(path)..lineTo(size.width, size.height)..lineTo(0, size.height)..close();
    canvas.drawPath(area, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [PocketColors.green.withAlpha(36), PocketColors.green.withAlpha(0)]).createShader(Offset.zero & size));
    canvas.drawPath(path, Paint()..color = PocketColors.green..strokeWidth = 2.3
      ..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round..style = PaintingStyle.stroke);
  }
  @override
  bool shouldRepaint(covariant _SparkPainter oldDelegate) => true;
}

class CategoryRing extends StatelessWidget {
  const CategoryRing(this.values, {super.key, this.size = 148, this.center});
  final Map<ExpenseCategory, int> values;
  final double size;
  final Widget? center;
  @override
  Widget build(BuildContext context) => SizedBox(width: size, height: size,
    child: Stack(alignment: Alignment.center, children: [
      Positioned.fill(child: CustomPaint(painter: _RingPainter(values))),
      ?center,
    ]),
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.values);
  final Map<ExpenseCategory, int> values;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(10, 10, size.width - 20, size.height - 20);
    final paint = Paint()..style = PaintingStyle.stroke..strokeWidth = 13..strokeCap = StrokeCap.butt;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = PocketColors.line);
    final total = values.values.fold(0, (sum, value) => sum + value);
    if (total <= 0) return;
    var start = -math.pi / 2;
    for (final entry in values.entries) {
      if (entry.value <= 0) continue;
      final sweep = entry.value / total * math.pi * 2;
      canvas.drawArc(rect, start + .025, math.max(0.0, sweep - .05), false, paint..color = entry.key.color);
      start += sweep;
    }
  }
  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) => true;
}
