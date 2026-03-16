import 'dart:convert';
import 'package:flutter/material.dart';

class FlightPathPainter extends CustomPainter {
  final List<Offset> pathPoints;
  final double animationValue;

  FlightPathPainter(this.pathPoints, {this.animationValue = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    if (pathPoints.isEmpty) return;

    // Scale points to fit canvas
    final scaleX = size.width / _getMaxX();
    final scaleY = size.height / _getMaxY();
    final scale = scaleX < scaleY ? scaleX : scaleY;

    final paint = Paint()
      ..color = Colors.blue
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke;

    final path = Path();
    
    // Scale and draw path
    final scaledPoints = pathPoints.map((p) => Offset(p.dx * scale, p.dy * scale)).toList();
    
    if (scaledPoints.isNotEmpty) {
      path.moveTo(scaledPoints[0].dx, scaledPoints[0].dy);
    }

    int endIndex = (scaledPoints.length * animationValue).round();
    for (int i = 1; i < endIndex && i < scaledPoints.length; i++) {
      path.lineTo(scaledPoints[i].dx, scaledPoints[i].dy);
    }

    canvas.drawPath(path, paint);

    // Draw disc at current position
    if (endIndex > 0 && endIndex <= scaledPoints.length) {
      final discPaint = Paint()
        ..color = Colors.orange
        ..style = PaintingStyle.fill;
      
      final glowPaint = Paint()
        ..color = Colors.orange.withOpacity(0.3)
        ..style = PaintingStyle.fill;
      
      canvas.drawCircle(scaledPoints[endIndex - 1], 12.0, glowPaint);
      canvas.drawCircle(scaledPoints[endIndex - 1], 8.0, discPaint);
    }
  }

  double _getMaxX() {
    if (pathPoints.isEmpty) return 1.0;
    return pathPoints.map((p) => p.dx).reduce((a, b) => a > b ? a : b);
  }

  double _getMaxY() {
    if (pathPoints.isEmpty) return 1.0;
    return pathPoints.map((p) => p.dy).reduce((a, b) => a > b ? a : b);
  }

  @override
  bool shouldRepaint(FlightPathPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue;
  }
}

class FlightPathWidget extends StatefulWidget {
  final String jsonCoordinates;

  const FlightPathWidget({Key? key, required this.jsonCoordinates}) : super(key: key);

  @override
  State<FlightPathWidget> createState() => _FlightPathWidgetState();
}

class _FlightPathWidgetState extends State<FlightPathWidget>
    with SingleTickerProviderStateMixin {
  late List<Offset> pathPoints;
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    pathPoints = _loadPathPoints(widget.jsonCoordinates);
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  List<Offset> _loadPathPoints(String jsonData) {
    try {
      final Map<String, dynamic> data = json.decode(jsonData);
      final List<dynamic> smoothedPath = data['smoothed_path'] ?? data['raw_coordinates'] ?? [];
      
      return smoothedPath.map<Offset>((point) {
        if (point is List && point.length >= 2) {
          return Offset(point[0].toDouble(), point[1].toDouble());
        }
        return Offset.zero;
      }).toList();
    } catch (e) {
      print('Error parsing flight path: $e');
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: FlightPathPainter(pathPoints, animationValue: _controller.value),
          child: Container(),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}