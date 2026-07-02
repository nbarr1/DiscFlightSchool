import 'package:flutter_test/flutter_test.dart';
import 'package:disc_golf_app/services/disc_tracker.dart';

void main() {
  group('GeometricSplineTracker', () {
    test('interpolates a straight horizontal line between two seed points', () async {
      final tracker = GeometricSplineTracker();
      final session = TrackerSession(
        videoPath: '/fake/path.mp4',
        fps: 10.0,
        totalFrames: 11,
        videoWidth: 1080,
        videoHeight: 1920,
      );

      final result = await tracker.track(
        session: session,
        seedPoints: [
          TrackerSeedPoint(frameIndex: 0, x: 0.1, y: 0.5),
          TrackerSeedPoint(frameIndex: 10, x: 0.9, y: 0.5),
        ],
      );

      expect(result.detections, hasLength(11));
      expect(result.detections.first.x, closeTo(0.1, 0.0001));
      expect(result.detections.last.x, closeTo(0.9, 0.0001));
      // Midpoint of a straight two-point line should land at the midpoint.
      final mid = result.detections.firstWhere((d) => d.frameIndex == 5);
      expect(mid.x, closeTo(0.5, 0.0001));
      expect(mid.y, closeTo(0.5, 0.0001));
      // Endpoints are seed points -> full confidence; interior points are not.
      expect(result.detections.first.confidence, 1.0);
      expect(mid.confidence, 0.5);
    });

    test('throws ArgumentError with fewer than 2 seed points', () async {
      final tracker = GeometricSplineTracker();
      final session = TrackerSession(
        videoPath: '/fake/path.mp4',
        fps: 10.0,
        totalFrames: 5,
        videoWidth: 1080,
        videoHeight: 1920,
      );

      expect(
        () => tracker.track(session: session, seedPoints: [
          TrackerSeedPoint(frameIndex: 0, x: 0.1, y: 0.5),
        ]),
        throwsArgumentError,
      );
    });
  });
}
