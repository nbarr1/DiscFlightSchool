import 'package:flutter/material.dart';
import 'dart:math';

class RouletteWheel extends StatelessWidget {
  final bool isSpinning;

  const RouletteWheel({Key? key, required this.isSpinning}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 250,
      height: 250,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            Colors.purple.shade700,
            Colors.purple.shade500,
            Colors.purple.shade300,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.purple.withValues(alpha: 0.5),
            blurRadius: 20,
            spreadRadius: 5,
          ),
        ],
      ),
      child: CustomPaint(
        painter: WheelPainter(),
        child: Center(
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 10,
                ),
              ],
            ),
            child: Icon(
              Icons.casino,
              size: 40,
              color: Colors.purple.shade700,
            ),
          ),
        ),
      ),
    );
  }
}

class WheelPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    const sections = 8;

    for (int i = 0; i < sections; i++) {
      // Draw section
      final paint = Paint()
        ..color = i.isEven ? Colors.purple.shade400 : Colors.purple.shade600
        ..style = PaintingStyle.fill;

      final startAngle = (2 * pi / sections) * i;
      final sweepAngle = 2 * pi / sections;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        true,
        paint,
      );

      // Draw dividing lines
      final linePaint = Paint()
        ..color = Colors.white
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;

      final endX = center.dx + radius * cos(startAngle);
      final endY = center.dy + radius * sin(startAngle);
      canvas.drawLine(center, Offset(endX, endY), linePaint);

      // Draw a small dot in the middle of each section
      final midAngle = startAngle + sweepAngle / 2;
      final dotRadius = radius * 0.63;
      final dotX = center.dx + dotRadius * cos(midAngle);
      final dotY = center.dy + dotRadius * sin(midAngle);
      final dotPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(dotX, dotY), 3, dotPaint);
    }
  }

  @override
  bool shouldRepaint(WheelPainter oldDelegate) => false;
}
