import 'package:flutter/material.dart';
import '../models/form_analysis.dart';

/// Clean skeleton overlay — color-coded limbs, minimal labels.
class SkeletonOverlay extends CustomPainter {
  final FormAnalysis analysis;
  final int currentFrame;

  SkeletonOverlay({
    required this.analysis,
    required this.currentFrame,
  });

  // Ideal angles for disc golf form
  static const _idealAngles = {
    'rightElbowAngle': 120.0,
    'leftElbowAngle': 140.0,
    'rightShoulderAngle': 100.0,
    'leftShoulderAngle': 100.0,
    'rightKneeAngle': 160.0,
    'leftKneeAngle': 160.0,
    'spineAngle': 85.0,
  };

  @override
  void paint(Canvas canvas, Size size) {
    if (analysis.frames.isEmpty) return;

    final frameIndex = currentFrame.clamp(0, analysis.frames.length - 1);
    final frame = analysis.frames[frameIndex];

    if (frame.keyPoints.isEmpty) return;

    // Draw color-coded skeleton limbs
    _drawSkeleton(canvas, size, frame);

    // Draw small joint dots
    _drawJoints(canvas, size, frame);

    // Show angle values at key joints only (elbow, shoulder, knee)
    _drawKeyAngleLabels(canvas, size, frame);
  }

  Offset _scalePoint(Offset point, Size canvasSize, FormFrame frame) {
    final imgW = frame.imageWidth;
    final imgH = frame.imageHeight;

    if (imgW != null && imgH != null && imgW > 0 && imgH > 0) {
      // Scale from image pixel coordinates to canvas
      return Offset(
        point.dx * canvasSize.width / imgW,
        point.dy * canvasSize.height / imgH,
      );
    }

    // Fallback: if coordinates are normalized (0-1), scale to canvas
    if (point.dx <= 1.0 && point.dy <= 1.0) {
      return Offset(point.dx * canvasSize.width, point.dy * canvasSize.height);
    }

    // Fallback: assume 640-wide frame
    return Offset(
      point.dx * canvasSize.width / 640,
      point.dy * canvasSize.height / 640,
    );
  }

  void _drawSkeleton(Canvas canvas, Size size, FormFrame frame) {
    // Limb groups with their associated angle for color-coding
    const limbGroups = [
      _LimbGroup(
        joints: [
          ['PoseLandmarkType.rightShoulder', 'PoseLandmarkType.rightElbow'],
          ['PoseLandmarkType.rightElbow', 'PoseLandmarkType.rightWrist'],
        ],
        angleKey: 'rightElbowAngle',
      ),
      _LimbGroup(
        joints: [
          ['PoseLandmarkType.leftShoulder', 'PoseLandmarkType.leftElbow'],
          ['PoseLandmarkType.leftElbow', 'PoseLandmarkType.leftWrist'],
        ],
        angleKey: 'leftElbowAngle',
      ),
      _LimbGroup(
        joints: [
          ['PoseLandmarkType.rightHip', 'PoseLandmarkType.rightKnee'],
          ['PoseLandmarkType.rightKnee', 'PoseLandmarkType.rightAnkle'],
        ],
        angleKey: 'rightKneeAngle',
      ),
      _LimbGroup(
        joints: [
          ['PoseLandmarkType.leftHip', 'PoseLandmarkType.leftKnee'],
          ['PoseLandmarkType.leftKnee', 'PoseLandmarkType.leftAnkle'],
        ],
        angleKey: 'leftKneeAngle',
      ),
      _LimbGroup(
        joints: [
          ['PoseLandmarkType.leftShoulder', 'PoseLandmarkType.rightShoulder'],
          ['PoseLandmarkType.leftShoulder', 'PoseLandmarkType.leftHip'],
          ['PoseLandmarkType.rightShoulder', 'PoseLandmarkType.rightHip'],
          ['PoseLandmarkType.leftHip', 'PoseLandmarkType.rightHip'],
        ],
        angleKey: 'spineAngle',
      ),
    ];

    for (final group in limbGroups) {
      final angle = frame.angles[group.angleKey];
      final color = _getAngleColor(group.angleKey, angle);

      final paint = Paint()
        ..color = color.withAlpha(200)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      for (final pair in group.joints) {
        final p1 = frame.keyPoints[pair[0]];
        final p2 = frame.keyPoints[pair[1]];
        if (p1 != null && p2 != null) {
          canvas.drawLine(
            _scalePoint(p1, size, frame),
            _scalePoint(p2, size, frame),
            paint,
          );
        }
      }
    }
  }

  void _drawJoints(Canvas canvas, Size size, FormFrame frame) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.black.withAlpha(120)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (final point in frame.keyPoints.values) {
      final scaled = _scalePoint(point, size, frame);
      canvas.drawCircle(scaled, 3.5, paint);
      canvas.drawCircle(scaled, 3.5, borderPaint);
    }
  }

  /// Show angle labels at 3 key joints only: throwing elbow, shoulder, lead knee.
  void _drawKeyAngleLabels(Canvas canvas, Size size, FormFrame frame) {
    const labels = [
      _AngleLabel(
        vertexKey: 'PoseLandmarkType.rightElbow',
        angleKey: 'rightElbowAngle',
        offset: Offset(10, -14),
      ),
      _AngleLabel(
        vertexKey: 'PoseLandmarkType.rightShoulder',
        angleKey: 'rightShoulderAngle',
        offset: Offset(10, -14),
      ),
      _AngleLabel(
        vertexKey: 'PoseLandmarkType.rightKnee',
        angleKey: 'rightKneeAngle',
        offset: Offset(10, -14),
      ),
    ];

    for (final label in labels) {
      final vertex = frame.keyPoints[label.vertexKey];
      final angle = frame.angles[label.angleKey];
      if (vertex == null || angle == null) continue;

      final pos = _scalePoint(vertex, size, frame) + label.offset;
      final color = _getAngleColor(label.angleKey, angle);

      // Draw pill background
      final text = '${angle.toStringAsFixed(0)}°';
      final textPainter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();

      final pillRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          pos.dx - 3,
          pos.dy - 1,
          textPainter.width + 6,
          textPainter.height + 2,
        ),
        const Radius.circular(4),
      );

      canvas.drawRRect(
        pillRect,
        Paint()..color = Colors.black.withAlpha(180),
      );

      textPainter.paint(canvas, pos);
    }
  }

  Color _getAngleColor(String angleKey, double? angle) {
    if (angle == null) return Colors.grey;

    final ideal = _idealAngles[angleKey];
    if (ideal == null) return Colors.cyan;

    final diff = (angle - ideal).abs();
    if (diff < 10) return Colors.green;
    if (diff < 25) return Colors.orange;
    return Colors.red;
  }

  @override
  bool shouldRepaint(SkeletonOverlay oldDelegate) {
    return oldDelegate.currentFrame != currentFrame;
  }
}

class _LimbGroup {
  final List<List<String>> joints;
  final String angleKey;

  const _LimbGroup({required this.joints, required this.angleKey});
}

class _AngleLabel {
  final String vertexKey;
  final String angleKey;
  final Offset offset;

  const _AngleLabel({
    required this.vertexKey,
    required this.angleKey,
    required this.offset,
  });
}
