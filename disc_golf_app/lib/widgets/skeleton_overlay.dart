import 'package:flutter/material.dart';
import 'dart:math';
import '../models/form_analysis.dart';

class SkeletonOverlay extends CustomPainter {
  final FormAnalysis analysis;
  final int currentFrame;

  SkeletonOverlay({
    required this.analysis,
    required this.currentFrame,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (analysis.frames.isEmpty) return;

    // Clamp to valid frame index
    final frameIndex = currentFrame.clamp(0, analysis.frames.length - 1);
    final frame = analysis.frames[frameIndex];

    if (frame.keyPoints.isEmpty) return;

    // Draw skeleton connections
    _drawSkeleton(canvas, size, frame);

    // Draw joints
    for (var entry in frame.keyPoints.entries) {
      final point = entry.value;
      // Scale keypoints to canvas size
      final scaledPoint = _scalePoint(point, size);

      final paint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.fill;

      canvas.drawCircle(scaledPoint, 6, paint);

      // Draw joint name label
      final textPainter = TextPainter(
        text: TextSpan(
          text: _formatJointName(entry.key),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 9,
            backgroundColor: Colors.black54,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, scaledPoint + const Offset(8, -5));
    }

    // Draw angle annotations
    _drawAngles(canvas, size, frame);
  }

  Offset _scalePoint(Offset point, Size size) {
    // If points are in pixel coordinates (>1.0), scale them down to canvas
    // If points are normalized (0-1), scale them up to canvas
    if (point.dx > 1.0 || point.dy > 1.0) {
      // Assume points are in video pixel coords; scale to canvas
      // Use a reference resolution of 640x480 (common frame extraction size)
      return Offset(
        point.dx * size.width / 640,
        point.dy * size.height / 480,
      );
    } else {
      return Offset(point.dx * size.width, point.dy * size.height);
    }
  }

  void _drawSkeleton(Canvas canvas, Size size, FormFrame frame) {
    final connections = [
      ['PoseLandmarkType.leftShoulder', 'PoseLandmarkType.rightShoulder'],
      ['PoseLandmarkType.leftShoulder', 'PoseLandmarkType.leftElbow'],
      ['PoseLandmarkType.leftElbow', 'PoseLandmarkType.leftWrist'],
      ['PoseLandmarkType.rightShoulder', 'PoseLandmarkType.rightElbow'],
      ['PoseLandmarkType.rightElbow', 'PoseLandmarkType.rightWrist'],
      ['PoseLandmarkType.leftShoulder', 'PoseLandmarkType.leftHip'],
      ['PoseLandmarkType.rightShoulder', 'PoseLandmarkType.rightHip'],
      ['PoseLandmarkType.leftHip', 'PoseLandmarkType.rightHip'],
      ['PoseLandmarkType.leftHip', 'PoseLandmarkType.leftKnee'],
      ['PoseLandmarkType.leftKnee', 'PoseLandmarkType.leftAnkle'],
      ['PoseLandmarkType.rightHip', 'PoseLandmarkType.rightKnee'],
      ['PoseLandmarkType.rightKnee', 'PoseLandmarkType.rightAnkle'],
    ];

    final paint = Paint()
      ..color = Colors.cyan
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    for (var connection in connections) {
      final p1 = frame.keyPoints[connection[0]];
      final p2 = frame.keyPoints[connection[1]];

      if (p1 != null && p2 != null) {
        canvas.drawLine(
          _scalePoint(p1, size),
          _scalePoint(p2, size),
          paint,
        );
      }
    }
  }

  void _drawAngles(Canvas canvas, Size size, FormFrame frame) {
    if (frame.angles.isEmpty) return;

    double yOffset = 20;
    for (var entry in frame.angles.entries) {
      final angleName = _formatAngleName(entry.key);
      final angleValue = entry.value;

      // Color based on how close to ideal
      final color = _getAngleColor(entry.key, angleValue);

      final textPainter = TextPainter(
        text: TextSpan(
          text: ' $angleName: ${angleValue.toStringAsFixed(1)}° ',
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.bold,
            backgroundColor: Colors.black87,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(8, yOffset));
      yOffset += 20;
    }

    // Draw angle arcs at joint locations
    _drawAngleArcs(canvas, size, frame);
  }

  void _drawAngleArcs(Canvas canvas, Size size, FormFrame frame) {
    final arcPaint = Paint()
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    // Draw arc at right elbow
    _drawArcAtJoint(
      canvas, size, frame,
      'PoseLandmarkType.rightShoulder',
      'PoseLandmarkType.rightElbow',
      'PoseLandmarkType.rightWrist',
      frame.angles['rightElbowAngle'],
      arcPaint,
    );

    // Draw arc at left elbow
    _drawArcAtJoint(
      canvas, size, frame,
      'PoseLandmarkType.leftShoulder',
      'PoseLandmarkType.leftElbow',
      'PoseLandmarkType.leftWrist',
      frame.angles['leftElbowAngle'],
      arcPaint,
    );

    // Draw arc at right shoulder
    _drawArcAtJoint(
      canvas, size, frame,
      'PoseLandmarkType.rightElbow',
      'PoseLandmarkType.rightShoulder',
      'PoseLandmarkType.rightHip',
      frame.angles['rightShoulderAngle'],
      arcPaint,
    );

    // Draw arc at right knee
    _drawArcAtJoint(
      canvas, size, frame,
      'PoseLandmarkType.rightHip',
      'PoseLandmarkType.rightKnee',
      'PoseLandmarkType.rightAnkle',
      frame.angles['rightKneeAngle'],
      arcPaint,
    );
  }

  void _drawArcAtJoint(
    Canvas canvas,
    Size size,
    FormFrame frame,
    String p1Key,
    String vertexKey,
    String p3Key,
    double? angle,
    Paint paint,
  ) {
    if (angle == null) return;

    final p1 = frame.keyPoints[p1Key];
    final vertex = frame.keyPoints[vertexKey];
    final p3 = frame.keyPoints[p3Key];

    if (p1 == null || vertex == null || p3 == null) return;

    final scaledVertex = _scalePoint(vertex, size);
    final scaledP1 = _scalePoint(p1, size);
    final scaledP3 = _scalePoint(p3, size);

    // Calculate angles for arc
    final startAngle = atan2(
      scaledP1.dy - scaledVertex.dy,
      scaledP1.dx - scaledVertex.dx,
    );
    final endAngle = atan2(
      scaledP3.dy - scaledVertex.dy,
      scaledP3.dx - scaledVertex.dx,
    );

    final color = _getAngleColor('', angle);
    paint.color = color.withAlpha(180);

    const arcRadius = 20.0;
    canvas.drawArc(
      Rect.fromCircle(center: scaledVertex, radius: arcRadius),
      startAngle,
      endAngle - startAngle,
      false,
      paint,
    );

    // Draw angle value near the arc
    final labelOffset = Offset(
      scaledVertex.dx + arcRadius * cos((startAngle + endAngle) / 2) + 5,
      scaledVertex.dy + arcRadius * sin((startAngle + endAngle) / 2) - 5,
    );

    final textPainter = TextPainter(
      text: TextSpan(
        text: '${angle.toStringAsFixed(0)}°',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, labelOffset);
  }

  Color _getAngleColor(String angleName, double angle) {
    // Ideal angles for disc golf form
    final idealAngles = {
      'rightElbowAngle': 120.0,
      'leftElbowAngle': 140.0,
      'rightShoulderAngle': 100.0,
      'leftShoulderAngle': 100.0,
      'rightKneeAngle': 160.0,
      'leftKneeAngle': 160.0,
      'spineAngle': 85.0,
    };

    final ideal = idealAngles[angleName];
    if (ideal == null) return Colors.yellow;

    final diff = (angle - ideal).abs();
    if (diff < 10) return Colors.green;
    if (diff < 25) return Colors.orange;
    return Colors.red;
  }

  String _formatAngleName(String name) {
    return name
        .replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(0)}')
        .replaceFirst(name[0], name[0].toUpperCase())
        .trim();
  }

  String _formatJointName(String name) {
    // Convert PoseLandmarkType.leftShoulder -> L Shoulder
    final cleaned = name.replaceAll('PoseLandmarkType.', '');
    if (cleaned.startsWith('left')) {
      return 'L ${cleaned.substring(4)}';
    } else if (cleaned.startsWith('right')) {
      return 'R ${cleaned.substring(5)}';
    }
    return cleaned;
  }

  @override
  bool shouldRepaint(SkeletonOverlay oldDelegate) {
    return oldDelegate.currentFrame != currentFrame;
  }
}
