import 'package:flutter_test/flutter_test.dart';
import 'package:disc_golf_app/services/detection_quality.dart';
import 'package:disc_golf_app/services/disc_detection_service.dart';

/// Builds a detection at [frame]. A negative [confidence] marks an
/// interpolated point, matching the sentinel DiscDetectionService writes.
DiscDetection _detection(int frame, {double confidence = 0.9}) {
  return DiscDetection(
    frameIndex: frame,
    x: 0.5,
    y: 0.5,
    width: 0.03,
    height: 0.03,
    confidence: confidence,
    timestamp: Duration(milliseconds: frame * 100),
  );
}

FlightTrackingResult _result(List<DiscDetection> detections,
    {int? totalFrames}) {
  return FlightTrackingResult(
    detections: detections,
    videoWidth: 1080,
    videoHeight: 1920,
    fps: 10.0,
    totalFrames: totalFrames ?? detections.length,
  );
}

void main() {
  group('assessDetectionQuality', () {
    test('a full, confident track raises no flags', () {
      final result = _result([for (int i = 0; i < 20; i++) _detection(i)]);

      final report =
          assessDetectionQuality(result, confidenceFloor: 0.1);

      expect(report.flags, isEmpty);
      expect(report.isLow, isFalse);
      expect(report.realDetections, 20);
      expect(report.coverage, closeTo(1.0, 0.0001));
      expect(report.interpolatedFraction, 0.0);
      expect(report.meanConfidence, closeTo(0.9, 0.0001));
    });

    test('flags a handful of detections as too few', () {
      final result = _result(
        [for (int i = 0; i < 4; i++) _detection(i)],
        totalFrames: 4,
      );

      final report = assessDetectionQuality(result, confidenceFloor: 0.1);

      expect(report.flags, contains(DetectionQualityFlag.tooFewDetections));
    });

    test('exactly minRealDetections is not too few', () {
      final result = _result(
        [for (int i = 0; i < 5; i++) _detection(i)],
        totalFrames: 5,
      );

      final report = assessDetectionQuality(result, confidenceFloor: 0.1);

      expect(
        report.flags,
        isNot(contains(DetectionQualityFlag.tooFewDetections)),
      );
    });

    test('flags a path spanning under half the clip', () {
      // 10 detections at the start of a 40-frame clip -> coverage 0.25.
      final result = _result(
        [for (int i = 0; i < 10; i++) _detection(i)],
        totalFrames: 40,
      );

      final report = assessDetectionQuality(result, confidenceFloor: 0.1);

      expect(report.coverage, closeTo(0.25, 0.0001));
      expect(report.flags, contains(DetectionQualityFlag.lowCoverage));
    });

    test('coverage exactly at the threshold is not flagged', () {
      // Frames 0..19 inclusive of a 40-frame clip -> coverage exactly 0.5.
      final result = _result(
        [for (int i = 0; i < 20; i++) _detection(i)],
        totalFrames: 40,
      );

      final report = assessDetectionQuality(result, confidenceFloor: 0.1);

      expect(report.coverage, closeTo(0.5, 0.0001));
      expect(report.flags, isNot(contains(DetectionQualityFlag.lowCoverage)));
    });

    test('40% interpolated is allowed, above it is flagged', () {
      final atThreshold = _result([
        for (int i = 0; i < 6; i++) _detection(i),
        for (int i = 6; i < 10; i++) _detection(i, confidence: -1),
      ]);
      expect(
        assessDetectionQuality(atThreshold, confidenceFloor: 0.1).flags,
        isNot(contains(DetectionQualityFlag.mostlyInterpolated)),
      );

      final overThreshold = _result([
        for (int i = 0; i < 5; i++) _detection(i),
        for (int i = 5; i < 10; i++) _detection(i, confidence: -1),
      ]);
      expect(
        assessDetectionQuality(overThreshold, confidenceFloor: 0.1).flags,
        contains(DetectionQualityFlag.mostlyInterpolated),
      );
    });

    test('interpolated points are excluded from mean confidence', () {
      final result = _result([
        for (int i = 0; i < 8; i++) _detection(i, confidence: 0.8),
        for (int i = 8; i < 10; i++) _detection(i, confidence: -1),
      ]);

      final report = assessDetectionQuality(result, confidenceFloor: 0.1);

      // 0.8, not the average of 0.8s and -1s.
      expect(report.meanConfidence, closeTo(0.8, 0.0001));
    });

    test('weak matches are judged against the absolute floor when the user '
        'threshold is low', () {
      final result =
          _result([for (int i = 0; i < 20; i++) _detection(i, confidence: 0.3)]);

      // 0.02 * 2.5 = 0.05, well under the 0.35 absolute floor, so 0.35 wins
      // and a mean of 0.3 is weak.
      final report = assessDetectionQuality(result, confidenceFloor: 0.02);

      expect(report.flags, contains(DetectionQualityFlag.weakMatches));
    });

    test('weak matches scale with a raised user threshold', () {
      final result =
          _result([for (int i = 0; i < 20; i++) _detection(i, confidence: 0.5)]);

      // At a low floor, 0.5 clears the 0.35 bar.
      expect(
        assessDetectionQuality(result, confidenceFloor: 0.1).flags,
        isNot(contains(DetectionQualityFlag.weakMatches)),
      );

      // At floor 0.3 the bar rises to 0.75, so the same track is now weak.
      expect(
        assessDetectionQuality(result, confidenceFloor: 0.3).flags,
        contains(DetectionQualityFlag.weakMatches),
      );
    });

    test('an empty result is flagged, but not as a weak match', () {
      final report = assessDetectionQuality(
        _result(const [], totalFrames: 20),
        confidenceFloor: 0.1,
      );

      expect(report.flags, contains(DetectionQualityFlag.tooFewDetections));
      expect(report.flags, contains(DetectionQualityFlag.lowCoverage));
      // Nothing was detected, so "the matches were weak" would be misleading.
      expect(report.flags, isNot(contains(DetectionQualityFlag.weakMatches)));
      expect(report.meanConfidence, 0.0);
    });

    test('an all-interpolated result reports no real detections', () {
      final result = _result(
        [for (int i = 0; i < 10; i++) _detection(i, confidence: -1)],
      );

      final report = assessDetectionQuality(result, confidenceFloor: 0.1);

      expect(report.realDetections, 0);
      expect(report.interpolatedFraction, closeTo(1.0, 0.0001));
      expect(report.flags, contains(DetectionQualityFlag.mostlyInterpolated));
      expect(report.flags, contains(DetectionQualityFlag.tooFewDetections));
    });

    test('expectedFrames overrides the result-reported span', () {
      final result = _result(
        [for (int i = 0; i < 20; i++) _detection(i)],
        totalFrames: 20,
      );

      final report = assessDetectionQuality(
        result,
        confidenceFloor: 0.1,
        expectedFrames: 100,
      );

      expect(report.coverage, closeTo(0.2, 0.0001));
      expect(report.flags, contains(DetectionQualityFlag.lowCoverage));
    });

    test('primaryFlag leads with the most fundamental problem', () {
      final report = assessDetectionQuality(
        _result(const [], totalFrames: 20),
        confidenceFloor: 0.1,
      );

      expect(report.primaryFlag, DetectionQualityFlag.tooFewDetections);
    });
  });

  group('sampleSeedPoints', () {
    test('samples down to the target, keeping both endpoints', () {
      final detections = [for (int i = 0; i < 100; i++) _detection(i)];

      final sampled = sampleSeedPoints(detections, target: 8);

      expect(sampled, hasLength(8));
      expect(sampled.first.frameIndex, 0);
      expect(sampled.last.frameIndex, 99);
    });

    test('returns strictly increasing frame indices with no duplicates', () {
      final detections = [for (int i = 0; i < 100; i++) _detection(i)];

      final sampled = sampleSeedPoints(detections, target: 8);

      for (int i = 1; i < sampled.length; i++) {
        expect(
          sampled[i].frameIndex,
          greaterThan(sampled[i - 1].frameIndex),
        );
      }
    });

    test('never selects an interpolated point', () {
      // Only frames 0, 1 and 98, 99 are real; everything between is fill.
      final detections = [
        _detection(0),
        _detection(1),
        for (int i = 2; i < 98; i++) _detection(i, confidence: -1),
        _detection(98),
        _detection(99),
      ];

      final sampled = sampleSeedPoints(detections, target: 8);

      expect(sampled.map((p) => p.frameIndex), [0, 1, 98, 99]);
    });

    test('returns everything when there are fewer points than the target', () {
      final sampled = sampleSeedPoints(
        [_detection(0), _detection(5), _detection(9), _detection(12)],
        target: 8,
      );

      expect(sampled.map((p) => p.frameIndex), [0, 5, 9, 12]);
    });

    test('handles a two-point input', () {
      final sampled =
          sampleSeedPoints([_detection(0), _detection(9)], target: 8);

      expect(sampled, hasLength(2));
    });

    test('returns empty when nothing was actually detected', () {
      final sampled = sampleSeedPoints(
        [for (int i = 0; i < 10; i++) _detection(i, confidence: -1)],
      );

      expect(sampled, isEmpty);
    });

    test('sorts unordered input before sampling', () {
      final sampled = sampleSeedPoints(
        [_detection(9), _detection(0), _detection(5)],
        target: 8,
      );

      expect(sampled.map((p) => p.frameIndex), [0, 5, 9]);
    });
  });
}
