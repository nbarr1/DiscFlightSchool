import 'dart:math';
import 'package:flutter/material.dart';
import '../services/disc_detection_service.dart';

// ---------------------------------------------------------------------------
// WorldAnchorFrame — two fixed background reference points at one video frame
// ---------------------------------------------------------------------------

/// One anchor frame: two fixed background reference points (A and B) recorded
/// at a specific video frame.
///
/// Using two points per frame gives the painter enough information to compute a
/// full 2-D similarity transform (translation + rotation + uniform scale)
/// between any two anchor frames — equivalent to After Effects'
/// "Create Null and Camera" world-lock workflow.
class WorldAnchorFrame {
  final int frameIndex;
  final Offset pointA; // normalized 0–1
  final Offset pointB; // normalized 0–1

  const WorldAnchorFrame({
    required this.frameIndex,
    required this.pointA,
    required this.pointB,
  });
}

// ---------------------------------------------------------------------------
// _SimilarityTransform — 2-D scale + rotation + translation (private)
// ---------------------------------------------------------------------------

class _SimilarityTransform {
  final double scale;
  final double rotation; // radians
  final Offset translation; // normalized units

  const _SimilarityTransform({
    required this.scale,
    required this.rotation,
    required this.translation,
  });

  static const identity = _SimilarityTransform(
    scale: 1.0,
    rotation: 0.0,
    translation: Offset.zero,
  );

  /// Compute the similarity transform that maps the pair (a1, b1) → (a2, b2).
  factory _SimilarityTransform.fromTwoPointPairs(
    Offset a1, Offset b1, // source frame (base)
    Offset a2, Offset b2, // destination frame
  ) {
    final d1 = (b1 - a1).distance;
    final d2 = (b2 - a2).distance;
    if (d1 < 1e-6) return identity;

    final scale = d2 / d1;
    final angle1 = atan2(b1.dy - a1.dy, b1.dx - a1.dx);
    final angle2 = atan2(b2.dy - a2.dy, b2.dx - a2.dx);
    final rotation = angle2 - angle1;

    final c1 = (a1 + b1) / 2;
    final c2 = (a2 + b2) / 2;
    final cosR = cos(rotation);
    final sinR = sin(rotation);
    final rotated = Offset(
      scale * (cosR * c1.dx - sinR * c1.dy),
      scale * (sinR * c1.dx + cosR * c1.dy),
    );
    final translation = c2 - rotated;

    return _SimilarityTransform(
      scale: scale,
      rotation: rotation,
      translation: translation,
    );
  }

  static _SimilarityTransform lerp(
    _SimilarityTransform a,
    _SimilarityTransform b,
    double t,
  ) {
    return _SimilarityTransform(
      scale: a.scale + (b.scale - a.scale) * t,
      rotation: a.rotation + (b.rotation - a.rotation) * t,
      translation: Offset(
        a.translation.dx + (b.translation.dx - a.translation.dx) * t,
        a.translation.dy + (b.translation.dy - a.translation.dy) * t,
      ),
    );
  }

  Offset apply(Offset p, Size size) {
    final cosR = cos(rotation);
    final sinR = sin(rotation);
    final rx = scale * (cosR * p.dx - sinR * p.dy) + translation.dx;
    final ry = scale * (sinR * p.dx + cosR * p.dy) + translation.dy;
    return Offset(rx * size.width, ry * size.height);
  }

  Offset inverse(Offset p) {
    final tx = p.dx - translation.dx;
    final ty = p.dy - translation.dy;
    final cosR = cos(-rotation);
    final sinR = sin(-rotation);
    return Offset(
      (cosR * tx - sinR * ty) / scale,
      (sinR * tx + cosR * ty) / scale,
    );
  }
}

class _TrailPoint {
  final Offset position;
  final int frameIndex;

  const _TrailPoint({
    required this.position,
    required this.frameIndex,
  });
}

// ---------------------------------------------------------------------------
// FollowFlightPainter
// ---------------------------------------------------------------------------

/// Renders a production-quality flight trail overlay on top of a video player.
///
/// The trail is drawn as adjacent stroke segments with a soft glow layer
/// underneath, giving a broadcast-style comet-tail look.
///
/// When [anchorFrames] contains ≥ 2 entries each trail point is world-locked
/// via a 2-D similarity transform, compensating for camera pan, zoom, and
/// rotation so the path stays anchored to the environment — equivalent to the
/// After-Effects "Create Null and Camera" workflow.
class FollowFlightPainter extends CustomPainter {
  final FlightTrackingResult trackingResult;
  final int currentFrame;
  final bool showTrail;
  final bool showCurrentDisc;
  final bool showFullTrail;
  final List<WorldAnchorFrame>? anchorFrames;

  FollowFlightPainter({
    required this.trackingResult,
    required this.currentFrame,
    this.showTrail = true,
    this.showCurrentDisc = true,
    this.showFullTrail = false,
    this.anchorFrames,
  });

  // ---------------------------------------------------------------------------
  // World-lock helpers
  // ---------------------------------------------------------------------------

  _SimilarityTransform _transformAt(int frame) {
    final anchors = anchorFrames;
    if (anchors == null || anchors.length < 2) return _SimilarityTransform.identity;

    final sorted = List<WorldAnchorFrame>.from(anchors)
      ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));
    final base = sorted.first;

    if (frame <= base.frameIndex) return _SimilarityTransform.identity;

    WorldAnchorFrame prev = base;
    WorldAnchorFrame next = sorted.last;
    for (final a in sorted) {
      if (a.frameIndex <= frame) prev = a;
    }
    for (final a in sorted.reversed) {
      if (a.frameIndex >= frame) {
        next = a;
        break;
      }
    }

    final tPrev = _SimilarityTransform.fromTwoPointPairs(
      base.pointA, base.pointB, prev.pointA, prev.pointB,
    );
    if (prev.frameIndex == next.frameIndex) return tPrev;

    final tNext = _SimilarityTransform.fromTwoPointPairs(
      base.pointA, base.pointB, next.pointA, next.pointB,
    );
    final t = (frame - prev.frameIndex) / (next.frameIndex - prev.frameIndex);
    return _SimilarityTransform.lerp(tPrev, tNext, t.clamp(0.0, 1.0));
  }

  Offset _toCanvas(DiscDetection d, Size size) {
    if (anchorFrames == null || anchorFrames!.length < 2) {
      return Offset(d.x * size.width, d.y * size.height);
    }
    final tRec = _transformAt(d.frameIndex);
    final tCur = _transformAt(currentFrame);
    final pWorld = tRec.inverse(Offset(d.x, d.y));
    return tCur.apply(pWorld, size);
  }

  // ---------------------------------------------------------------------------
  // Paint
  // ---------------------------------------------------------------------------

  @override
  void paint(Canvas canvas, Size size) {
    final allDetections = showFullTrail
        ? trackingResult.detections
        : trackingResult.detectionsUpToFrame(currentFrame);
    if (allDetections.isEmpty) return;

    final trailPoints = allDetections
        .map((d) => _TrailPoint(
              position: _toCanvas(d, size),
              frameIndex: d.frameIndex,
            ))
        .toList();

    if (showTrail && trailPoints.length >= 2) {
      _drawTrail(canvas, trailPoints);
    }

    if (showCurrentDisc) {
      _drawCurrentDisc(canvas, size);
    }
  }

  // ---------------------------------------------------------------------------
  // Trail — segmented strokes with age-based glow
  // ---------------------------------------------------------------------------

  void _drawTrail(Canvas canvas, List<_TrailPoint> points) {
    final oldestFrame = points
        .where((p) => p.frameIndex <= currentFrame)
        .fold<int?>(null, (oldest, p) {
      if (oldest == null || p.frameIndex < oldest) return p.frameIndex;
      return oldest;
    }) ?? points.first.frameIndex;
    final ageSpan = max(1, currentFrame - oldestFrame);

    for (int i = 0; i < points.length - 1; i++) {
      final start = points[i];
      final end = points[i + 1];
      final path = Path()
        ..moveTo(start.position.dx, start.position.dy)
        ..lineTo(end.position.dx, end.position.dy);

      final pathPosition = i / max(1, points.length - 2);
      final color = _trailColorAt(pathPosition);
      final segmentFrame = max(start.frameIndex, end.frameIndex);
      final opacity = _segmentOpacity(segmentFrame, oldestFrame, ageSpan);

      // Glow layer — wide, blurred, lower-alpha version of the same age fade.
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withAlpha(
            (55 * opacity).round().clamp(0, 255).toInt(),
          )
          ..strokeWidth = 14.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );

      // Main line — sharp, high-alpha version of the same age fade.
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withAlpha(
            (230 * opacity).round().clamp(0, 255).toInt(),
          )
          ..strokeWidth = 3.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  double _segmentOpacity(int segmentFrame, int oldestFrame, int ageSpan) {
    const minOpacity = 0.10;
    if (segmentFrame >= currentFrame) return 1.0;

    final recency = ((segmentFrame - oldestFrame) / ageSpan).clamp(0.0, 1.0);
    return minOpacity + ((1.0 - minOpacity) * recency);
  }

  Color _trailColorAt(double t) {
    final hue = t < 0.5
        ? 120.0 + ((60.0 - 120.0) * (t / 0.5))
        : 60.0 + ((0.0 - 60.0) * ((t - 0.5) / 0.5));
    return HSLColor.fromAHSL(1.0, hue, 0.9, 0.5).toColor();
  }

  // ---------------------------------------------------------------------------
  // Current disc indicator
  // ---------------------------------------------------------------------------

  void _drawCurrentDisc(Canvas canvas, Size size) {
    final detection = trackingResult.detectionAtFrame(currentFrame);
    if (detection == null) return;
    final c = Offset(detection.x * size.width, detection.y * size.height);

    // Soft outer glow
    canvas.drawCircle(
      c,
      16,
      Paint()
        ..color = Colors.white.withAlpha(28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    // White ring
    canvas.drawCircle(
      c,
      8,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // Solid center dot
    canvas.drawCircle(c, 3, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(FollowFlightPainter oldDelegate) {
    return oldDelegate.currentFrame != currentFrame ||
        oldDelegate.showTrail != showTrail ||
        oldDelegate.showFullTrail != showFullTrail ||
        oldDelegate.anchorFrames != anchorFrames;
  }
}
