import 'package:flutter/material.dart';
import 'dart:math';
import '../services/disc_detection_service.dart';

/// Renders a follow-flight overlay on top of a video player.
/// Draws a smooth, fading trail following the detected disc trajectory.
class FollowFlightPainter extends CustomPainter {
  final FlightTrackingResult trackingResult;
  final int currentFrame;
  final bool showTrail;
  final bool showCurrentDisc;
  final int trailFadeFrames; // Trail visible for this many frames behind current
  final bool showFullTrail; // Show entire trail at full opacity (for export)

  FollowFlightPainter({
    required this.trackingResult,
    required this.currentFrame,
    this.showTrail = true,
    this.showCurrentDisc = true,
    this.trailFadeFrames = 30, // 3 seconds at 10fps
    this.showFullTrail = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final trail = trackingResult.getTrail(currentFrame);
    if (trail.isEmpty) return;

    final allDetections = trackingResult.detectionsUpToFrame(currentFrame);
    if (allDetections.isEmpty) return;

    // Scale normalized coordinates (0-1) to canvas size
    final scaledTrail = trail
        .map((p) => Offset(p.dx * size.width, p.dy * size.height))
        .toList();

    if (showTrail && scaledTrail.length >= 2) {
      _drawFadingTrail(canvas, size, scaledTrail, allDetections);
    }

    if (showCurrentDisc) {
      _drawCurrentDisc(canvas, size);
    }

    // Draw start marker only if within fade window (or full trail mode)
    if (scaledTrail.isNotEmpty && allDetections.isNotEmpty) {
      if (showFullTrail) {
        _drawStartMarker(canvas, scaledTrail.first, 1.0);
      } else {
        final startAge = currentFrame - allDetections.first.frameIndex;
        if (startAge <= trailFadeFrames) {
          final fade = 1.0 - (startAge / trailFadeFrames);
          _drawStartMarker(canvas, scaledTrail.first, fade);
        }
      }
    }
  }

  /// Returns a gradient color from green (start) through yellow to red (end).
  Color _gradientColor(int index, int total) {
    if (total <= 0) return Colors.green;
    final hue = 120.0 * (1.0 - index / total); // green(120) → red(0)
    return HSLColor.fromAHSL(1.0, hue, 0.9, 0.5).toColor();
  }

  void _drawFadingTrail(
    Canvas canvas,
    Size size,
    List<Offset> scaledTrail,
    List<DiscDetection> detections,
  ) {
    // Draw individual segments with per-segment fading and gradient color
    for (int i = 1; i < scaledTrail.length; i++) {
      final double fade;
      if (showFullTrail) {
        fade = 1.0;
      } else {
        final detIdx = min(i, detections.length - 1);
        final segmentFrame = detections[detIdx].frameIndex;
        final age = currentFrame - segmentFrame;

        // Skip segments outside fade window
        if (age > trailFadeFrames) continue;

        fade = (1.0 - (age / trailFadeFrames)).clamp(0.0, 1.0);
      }

      // Determine this segment's position in the full trail for gradient
      final segColor = _gradientColor(i, scaledTrail.length);

      // Glow layer
      final glowPaint = Paint()
        ..color = segColor.withAlpha((fade * 40).round())
        ..strokeWidth = 8.0
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(scaledTrail[i - 1], scaledTrail[i], glowPaint);

      // Main trail line
      final trailPaint = Paint()
        ..color = segColor.withAlpha((fade * 220).round())
        ..strokeWidth = 3.0
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(scaledTrail[i - 1], scaledTrail[i], trailPaint);
    }

    // Detection dots (also fading)
    for (int i = 0; i < scaledTrail.length && i < detections.length; i++) {
      if (detections[i].confidence > 0.9) {
        final double fade;
        if (showFullTrail) {
          fade = 1.0;
        } else {
          final age = currentFrame - detections[i].frameIndex;
          if (age > trailFadeFrames) continue;
          fade = (1.0 - (age / trailFadeFrames)).clamp(0.0, 1.0);
        }
        final dotPaint = Paint()
          ..color = Colors.white.withAlpha((fade * 160).round())
          ..style = PaintingStyle.fill;
        canvas.drawCircle(scaledTrail[i], 2.5, dotPaint);
      }
    }
  }

  void _drawCurrentDisc(Canvas canvas, Size size) {
    final detection = trackingResult.detectionAtFrame(currentFrame);
    if (detection == null) return;

    final cx = detection.x * size.width;
    final cy = detection.y * size.height;
    final radius = max(detection.width, detection.height) * size.width * 0.5;
    final discRadius = max(radius, 8.0);

    // Glow
    final glowPaint = Paint()
      ..color = Colors.red.withAlpha(60)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), discRadius * 1.5, glowPaint);

    // Ring
    final ringPaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(Offset(cx, cy), discRadius, ringPaint);

    // Crosshair
    final crossPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    const crossSize = 6.0;
    canvas.drawLine(
        Offset(cx - crossSize, cy), Offset(cx + crossSize, cy), crossPaint);
    canvas.drawLine(
        Offset(cx, cy - crossSize), Offset(cx, cy + crossSize), crossPaint);
  }

  void _drawStartMarker(Canvas canvas, Offset start, double fade) {
    final paint = Paint()
      ..color = Colors.green.withAlpha((fade * 255).round())
      ..style = PaintingStyle.fill;
    canvas.drawCircle(start, 6, paint);

    final borderPaint = Paint()
      ..color = Colors.white.withAlpha((fade * 255).round())
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(start, 6, borderPaint);
  }

  @override
  bool shouldRepaint(FollowFlightPainter oldDelegate) {
    return oldDelegate.currentFrame != currentFrame ||
        oldDelegate.showTrail != showTrail;
  }
}
