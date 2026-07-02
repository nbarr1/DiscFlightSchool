import 'disc_detection_service.dart';

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

  const TrackerSession({
    required this.videoPath,
    required this.fps,
    required this.totalFrames,
    required this.videoWidth,
    required this.videoHeight,
  });
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
        final x = _catmullRom(p0.x, kfStart.x, kfEnd.x, p3.x, t);
        final y = _catmullRom(p0.y, kfStart.y, kfEnd.y, p3.y, t);
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

  double _catmullRom(double p0, double p1, double p2, double p3, double t) {
    final t2 = t * t;
    final t3 = t2 * t;
    return 0.5 *
        ((2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
  }

  @override
  void dispose() {}
}
