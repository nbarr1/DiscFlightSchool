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

    // centroid2 = scale * R(rotation) * centroid1 + t  →  solve for t
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

  /// Linear interpolation between two transforms.
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

  /// Apply this transform to a normalized point, returning canvas pixels.
  Offset apply(Offset p, Size size) {
    final cosR = cos(rotation);
    final sinR = sin(rotation);
    final rx = scale * (cosR * p.dx - sinR * p.dy) + translation.dx;
    final ry = scale * (sinR * p.dx + cosR * p.dy) + translation.dy;
    return Offset(rx * size.width, ry * size.height);
  }

  /// Inverse transform: normalized screen coords → normalized world coords.
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

// ---------------------------------------------------------------------------
// FollowFlightPainter
// ---------------------------------------------------------------------------

/// Renders a follow-flight overlay on top of a video player.
///
/// When [anchorFrames] contains ≥ 2 entries, each trail point is world-locked
/// via a 2-D similarity transform computed from the two fixed background
/// reference points per anchor frame.  This compensates for camera pan, zoom,
/// and rotation so the trail stays anchored to the environment — equivalent to
/// the After-Effects "Create Null and Camera" workflow.
class FollowFlightPainter extends CustomPainter {
  final FlightTrackingResult trackingResult;
  final int currentFrame;
  final bool showTrail;
  final bool showCurrentDisc;
  final int trailFadeFrames;
  final bool showFullTrail;

  /// World anchor frames.  Requires ≥ 2 entries to enable compensation.
  final List<WorldAnchorFrame>? anchorFrames;

  FollowFlightPainter({
    required this.trackingResult,
    required this.currentFrame,
    this.showTrail = true,
    this.showCurrentDisc = true,
    this.trailFadeFrames = 30,
    this.showFullTrail = false,
    this.anchorFrames,
  });

  // ---------------------------------------------------------------------------
  // World-lock helpers
  // ---------------------------------------------------------------------------

  /// Returns the similarity transform at [frame] relative to the earliest
  /// anchor frame (the world origin).  Transforms are linearly interpolated
  /// between anchor frames; frames outside the range clamp to nearest.
  _SimilarityTransform _transformAt(int frame) {
    final anchors = anchorFrames;
    if (anchors == null || anchors.length < 2) return _SimilarityTransform.identity;

    final sorted = List<WorldAnchorFrame>.from(anchors)
      ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));
    final base = sorted.first;

    // Identity at or before the base frame
    if (frame <= base.frameIndex) return _SimilarityTransform.identity;

    // Find surrounding anchor frames
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

  /// Converts a [DiscDetection] to a world-locked canvas pixel position.
  ///
  ///   p_world = T_rec⁻¹(p_screen_at_rec)
  ///   p_draw  = T_current(p_world) × size
  ///
  /// When no anchor frames are set, falls back to simple normalized→pixel scaling.
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
    final allDetections = trackingResult.detectionsUpToFrame(currentFrame);
    if (allDetections.isEmpty) return;

    final scaledTrail = allDetections.map((d) => _toCanvas(d, size)).toList();

    if (showTrail && scaledTrail.length >= 2) {
      _drawFadingTrail(canvas, scaledTrail, allDetections);
    }

    if (showCurrentDisc) {
      _drawCurrentDisc(canvas, size);
    }

    if (scaledTrail.isNotEmpty && allDetections.isNotEmpty) {
      if (showFullTrail) {
        _drawStartMarker(canvas, scaledTrail.first, 1.0);
      } else {
        final startAge = currentFrame - allDetections.first.frameIndex;
        if (startAge <= trailFadeFrames) {
          _drawStartMarker(
              canvas, scaledTrail.first, 1.0 - (startAge / trailFadeFrames));
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Colour gradient: green → yellow → red
  // ---------------------------------------------------------------------------

  Color _gradientColor(int index, int total) {
    if (total <= 0) return Colors.green;
    final hue = 120.0 * (1.0 - index / total);
    return HSLColor.fromAHSL(1.0, hue, 0.9, 0.5).toColor();
  }

  // ---------------------------------------------------------------------------
  // Trail drawing
  // ---------------------------------------------------------------------------

  void _drawFadingTrail(
    Canvas canvas,
    List<Offset> scaledTrail,
    List<DiscDetection> detections,
  ) {
    final n = scaledTrail.length;
    if (n < 2) return;

    for (int i = 1; i < n; i++) {
      final double fade;
      if (showFullTrail) {
        fade = 1.0;
      } else {
        final detIdx = min(i, detections.length - 1);
        final age = currentFrame - detections[detIdx].frameIndex;
        if (age > trailFadeFrames) continue;
        fade = (1.0 - (age / trailFadeFrames)).clamp(0.0, 1.0);
      }

      final segColor = _gradientColor(i, n);

      // Glow layer
      canvas.drawLine(
        scaledTrail[i - 1],
        scaledTrail[i],
        Paint()
          ..color = segColor.withAlpha((fade * 40).round())
          ..strokeWidth = 8.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );

      // Main trail line
      canvas.drawLine(
        scaledTrail[i - 1],
        scaledTrail[i],
        Paint()
          ..color = segColor.withAlpha((fade * 220).round())
          ..strokeWidth = 3.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }

    // High-confidence detection dots
    for (int i = 0; i < n && i < detections.length; i++) {
      if (detections[i].confidence <= 0.9) continue;
      final double fade;
      if (showFullTrail) {
        fade = 1.0;
      } else {
        final age = currentFrame - detections[i].frameIndex;
        if (age > trailFadeFrames) continue;
        fade = (1.0 - (age / trailFadeFrames)).clamp(0.0, 1.0);
      }
      canvas.drawCircle(
        scaledTrail[i],
        2.5,
        Paint()
          ..color = Colors.white.withAlpha((fade * 160).round())
          ..style = PaintingStyle.fill,
      );
    }
  }

  void _drawCurrentDisc(Canvas canvas, Size size) {
    final detection = trackingResult.detectionAtFrame(currentFrame);
    if (detection == null) return;

    // Current disc is always at its raw screen position — the world-lock
    // round-trips T_cur⁻¹ then T_cur which cancels to the identity.
    final center = Offset(detection.x * size.width, detection.y * size.height);

    canvas.drawCircle(center, 14, Paint()..color = Colors.orange.withAlpha(50));
    canvas.drawCircle(center, 6, Paint()..color = Colors.white);
    canvas.drawCircle(
      center,
      6,
      Paint()
        ..color = Colors.orange
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _drawStartMarker(Canvas canvas, Offset start, double fade) {
    canvas.drawCircle(
      start,
      6,
      Paint()
        ..color = Colors.green.withAlpha((fade * 255).round())
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      start,
      6,
      Paint()
        ..color = Colors.white.withAlpha((fade * 255).round())
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(FollowFlightPainter oldDelegate) {
    return oldDelegate.currentFrame != currentFrame ||
        oldDelegate.showTrail != showTrail ||
        oldDelegate.showFullTrail != showFullTrail ||
        oldDelegate.anchorFrames != anchorFrames;
  }
}
