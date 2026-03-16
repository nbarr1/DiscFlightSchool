import 'package:flutter/material.dart';

class FlightPathPainter extends CustomPainter {
  final List<Offset> points;

  FlightPathPainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    // Draw path line
    final pathPaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    final path = Path();
    
    if (points.isNotEmpty) {
      path.moveTo(points.first.dx, points.first.dy);
      for (var i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
    }

    canvas.drawPath(path, pathPaint);

    // Draw points
    final pointPaint = Paint()
      ..color = Colors.yellow
      ..style = PaintingStyle.fill;

    for (var point in points) {
      canvas.drawCircle(point, 5, pointPaint);
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