import 'package:flutter/material.dart';
import '../models/form_analysis.dart';

/// Clean skeleton overlay — color-coded limbs, minimal labels.
/// In interactive mode, adjustable joints are highlighted for drag-to-correct,
/// and their border color reflects ML Kit detection confidence:
///   cyan   → confident (≥ 0.7)
///   orange → uncertain (0.5–0.7)
///   red    → unreliable (< 0.5) or unknown
class SkeletonOverlay extends CustomPainter {
  final FormAnalysis analysis;
  final int currentFrame;
  final bool interactive;
  final String? selectedLandmark;
  final Set<int>? correctedFrames;

  /// The 12 landmarks that can be manually adjusted in correction mode.
  static const adjustableLandmarks = [
    'PoseLandmarkType.rightShoulder',
    'PoseLandmarkType.leftShoulder',
    'PoseLandmarkType.rightElbow',
    'PoseLandmarkType.leftElbow',
    'PoseLandmarkType.rightWrist',
    'PoseLandmarkType.leftWrist',
    'PoseLandmarkType.rightHip',
    'PoseLandmarkType.leftHip',
    'PoseLandmarkType.rightKnee',
    'PoseLandmarkType.leftKnee',
    'PoseLandmarkType.rightAnkle',
    'PoseLandmarkType.leftAnkle',
  ];

  SkeletonOverlay({
    required this.analysis,
    required this.currentFrame,
    this.interactive = false,
    this.selectedLandmark,
    this.correctedFrames,
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

    _drawSkeleton(canvas, size, frame);
    _drawJoints(canvas, size, frame);
    _drawKeyAngleLabels(canvas, size, frame);
  }

  Offset _scalePoint(Offset point, Size canvasSize, FormFrame frame) {
    final imgW = frame.imageWidth;
    final imgH = frame.imageHeight;

    if (imgW != null && imgH != null && imgW > 0 && imgH > 0) {
      return Offset(
        point.dx * canvasSize.width / imgW,
        point.dy * canvasSize.height / imgH,
      );
    }

    if (point.dx <= 1.0 && point.dy <= 1.0) {
      return Offset(point.dx * canvasSize.width, point.dy * canvasSize.height);
    }

    return Offset(
      point.dx * canvasSize.width / 640,
      point.dy * canvasSize.height / 640,
    );
  }

  void _drawSkeleton(Canvas canvas, Size size, FormFrame frame) {
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
    final defaultPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.black.withAlpha(120)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (final entry in frame.keyPoints.entries) {
      final scaled = _scalePoint(entry.value, size, frame);

      if (interactive && adjustableLandmarks.contains(entry.key)) {
        if (entry.key == selectedLandmark) {
          // Selected joint — yellow with halo
          canvas.drawCircle(
              scaled, 12, Paint()..color = Colors.yellow.withAlpha(60));
          canvas.drawCircle(scaled, 8, Paint()..color = Colors.yellow);
          canvas.drawCircle(
              scaled,
              8,
              Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2);
        } else {
          // Adjustable but not selected — border color reflects confidence
          final borderColor = _getConfidenceColor(
              entry.key, frame.landmarkConf);
          canvas.drawCircle(scaled, 6, Paint()..color = Colors.white);
          canvas.drawCircle(
              scaled,
              6,
              Paint()
                ..color = borderColor
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2);
        }
      } else {
        // Non-interactive joint dot
        canvas.drawCircle(scaled, 3.5, defaultPaint);
        canvas.drawCircle(scaled, 3.5, borderPaint);
      }
    }
  }

  /// Returns the confidence-indicating border color for an interactive joint.
  ///   cyan   → high confidence (≥ 0.7)
  ///   orange → medium confidence (0.5 – 0.7)
  ///   red    → low confidence (< 0.5) or no data (manually corrected = trusted)
  Color _getConfidenceColor(String key, Map<String, double> conf) {
    // Manually corrected frames have empty landmarkConf — treat as trusted.
    if (conf.isEmpty) return Colors.cyanAccent;
    final c = conf[key];
    if (c == null) return Colors.redAccent;
    if (c >= 0.7) return Colors.cyanAccent;
    if (c >= 0.5) return Colors.orange;
    return Colors.redAccent;
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
    return oldDelegate.currentFrame != currentFrame ||
        oldDelegate.selectedLandmark != selectedLandmark ||
        oldDelegate.interactive != interactive;
  }

  /// Find the nearest adjustable landmark to a canvas-space tap point.
  /// Returns the landmark key, or null if none within [threshold] pixels.
  static String? nearestLandmark(
    Offset tapPoint,
    Size canvasSize,
    FormFrame frame, {
    double threshold = 30.0,
  }) {
    String? closest;
    double closestDist = threshold;

    for (final key in adjustableLandmarks) {
      final point = frame.keyPoints[key];
      if (point == null) continue;

      final imgW = frame.imageWidth;
      final imgH = frame.imageHeight;
      Offset scaled;
      if (imgW != null && imgH != null && imgW > 0 && imgH > 0) {
        scaled = Offset(
          point.dx * canvasSize.width / imgW,
          point.dy * canvasSize.height / imgH,
        );
      } else if (point.dx <= 1.0 && point.dy <= 1.0) {
        scaled = Offset(
            point.dx * canvasSize.width, point.dy * canvasSize.height);
      } else {
        scaled = Offset(
          point.dx * canvasSize.width / 640,
          point.dy * canvasSize.height / 640,
        );
      }

      final dist = (scaled - tapPoint).distance;
      if (dist < closestDist) {
        closestDist = dist;
        closest = key;
      }
    }

    return closest;
  }

  /// Convert canvas-space coordinates back to image pixel coordinates.
  static Offset canvasToImage(
      Offset canvasPoint, Size canvasSize, FormFrame frame) {
    final imgW = frame.imageWidth;
    final imgH = frame.imageHeight;
    if (imgW != null && imgH != null && imgW > 0 && imgH > 0) {
      return Offset(
        canvasPoint.dx * imgW / canvasSize.width,
        canvasPoint.dy * imgH / canvasSize.height,
      );
    }
    return Offset(
      canvasPoint.dx / canvasSize.width,
      canvasPoint.dy / canvasSize.height,
    );
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
