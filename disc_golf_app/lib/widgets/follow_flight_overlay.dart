import 'dart:math';
import 'package:flutter/material.dart';
import '../services/disc_detection_service.dart';

/// Renders a follow-flight overlay on top of a video player.
/// Draws a smooth, fading trail following the detected disc trajectory.
///
/// [cameraOffsets] — optional per-frame camera offsets (normalized 0-1) keyed
/// by frame index.  When provided the trail is "world-locked": past positions
/// are shifted so they stay anchored to the environment as the camera pans,
/// matching the After-Effects "Null + 3D Camera" approach.  Offsets are
/// interpolated linearly between keyed frames; frames outside the keyed range
/// clamp to the nearest value.
class FollowFlightPainter extends CustomPainter {
  final FlightTrackingResult trackingResult;
  final int currentFrame;
  final bool showTrail;
  final bool showCurrentDisc;
  final int trailFadeFrames; // Trail visible for this many frames behind current
  final bool showFullTrail; // Show entire trail at full opacity (for export)
  /// Keyed camera offsets in normalized (0-1) units.
  /// Key = frame index, value = (dx, dy) offset of the reference point
  /// relative to the first reference frame.
  final Map<int, Offset>? cameraOffsets;

  FollowFlightPainter({
    required this.trackingResult,
    required this.currentFrame,
    this.showTrail = true,
    this.showCurrentDisc = true,
    this.trailFadeFrames = 30, // 3 seconds at 10fps
    this.showFullTrail = false,
    this.cameraOffsets,
  });

  // ---------------------------------------------------------------------------
  // Camera offset interpolation
  // ---------------------------------------------------------------------------

  /// Returns the interpolated camera offset (normalized 0-1) at [frame].
  /// When [cameraOffsets] is null or empty, returns [Offset.zero].
  Offset _cameraOffsetAt(int frame) {
    if (cameraOffsets == null || cameraOffsets!.isEmpty) return Offset.zero;
    final frames = cameraOffsets!.keys.toList()..sort();
    if (frame <= frames.first) return cameraOffsets![frames.first]!;
    if (frame >= frames.last) return cameraOffsets![frames.last]!;

    // Find the surrounding keyed frames
    int prevF = frames.first;
    int nextF = frames.last;
    for (final f in frames) {
      if (f <= frame) prevF = f;
    }
    for (final f in frames.reversed) {
      if (f >= frame) { nextF = f; break; }
    }
    if (prevF == nextF) return cameraOffsets![prevF]!;

    final t = (frame - prevF) / (nextF - prevF);
    final prev = cameraOffsets![prevF]!;
    final next = cameraOffsets![nextF]!;
    return Offset(
      prev.dx + (next.dx - prev.dx) * t,
      prev.dy + (next.dy - prev.dy) * t,
    );
  }

  /// Converts a [DiscDetection] to a canvas pixel position, accounting for
  /// camera motion so that the rendered point stays world-locked.
  ///
  /// Formula:
  ///   draw = (raw_pos - cam_offset_at_detection_frame + cam_offset_at_current_frame) * size
  ///
  /// When there are no camera offsets the formula degenerates to draw = raw_pos * size.
  Offset _toCanvas(DiscDetection d, Size size, Offset currentCamOffset) {
    final pastCamOffset = _cameraOffsetAt(d.frameIndex);
    final dx = (d.x - pastCamOffset.dx + currentCamOffset.dx) * size.width;
    final dy = (d.y - pastCamOffset.dy + currentCamOffset.dy) * size.height;
    return Offset(dx, dy);
  }

  // ---------------------------------------------------------------------------
  // Paint
  // ---------------------------------------------------------------------------

  @override
  void paint(Canvas canvas, Size size) {
    final allDetections = trackingResult.detectionsUpToFrame(currentFrame);
    if (allDetections.isEmpty) return;

    final currentCamOffset = _cameraOffsetAt(currentFrame);

    // Build camera-compensated trail positions
    final scaledTrail = allDetections
        .map((d) => _toCanvas(d, size, currentCamOffset))
        .toList();

    if (showTrail && scaledTrail.length >= 2) {
      _drawFadingTrail(canvas, size, scaledTrail, allDetections);
    }

    if (showCurrentDisc) {
      _drawCurrentDisc(canvas, size, currentCamOffset);
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

  // ---------------------------------------------------------------------------
  // Color gradient
  // ---------------------------------------------------------------------------

  /// Returns a gradient color from green (start) through yellow to red (end).
  Color _gradientColor(int index, int total) {
    if (total <= 0) return Colors.green;
    final hue = 120.0 * (1.0 - index / total); // green(120) → red(0)
    return HSLColor.fromAHSL(1.0, hue, 0.9, 0.5).toColor();
  }

  // ---------------------------------------------------------------------------
  // Trail drawing
  // ---------------------------------------------------------------------------

  /// Draws the fading trail as a series of smooth path strokes.
  ///
  /// Each segment is drawn as part of a [Path] with [StrokeJoin.round] so
  /// adjacent segments join without gaps.  The glow layer uses
  /// [MaskFilter.blur] for a realistic soft-light effect rather than a plain
  /// wide line.
  ///
  /// Consecutive visible segments are grouped into a single path per opacity
  /// bucket so the number of canvas draw calls is minimised.
  void _drawFadingTrail(
    Canvas canvas,
    Size size,
    List<Offset> scaledTrail,
    List<DiscDetection> detections,
  ) {
    final n = scaledTrail.length;
    if (n < 2) return;

    // Build per-segment visibility and style info
    final List<double> fades = List.filled(n, 0.0);
    final List<Color> colors = List.filled(n, Colors.green);

    for (int i = 1; i < n; i++) {
      final double fade;
      if (showFullTrail) {
        fade = 1.0;
      } else {
        final detIdx = min(i, detections.length - 1);
        final segmentFrame = detections[detIdx].frameIndex;
        final age = currentFrame - segmentFrame;
        if (age > trailFadeFrames) { fades[i] = 0; continue; }
        fade = (1.0 - (age / trailFadeFrames)).clamp(0.0, 1.0);
      }
      fades[i] = fade;
      colors[i] = _gradientColor(i, n);
    }

    // --- Glow pass: draw visible segments as grouped paths with blur ---
    // Group contiguous visible segments; draw each group as one path.
    // This avoids per-segment draw calls and produces smooth anti-aliased
    // joints with the blur filter.
    _drawGroupedPaths(
      canvas,
      scaledTrail,
      fades,
      colors,
      strokeWidth: 10.0,
      alphaScale: 50,
      useMaskBlur: true,
      blurSigma: 5.0,
    );

    // --- Main line pass: same grouping, no blur, full opacity ---
    _drawGroupedPaths(
      canvas,
      scaledTrail,
      fades,
      colors,
      strokeWidth: 3.5,
      alphaScale: 220,
      useMaskBlur: false,
    );

    // --- High-confidence detection dots ---
    for (int i = 0; i < n && i < detections.length; i++) {
      if (fades[i] <= 0) continue;
      if (detections[i].confidence > 0.9) {
        final dotPaint = Paint()
          ..color = Colors.white.withAlpha((fades[i] * 160).round())
          ..style = PaintingStyle.fill;
        canvas.drawCircle(scaledTrail[i], 2.5, dotPaint);
      }
    }
  }

  /// Draws [scaledTrail] segments grouped by approximate fade/color bucket.
  ///
  /// Segments with fade ≤ 0 are skipped; contiguous visible segments are
  /// batched into a single [Path] per color, reducing GPU draw calls.
  void _drawGroupedPaths(
    Canvas canvas,
    List<Offset> trail,
    List<double> fades,
    List<Color> colors, {
    required double strokeWidth,
    required int alphaScale,
    required bool useMaskBlur,
    double blurSigma = 4.0,
  }) {
    // We draw segment-by-segment but share a Path across adjacent segments
    // that have the same rounded alpha value to keep draw calls low while
    // still producing the fade gradient.
    Path? currentPath;
    int? currentAlpha;
    Color? currentColor;
    int? pathStartIdx;

    void flushPath() {
      if (currentPath == null || currentAlpha == null || currentColor == null) return;
      final paint = Paint()
        ..color = currentColor!.withAlpha(currentAlpha!)
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (useMaskBlur) {
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma);
      }
      canvas.drawPath(currentPath!, paint);
      currentPath = null;
      currentAlpha = null;
      currentColor = null;
      pathStartIdx = null;
    }

    for (int i = 1; i < trail.length; i++) {
      final fade = fades[i];
      if (fade <= 0) { flushPath(); continue; }

      final alpha = (fade * alphaScale).round().clamp(0, 255);
      final color = colors[i];

      // Round alpha to nearest 16 to batch adjacent segments that look the same
      final alphaKey = (alpha ~/ 16) * 16;

      if (alphaKey != currentAlpha || currentPath == null) {
        flushPath();
        currentPath = Path()..moveTo(trail[i - 1].dx, trail[i - 1].dy);
        currentAlpha = alphaKey;
        currentColor = color;
        pathStartIdx = i;
      } else {
        // Continue existing path — ensure continuity from previous segment end
        currentPath!.moveTo(trail[i - 1].dx, trail[i - 1].dy);
      }
      currentPath!.lineTo(trail[i].dx, trail[i].dy);
      // Update color to latest in group (creates a subtle gradient within group)
      currentColor = color;
    }
    flushPath();
  }

  void _drawCurrentDisc(Canvas canvas, Size size, Offset camOffset) {
    final detection = trackingResult.detectionAtFrame(currentFrame);
    if (detection == null) return;

    // Current-frame disc is always at its raw screen position (cam compensation
    // cancels: raw - current_offset + current_offset = raw)
    final cx = detection.x * size.width;
    final cy = detection.y * size.height;
    final center = Offset(cx, cy);

    // Soft blur glow
    canvas.drawCircle(
      center,
      18,
      Paint()
        ..color = Colors.orange.withAlpha(45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // Solid inner dot
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
        oldDelegate.cameraOffsets != cameraOffsets;
  }
}
