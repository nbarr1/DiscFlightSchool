import 'package:flutter/material.dart';
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

    // Find the frame closest to current frame
    PoseFrame? frame;
    for (var f in analysis.frames) {
      if (f.frameNumber == currentFrame) {
        frame = f;
        break;
      }
    }

    if (frame == null) return;

    // Draw skeleton connections
    _drawSkeleton(canvas, frame);

    // Draw joints
    for (var joint in frame.joints) {
      final paint = Paint()
        ..color = _getJointColor(joint.confidence)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(
        Offset(joint.x, joint.y),
        8,
        paint,
      );

      // Draw joint name
      final textPainter = TextPainter(
        text: TextSpan(
          text: joint.name,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            backgroundColor: Colors.black54,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(joint.x + 10, joint.y - 5),
      );
    }

    // Draw angles
    _drawAngles(canvas, frame);
  }

  void _drawSkeleton(Canvas canvas, PoseFrame frame) {
    final connections = [
      ['leftShoulder', 'rightShoulder'],
      ['leftShoulder', 'leftElbow'],
      ['leftElbow', 'leftWrist'],
      ['rightShoulder', 'rightElbow'],
      ['rightElbow', 'rightWrist'],
      ['leftShoulder', 'leftHip'],
      ['rightShoulder', 'rightHip'],
      ['leftHip', 'rightHip'],
      ['leftHip', 'leftKnee'],
      ['leftKnee', 'leftAnkle'],
      ['rightHip', 'rightKnee'],
      ['rightKnee', 'rightAnkle'],
    ];

    final paint = Paint()
      ..color = Colors.cyan
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    for (var connection in connections) {
      final joint1 = frame.joints.where((j) => j.name == connection[0]).firstOrNull;
      final joint2 = frame.joints.where((j) => j.name == connection[1]).firstOrNull;

      if (joint1 != null && joint2 != null) {
        canvas.drawLine(
          Offset(joint1.x, joint1.y),
          Offset(joint2.x, joint2.y),
          paint,
        );
      }
    }
  }

  void _drawAngles(Canvas canvas, PoseFrame frame) {
    double yOffset = 30;
    frame.angles.forEach((angleName, angleValue) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: '$angleName: ${angleValue.toStringAsFixed(1)}°',
          style: const TextStyle(
            color: Colors.yellow,
            fontSize: 14,
            fontWeight: FontWeight.bold,
            backgroundColor: Colors.black87,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(10, yOffset));
      yOffset += 20;
    });
  }

  Color _getJointColor(double confidence) {
    if (confidence > 0.8) return Colors.green;
    if (confidence > 0.5) return Colors.yellow;
    return Colors.red;
  }

  @override
  bool shouldRepaint(SkeletonOverlay oldDelegate) {
    return oldDelegate.currentFrame != currentFrame;
  }
}