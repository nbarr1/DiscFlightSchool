import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One successfully extracted video frame, tagged with the frame index it was
/// sampled at.
///
/// The index is carried explicitly rather than implied by list position:
/// extraction can skip a frame mid-video, and using list position would then
/// shift every later frame's timestamp and spline anchor relative to the
/// actual video.
class ExtractedFrame {
  final int index;
  final String path;

  const ExtractedFrame({required this.index, required this.path});
}

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

/// Thrown by [DiscDetectionService.processVideo] when a run was stopped by
/// [DiscDetectionService.cancelProcessing] rather than failing on its own.
///
/// Callers should treat this as "the user changed their mind" and stay quiet,
/// not surface it as an error.
class DetectionCancelledException implements Exception {
  const DetectionCancelledException();

  @override
  String toString() => 'Disc detection was cancelled';
}

/// Mutable lock-on state for the track-by-detection state machine: the
/// disc's last confirmed position, its estimated per-frame velocity, and how
/// long it's been coasting without a confirmed detection.
class _DiscTrack {
  double x;
  double y;
  double vx = 0.0;
  double vy = 0.0;
  int lastFrameIndex;
  int occlusionStreak = 0;

  _DiscTrack({required this.x, required this.y, required this.lastFrameIndex});

  /// Linearly extrapolate the position [frameGap] frames ahead of the last
  /// confirmed detection.
  (double, double) predict(int frameGap) => (
        (x + vx * frameGap).clamp(0.0, 1.0),
        (y + vy * frameGap).clamp(0.0, 1.0),
      );

  /// Fold a newly confirmed detection into the track: updates position,
  /// smooths the velocity estimate, and resets the occlusion counter.
  void confirm(DiscDetection detection) {
    final gap = detection.frameIndex - lastFrameIndex;
    if (gap > 0) {
      final newVx = (detection.x - x) / gap;
      final newVy = (detection.y - y) / gap;
      const smoothing = DiscDetectionService._velocitySmoothing;
      vx = smoothing * newVx + (1 - smoothing) * vx;
      vy = smoothing * newVy + (1 - smoothing) * vy;
    }
    x = detection.x;
    y = detection.y;
    lastFrameIndex = detection.frameIndex;
    occlusionStreak = 0;
  }
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

  /// Fallback input size used only until a model is loaded. The real value
  /// is read from the interpreter's input tensor at load time (see
  /// [_loadModelImpl]) — a retrained model is not guaranteed to ship at the
  /// same geometry as the bundled default, and nothing here calls
  /// `resizeInputTensor`, so preprocessing must match whatever the model
  /// actually expects.
  static const int _defaultInputSize = 640;
  int _inputSize = _defaultInputSize;

  /// Whether the loaded model's input tensor is channel-first — NCHW,
  /// `[1,3,H,W]` — rather than channel-last, NHWC, `[1,H,W,3]`.
  ///
  /// Ultralytics' current LiteRT/`format="litert"` export (the only export
  /// path as of Ultralytics 8.4.83 — the standalone `tflite` format now
  /// silently redirects to it) traces the PyTorch model directly and
  /// produces NCHW. The legacy onnx2tf-based export this service originally
  /// supported produced NHWC. Detected per-load in [detectInputLayout];
  /// [_preprocessImage] writes pixels in whichever order this says.
  bool _channelsFirst = false;
  /// Default confidence threshold — applied when no user override is set.
  static const double defaultConfidenceThreshold = 0.1;
  static const String _prefsKey = 'disc_confidence_threshold';

  /// Runtime confidence threshold, loaded from SharedPreferences.
  double _confidenceThreshold = defaultConfidenceThreshold;
  double get confidenceThreshold => _confidenceThreshold;

  /// Maximum normalized distance a detection can jump per frame-step
  /// during spatial coherence filtering (8% of frame dimension).
  ///
  /// This is also the single source of truth for how wide the tracking-mode
  /// search window is (see [_searchWindowSizeFor]) — a window wider than
  /// what this constant allows would accept detections that
  /// [_filterSpatialCoherence] then discards downstream as an impossible
  /// jump, silently undoing the tracker's work.
  static const double _maxJumpPerFrame = 0.08;
  /// Maximum consecutive frames to skip when building a coherent chain.
  static const int _maxChainGap = 5;

  /// How much wider than the coherence filter's raw per-frame budget the
  /// tracking search window is, to absorb prediction error on top of the
  /// motion the velocity estimate already accounts for.
  static const double _trackingWindowMargin = 1.5;
  static const double _minTrackingWindowSize = 0.15;
  static const double _maxTrackingWindowSize = 0.5;
  /// Frames the tracker will coast on velocity alone (no confirmed
  /// detection) before giving up the lock and reverting to full-frame
  /// discovery. Matches [_maxChainGap] — no point tolerating a gap here that
  /// the coherence filter won't bridge anyway.
  static const int _maxOcclusionFrames = _maxChainGap;
  /// Exponential smoothing factor applied to new velocity estimates, so a
  /// single noisy detection doesn't yank the predicted search window off the
  /// disc's real trajectory.
  static const double _velocitySmoothing = 0.6;

  /// Reusable inference buffers.
  ///
  /// A 640x640x3 input alone is over a million boxed doubles; rebuilding
  /// both input and output buffers per frame dominated tracking cost over a
  /// multi-hundred-frame run. The shapes are constant for a given model
  /// (until it's swapped — see [_loadModelImpl]), so allocate once and
  /// overwrite in place.
  List<List<List<List<double>>>>? _inputBuffer;
  List<List<List<double>>>? _outputBuffer;
  List<int>? _outputBufferShape;

  /// Guards against overlapping [processVideo] runs, which would interleave
  /// progress/status updates and race on [_lastResult].
  bool _processLock = false;

  /// Set by [cancelProcessing]; cleared at the start and end of every
  /// [processVideo] run.
  bool _cancelRequested = false;

  /// Serializes concurrent [loadModel] calls so two callers cannot each build
  /// an Interpreter and leak one of them.
  Future<void>? _loadInFlight;

  DiscDetectionService() {
    _loadThreshold();
  }

  Future<void> _loadThreshold() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getDouble(_prefsKey);
      if (stored != null) {
        _confidenceThreshold = stored.clamp(0.01, 0.95);
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> setConfidenceThreshold(double value) async {
    _confidenceThreshold = value.clamp(0.01, 0.95);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefsKey, _confidenceThreshold);
    } catch (_) {}
  }

  /// Load the TFLite model. Uses a custom (retrained) model if available,
  /// otherwise falls back to the bundled asset model.
  Future<void> loadModel({String? customModelPath, bool forceReload = false}) {
    if (_isModelLoaded && !forceReload) return Future<void>.value();

    // Join an in-flight load instead of starting a second one.
    final inFlight = _loadInFlight;
    if (inFlight != null) return inFlight;

    final load = _loadModelImpl(
      customModelPath: customModelPath,
      forceReload: forceReload,
    ).whenComplete(() => _loadInFlight = null);
    _loadInFlight = load;
    return load;
  }

  Future<void> _loadModelImpl({
    String? customModelPath,
    bool forceReload = false,
  }) async {
    try {
      File modelFile;
      final resolvedCustomPath = customModelPath ?? await _getDownloadedModelPath();

      if (resolvedCustomPath != null && await File(resolvedCustomPath).exists()) {
        modelFile = File(resolvedCustomPath);
        debugPrint('Loading custom disc detection model: $resolvedCustomPath');
      } else {
        final modelData =
            await rootBundle.load('assets/models/disc_detector.tflite');
        final tempDir = await getTemporaryDirectory();
        modelFile = File('${tempDir.path}/disc_detector.tflite');
        await modelFile.writeAsBytes(modelData.buffer.asUint8List());
        debugPrint('Loading bundled disc detection model');
      }

      // Build the replacement interpreter before swapping it in, and close
      // the old one only after the swap. This keeps _interpreter non-null
      // at every point a concurrent processVideo()/_detectDisc() call could
      // observe it, instead of nulling it out for the duration of the load.
      final options = InterpreterOptions();
      _configureAccelerationDelegate(options);

      Interpreter newInterpreter;
      try {
        newInterpreter = Interpreter.fromFile(modelFile, options: options);
      } catch (e) {
        // GPU delegate creation/binding can fail on unsupported hardware or
        // emulators; fall back to plain CPU inference rather than losing
        // detection entirely.
        debugPrint('GPU-accelerated interpreter failed to load ($e); '
            'retrying on CPU');
        newInterpreter = Interpreter.fromFile(modelFile);
      }

      // The model's actual input geometry drives preprocessing, not an
      // assumed constant — see the comment on [_defaultInputSize].
      final inputShape = newInterpreter.getInputTensor(0).shape;
      final layout = detectInputLayout(inputShape);
      _inputSize = layout.size;
      _channelsFirst = layout.channelsFirst;
      if (!layout.recognized) {
        debugPrint('Model input shape $inputShape is neither NHWC ([1,H,W,3]) '
            'nor NCHW ([1,3,H,W]); guessing size=$_inputSize, channel-last. '
            'Inference will throw if that mismatches what the interpreter '
            'actually expects.');
      }

      _validateModelGeometry(newInterpreter);

      final oldInterpreter = _interpreter;
      _interpreter = newInterpreter;
      _isModelLoaded = true;
      // A replacement model may have a different input/output shape, so the
      // cached buffers are no longer valid.
      _inputBuffer = null;
      _outputBuffer = null;
      _outputBufferShape = null;
      oldInterpreter?.close();
      debugPrint(
          'Disc detection model loaded successfully (input=${_inputSize}x$_inputSize)');
    } catch (e) {
      debugPrint('Error loading disc detection model: $e');
      rethrow;
    }
  }

  /// Determines the square input size and channel order from a loaded
  /// model's input tensor shape.
  ///
  /// Distinguishes NHWC (`[1,H,W,3]`) from NCHW (`[1,3,H,W]`) by which
  /// dimension after the batch dim equals 3 — the channel count. This is
  /// unambiguous for any real detector: a stride-32 head needs an input of
  /// at least 32px, so a dimension of exactly 3 can only ever be the
  /// channel axis, never a spatial one. Falls back to the historical NHWC
  /// assumption, with `recognized: false`, for a shape that isn't 4D or
  /// doesn't match either pattern — [_validateModelGeometry]'s anchor-count
  /// check will flag it downstream if the guess is wrong.
  @visibleForTesting
  static ({int size, bool channelsFirst, bool recognized}) detectInputLayout(
      List<int> shape) {
    if (shape.length == 4 && shape[3] == 3) {
      return (size: shape[1], channelsFirst: false, recognized: true);
    }
    if (shape.length == 4 && shape[1] == 3) {
      return (size: shape[2], channelsFirst: true, recognized: true);
    }
    if (shape.length >= 3 && shape[1] > 0) {
      return (size: shape[1], channelsFirst: false, recognized: false);
    }
    return (size: _defaultInputSize, channelsFirst: false, recognized: false);
  }

  /// Anchor count an ultralytics anchor-free `Detect` head produces for a
  /// square [inputSize]: one prediction per cell across the P3/P4/P5 strides
  /// (8, 16, 32). 640 gives 80²+40²+20² = 8400; 320 gives 40²+20²+10² = 2100.
  @visibleForTesting
  static int expectedAnchors(int inputSize) {
    const strides = [8, 16, 32];
    var total = 0;
    for (final stride in strides) {
      final cells = inputSize ~/ stride;
      total += cells * cells;
    }
    return total;
  }

  /// Logs the loaded model's geometry and warns — but never throws — when it
  /// doesn't look like the single-class YOLO11 detector this app expects.
  ///
  /// Warn-and-continue is deliberate. A model downloaded from the training
  /// server is allowed to ship at a different geometry than the bundled
  /// asset, and refusing to load it would break detection outright rather
  /// than degrading. Everything downstream already adapts: [_inputSize] is
  /// read from the input tensor, and [_parseBestDetection] branches on the
  /// output layout instead of assuming one.
  void _validateModelGeometry(Interpreter interpreter) {
    final inputShape = interpreter.getInputTensor(0).shape;
    final outputShape = interpreter.getOutputTensor(0).shape;
    debugPrint('Detector geometry: input $inputShape '
        '(${_channelsFirst ? 'NCHW' : 'NHWC'}), output $outputShape');

    if (_inputSize % 32 != 0) {
      debugPrint('Detector warning: input size $_inputSize is not a multiple '
          'of 32, so the P5 stride grid does not divide evenly.');
    }

    if (outputShape.length < 3) {
      debugPrint('Detector warning: output shape $outputShape is not the '
          'expected 3-dimensional Detect head output.');
      return;
    }

    // Transposed [1, 4+nc, N] is what ultralytics TFLite exports emit; the
    // parser also accepts the standard [1, N, 4+nc] layout.
    final isTransposed = outputShape[1] == 5 || outputShape[1] == 6;
    final channels = isTransposed ? outputShape[1] : outputShape[2];
    final anchors = isTransposed ? outputShape[2] : outputShape[1];

    if (channels != 5 && channels != 6) {
      debugPrint('Detector warning: output $outputShape has $channels '
          'channels; expected 5 (4 box coords + 1 class) or 6.');
    } else if (channels == 6) {
      debugPrint('Detector note: model reports 2 classes; only class 0 '
          '(disc) is used.');
    }

    final expected = expectedAnchors(_inputSize);
    if (anchors != expected) {
      debugPrint('Detector warning: output $outputShape has $anchors anchors, '
          'but a ${_inputSize}x$_inputSize anchor-free Detect head should '
          'produce $expected. The model may have been exported at a different '
          'size than its input tensor declares.');
    }
  }

  /// Adds the platform's GPU delegate to [options] for faster inference,
  /// falling back silently to CPU-only options if delegate creation throws
  /// (e.g. unsupported hardware, some emulators).
  void _configureAccelerationDelegate(InterpreterOptions options) {
    try {
      if (Platform.isAndroid) {
        options.addDelegate(GpuDelegateV2());
      } else if (Platform.isIOS) {
        options.useMetalDelegateForIOS = true;
      }
    } catch (e) {
      debugPrint('GPU delegate setup failed, will run on CPU: $e');
    }
  }

  Future<String?> _getDownloadedModelPath() async {
    final appDir = await getApplicationDocumentsDirectory();
    final modelPath = '${appDir.path}/training_data/models/disc_detector.tflite';
    return await File(modelPath).exists() ? modelPath : null;
  }

  /// Requests that an in-flight [processVideo] stop at the next frame
  /// boundary, completing with a [DetectionCancelledException].
  ///
  /// Granularity is one frame: inference is synchronous, so the frame already
  /// in flight always finishes.
  void cancelProcessing() {
    if (_isProcessing) _cancelRequested = true;
  }

  /// Process a video file: extract frames, run detection, filter & smooth.
  ///
  /// [startMs]/[endMs] restrict extraction to a trimmed range. Frame index 0
  /// is the first frame at or after [startMs], so every returned
  /// [DiscDetection.frameIndex] is relative to the trim start — matching the
  /// frame space the player and any user-placed keyframes already use.
  Future<FlightTrackingResult> processVideo(
    String videoPath, {
    double fps = 10.0, // Lower FPS = faster + larger disc movement per frame
    int maxFrames = 300,
    int startMs = 0,
    int? endMs,
  }) async {
    if (_processLock) {
      throw StateError(
          'DiscDetectionService.processVideo() is already running; await the '
          'in-flight call before starting another.');
    }
    _processLock = true;

    // Everything after the lock is acquired runs inside try/finally. Model
    // loading and temp-directory setup can both throw, and releasing the lock
    // only in the inner block would wedge the service after the first failure.
    Directory? framesDir;
    try {
      // Reset progress state *before* loading the model. Loading copies a
      // multi-megabyte asset out of the bundle and builds an interpreter, and
      // on a fresh install that is the first thing the user waits on —
      // leaving the previous run's 'Complete!' at 100% on screen for those
      // seconds makes a determinate progress bar actively misleading.
      _cancelRequested = false;
      _isProcessing = true;
      _progress = 0.0;

      if (!_isModelLoaded) {
        _statusMessage = 'Loading detector...';
        notifyListeners();
        await loadModel();
      }

      _statusMessage = 'Extracting frames...';
      notifyListeners();

      final tempDir = await getTemporaryDirectory();
      framesDir = Directory(
          '${tempDir.path}/disc_detect_${DateTime.now().millisecondsSinceEpoch}');
      await framesDir.create(recursive: true);

      // Step 1: Extract frames at lower FPS for speed
      final frames = await _extractFrames(
        videoPath,
        framesDir.path,
        fps: fps,
        maxFrames: maxFrames,
        startMs: startMs,
        endMs: endMs,
      );

      if (frames.isEmpty) {
        throw Exception('No frames could be extracted from video');
      }

      // Frame indices can be sparse if extraction skipped a frame, so the
      // trajectory's frame span is the last index reached, not the count.
      final totalFrames = frames.last.index + 1;

      debugPrint('Extracted ${frames.length} frames '
          '(span $totalFrames) at ${fps}fps');

      _statusMessage = 'Detecting disc in ${frames.length} frames...';
      notifyListeners();

      // Step 2: Track-by-detection — full-frame discovery to find the disc,
      // then windowed tracking that follows the established track instead of
      // re-scanning the whole frame every time.
      final rawDetections = <DiscDetection>[];
      double firstImageW = 640;
      double firstImageH = 1138;
      _DiscTrack? track;

      for (int i = 0; i < frames.length; i++) {
        final frame = frames[i];
        _progress = (i / frames.length) * 0.7;
        // Rebuild the status string only every tenth frame — it allocates —
        // but notify every frame: _progress changes each iteration, and a
        // determinate progress bar bound to it would otherwise advance in
        // multi-second jumps.
        if (i % 10 == 0) {
          _statusMessage = 'Detecting disc: frame ${i + 1}/${frames.length}';
        }
        notifyListeners();

        final imageFile = File(frame.path);
        if (!await imageFile.exists()) continue;

        final bytes = await imageFile.readAsBytes();
        final image = img.decodeImage(bytes);
        if (image == null) continue;

        if (i == 0) {
          firstImageW = image.width.toDouble();
          firstImageH = image.height.toDouble();
        }

        DiscDetection? chosen;
        final currentTrack = track;

        if (currentTrack == null) {
          // Discovery mode: full-frame scan for the disc leaving the
          // thrower's hand or in early flight.
          chosen = await _detectDisc(image, frame.index, fps);
        } else {
          // Tracking mode: search only the region the track predicts the
          // disc has moved to.
          final gap = frame.index - currentTrack.lastFrameIndex;
          final (predictedX, predictedY) = currentTrack.predict(gap);
          final candidates = await detectInWindow(
            image,
            frame.index,
            fps,
            centerX: predictedX,
            centerY: predictedY,
            regionSize: _searchWindowSizeFor(gap),
          );

          if (candidates.isEmpty) {
            currentTrack.occlusionStreak++;
            if (currentTrack.occlusionStreak > _maxOcclusionFrames) {
              // Lost the lock — fall back to full-frame discovery on the
              // next frame rather than keep coasting indefinitely.
              track = null;
            }
          } else {
            chosen = candidates.length == 1
                ? candidates.first
                : selectClosestCandidate(candidates, predictedX, predictedY);
          }
        }

        if (chosen != null) {
          rawDetections.add(chosen);
          if (track == null) {
            track = _DiscTrack(
              x: chosen.x,
              y: chosen.y,
              lastFrameIndex: chosen.frameIndex,
            );
          } else {
            track.confirm(chosen);
          }
        }

        // Yield after every frame, not every tenth. Inference is synchronous
        // and blocks this isolate for the duration of the call, so this is the
        // only chance the UI gets to paint between frames.
        await Future.delayed(Duration.zero);

        // Checked after the yield, so a cancel tapped while this frame was in
        // inference is seen now rather than a frame late.
        if (_cancelRequested) {
          throw const DetectionCancelledException();
        }
      }

      debugPrint(
          'Raw detections: ${rawDetections.length}/${frames.length} frames');

      // Step 3: Spatial coherence filtering — find the real flight path
      _progress = 0.8;
      _statusMessage = 'Filtering trajectory...';
      notifyListeners();

      final coherent = _filterSpatialCoherence(
        rawDetections,
        totalFrames,
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

      final interpolated = _interpolateDetections(smoothed, totalFrames, fps);

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
        totalFrames: totalFrames,
      );

      _lastResult = result;
      notifyListeners();
      return result;
    } finally {
      if (framesDir != null) {
        try {
          await framesDir.delete(recursive: true);
        } catch (e) {
          debugPrint('Failed to clean up detection frames: $e');
        }
      }

      _processLock = false;
      _cancelRequested = false;
      if (_isProcessing) {
        _isProcessing = false;
        notifyListeners();
      }
    }
  }

  /// Extract frames from video at the given FPS in a single FFmpeg pass,
  /// scaled down to a 640px-wide working resolution as they're extracted.
  ///
  /// Replaces what used to be [maxFrames] separate `video_thumbnail` calls
  /// (one native decode-and-seek per frame) with one `fps` + `scale` filter
  /// pass over the whole clip — the dominant cost in extraction was that
  /// per-frame process/decode overhead, not the decoding itself.
  ///
  /// Returns only the frames that made it to disk, each tagged with its
  /// sequence index — the list can be sparse if ffmpeg exits partway through
  /// (in which case whatever frames it did write are still salvaged and
  /// returned, matching the old loop's tolerance for a truncated run).
  Future<List<ExtractedFrame>> _extractFrames(
    String videoPath,
    String outputDir, {
    required double fps,
    required int maxFrames,
    int startMs = 0,
    int? endMs,
  }) async {
    final outputPattern = '$outputDir/frame_%04d.jpg';

    final session = await FFmpegKit.execute(buildExtractCommand(
      videoPath: videoPath,
      outputPattern: outputPattern,
      fps: fps,
      maxFrames: maxFrames,
      startMs: startMs,
      endMs: endMs,
    ));

    final returnCode = await session.getReturnCode();

    final dir = Directory(outputDir);
    var files = <File>[];
    if (await dir.exists()) {
      files = await dir
          .list()
          .where((e) => e is File && e.path.toLowerCase().endsWith('.jpg'))
          .cast<File>()
          .toList();
      files.sort((a, b) => a.path.compareTo(b.path));
    }

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      if (files.isEmpty) {
        debugPrint('FFmpeg frame extraction failed with no output: $logs');
        return const [];
      }
      debugPrint('FFmpeg frame extraction ended early '
          '(${files.length} frame(s) salvaged): $logs');
    }

    // ffmpeg's %04d sequence has no ability to skip a busted frame, so it's
    // contiguous by construction — list position doubles as the frame index,
    // counted from the first frame at or after the trim start.
    return [
      for (int i = 0; i < files.length; i++)
        ExtractedFrame(index: i, path: files[i].path),
    ];
  }

  /// Builds the FFmpeg argument string for one frame-extraction pass.
  ///
  /// Split out from [_extractFrames] so it can be asserted in a host test.
  /// The failure mode here is silent — a wrong `-ss` yields frames from the
  /// wrong part of the clip, which still look perfectly plausible — and
  /// string construction is exactly what breaks unnoticed.
  @visibleForTesting
  static String buildExtractCommand({
    required String videoPath,
    required String outputPattern,
    required double fps,
    required int maxFrames,
    int startMs = 0,
    int? endMs,
  }) {
    final command = StringBuffer('-y -i "$videoPath"');

    // Output seeking (`-ss` *after* `-i`) rather than input seeking. Input
    // seeking is faster but can snap to the nearest keyframe on some codecs,
    // which would shift every frame index relative to the trim start and
    // silently misalign the overlay. These clips are seconds long, so
    // decoding from zero costs far less than inference does, and exactness
    // is the entire point of honoring the trim.
    if (startMs > 0) {
      command.write(' -ss ${_secondsArg(startMs)}');
    }
    if (endMs != null && endMs > startMs) {
      command.write(' -t ${_secondsArg(endMs - startMs)}');
    }

    // scale=min(640\,iw):-2 matches the old maxWidth:640 behavior — downscale
    // to a 640px-wide working resolution but never upscale a smaller source,
    // and -2 keeps the resulting height even (required by some encoders).
    // The comma is backslash-escaped per ffmpeg's own filtergraph syntax —
    // not shell-quoted — because FFmpegKit tokenizes this string itself
    // rather than handing it to a real shell; single/double quotes around
    // the expression would be passed through literally and fail to parse.
    command
      ..write(' -vf "fps=$fps,scale=min(640\\,iw):-2"')
      ..write(' -frames:v $maxFrames -q:v 3 "$outputPattern"');

    return command.toString();
  }

  /// Milliseconds rendered as an ffmpeg seconds argument. `toStringAsFixed`
  /// is locale-independent in Dart, so this cannot emit a comma as the
  /// decimal separator on a device with a European locale.
  static String _secondsArg(int milliseconds) =>
      (milliseconds / 1000).toStringAsFixed(3);

  /// Run inference on [image] as-is (already cropped to whatever region the
  /// caller wants examined) and return the raw model output, or null if no
  /// model is loaded. Shared by full-frame discovery and windowed tracking
  /// so both go through identical preprocessing and buffer reuse.
  ({List<List<List<double>>> output, List<int> shape})? _runInference(
    img.Image image,
    int frameIndex,
  ) {
    if (_interpreter == null) return null;

    final inputImage = _preprocessImage(image);

    final outputTensor = _interpreter!.getOutputTensor(0);
    final outputShape = outputTensor.shape;
    final outputType = outputTensor.type;
    if (outputShape.length < 3) return null;

    final outputBuffer = _outputBufferFor(outputShape);

    _interpreter!.run(inputImage, outputBuffer);

    if (frameIndex == 0) {
      debugPrint('TFLite output shape: $outputShape, type: $outputType');
    }

    return (output: outputBuffer, shape: outputShape);
  }

  /// Run YOLO inference on a full frame.
  Future<DiscDetection?> _detectDisc(
    img.Image image,
    int frameIndex,
    double fps,
  ) async {
    final result = _runInference(image, frameIndex);
    if (result == null) return null;
    return _parseBestDetection(result.output, result.shape, frameIndex, fps);
  }

  /// Run YOLO inference restricted to a square window of [image] centered at
  /// normalized ([centerX], [centerY]) with side length [regionSize]
  /// (normalized to the image's shorter dimension). Returns every candidate
  /// above the confidence threshold, remapped back to full-frame normalized
  /// coordinates — unlike [_detectDisc], which only surfaces the single best
  /// one. Used by tracking mode, where the caller needs to pick the
  /// candidate consistent with the established track rather than assuming
  /// the top-confidence one is the disc.
  ///
  /// The crop is square in source pixels (not squashed independently on each
  /// axis) so a window clamped against a frame edge doesn't get a different
  /// aspect ratio than one in the middle of the frame — that would make the
  /// model see a distorted disc shape inconsistently frame-to-frame.
  Future<List<DiscDetection>> detectInWindow(
    img.Image image,
    int frameIndex,
    double fps, {
    required double centerX,
    required double centerY,
    required double regionSize,
    int maxCandidates = 5,
  }) async {
    if (!_isModelLoaded) await loadModel();
    if (_interpreter == null) return const [];

    final minDim = min(image.width, image.height);
    final side = (regionSize * minDim).round().clamp(20, minDim);

    var xMin = (centerX * image.width - side / 2).round();
    var yMin = (centerY * image.height - side / 2).round();
    xMin = xMin.clamp(0, image.width - side);
    yMin = yMin.clamp(0, image.height - side);

    final crop = img.copyCrop(image, x: xMin, y: yMin, width: side, height: side);
    final result = _runInference(crop, frameIndex);
    if (result == null) return const [];

    final candidates = _parseCandidateDetections(
      result.output,
      result.shape,
      frameIndex,
      fps,
      maxCandidates: maxCandidates,
    );

    return [
      for (final d in candidates)
        DiscDetection(
          frameIndex: d.frameIndex,
          x: ((xMin + d.x * side) / image.width).clamp(0.0, 1.0),
          y: ((yMin + d.y * side) / image.height).clamp(0.0, 1.0),
          width: d.width * side / image.width,
          height: d.height * side / image.height,
          confidence: d.confidence,
          timestamp: d.timestamp,
        ),
    ];
  }

  /// Picks the candidate whose position best matches ([predictedX],
  /// [predictedY]) — the track's last known position plus motion prediction
  /// — instead of blindly taking the highest-confidence or largest
  /// detection. A small confidence term only breaks close ties; motion
  /// consistency dominates, since a distant high-confidence blob is more
  /// likely clutter (a hand, a second disc, a shadow) than the tracked disc
  /// suddenly teleporting.
  DiscDetection selectClosestCandidate(
    List<DiscDetection> candidates,
    double predictedX,
    double predictedY,
  ) {
    var best = candidates.first;
    var bestScore = double.infinity;
    for (final c in candidates) {
      final dx = c.x - predictedX;
      final dy = c.y - predictedY;
      final score = sqrt(dx * dx + dy * dy) - c.confidence * 0.02;
      if (score < bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return best;
  }

  /// Search-window side length, normalized to the frame's shorter
  /// dimension, for a track that hasn't been confirmed in [frameGap] frames.
  /// Deliberately tied to [_maxJumpPerFrame] rather than
  /// an independent constant: a window wider than that budget would accept
  /// detections [_filterSpatialCoherence] later throws away as an
  /// impossible jump, so the two must move together.
  double _searchWindowSizeFor(int frameGap) {
    final gap = frameGap.clamp(1, _maxOcclusionFrames + 1);
    final size = _maxJumpPerFrame * gap * 2 * _trackingWindowMargin;
    return size.clamp(_minTrackingWindowSize, _maxTrackingWindowSize);
  }

  /// Preprocess image for YOLO: resize to the model's input size, normalize
  /// to 0-1, and write in whichever tensor layout [_channelsFirst] says the
  /// loaded model expects (see [detectInputLayout]).
  ///
  /// Writes into a buffer that is allocated once and reused for every frame —
  /// the returned list is owned by this service and is overwritten by the next
  /// call, so callers must not retain it across frames. Rebuilt whenever the
  /// model (and therefore its shape) changes — see [_loadModelImpl], which
  /// nulls [_inputBuffer] on every load, so a cached buffer never survives a
  /// layout change.
  List<List<List<List<double>>>> _preprocessImage(img.Image image) {
    final resized =
        img.copyResize(image, width: _inputSize, height: _inputSize);

    // Read the frame as one packed RGB byte array rather than calling
    // getPixel() per pixel. getPixel allocates a Pixel accessor on every
    // call — 409,600 of them per frame at 640x640, once per frame for a
    // whole clip. getBytes hands back the underlying bytes in one go.
    final bytes = resized.getBytes(order: img.ChannelOrder.rgb);

    if (_channelsFirst) {
      return _writeChannelsFirst(bytes);
    }
    return _writeChannelsLast(bytes);
  }

  /// NHWC: `[1, H, W, 3]`, pixels interleaved as R,G,B per pixel. The legacy
  /// onnx2tf-based export produced this layout, and it's what every model
  /// this service supported before Ultralytics moved to LiteRT used.
  List<List<List<List<double>>>> _writeChannelsLast(List<int> bytes) {
    final buffer = _inputBuffer ??= List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (_) => List.generate(
          _inputSize,
          (_) => List<double>.filled(3, 0.0),
        ),
      ),
    );

    final plane = buffer[0];
    int i = 0;
    for (int y = 0; y < _inputSize; y++) {
      final row = plane[y];
      for (int x = 0; x < _inputSize; x++) {
        final rgb = row[x];
        rgb[0] = bytes[i] / 255.0;
        rgb[1] = bytes[i + 1] / 255.0;
        rgb[2] = bytes[i + 2] / 255.0;
        i += 3;
      }
    }
    return buffer;
  }

  /// NCHW: `[1, 3, H, W]`, channel-planar — all of R, then all of G, then
  /// all of B. Ultralytics' current LiteRT/w8a32 export produces this by
  /// tracing the PyTorch model directly rather than going through the old
  /// onnx2tf conversion.
  List<List<List<List<double>>>> _writeChannelsFirst(List<int> bytes) {
    final buffer = _inputBuffer ??= List.generate(
      1,
      (_) => List.generate(
        3,
        (_) => List.generate(
          _inputSize,
          (_) => List<double>.filled(_inputSize, 0.0),
        ),
      ),
    );

    final planes = buffer[0];
    final rPlane = planes[0];
    final gPlane = planes[1];
    final bPlane = planes[2];
    int i = 0;
    for (int y = 0; y < _inputSize; y++) {
      final rRow = rPlane[y];
      final gRow = gPlane[y];
      final bRow = bPlane[y];
      for (int x = 0; x < _inputSize; x++) {
        rRow[x] = bytes[i] / 255.0;
        gRow[x] = bytes[i + 1] / 255.0;
        bRow[x] = bytes[i + 2] / 255.0;
        i += 3;
      }
    }
    return buffer;
  }

  /// Reusable output buffer matching [shape]; reallocated only when the shape
  /// changes (i.e. after a model swap). `Interpreter.run` fully overwrites the
  /// buffer, so stale contents from the previous frame do not leak through.
  List<List<List<double>>> _outputBufferFor(List<int> shape) {
    final cached = _outputBuffer;
    final cachedShape = _outputBufferShape;
    if (cached != null &&
        cachedShape != null &&
        cachedShape.length == shape.length &&
        cachedShape[0] == shape[0] &&
        cachedShape[1] == shape[1] &&
        cachedShape[2] == shape[2]) {
      return cached;
    }

    final created = List.generate(
      shape[0],
      (_) => List.generate(
        shape[1],
        (_) => List<double>.filled(shape[2], 0.0),
      ),
    );
    _outputBuffer = created;
    _outputBufferShape = List<int>.from(shape);
    return created;
  }

  /// Parse YOLO detection output to find the best disc detection.
  ///
  /// Format is identical for YOLOv8 and YOLO11 exports (both use the
  /// ultralytics anchor-free `Detect` head): `[1, 4+nc, N]` transposed or
  /// `[1, N, 4+nc]` standard, coordinates normalized 0-1 by the TFLite
  /// export. Verified against the ultralytics head implementation — no
  /// version branching exists there — rather than assumed.
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
            x: _normalizeModelValue(output[0][0][i]),
            y: _normalizeModelValue(output[0][1][i]),
            width: _normalizeModelValue(output[0][2][i]),
            height: _normalizeModelValue(output[0][3][i]),
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
            x: _normalizeModelValue(output[0][i][0]),
            y: _normalizeModelValue(output[0][i][1]),
            width: _normalizeModelValue(output[0][i][2]),
            height: _normalizeModelValue(output[0][i][3]),
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

  /// Parse YOLO output into every candidate above the confidence threshold,
  /// sorted highest-confidence first and capped to [maxCandidates].
  ///
  /// Deliberately a separate implementation from [_parseBestDetection]
  /// rather than that method built on top of this one: [_parseBestDetection]
  /// is covered by tests pinned to its exact tie-breaking behavior (strict
  /// `>` comparison against a running best, so the first of equal-confidence
  /// candidates wins), and routing it through a sort here would depend on
  /// sort-stability guarantees that aren't worth risking for the sake of
  /// avoiding a few duplicated lines.
  List<DiscDetection> _parseCandidateDetections(
    List<List<List<double>>> output,
    List<int> shape,
    int frameIndex,
    double fps, {
    required int maxCandidates,
  }) {
    final dim1 = shape[1];
    final dim2 = shape[2];

    final candidates = <DiscDetection>[];
    final timestamp = Duration(milliseconds: (frameIndex * 1000 / fps).round());

    if (dim1 == 5 || dim1 == 6) {
      final numDetections = dim2;
      for (int i = 0; i < numDetections; i++) {
        final conf = dim1 == 5
            ? output[0][4][i]
            : output[0][4][i] * output[0][5][i];
        if (conf <= _confidenceThreshold) continue;
        candidates.add(DiscDetection(
          frameIndex: frameIndex,
          x: _normalizeModelValue(output[0][0][i]),
          y: _normalizeModelValue(output[0][1][i]),
          width: _normalizeModelValue(output[0][2][i]),
          height: _normalizeModelValue(output[0][3][i]),
          confidence: conf,
          timestamp: timestamp,
        ));
      }
    } else {
      final numDetections = dim1;
      for (int i = 0; i < numDetections; i++) {
        final conf = dim2 >= 6
            ? output[0][i][4] * output[0][i][5]
            : output[0][i][4];
        if (conf <= _confidenceThreshold) continue;
        candidates.add(DiscDetection(
          frameIndex: frameIndex,
          x: _normalizeModelValue(output[0][i][0]),
          y: _normalizeModelValue(output[0][i][1]),
          width: _normalizeModelValue(output[0][i][2]),
          height: _normalizeModelValue(output[0][i][3]),
          confidence: conf,
          timestamp: timestamp,
        ));
      }
    }

    candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
    return candidates.length > maxCandidates
        ? candidates.sublist(0, maxCandidates)
        : candidates;
  }

  double _normalizeModelValue(double value) {
    final normalized = value > 1.0 ? value / _inputSize : value;
    return normalized.clamp(0.0, 1.0).toDouble();
  }

  @visibleForTesting
  DiscDetection? parseBestDetectionForTesting(
    List<List<List<double>>> output,
    List<int> shape,
    int frameIndex,
    double fps,
  ) {
    return _parseBestDetection(output, shape, frameIndex, fps);
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
  ///
  /// [startMs]/[endMs] carry the same meaning as on [processVideo]: frame
  /// index 0 is the first frame at or after [startMs]. Callers working from
  /// user-placed keyframes must pass the trim range, since those keyframes
  /// are indexed from the trim start rather than the start of the file.
  Future<List<ExtractedFrame>> extractFrames(
    String videoPath,
    String outputDir, {
    required double fps,
    int maxFrames = 300,
    int startMs = 0,
    int? endMs,
  }) {
    return _extractFrames(
      videoPath,
      outputDir,
      fps: fps,
      maxFrames: maxFrames,
      startMs: startMs,
      endMs: endMs,
    );
  }

  /// Public access to smoothing for use by HybridDetectionService.
  List<DiscDetection> smoothDetections(
    List<DiscDetection> detections, {
    int windowSize = 3,
  }) {
    return _smoothDetections(detections, windowSize: windowSize);
  }

  /// Test hook for the spatial-coherence filter — the step that separates a
  /// real flight path from scattered false positives.
  @visibleForTesting
  List<DiscDetection> filterSpatialCoherenceForTesting(
    List<DiscDetection> detections,
    int totalFrames, {
    double maxJumpPerFrame = _maxJumpPerFrame,
    int maxGap = _maxChainGap,
    double fps = 10.0,
  }) {
    return _filterSpatialCoherence(
      detections,
      totalFrames,
      maxJumpPerFrame: maxJumpPerFrame,
      maxGap: maxGap,
      fps: fps,
    );
  }

  /// Test hook for gap interpolation.
  @visibleForTesting
  List<DiscDetection> interpolateDetectionsForTesting(
    List<DiscDetection> detections,
    int totalFrames,
    double fps,
  ) {
    return _interpolateDetections(detections, totalFrames, fps);
  }

  /// Test hook for the model-output coordinate normalization heuristic.
  @visibleForTesting
  double normalizeModelValueForTesting(double value) =>
      _normalizeModelValue(value);

  /// Test hook for [_preprocessImage]'s NHWC/NCHW write patterns, without
  /// needing a loaded interpreter to drive [_inputSize]/[_channelsFirst].
  @visibleForTesting
  List<List<List<List<double>>>> preprocessImageForTesting(
    img.Image image, {
    required int inputSize,
    required bool channelsFirst,
  }) {
    _inputSize = inputSize;
    _channelsFirst = channelsFirst;
    _inputBuffer = null;
    return _preprocessImage(image);
  }

  @override
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isModelLoaded = false;
    _inputBuffer = null;
    _outputBuffer = null;
    _outputBufferShape = null;
    super.dispose();
  }
}
