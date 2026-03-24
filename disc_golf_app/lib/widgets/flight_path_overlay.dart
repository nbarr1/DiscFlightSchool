import 'package:flutter/material.dart';

class FlightPathPainter extends CustomPainter {
  final List<Offset> points;

  FlightPathPainter({required this.points});

  /// Returns a gradient color from green (start) through yellow to red (end).
  Color _gradientColor(int index, int total) {
    if (total <= 0) return Colors.green;
    final hue = 120.0 * (1.0 - index / total); // green(120) → red(0)
    return HSLColor.fromAHSL(1.0, hue, 0.9, 0.5).toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final totalSegments = points.length - 1;

    // Draw per-segment gradient path
    for (int i = 1; i < points.length; i++) {
      final segPaint = Paint()
        ..color = _gradientColor(i - 1, totalSegments)
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(points[i - 1], points[i], segPaint);
    }

    // Draw start point (green)
    if (points.isNotEmpty) {
      final startPaint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.fill;
      canvas.drawCircle(points.first, 8, startPaint);
    }

    // Draw end point (red)
    if (points.length > 1) {
      final endPaint = Paint()
        ..color = Colors.red
        ..style = PaintingStyle.fill;
      canvas.drawCircle(points.last, 8, endPaint);
    }
  }

  @override
  bool shouldRepaint(covariant FlightPathPainter oldDelegate) {
    return oldDelegate.points != points;
  }
}