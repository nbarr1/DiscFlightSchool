import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:path_provider/path_provider.dart';

/// Represents a detected disc position in a single frame.
class DiscDetection {
  final int frameIndex;
  final double x; // Center x, normalized 0-1
  final double y; // Center y, normalized 0-1
  final double width; // Box width, normalized 0-1
  final double height; // Box height, normalized 0-1
  final double confidence;
  final Duration timestamp;

  DiscDetection({
    required this.frameIndex,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.confidence,
    required this.timestamp,
  });

  Offset get center => Offset(x, y);
}

/// Result of tracking a full video — disc positions per frame.
class FlightTrackingResult {
  final List<DiscDetection> detections;
  final double videoWidth;
  final double videoHeight;
  final double fps;
  final int totalFrames;

  FlightTrackingResult({
    required this.detections,
    required this.videoWidth,
    required this.videoHeight,
    required this.fps,
    required this.totalFrames,
  });

  /// Get the disc position at a given frame, or null if not detected.
  DiscDetection? detectionAtFrame(int frame) {
    try {
      return detections.firstWhere((d) => d.frameIndex == frame);
    } catch (_) {
      return null;
    }
  }

  /// Get all detections up to and including the given frame.
  List<DiscDetection> detectionsUpToFrame(int frame) {
    return detections.where((d) => d.frameIndex <= frame).toList();
  }

  /// Get trail points up to the current frame (simple — no camera compensation).
  List<Offset> getTrail(int currentFrame) {
    return detectionsUpToFrame(currentFrame)
        .map((d) => Offset(d.x, d.y))
        .toList();
  }

  /// Legacy compatibility — same as getTrail.
  List<Offset> getCompensatedTrail(int currentFrame) => getTrail(currentFrame);
}

class DiscDetectionService extends ChangeNotifier {
  Interpreter? _interpreter;
  bool _isModelLoaded = false;
  bool _isProcessing = false;
  double _progress = 0.0;
  String _statusMessage = '';
  FlightTrackingResult? _lastResult;

  bool get isModelLoaded => _isModelLoaded;
  bool get isProcessing => _isProcessing;
  double get progress => _progress;
  String get statusMessage => _statusMessage;
  FlightTrackingResult? get lastResult => _lastResult;

  static const int _inputSize = 320;
  static const double _confidenceThreshold = 0.003;
  /// Maximum normalized distance a detection can jump per frame-step
  /// during spatial coherence filtering (8% of frame dimension).
  static const double _maxJumpPerFrame = 0.08;
  /// Maximum consecutive frames to skip when building a coherent chain.
  static const int _maxChainGap = 5;

  /// Load the TFLite model. Uses a custom (retrained) model if available,
  /// otherwise falls back to the bundled asset model.
  Future<void> loadModel({String? customModelPath}) async {
    if (_isModelLoaded) return;

    try {
      File modelFile;

      if (customModelPath != null && await File(customModelPath).exists()) {
        modelFile = File(customModelPath);
        debugPrint('Loading custom disc detection model: $customModelPath');
      } else {
        final modelData =
            await rootBundle.load('assets/models/disc_detector.tflite');
        final tempDir = await getTemporaryDirectory();
        modelFile = File('${tempDir.path}/disc_detector.tflite');
        await modelFile.writeAsBytes(modelData.buffer.asUint8List());
        debugPrint('Loading bundled disc detection model');
      }

      _interpreter = Interpreter.fromFile(modelFile);
      _isModelLoaded = true;
      debugPrint('Disc detection model loaded successfully');
    } catch (e) {
      debugPrint('Error loading disc detection model: $e');
      rethrow;
    }
  }

  /// Process a video file: extract frames, run detection, filter & smooth.
  Future<FlightTrackingResult> processVideo(
    String videoPath, {
    double fps = 10.0, // Lower FPS = faster + larger disc movement per frame
    int maxFrames = 300,
  }) async {
    if (!_isModelLoaded) {
      await loadModel();
    }

    _isProcessing = true;
    _progress = 0.0;
    _statusMessage = 'Extracting frames...';
    notifyListeners();

    final tempDir = await getTemporaryDirectory();
    final framesDir = Directory(
        '${tempDir.path}/disc_detect_${DateTime.now().millisecondsSinceEpoch}');
    await framesDir.create(recursive: true);

    try {
      // Step 1: Extract frames at lower FPS for speed
      final framePaths = await _extractFrames(
        videoPath,
        framesDir.path,
        fps: fps,
        maxFrames: maxFrames,
      );

      if (framePaths.isEmpty) {
        throw Exception('No frames could be extracted from video');
      }

      debugPrint('Extracted ${framePaths.length} frames at ${fps}fps');

      _statusMessage = 'Detecting disc in ${framePaths.length} frames...';
      notifyListeners();

      // Step 2: Run detection on each frame — collect ALL candidates per frame
      final rawDetections = <DiscDetection>[];
      double firstImageW = 640;
      double firstImageH = 1138;

      for (int i = 0; i < framePaths.length; i++) {
        _progress = (i / framePaths.length) * 0.7;
        if (i % 10 == 0) {
          _statusMessage =
              'Detecting disc: frame ${i + 1}/${framePaths.length}';
          notifyListeners();
        }

        final imageFile = File(framePaths[i]);
        if (!await imageFile.exists()) continue;

        final bytes = await imageFile.readAsBytes();
        final image = img.decodeImage(bytes);
        if (image == null) continue;

        if (i == 0) {
          firstImageW = image.width.toDouble();
          firstImageH = image.height.toDouble();
        }

        final detection = await _detectDisc(image, i, fps);
        if (detection != null) {
          rawDetections.add(detection);
        }

        if (i % 10 == 0) await Future.delayed(Duration.zero);
      }

      debugPrint(
          'Raw detections: ${rawDetections.length}/${framePaths.length} frames');

      // Step 3: Spatial coherence filtering — find the real flight path
      _progress = 0.8;
      _statusMessage = 'Filtering trajectory...';
      notifyListeners();

      final coherent = _filterSpatialCoherence(
        rawDetections,
        framePaths.length,
        fps: fps,
      );

      debugPrint(
          'After spatial filtering: ${coherent.length} coherent detections');

      // Step 4: Smooth the trajectory
      _progress = 0.9;
      _statusMessage = 'Smoothing...';
      notifyListeners();

      final smoothed = _smoothDetections(coherent, windowSize: 3);

      // Step 5: Interpolate small gaps
      _progress = 0.95;
      _statusMessage = 'Interpolating gaps...';
      notifyListeners();

      final interpolated =
          _interpolateDetections(smoothed, framePaths.length, fps);

      debugPrint(
          'Final: ${interpolated.where((d) => d.confidence >= 0).length} detected, '
          '${interpolated.where((d) => d.confidence < 0).length} interpolated');

      _progress = 1.0;
      _statusMessage = 'Complete!';
      _isProcessing = false;

      final result = FlightTrackingResult(
        detections: interpolated,
        videoWidth: firstImageW,
        videoHeight: firstImageH,
        fps: fps,
        totalFrames: framePaths.length,
      );

      _lastResult = result;
      notifyListeners();
      return result;
    } finally {
      try {
        await framesDir.delete(recursive: true);
      } catch (_) {}

      if (_isProcessing) {
        _isProcessing = false;
        notifyListeners();
      }
    }
  }

  /// Extract frames from video at the given FPS.
  Future<List<String>> _extractFrames(
    String videoPath,
    String outputDir, {
    required double fps,
    required int maxFrames,
  }) async {
    final framePaths = <String>[];
    final intervalMs = (1000 / fps).round();

    for (int i = 0; i < maxFrames; i++) {
      final timeMs = i * intervalMs;

      try {
        final path = await VideoThumbnail.thumbnailFile(
          video: videoPath,
          thumbnailPath: outputDir,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 640,
          timeMs: timeMs,
          quality: 85,
        );

        if (path != null) {
          final newPath =
              '$outputDir/frame_${i.toString().padLeft(4, '0')}.jpg';
          final file = File(path);
          if (await file.exists()) {
            await file.rename(newPath);
            framePaths.add(newPath);
          }
        } else {
          break;
        }
      } catch (e) {
        break;
      }

      if (i % 10 == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    return framePaths;
  }

  /// Run YOLOv8 inference on a single frame.
  Future<DiscDetection?> _detectDisc(
    img.Image image,
    int frameIndex,
    double fps,
  ) async {
    if (_interpreter == null) return null;

    final inputImage = _preprocessImage(image);

    final outputTensor = _interpreter!.getOutputTensor(0);
    final outputShape = outputTensor.shape;
    final outputType = outputTensor.type;
    if (outputShape.length < 3) return null;

    final outputBuffer = List.generate(
      outputShape[0],
      (_) => List.generate(
        outputShape[1],
        (_) => List.filled(outputShape[2], 0.0),
      ),
    );

    _interpreter!.run(inputImage, outputBuffer);

    if (frameIndex == 0) {
      debugPrint('TFLite output shape: $outputShape, type: $outputType');
    }

    return _parseBestDetection(
      outputBuffer,
      outputShape,
      frameIndex,
      fps,
    );
  }

  /// Preprocess image for YOLOv8: resize to 320x320, normalize to 0-1, NHWC.
  List<List<List<List<double>>>> _preprocessImage(img.Image image) {
    final resized =
        img.copyResize(image, width: _inputSize, height: _inputSize);

    return List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (y) => List.generate(
          _inputSize,
          (x) {
            final pixel = resized.getPixel(x, y);
            return [
              pixel.r / 255.0,
              pixel.g / 255.0,
              pixel.b / 255.0,
            ];
          },
        ),
      ),
    );
  }

  /// Parse YOLOv8 output to find the best disc detection.
  DiscDetection? _parseBestDetection(
    List<List<List<double>>> output,
    List<int> shape,
    int frameIndex,
    double fps,
  ) {
    final dim1 = shape[1];
    final dim2 = shape[2];

    DiscDetection? bestDetection;
    double bestConfidence = _confidenceThreshold;

    if (dim1 == 5 || dim1 == 6) {
      // Shape [1, 5, N] — transposed format
      // Coordinates are already normalized 0-1 by TFLite export
      final numDetections = dim2;
      for (int i = 0; i < numDetections; i++) {
        final conf = dim1 == 5
            ? output[0][4][i]
            : output[0][4][i] * output[0][5][i];

        if (conf > bestConfidence) {
          bestConfidence = conf;

          bestDetection = DiscDetection(
            frameIndex: frameIndex,
            x: output[0][0][i].clamp(0.0, 1.0),
            y: output[0][1][i].clamp(0.0, 1.0),
            width: output[0][2][i].clamp(0.0, 1.0),
            height: output[0][3][i].clamp(0.0, 1.0),
            confidence: conf,
            timestamp:
                Duration(milliseconds: (frameIndex * 1000 / fps).round()),
          );
        }
      }
    } else {
      // Shape [1, N, 5+] — standard format
      final numDetections = dim1;
      for (int i = 0; i < numDetections; i++) {
        final conf = dim2 >= 6
            ? output[0][i][4] * output[0][i][5]
            : output[0][i][4];

        if (conf > bestConfidence) {
          bestConfidence = conf;
          bestDetection = DiscDetection(
            frameIndex: frameIndex,
            x: output[0][i][0].clamp(0.0, 1.0),
            y: output[0][i][1].clamp(0.0, 1.0),
            width: output[0][i][2].clamp(0.0, 1.0),
            height: output[0][i][3].clamp(0.0, 1.0),
            confidence: conf,
            timestamp:
                Duration(milliseconds: (frameIndex * 1000 / fps).round()),
          );
        }
      }
    }

    // Log first few detections for debugging
    if (frameIndex < 5 && bestDetection != null) {
      debugPrint(
          'Frame $frameIndex: (${bestDetection.x.toStringAsFixed(3)}, '
          '${bestDetection.y.toStringAsFixed(3)}) '
          'conf=${bestDetection.confidence.toStringAsFixed(4)}');
    }

    return bestDetection;
  }

  /// Find the longest spatially-coherent chain of detections.
  /// This is the key filter: a real disc follows a smooth trajectory,
  /// while noise is scattered randomly.
  List<DiscDetection> _filterSpatialCoherence(
    List<DiscDetection> detections,
    int totalFrames, {
    double maxJumpPerFrame = _maxJumpPerFrame,
    int maxGap = _maxChainGap,
    double fps = 10.0,
  }) {
    if (detections.length < 3) return detections;

    final sorted = List<DiscDetection>.from(detections)
      ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));

    // Build frame lookup
    final byFrame = <int, DiscDetection>{};
    for (final d in sorted) {
      byFrame[d.frameIndex] = d;
    }

    List<DiscDetection> bestChain = [];

    // Try starting from each detection
    for (int startIdx = 0; startIdx < sorted.length; startIdx++) {
      final chain = <DiscDetection>[sorted[startIdx]];
      var last = sorted[startIdx];

      // Extend forward
      for (int frame = last.frameIndex + 1; frame < totalFrames; frame++) {
        final det = byFrame[frame];
        if (det == null) {
          if (frame - last.frameIndex > maxGap) break;
          continue;
        }

        final frameGap = det.frameIndex - last.frameIndex;
        final maxDist = maxJumpPerFrame * frameGap;
        final dist = sqrt(pow(det.x - last.x, 2) + pow(det.y - last.y, 2));

        if (dist <= maxDist) {
          chain.add(det);
          last = det;
        } else {
          // This detection is too far — skip it but don't stop the search
          if (frame - last.frameIndex > maxGap) break;
        }
      }

      if (chain.length > bestChain.length) {
        bestChain = chain;
      }

      // Early termination: if we found a chain covering >50% of frames, good enough
      if (bestChain.length > totalFrames * 0.4) break;
    }

    debugPrint('Spatial coherence: best chain has ${bestChain.length} points '
        '(from ${sorted.length} raw detections)');

    return bestChain;
  }

  /// Smooth detections using a moving average window.
  List<DiscDetection> _smoothDetections(
    List<DiscDetection> detections, {
    int windowSize = 3,
  }) {
    if (detections.length < windowSize) return detections;

    final sorted = List<DiscDetection>.from(detections)
      ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));

    final smoothed = <DiscDetection>[];
    final halfWindow = windowSize ~/ 2;

    for (int i = 0; i < sorted.length; i++) {
      double sumX = 0, sumY = 0, sumW = 0, sumH = 0;
      int count = 0;

      for (int j = max(0, i - halfWindow);
          j <= min(sorted.length - 1, i + halfWindow);
          j++) {
        sumX += sorted[j].x;
        sumY += sorted[j].y;
        sumW += sorted[j].width;
        sumH += sorted[j].height;
        count++;
      }

      smoothed.add(DiscDetection(
        frameIndex: sorted[i].frameIndex,
        x: sumX / count,
        y: sumY / count,
        width: sumW / count,
        height: sumH / count,
        confidence: sorted[i].confidence,
        timestamp: sorted[i].timestamp,
      ));
    }

    return smoothed;
  }

  /// Fill gaps in detections using linear interpolation.
  List<DiscDetection> _interpolateDetections(
    List<DiscDetection> detections,
    int totalFrames,
    double fps,
  ) {
    if (detections.length < 2) return detections;

    final sorted = List<DiscDetection>.from(detections)
      ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));

    final result = <DiscDetection>[];

    for (int i = 0; i < sorted.length - 1; i++) {
      final start = sorted[i];
      final end = sorted[i + 1];
      result.add(start);

      final gap = end.frameIndex - start.frameIndex;
      if (gap > 1 && gap <= 10) {
        for (int f = 1; f < gap; f++) {
          final t = f / gap;
          result.add(DiscDetection(
            frameIndex: start.frameIndex + f,
            x: start.x + (end.x - start.x) * t,
            y: start.y + (end.y - start.y) * t,
            width: start.width + (end.width - start.width) * t,
            height: start.height + (end.height - start.height) * t,
            confidence: -1, // Mark as interpolated
            timestamp: Duration(
              milliseconds: ((start.frameIndex + f) * 1000 / fps).round(),
            ),
          ));
        }
      }
    }

    result.add(sorted.last);
    return result;
  }

  /// Public wrapper around [_detectDisc] for use by HybridDetectionService.
  Future<DiscDetection?> detectInImage(
    img.Image image,
    int frameIndex,
    double fps,
  ) async {
    if (!_isModelLoaded) await loadModel();
    return _detectDisc(image, frameIndex, fps);
  }

  /// Public wrapper around [_extractFrames] for use by HybridDetectionService.
  Future<List<String>> extractFrames(
    String videoPath,
    String outputDir, {
    required double fps,
    int maxFrames = 300,
  }) {
    return _extractFrames(videoPath, outputDir, fps: fps, maxFrames: maxFrames);
  }

  /// Public access to smoothing for use by HybridDetectionService.
  List<DiscDetection> smoothDetections(
    List<DiscDetection> detections, {
    int windowSize = 3,
  }) {
    return _smoothDetections(detections, windowSize: windowSize);
  }

  @override
  void dispose() {
    _interpreter?.close();
    super.dispose();
  }
}
