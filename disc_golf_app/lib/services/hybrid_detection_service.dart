import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'disc_detection_service.dart';
import '../utils/angle_calculator.dart';

/// Keyframe seed placed by the user for hybrid detection.
class SeedKeyframe {
  final int frameIndex;
  final double x; // normalized 0-1
  final double y; // normalized 0-1

  SeedKeyframe({required this.frameIndex, required this.x, required this.y});

  Offset get offset => Offset(x, y);
}

/// Hybrid disc detection: user seed keyframes → Catmull-Rom spline prediction
/// → per-frame refinement via color blob and/or YOLO in narrow search windows.
class HybridDetectionService extends ChangeNotifier {
  final DiscDetectionService _detector;

  double _progress = 0.0;
  String _statusMessage = '';
  bool _isProcessing = false;

  double get progress => _progress;
  String get statusMessage => _statusMessage;
  bool get isProcessing => _isProcessing;

  HybridDetectionService(this._detector);

  /// Run hybrid detection.
  ///
  /// [seedKeyframes] must have 3+ entries. [discColor] is optional — if
  /// provided, color blob detection supplements YOLO in search windows.
  Future<FlightTrackingResult> detect({
    required List<SeedKeyframe> seedKeyframes,
    required String videoPath,
    required double fps,
    required int totalFrames,
    required double videoWidth,
    required double videoHeight,
    Color? discColor,
  }) async {
    assert(seedKeyframes.length >= 3, 'Need at least 3 seed keyframes');

    _isProcessing = true;
    _progress = 0.0;
    _statusMessage = 'Generating spline prediction...';
    notifyListeners();

    try {
      // ---------------------------------------------------------------
      // Step 1: Catmull-Rom spline through seed keyframes
      // ---------------------------------------------------------------
      final anchors = <int, Offset>{};
      for (final kf in seedKeyframes) {
        anchors[kf.frameIndex] = kf.offset;
      }

      final sortedKeys = anchors.keys.toList()..sort();
      final firstFrame = sortedKeys.first;
      final lastFrame = sortedKeys.last;

      final predicted = AngleCalculator.interpolateAnchors(
        anchors,
        firstFrame,
        lastFrame,
      );

      _progress = 0.1;
      _statusMessage = 'Extracting video frames...';
      notifyListeners();

      // ---------------------------------------------------------------
      // Step 2: Extract video frames for the flight range
      // ---------------------------------------------------------------
      final tempDir = await getTemporaryDirectory();
      final framesDir = Directory(
          '${tempDir.path}/hybrid_detect_${DateTime.now().millisecondsSinceEpoch}');
      await framesDir.create(recursive: true);

      final framePaths = await _detector.extractFrames(
        videoPath,
        framesDir.path,
        fps: fps,
        maxFrames: totalFrames,
      );

      if (framePaths.isEmpty) {
        throw Exception('No frames could be extracted');
      }

      _progress = 0.3;
      _statusMessage = 'Refining with detection...';
      notifyListeners();

      // Precompute target HSV if disc color is provided
      final targetHsv = discColor != null ? _rgbToHsv(
        (discColor.r * 255.0).round().clamp(0, 255),
        (discColor.g * 255.0).round().clamp(0, 255),
        (discColor.b * 255.0).round().clamp(0, 255),
      ) : null;

      // ---------------------------------------------------------------
      // Step 3: Per-frame refinement in search windows
      // ---------------------------------------------------------------
      final refinedDetections = <DiscDetection>[];
      final frameCount = lastFrame - firstFrame + 1;

      for (int frame = firstFrame; frame <= lastFrame; frame++) {
        final progressFraction = (frame - firstFrame) / frameCount;
        _progress = 0.3 + progressFraction * 0.6;

        if (frame % 10 == 0) {
          _statusMessage =
              'Refining frame ${frame - firstFrame + 1}/$frameCount';
          notifyListeners();
        }

        final splinePos = predicted[frame];
        if (splinePos == null) continue;
        if (frame >= framePaths.length) continue;

        // Try to refine using color and/or YOLO
        Offset? refined;
        double confidence = 0.5; // spline-only confidence

        final imageFile = File(framePaths[frame]);
        if (await imageFile.exists()) {
          final bytes = await imageFile.readAsBytes();
          final image = img.decodeImage(bytes);

          if (image != null) {
            // Search window: ±15% of frame around predicted position
            final windowFrac = 0.15;
            final wxMin =
                ((splinePos.dx - windowFrac) * image.width).round().clamp(0, image.width - 1);
            final wyMin =
                ((splinePos.dy - windowFrac) * image.height).round().clamp(0, image.height - 1);
            final wxMax =
                ((splinePos.dx + windowFrac) * image.width).round().clamp(0, image.width - 1);
            final wyMax =
                ((splinePos.dy + windowFrac) * image.height).round().clamp(0, image.height - 1);

            final cropW = wxMax - wxMin;
            final cropH = wyMax - wyMin;

            if (cropW > 10 && cropH > 10) {
              Offset? colorResult;
              Offset? yoloResult;

              // Color blob detection
              if (targetHsv != null) {
                final crop = img.copyCrop(image,
                    x: wxMin, y: wyMin, width: cropW, height: cropH);
                colorResult = _findColorBlob(crop, targetHsv);
                if (colorResult != null) {
                  // Remap from crop coords to normalized frame coords
                  colorResult = Offset(
                    (wxMin + colorResult.dx * cropW) / image.width,
                    (wyMin + colorResult.dy * cropH) / image.height,
                  );
                }
              }

              // YOLO detection in search window
              if (_detector.isModelLoaded) {
                final crop = img.copyCrop(image,
                    x: wxMin, y: wyMin, width: cropW, height: cropH);
                final yoloDet =
                    await _detector.detectInImage(crop, frame, fps);
                if (yoloDet != null) {
                  // Remap from crop coords to normalized frame coords
                  yoloResult = Offset(
                    (wxMin + yoloDet.x * cropW) / image.width,
                    (wyMin + yoloDet.y * cropH) / image.height,
                  );
                }
              }

              // Merge results
              if (colorResult != null && yoloResult != null) {
                final dist = (colorResult - yoloResult).distance;
                if (dist < 0.05) {
                  // Both agree — high confidence, average position
                  refined = Offset(
                    (colorResult.dx + yoloResult.dx) / 2,
                    (colorResult.dy + yoloResult.dy) / 2,
                  );
                  confidence = 0.9;
                } else {
                  // Disagree — prefer YOLO (trained model)
                  refined = yoloResult;
                  confidence = 0.7;
                }
              } else if (colorResult != null) {
                refined = colorResult;
                confidence = 0.65;
              } else if (yoloResult != null) {
                refined = yoloResult;
                confidence = 0.7;
              }
            }
          }
        }

        // Fall back to spline prediction if no refinement found
        final pos = refined ?? splinePos;

        refinedDetections.add(DiscDetection(
          frameIndex: frame,
          x: pos.dx.clamp(0.0, 1.0),
          y: pos.dy.clamp(0.0, 1.0),
          width: 0.03,
          height: 0.03,
          confidence: confidence,
          timestamp:
              Duration(milliseconds: (frame * 1000 / fps).round()),
        ));

        if (frame % 10 == 0) await Future.delayed(Duration.zero);
      }

      // ---------------------------------------------------------------
      // Step 4: Smooth the merged trajectory
      // ---------------------------------------------------------------
      _progress = 0.95;
      _statusMessage = 'Smoothing trajectory...';
      notifyListeners();

      final smoothed =
          _detector.smoothDetections(refinedDetections, windowSize: 3);

      // ---------------------------------------------------------------
      // Step 5: Return result
      // ---------------------------------------------------------------
      _progress = 1.0;
      _statusMessage = 'Complete!';
      _isProcessing = false;
      notifyListeners();

      // Cleanup temp frames
      try {
        await framesDir.delete(recursive: true);
      } catch (_) {}

      return FlightTrackingResult(
        detections: smoothed,
        videoWidth: videoWidth,
        videoHeight: videoHeight,
        fps: fps,
        totalFrames: totalFrames,
      );
    } catch (e) {
      _isProcessing = false;
      _statusMessage = 'Error: $e';
      notifyListeners();
      rethrow;
    }
  }

  // -----------------------------------------------------------------------
  // Color blob detection
  // -----------------------------------------------------------------------

  /// Find the centroid of pixels matching the target HSV color in a crop.
  /// Returns normalized coordinates (0-1) within the crop, or null.
  Offset? _findColorBlob(
    img.Image crop,
    ({double h, double s, double v}) targetHsv, {
    double hueTolerance = 25.0,
    double satTolerance = 0.3,
    double valTolerance = 0.3,
    int minPixels = 5,
  }) {
    double sumX = 0, sumY = 0;
    int count = 0;

    for (int y = 0; y < crop.height; y++) {
      for (int x = 0; x < crop.width; x++) {
        final pixel = crop.getPixel(x, y);
        final hsv = _rgbToHsv(pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt());

        // Hue is circular (0-360)
        var hueDiff = (hsv.h - targetHsv.h).abs();
        if (hueDiff > 180) hueDiff = 360 - hueDiff;

        if (hueDiff <= hueTolerance &&
            (hsv.s - targetHsv.s).abs() <= satTolerance &&
            (hsv.v - targetHsv.v).abs() <= valTolerance) {
          sumX += x;
          sumY += y;
          count++;
        }
      }
    }

    if (count < minPixels) return null;

    return Offset(
      sumX / count / crop.width,
      sumY / count / crop.height,
    );
  }

  /// Standard RGB to HSV conversion.
  /// H in [0, 360], S and V in [0, 1].
  ({double h, double s, double v}) _rgbToHsv(int r, int g, int b) {
    final rf = r / 255.0;
    final gf = g / 255.0;
    final bf = b / 255.0;

    final cMax = [rf, gf, bf].reduce(max);
    final cMin = [rf, gf, bf].reduce(min);
    final delta = cMax - cMin;

    double h = 0;
    if (delta != 0) {
      if (cMax == rf) {
        h = 60 * (((gf - bf) / delta) % 6);
      } else if (cMax == gf) {
        h = 60 * (((bf - rf) / delta) + 2);
      } else {
        h = 60 * (((rf - gf) / delta) + 4);
      }
    }
    if (h < 0) h += 360;

    final s = cMax == 0 ? 0.0 : delta / cMax;
    final v = cMax;

    return (h: h, s: s, v: v);
  }
}
