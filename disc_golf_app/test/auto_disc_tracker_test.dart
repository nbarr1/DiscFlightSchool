import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:disc_golf_app/services/disc_detection_service.dart';
import 'package:disc_golf_app/services/disc_tracker.dart';

/// Records what AutoDiscTracker asked processVideo for, so the forwarding can
/// be asserted without the TFLite native library or a real video file.
class _RecordingProcessor {
  String? videoPath;
  double? fps;
  int? maxFrames;
  int? startMs;
  int? endMs;
  int callCount = 0;

  FlightTrackingResult result = FlightTrackingResult(
    detections: [
      DiscDetection(
        frameIndex: 0,
        x: 0.1,
        y: 0.5,
        width: 0.03,
        height: 0.03,
        confidence: 0.9,
        timestamp: Duration.zero,
      ),
    ],
    // Deliberately unlike anything a caller would pass, so a test can tell
    // whether the tracker re-stated the session's dimensions or passed these
    // straight through.
    videoWidth: 640,
    videoHeight: 360,
    fps: 10.0,
    totalFrames: 1,
  );

  Future<FlightTrackingResult> call(
    String path, {
    double fps = 10.0,
    int maxFrames = 300,
    int startMs = 0,
    int? endMs,
  }) async {
    callCount++;
    videoPath = path;
    this.fps = fps;
    this.maxFrames = maxFrames;
    this.startMs = startMs;
    this.endMs = endMs;
    return result;
  }
}

TrackerSession _session({
  int trimStartMs = 0,
  int? trimEndMs,
  double fps = 10.0,
}) {
  return TrackerSession(
    videoPath: '/fake/path.mp4',
    fps: fps,
    totalFrames: 60,
    videoWidth: 1080,
    videoHeight: 1920,
    trimStartMs: trimStartMs,
    trimEndMs: trimEndMs,
  );
}

AutoDiscTracker _tracker(
  DiscDetectionService detector,
  _RecordingProcessor processor, {
  Future<void> Function()? loadModel,
}) {
  return AutoDiscTracker.withProcessor(
    detector,
    processor.call,
    loadModel: loadModel ?? () async {},
  );
}

void main() {
  // DiscDetectionService reads its confidence threshold from SharedPreferences
  // in its constructor.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AutoDiscTracker.framesForSession', () {
    test('derives the frame count from the trimmed span', () {
      // A six-second trim at 10fps is 61 frames, not processVideo's 300.
      expect(
        AutoDiscTracker.framesForSession(
          _session(trimStartMs: 2000, trimEndMs: 8000),
        ),
        61,
      );
    });

    test('falls back to the full cap when there is no trim end', () {
      expect(
        AutoDiscTracker.framesForSession(_session(trimStartMs: 2000)),
        AutoDiscTracker.maxProcessedFrames,
      );
    });

    test('clamps a very long span to the cap', () {
      expect(
        AutoDiscTracker.framesForSession(
          _session(trimStartMs: 0, trimEndMs: 600000),
        ),
        AutoDiscTracker.maxProcessedFrames,
      );
    });

    test('returns a usable minimum for a zero or inverted span', () {
      expect(
        AutoDiscTracker.framesForSession(
          _session(trimStartMs: 5000, trimEndMs: 5000),
        ),
        2,
      );
      expect(
        AutoDiscTracker.framesForSession(
          _session(trimStartMs: 5000, trimEndMs: 1000),
        ),
        2,
      );
    });
  });

  group('AutoDiscTracker.track', () {
    test('accepts an empty seed point list', () async {
      final processor = _RecordingProcessor();
      final tracker = _tracker(DiscDetectionService(), processor);

      final result = await tracker.track(
        session: _session(trimEndMs: 6000),
        seedPoints: const [],
      );

      expect(processor.callCount, 1);
      expect(result.detections, hasLength(1));
    });

    test('forwards the trim range verbatim', () async {
      final processor = _RecordingProcessor();
      final tracker = _tracker(DiscDetectionService(), processor);

      await tracker.track(
        session: _session(trimStartMs: 2500, trimEndMs: 8500),
        seedPoints: const [],
      );

      expect(processor.videoPath, '/fake/path.mp4');
      expect(processor.startMs, 2500);
      expect(processor.endMs, 8500);
      expect(processor.fps, 10.0);
    });

    test('passes the derived frame count, not the 300 default', () async {
      final processor = _RecordingProcessor();
      final tracker = _tracker(DiscDetectionService(), processor);

      await tracker.track(
        session: _session(trimStartMs: 2000, trimEndMs: 8000),
        seedPoints: const [],
      );

      expect(processor.maxFrames, 61);
    });

    test('reports the session dimensions rather than the extraction ones',
        () async {
      final processor = _RecordingProcessor();
      final tracker = _tracker(DiscDetectionService(), processor);

      final result = await tracker.track(
        session: _session(trimEndMs: 6000),
        seedPoints: const [],
      );

      // The processor returned 640x360 — the downscaled working resolution.
      expect(result.videoWidth, 1080);
      expect(result.videoHeight, 1920);
    });

    test('wraps a model load failure in DetectorModelUnavailableException',
        () async {
      final processor = _RecordingProcessor();
      final tracker = _tracker(
        DiscDetectionService(),
        processor,
        loadModel: () async => throw Exception('no native library'),
      );

      await expectLater(
        tracker.track(
          session: _session(trimEndMs: 6000),
          seedPoints: const [],
        ),
        throwsA(isA<DetectorModelUnavailableException>()),
      );
    });

    test('does not run detection when the model is unavailable', () async {
      final processor = _RecordingProcessor();
      final tracker = _tracker(
        DiscDetectionService(),
        processor,
        loadModel: () async => throw Exception('no native library'),
      );

      await expectLater(
        tracker.track(
          session: _session(trimEndMs: 6000),
          seedPoints: const [],
        ),
        throwsA(isA<DetectorModelUnavailableException>()),
      );
      expect(processor.callCount, 0);
    });
  });

  group('AutoDiscTracker.dispose', () {
    test('leaves the app-scoped detector usable', () async {
      // The detector is owned by main.dart and shared across the app, so
      // disposing a tracker must not close its interpreter. Calling through
      // the tracker again after dispose is the observable proof.
      final processor = _RecordingProcessor();
      final detector = DiscDetectionService();
      final tracker = _tracker(detector, processor);

      tracker.dispose();

      await tracker.track(
        session: _session(trimEndMs: 6000),
        seedPoints: const [],
      );
      expect(processor.callCount, 1);
      expect(detector.isModelLoaded, isFalse);
    });
  });

  group('FrameIndexing', () {
    test('frame 0 is the trim start, not the start of the file', () {
      expect(
        FrameIndexing.frameIndexAt(
          positionMs: 2000,
          trimStartMs: 2000,
          fps: 10.0,
        ),
        0,
      );
      expect(
        FrameIndexing.frameIndexAt(
          positionMs: 3000,
          trimStartMs: 2000,
          fps: 10.0,
        ),
        10,
      );
    });

    test('round-trips a position back to itself', () {
      for (final trimStartMs in [0, 1500, 12345]) {
        for (final offsetMs in [0, 100, 900, 5000]) {
          final frame = FrameIndexing.frameIndexAt(
            positionMs: trimStartMs + offsetMs,
            trimStartMs: trimStartMs,
            fps: 10.0,
          );
          final back =
              FrameIndexing.timestampOf(frameIndex: frame, fps: 10.0);
          expect(back.inMilliseconds, offsetMs);
        }
      }
    });

    test('TrackerSession delegates to the same maths', () {
      final session = _session(trimStartMs: 2000, trimEndMs: 8000);

      expect(session.frameIndexAt(3000), 10);
      expect(session.timestampOf(10).inMilliseconds, 1000);
    });
  });
}
