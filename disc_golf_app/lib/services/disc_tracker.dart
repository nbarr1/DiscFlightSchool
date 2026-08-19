import 'package:flutter/foundation.dart';

import '../utils/angle_calculator.dart';
import 'disc_detection_service.dart';
import 'hybrid_detection_service.dart';

/// Frame-index maths shared by the video player and every tracker.
///
/// Frame index 0 is the first frame at or after the trim start — *not* the
/// start of the file. Both directions live here so the player's live frame
/// counter and a tracker's returned detections cannot drift apart: they did,
/// before this existed, whenever a clip was trimmed.
class FrameIndexing {
  const FrameIndexing._();

  /// The frame index a playback position maps to, relative to [trimStartMs].
  static int frameIndexAt({
    required int positionMs,
    required int trimStartMs,
    required double fps,
  }) =>
      ((positionMs - trimStartMs) * fps / 1000).round();

  /// The offset of [frameIndex] from the trim start.
  static Duration timestampOf({
    required int frameIndex,
    required double fps,
  }) =>
      Duration(milliseconds: (frameIndex * 1000 / fps).round());
}

/// A single user-placed seed point marking the disc's position at a frame.
class TrackerSeedPoint {
  final int frameIndex;
  final double x; // normalized 0-1
  final double y; // normalized 0-1

  const TrackerSeedPoint({
    required this.frameIndex,
    required this.x,
    required this.y,
  });
}

/// Parameters describing the video being tracked.
class TrackerSession {
  final String videoPath;
  final double fps;
  final int totalFrames;
  final double videoWidth;
  final double videoHeight;

  /// Start of the trimmed range, in milliseconds from the start of the file.
  ///
  /// Frame index 0 is the first frame at or after this point. Every
  /// [TrackerSeedPoint.frameIndex], every [DiscDetection.frameIndex] a
  /// tracker returns, and the player's own current frame all live in that
  /// space. A tracker that extracts frames from the start of the file
  /// instead would pair every position with an image from the wrong moment.
  final int trimStartMs;

  /// End of the trimmed range in milliseconds, or null for end-of-file.
  final int? trimEndMs;

  const TrackerSession({
    required this.videoPath,
    required this.fps,
    required this.totalFrames,
    required this.videoWidth,
    required this.videoHeight,
    this.trimStartMs = 0,
    this.trimEndMs,
  });

  /// The frame index a playback position maps to in this session's space.
  int frameIndexAt(int positionMs) => FrameIndexing.frameIndexAt(
        positionMs: positionMs,
        trimStartMs: trimStartMs,
        fps: fps,
      );

  /// The offset of [frameIndex] from the trim start.
  Duration timestampOf(int frameIndex) =>
      FrameIndexing.timestampOf(frameIndex: frameIndex, fps: fps);
}

/// Common contract for turning user-seeded points into a full per-frame
/// flight path. Lets the UI swap tracking strategies — pure geometric
/// spline, detection-refined hybrid, or a future fully-automatic
/// detector — without changing call sites.
abstract class DiscTracker {
  /// Progress in [0, 1] for the most recent [track] call.
  double get progress;

  /// Human-readable status for the most recent [track] call.
  String get statusMessage;

  /// Build a full per-frame [FlightTrackingResult] from the given seed
  /// points, ordered or unordered by frame index.
  Future<FlightTrackingResult> track({
    required TrackerSession session,
    required List<TrackerSeedPoint> seedPoints,
  });

  /// Release any resources held by this tracker. Safe to call multiple
  /// times and safe to call even if [track] was never invoked.
  void dispose();
}

/// Default tracker: pure Catmull-Rom spline through the seed points, with
/// no image analysis. Requires at least 2 seed points. This is the exact
/// interpolation logic that previously lived inline in
/// `VideoPlayerScreen._processKeyframes`.
class GeometricSplineTracker implements DiscTracker {
  double _progress = 0.0;
  String _statusMessage = '';

  @override
  double get progress => _progress;

  @override
  String get statusMessage => _statusMessage;

  @override
  Future<FlightTrackingResult> track({
    required TrackerSession session,
    required List<TrackerSeedPoint> seedPoints,
  }) async {
    if (seedPoints.length < 2) {
      throw ArgumentError.value(
        seedPoints.length,
        'seedPoints',
        'GeometricSplineTracker needs at least 2 seed points',
      );
    }

    _statusMessage = 'Generating spline...';
    _progress = 0.0;

    final sorted = List<TrackerSeedPoint>.from(seedPoints)
      ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));

    final detections = <DiscDetection>[];

    for (int i = 0; i < sorted.length - 1; i++) {
      final kfStart = sorted[i];
      final kfEnd = sorted[i + 1];

      final p0 = i > 0 ? sorted[i - 1] : kfStart;
      final p3 = i < sorted.length - 2 ? sorted[i + 2] : kfEnd;

      final frameSpan = kfEnd.frameIndex - kfStart.frameIndex;
      if (frameSpan <= 0) continue;

      final isLastSegment = i == sorted.length - 2;
      final endF = isLastSegment ? frameSpan : frameSpan - 1;

      for (int f = 0; f <= endF; f++) {
        final t = f / frameSpan;
        final x = AngleCalculator.catmullRom(p0.x, kfStart.x, kfEnd.x, p3.x, t);
        final y = AngleCalculator.catmullRom(p0.y, kfStart.y, kfEnd.y, p3.y, t);
        final frameIdx = kfStart.frameIndex + f;

        final isSeed = sorted.any((s) => s.frameIndex == frameIdx);

        detections.add(DiscDetection(
          frameIndex: frameIdx,
          x: x.clamp(0.0, 1.0),
          y: y.clamp(0.0, 1.0),
          width: 0.03,
          height: 0.03,
          confidence: isSeed ? 1.0 : 0.5,
          timestamp: Duration(
            milliseconds: (frameIdx * 1000 / session.fps).round(),
          ),
        ));
      }

      _progress = (i + 1) / (sorted.length - 1);
    }

    _progress = 1.0;
    _statusMessage = 'Complete!';

    return FlightTrackingResult(
      detections: detections,
      videoWidth: session.videoWidth,
      videoHeight: session.videoHeight,
      fps: session.fps,
      totalFrames: session.totalFrames,
    );
  }

  @override
  void dispose() {}
}

/// Detection-refined tracker: predicts a spline through the seed points,
/// then refines each frame against the actual video using YOLO (and
/// optionally color-blob matching) in a narrow search window. Requires at
/// least 3 seed points — delegates to [HybridDetectionService].
class HybridDiscTracker implements DiscTracker {
  final HybridDetectionService _service;

  HybridDiscTracker(DiscDetectionService detector)
      : _service = HybridDetectionService(detector);

  @override
  double get progress => _service.progress;

  @override
  String get statusMessage => _service.statusMessage;

  @override
  Future<FlightTrackingResult> track({
    required TrackerSession session,
    required List<TrackerSeedPoint> seedPoints,
  }) {
    if (seedPoints.length < 3) {
      throw ArgumentError.value(
        seedPoints.length,
        'seedPoints',
        'HybridDiscTracker needs at least 3 seed points',
      );
    }

    return _service.detect(
      seedKeyframes: seedPoints
          .map((s) => SeedKeyframe(
                frameIndex: s.frameIndex,
                x: s.x,
                y: s.y,
              ))
          .toList(),
      videoPath: session.videoPath,
      fps: session.fps,
      totalFrames: session.totalFrames,
      videoWidth: session.videoWidth,
      videoHeight: session.videoHeight,
      startMs: session.trimStartMs,
      endMs: session.trimEndMs,
    );
  }

  @override
  void dispose() {
    _service.dispose();
  }
}

/// Thrown when the detector model could not be loaded at all, so automatic
/// detection cannot run. Kept distinct from "ran, and found nothing" so the
/// UI can tell the user which of the two actually happened.
class DetectorModelUnavailableException implements Exception {
  final Object cause;

  const DetectorModelUnavailableException(this.cause);

  @override
  String toString() => 'Disc detector model unavailable: $cause';
}

/// The shape of [DiscDetectionService.processVideo], so tests can drive
/// [AutoDiscTracker] without the TFLite native library or path_provider.
typedef ProcessVideoFn = Future<FlightTrackingResult> Function(
  String videoPath, {
  double fps,
  int maxFrames,
  int startMs,
  int? endMs,
});

/// Fully automatic tracker: finds the disc with no user input at all.
///
/// This is the "future fully-automatic detector" [DiscTracker] was written to
/// accommodate. It delegates to [DiscDetectionService.processVideo], whose
/// track-by-detection pipeline discovers the disc with a full-frame scan and
/// then follows it frame-to-frame in a predicted search window.
class AutoDiscTracker implements DiscTracker {
  /// Upper bound on frames processed in one run, matching
  /// [DiscDetectionService.processVideo]'s own default.
  static const int maxProcessedFrames = 300;

  final DiscDetectionService _detector;
  final ProcessVideoFn _processVideo;
  final Future<void> Function()? _loadModelOverride;

  AutoDiscTracker(DiscDetectionService detector)
      : _detector = detector,
        _processVideo = detector.processVideo,
        _loadModelOverride = null;

  /// Test seam: drive the tracker with stand-ins for the two calls that need
  /// the TFLite native library, so the rest of its behaviour is host-testable.
  @visibleForTesting
  AutoDiscTracker.withProcessor(
    this._detector,
    this._processVideo, {
    Future<void> Function()? loadModel,
  }) : _loadModelOverride = loadModel;

  @override
  double get progress => _detector.progress;

  @override
  String get statusMessage => _detector.statusMessage;

  /// How many frames to process for [session], derived from the trimmed span
  /// rather than taking `processVideo`'s 300-frame default.
  ///
  /// A six-second trim at 10fps is ~61 frames; processing 300 would spend
  /// five times as long walking past the end of the clip — and at this
  /// model's input size, every frame costs real wall-clock time.
  @visibleForTesting
  static int framesForSession(TrackerSession session) {
    final endMs = session.trimEndMs;
    if (endMs == null) return maxProcessedFrames;

    final spanMs = endMs - session.trimStartMs;
    if (spanMs <= 0) return 2;

    // +1 because a span of N frame-intervals contains N+1 frame boundaries.
    final frames = (spanMs / 1000 * session.fps).ceil() + 1;
    return frames.clamp(2, maxProcessedFrames);
  }

  @override
  Future<FlightTrackingResult> track({
    required TrackerSession session,
    // Ignored — this tracker discovers the disc itself. Callers pass const [].
    required List<TrackerSeedPoint> seedPoints,
  }) async {
    // Load explicitly rather than leaning on processVideo's lazy load, so a
    // model that cannot load is reported as its own distinct failure instead
    // of surfacing as an anonymous exception partway through a run.
    try {
      await (_loadModelOverride ?? () => _detector.loadModel())();
    } catch (e) {
      throw DetectorModelUnavailableException(e);
    }

    final result = await _processVideo(
      session.videoPath,
      fps: session.fps,
      maxFrames: framesForSession(session),
      startMs: session.trimStartMs,
      endMs: session.trimEndMs,
    );

    // processVideo reports the dimensions of its decoded working frames —
    // downscaled to 640px wide during extraction — not the video the player
    // is showing. Re-state the session's own dimensions so anything that
    // reads these fields isn't quietly handed the extraction resolution.
    return FlightTrackingResult(
      detections: result.detections,
      videoWidth: session.videoWidth,
      videoHeight: session.videoHeight,
      fps: result.fps,
      totalFrames: result.totalFrames,
    );
  }

  /// Deliberately empty.
  ///
  /// [DiscDetectionService] is app-scoped — built and disposed in `main.dart`
  /// — while call sites dispose trackers in a `finally`. Forwarding this
  /// would close the shared TFLite interpreter for the rest of the app
  /// session. Unlike [HybridDiscTracker], this tracker constructs nothing of
  /// its own that needs releasing.
  @override
  void dispose() {}
}
