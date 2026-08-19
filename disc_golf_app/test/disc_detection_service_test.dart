import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:disc_golf_app/services/disc_detection_service.dart';

DiscDetection detection(
  int frame,
  double x,
  double y, {
  double confidence = 0.9,
  double size = 0.03,
}) {
  return DiscDetection(
    frameIndex: frame,
    x: x,
    y: y,
    width: size,
    height: size,
    confidence: confidence,
    timestamp: Duration(milliseconds: frame * 100),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DiscDetectionService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = DiscDetectionService();
  });

  group('confidence threshold', () {
    test('defaults to the documented value', () {
      expect(
        service.confidenceThreshold,
        DiscDetectionService.defaultConfidenceThreshold,
      );
    });

    test('is clamped to a usable band', () async {
      await service.setConfidenceThreshold(5.0);
      expect(service.confidenceThreshold, 0.95);

      await service.setConfidenceThreshold(-1.0);
      expect(service.confidenceThreshold, 0.01);
    });
  });

  group('normalizeModelValue', () {
    test('passes through already-normalized coordinates', () {
      expect(service.normalizeModelValueForTesting(0.42), closeTo(0.42, 1e-9));
    });

    test('divides pixel-space coordinates by the input size', () {
      // Values above 1 are assumed to be in model input pixels. No model is
      // loaded in this test, so the input size is the pre-load default
      // (640x640) — see _defaultInputSize in DiscDetectionService.
      expect(service.normalizeModelValueForTesting(320.0), closeTo(0.5, 1e-9));
    });

    test('clamps into 0..1', () {
      expect(service.normalizeModelValueForTesting(-5.0), 0.0);
      expect(service.normalizeModelValueForTesting(9999.0), 1.0);
    });
  });

  group('parseBestDetection', () {
    test('reads the transposed [1, 5, N] layout', () {
      // output[0][channel][detection]: cx, cy, w, h, conf
      final output = [
        [
          [0.25, 0.75], // cx
          [0.35, 0.85], // cy
          [0.03, 0.04], // w
          [0.03, 0.04], // h
          [0.20, 0.90], // conf
        ]
      ];
      final best = service.parseBestDetectionForTesting(output, [1, 5, 2], 7, 10);

      expect(best, isNotNull);
      expect(best!.frameIndex, 7);
      expect(best.x, closeTo(0.75, 1e-9));
      expect(best.y, closeTo(0.85, 1e-9));
      expect(best.confidence, closeTo(0.90, 1e-9));
    });

    test('reads the standard [1, N, 5] layout', () {
      final output = [
        [
          [0.25, 0.35, 0.03, 0.03, 0.20],
          [0.75, 0.85, 0.04, 0.04, 0.90],
        ]
      ];
      final best = service.parseBestDetectionForTesting(output, [1, 2, 5], 3, 10);

      expect(best, isNotNull);
      expect(best!.x, closeTo(0.75, 1e-9));
      expect(best.confidence, closeTo(0.90, 1e-9));
    });

    test('returns null when every candidate is below threshold', () {
      final output = [
        [
          [0.5],
          [0.5],
          [0.03],
          [0.03],
          [0.001],
        ]
      ];
      expect(
        service.parseBestDetectionForTesting(output, [1, 5, 1], 0, 10),
        isNull,
      );
    });

    test('derives the timestamp from frame index and fps', () {
      final output = [
        [
          [0.5],
          [0.5],
          [0.03],
          [0.03],
          [0.99],
        ]
      ];
      final best = service.parseBestDetectionForTesting(output, [1, 5, 1], 20, 10);
      expect(best!.timestamp, const Duration(milliseconds: 2000));
    });
  });

  group('selectClosestCandidate', () {
    test('picks the candidate nearest the predicted position over the '
        'more confident one', () {
      final near = detection(5, 0.51, 0.51, confidence: 0.3);
      final far = detection(5, 0.9, 0.9, confidence: 0.95);

      final chosen =
          service.selectClosestCandidate([far, near], 0.5, 0.5);

      expect(chosen, same(near),
          reason: 'a distant high-confidence blob should lose to the one '
              'consistent with the track');
    });

    test('breaks a close tie toward the more confident candidate', () {
      final lessConfident = detection(5, 0.50, 0.50, confidence: 0.2);
      final moreConfident = detection(5, 0.505, 0.505, confidence: 0.9);

      final chosen = service.selectClosestCandidate(
        [lessConfident, moreConfident],
        0.5,
        0.5,
      );

      expect(chosen, same(moreConfident));
    });

    test('returns the sole candidate unchanged', () {
      final only = detection(5, 0.2, 0.8, confidence: 0.5);
      expect(service.selectClosestCandidate([only], 0.9, 0.1), same(only));
    });
  });

  group('spatial coherence filter', () {
    test('keeps a smooth trajectory intact', () {
      final path = [
        for (var i = 0; i < 10; i++) detection(i, 0.1 + i * 0.05, 0.5)
      ];
      final result = service.filterSpatialCoherenceForTesting(path, 10);
      expect(result, hasLength(10));
    });

    test('rejects scattered noise in favour of the coherent chain', () {
      final path = <DiscDetection>[
        for (var i = 0; i < 8; i++) detection(i, 0.1 + i * 0.04, 0.5),
      ];
      // Outliers occupy frames the smooth path does not, so the filter has to
      // choose between them rather than the two colliding on one frame key.
      final noisy = [...path, detection(8, 0.95, 0.05), detection(9, 0.02, 0.98)];

      final result = service.filterSpatialCoherenceForTesting(noisy, 10);

      // Every kept point should be on the smooth line, not the outliers.
      for (final d in result) {
        expect(d.y, closeTo(0.5, 1e-9),
            reason: 'kept an outlier at frame ${d.frameIndex}');
      }
      expect(result, hasLength(8));
    });

    test('passes through fewer than three detections unchanged', () {
      final input = [detection(0, 0.1, 0.1), detection(1, 0.9, 0.9)];
      expect(service.filterSpatialCoherenceForTesting(input, 2), hasLength(2));
    });

    test('returns detections in frame order', () {
      final shuffled = [
        detection(5, 0.3, 0.5),
        detection(0, 0.1, 0.5),
        detection(3, 0.22, 0.5),
        detection(1, 0.14, 0.5),
      ];
      final result = service.filterSpatialCoherenceForTesting(shuffled, 6);
      final frames = result.map((d) => d.frameIndex).toList();
      final sorted = [...frames]..sort();
      expect(frames, sorted);
    });

    test('handles an empty input', () {
      expect(service.filterSpatialCoherenceForTesting([], 0), isEmpty);
    });
  });

  group('smoothing', () {
    test('averages positions across the window', () {
      final noisy = [
        detection(0, 0.0, 0.5),
        detection(1, 1.0, 0.5),
        detection(2, 0.0, 0.5),
        detection(3, 1.0, 0.5),
        detection(4, 0.0, 0.5),
      ];
      final smoothed = service.smoothDetections(noisy, windowSize: 3);

      expect(smoothed, hasLength(5));
      // The interior points pull toward the mean rather than staying at the
      // alternating extremes.
      expect(smoothed[2].x, greaterThan(0.0));
      expect(smoothed[2].x, lessThan(1.0));
    });

    test('preserves frame indices and confidence', () {
      final input = [
        detection(4, 0.1, 0.1, confidence: 0.7),
        detection(5, 0.2, 0.2, confidence: 0.8),
        detection(6, 0.3, 0.3, confidence: 0.9),
      ];
      final smoothed = service.smoothDetections(input, windowSize: 3);
      expect(smoothed.map((d) => d.frameIndex), [4, 5, 6]);
      expect(smoothed[1].confidence, 0.8);
    });

    test('returns input unchanged when shorter than the window', () {
      final input = [detection(0, 0.1, 0.1), detection(1, 0.2, 0.2)];
      expect(service.smoothDetections(input, windowSize: 5), hasLength(2));
    });

    test('leaves a constant track unchanged', () {
      final flat = [for (var i = 0; i < 6; i++) detection(i, 0.4, 0.6)];
      final smoothed = service.smoothDetections(flat, windowSize: 3);
      for (final d in smoothed) {
        expect(d.x, closeTo(0.4, 1e-9));
        expect(d.y, closeTo(0.6, 1e-9));
      }
    });
  });

  group('gap interpolation', () {
    test('fills a short gap linearly and marks it interpolated', () {
      final sparse = [detection(0, 0.0, 0.0), detection(4, 0.4, 0.8)];
      final filled = service.interpolateDetectionsForTesting(sparse, 5, 10);

      expect(filled.map((d) => d.frameIndex), [0, 1, 2, 3, 4]);
      final mid = filled.firstWhere((d) => d.frameIndex == 2);
      expect(mid.x, closeTo(0.2, 1e-9));
      expect(mid.y, closeTo(0.4, 1e-9));
      expect(mid.confidence, lessThan(0),
          reason: 'interpolated points are flagged with negative confidence');
    });

    test('keeps real detections at full confidence', () {
      final sparse = [detection(0, 0.0, 0.0), detection(3, 0.3, 0.3)];
      final filled = service.interpolateDetectionsForTesting(sparse, 4, 10);
      expect(filled.first.confidence, greaterThanOrEqualTo(0));
      expect(filled.last.confidence, greaterThanOrEqualTo(0));
    });

    test('does not bridge a gap larger than ten frames', () {
      final sparse = [detection(0, 0.0, 0.0), detection(30, 0.9, 0.9)];
      final filled = service.interpolateDetectionsForTesting(sparse, 31, 10);
      expect(filled, hasLength(2));
    });

    test('passes through fewer than two detections', () {
      expect(
        service.interpolateDetectionsForTesting([detection(0, 0.1, 0.1)], 1, 10),
        hasLength(1),
      );
      expect(service.interpolateDetectionsForTesting([], 0, 10), isEmpty);
    });

    test('assigns timestamps consistent with the frame index and fps', () {
      final sparse = [detection(0, 0.0, 0.0), detection(2, 0.2, 0.2)];
      final filled = service.interpolateDetectionsForTesting(sparse, 3, 20);
      final mid = filled.firstWhere((d) => d.frameIndex == 1);
      expect(mid.timestamp, const Duration(milliseconds: 50));
    });
  });

  group('ExtractedFrame', () {
    test('carries the video frame index alongside the path', () {
      // Regression: extraction used to return bare paths, so a skipped frame
      // shifted every later frame's index — and with it the timestamps and
      // spline anchors — relative to the actual video.
      const frame = ExtractedFrame(index: 42, path: '/tmp/frame_0042.jpg');
      expect(frame.index, 42);
      expect(frame.path, endsWith('frame_0042.jpg'));
    });

    test('a sparse frame list still reports the true frame span', () {
      const frames = [
        ExtractedFrame(index: 0, path: 'a'),
        ExtractedFrame(index: 1, path: 'b'),
        // frame 2 failed to extract
        ExtractedFrame(index: 3, path: 'd'),
      ];
      expect(frames.length, 3);
      expect(frames.last.index + 1, 4,
          reason: 'span is derived from the last index, not the list length');
    });
  });

  group('FlightTrackingResult', () {
    final result = FlightTrackingResult(
      detections: [
        detection(0, 0.1, 0.5),
        detection(1, 0.2, 0.5),
        detection(2, 0.3, 0.5),
      ],
      videoWidth: 640,
      videoHeight: 1138,
      fps: 10,
      totalFrames: 3,
    );

    test('finds a detection by frame', () {
      expect(result.detectionAtFrame(1)!.x, closeTo(0.2, 1e-9));
    });

    test('returns null for a frame with no detection', () {
      expect(result.detectionAtFrame(99), isNull);
    });

    test('builds a trail up to the current frame', () {
      expect(result.getTrail(1), hasLength(2));
      expect(result.getTrail(99), hasLength(3));
      expect(result.getTrail(-1), isEmpty);
    });

    test('getCompensatedTrail matches getTrail', () {
      expect(result.getCompensatedTrail(2), result.getTrail(2));
    });
  });

  // Note: processVideo() itself is not unit-testable on the host — it needs
  // path_provider and the TFLite native library. Its re-entrancy guard and
  // lock release are covered by inspection plus the integration path; see
  // docs/testing.md for what still requires a device.
}
