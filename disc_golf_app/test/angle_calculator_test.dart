import 'dart:math';

// Offset comes from flutter_test's re-export of dart:ui; importing dart:ui
// directly trips the unnecessary_import lint.
import 'package:flutter_test/flutter_test.dart';

import 'package:disc_golf_app/utils/angle_calculator.dart';

typedef Vec3 = ({double x, double y, double z});

Vec3 v(double x, double y, double z) => (x: x, y: y, z: z);

void main() {
  group('angleBetween (2D)', () {
    test('a right angle measures 90 degrees', () {
      final angle = AngleCalculator.angleBetween(
        const Offset(0, 1),
        Offset.zero,
        const Offset(1, 0),
      );
      expect(angle, closeTo(90.0, 1e-9));
    });

    test('a straight limb measures 180 degrees', () {
      final angle = AngleCalculator.angleBetween(
        const Offset(-1, 0),
        Offset.zero,
        const Offset(1, 0),
      );
      expect(angle, closeTo(180.0, 1e-9));
    });

    test('a fully folded limb measures 0 degrees', () {
      final angle = AngleCalculator.angleBetween(
        const Offset(1, 0),
        Offset.zero,
        const Offset(2, 0),
      );
      expect(angle, closeTo(0.0, 1e-9));
    });

    test('is invariant to translation and uniform scale', () {
      const a = Offset(0, 3);
      const b = Offset(1, 1);
      const c = Offset(4, 1);
      final base = AngleCalculator.angleBetween(a, b, c);

      const shift = Offset(100, -50);
      final translated =
          AngleCalculator.angleBetween(a + shift, b + shift, c + shift);
      final scaled = AngleCalculator.angleBetween(a * 7, b * 7, c * 7);

      expect(translated, closeTo(base, 1e-9));
      expect(scaled, closeTo(base, 1e-9));
    });

    test('degenerate input returns 0 rather than NaN', () {
      // Note: 0 is indistinguishable from a genuinely folded limb. The 3D
      // variant returns NaN instead; see angleBetween3D below.
      final angle = AngleCalculator.angleBetween(
        Offset.zero,
        Offset.zero,
        const Offset(1, 0),
      );
      expect(angle, 0.0);
    });

    test('never returns NaN from floating point drift at the extremes', () {
      // cos can drift a hair outside [-1, 1]; the implementation clamps.
      for (final scale in [1e-6, 1.0, 1e6]) {
        final angle = AngleCalculator.angleBetween(
          Offset(-scale, 0),
          Offset.zero,
          Offset(scale, 0),
        );
        expect(angle.isNaN, isFalse);
        expect(angle, closeTo(180.0, 1e-6));
      }
    });
  });

  group('angleBetween3D', () {
    test('a right angle measures 90 degrees', () {
      final angle = AngleCalculator.angleBetween3D(
        v(0, 1, 0),
        v(0, 0, 0),
        v(1, 0, 0),
      );
      expect(angle, closeTo(90.0, 1e-9));
    });

    test('uses depth, not just the projection', () {
      // Identical in x/y, different in z: the 2D calculation would see a
      // straight line, the 3D one must not.
      final angle = AngleCalculator.angleBetween3D(
        v(0, 0, 1),
        v(0, 0, 0),
        v(1, 0, 0),
      );
      expect(angle, closeTo(90.0, 1e-9));
    });

    test('degenerate input returns NaN so callers can drop it', () {
      final angle = AngleCalculator.angleBetween3D(
        v(0, 0, 0),
        v(0, 0, 0),
        v(1, 0, 0),
      );
      expect(angle.isNaN, isTrue);
    });
  });

  group('xFactor3D', () {
    test('is zero when shoulders and hips are aligned', () {
      final x = AngleCalculator.xFactor3D(
        v(1, 0, 0), // right shoulder
        v(-1, 0, 0), // left shoulder
        v(1, 0, 0), // right hip
        v(-1, 0, 0), // left hip
      );
      expect(x, closeTo(0.0, 1e-9));
    });

    test('measures separation when shoulders rotate past the hips', () {
      // Shoulders rotated 45 degrees about the vertical axis.
      final x = AngleCalculator.xFactor3D(
        v(1, 0, 1),
        v(-1, 0, -1),
        v(1, 0, 0),
        v(-1, 0, 0),
      );
      expect(x.abs(), closeTo(45.0, 1e-6));
    });

    test('sign flips with rotation direction', () {
      final positive = AngleCalculator.xFactor3D(
        v(1, 0, 1),
        v(-1, 0, -1),
        v(1, 0, 0),
        v(-1, 0, 0),
      );
      final negative = AngleCalculator.xFactor3D(
        v(1, 0, -1),
        v(-1, 0, 1),
        v(1, 0, 0),
        v(-1, 0, 0),
      );
      expect(positive.sign, isNot(negative.sign));
      expect(positive.abs(), closeTo(negative.abs(), 1e-6));
    });

    test('returns NaN when depth is degenerate', () {
      final x = AngleCalculator.xFactor3D(
        v(0, 0, 0),
        v(0, 0, 0),
        v(1, 0, 0),
        v(-1, 0, 0),
      );
      expect(x.isNaN, isTrue);
    });
  });

  group('catmullRom', () {
    test('passes exactly through its control points', () {
      expect(AngleCalculator.catmullRom(0, 10, 20, 30, 0.0), closeTo(10, 1e-12));
      expect(AngleCalculator.catmullRom(0, 10, 20, 30, 1.0), closeTo(20, 1e-12));
    });

    test('is linear for evenly spaced collinear points', () {
      for (final t in [0.25, 0.5, 0.75]) {
        expect(
          AngleCalculator.catmullRom(0, 10, 20, 30, t),
          closeTo(10 + 10 * t, 1e-9),
        );
      }
    });

    test('stays monotonic through a monotonic control sequence', () {
      double previous = AngleCalculator.catmullRom(0, 1, 2, 3, 0);
      for (var i = 1; i <= 20; i++) {
        final value = AngleCalculator.catmullRom(0, 1, 2, 3, i / 20);
        expect(value, greaterThanOrEqualTo(previous - 1e-12));
        previous = value;
      }
    });

    test('catmullRomOffset interpolates both axes', () {
      final mid = AngleCalculator.catmullRomOffset(
        const Offset(0, 0),
        const Offset(10, 100),
        const Offset(20, 200),
        const Offset(30, 300),
        0.5,
      );
      expect(mid.dx, closeTo(15, 1e-9));
      expect(mid.dy, closeTo(150, 1e-9));
    });
  });

  group('interpolateAnchors', () {
    test('returns an empty map for empty input', () {
      expect(AngleCalculator.interpolateAnchors({}, 0, 10), isEmpty);
    });

    test('preserves anchors exactly', () {
      final anchors = {
        0: const Offset(0.1, 0.9),
        10: const Offset(0.5, 0.5),
        20: const Offset(0.9, 0.1),
      };
      final result = AngleCalculator.interpolateAnchors(anchors, 0, 20);

      for (final entry in anchors.entries) {
        expect(result[entry.key]!.dx, closeTo(entry.value.dx, 1e-12));
        expect(result[entry.key]!.dy, closeTo(entry.value.dy, 1e-12));
      }
    });

    test('fills every frame between the first and last anchor', () {
      final result = AngleCalculator.interpolateAnchors(
        {0: const Offset(0, 0), 5: const Offset(1, 1), 10: const Offset(2, 0)},
        0,
        10,
      );
      for (var frame = 0; frame <= 10; frame++) {
        expect(result.containsKey(frame), isTrue, reason: 'missing $frame');
      }
    });

    test('interpolates a straight line linearly in interior segments', () {
      // Only interior segments have four distinct control points. The first
      // and last segments duplicate an endpoint (p0 == p1 / p2 == p3), which
      // is standard Catmull-Rom end handling and is *not* linear even for
      // collinear anchors — so this asserts on the middle segment.
      final result = AngleCalculator.interpolateAnchors(
        {
          0: const Offset(0, 0),
          4: const Offset(4, 8),
          8: const Offset(8, 16),
          12: const Offset(12, 24),
        },
        0,
        12,
      );
      expect(result[6]!.dx, closeTo(6, 1e-9));
      expect(result[6]!.dy, closeTo(12, 1e-9));
    });

    test('endpoint segments stay within the anchor range', () {
      // The duplicated-endpoint segments must not overshoot wildly, or the
      // rendered flight path leaves the frame near the seed points.
      final result = AngleCalculator.interpolateAnchors(
        {
          0: const Offset(0.1, 0.9),
          10: const Offset(0.5, 0.5),
          20: const Offset(0.9, 0.1),
        },
        0,
        20,
      );
      for (final point in result.values) {
        expect(point.dx, inInclusiveRange(0.0, 1.0));
        expect(point.dy, inInclusiveRange(0.0, 1.0));
      }
    });

    test('handles adjacent anchors with no gap to fill', () {
      final result = AngleCalculator.interpolateAnchors(
        {0: const Offset(0, 0), 1: const Offset(1, 1)},
        0,
        1,
      );
      expect(result, hasLength(2));
    });

    test('is order independent with respect to map insertion order', () {
      final ascending = AngleCalculator.interpolateAnchors(
        {0: const Offset(0, 0), 5: const Offset(1, 1), 10: const Offset(2, 2)},
        0,
        10,
      );
      final shuffled = AngleCalculator.interpolateAnchors(
        {10: const Offset(2, 2), 0: const Offset(0, 0), 5: const Offset(1, 1)},
        0,
        10,
      );
      for (final frame in ascending.keys) {
        expect(shuffled[frame]!.dx, closeTo(ascending[frame]!.dx, 1e-12));
        expect(shuffled[frame]!.dy, closeTo(ascending[frame]!.dy, 1e-12));
      }
    });
  });

  group('calculateFromKeyPoints', () {
    Map<String, Offset> keyPoints(Map<String, Offset> raw) => {
          for (final e in raw.entries) 'PoseLandmarkType.${e.key}': e.value,
        };

    test('computes an elbow angle from shoulder/elbow/wrist', () {
      final angles = AngleCalculator.calculateFromKeyPoints(keyPoints({
        'rightShoulder': const Offset(0, 0),
        'rightElbow': const Offset(0, 1),
        'rightWrist': const Offset(1, 1),
      }));
      expect(angles['rightElbowAngle'], closeTo(90.0, 1e-9));
    });

    test('omits angles whose landmarks are missing', () {
      final angles = AngleCalculator.calculateFromKeyPoints(keyPoints({
        'rightShoulder': const Offset(0, 0),
        'rightElbow': const Offset(0, 1),
        // no wrist
      }));
      expect(angles.containsKey('rightElbowAngle'), isFalse);
    });

    test('reports a vertical spine as 90 degrees', () {
      final angles = AngleCalculator.calculateFromKeyPoints(keyPoints({
        'rightShoulder': const Offset(1, 0),
        'leftShoulder': const Offset(-1, 0),
        'rightHip': const Offset(1, 2),
        'leftHip': const Offset(-1, 2),
      }));
      expect(angles['spineAngle'], closeTo(90.0, 1e-9));
    });

    test('a leaning spine reads below 90 degrees', () {
      final angles = AngleCalculator.calculateFromKeyPoints(keyPoints({
        'rightShoulder': const Offset(2, 0),
        'leftShoulder': const Offset(0, 0),
        'rightHip': const Offset(1, 2),
        'leftHip': const Offset(-1, 2),
      }));
      expect(angles['spineAngle'], lessThan(90.0));
    });

    test('returns an empty map for empty input', () {
      expect(AngleCalculator.calculateFromKeyPoints({}), isEmpty);
    });

    test('produces no NaN values for a plausible full skeleton', () {
      final angles = AngleCalculator.calculateFromKeyPoints(keyPoints({
        'rightShoulder': const Offset(0.55, 0.30),
        'leftShoulder': const Offset(0.45, 0.30),
        'rightElbow': const Offset(0.62, 0.42),
        'leftElbow': const Offset(0.38, 0.42),
        'rightWrist': const Offset(0.68, 0.55),
        'leftWrist': const Offset(0.32, 0.55),
        'rightHip': const Offset(0.53, 0.55),
        'leftHip': const Offset(0.47, 0.55),
        'rightKnee': const Offset(0.54, 0.72),
        'leftKnee': const Offset(0.46, 0.72),
        'rightAnkle': const Offset(0.55, 0.90),
        'leftAnkle': const Offset(0.45, 0.90),
      }));

      expect(angles, isNotEmpty);
      for (final entry in angles.entries) {
        expect(entry.value.isNaN, isFalse, reason: '${entry.key} is NaN');
        expect(entry.value.isFinite, isTrue, reason: '${entry.key} is infinite');
      }
      // Joint angles are in [0, 180] by construction.
      for (final key in ['rightElbowAngle', 'leftElbowAngle', 'rightKneeAngle']) {
        expect(angles[key], inInclusiveRange(0.0, 180.0));
      }
    });
  });

  group('regression: spline implementations agree', () {
    test('AngleCalculator.catmullRom matches the classic formulation', () {
      double reference(double p0, double p1, double p2, double p3, double t) {
        final t2 = t * t;
        final t3 = t2 * t;
        return 0.5 *
            ((2 * p1) +
                (-p0 + p2) * t +
                (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
                (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
      }

      final random = Random(20260804);
      for (var i = 0; i < 200; i++) {
        final p0 = random.nextDouble();
        final p1 = random.nextDouble();
        final p2 = random.nextDouble();
        final p3 = random.nextDouble();
        final t = random.nextDouble();
        expect(
          AngleCalculator.catmullRom(p0, p1, p2, p3, t),
          closeTo(reference(p0, p1, p2, p3, t), 1e-12),
        );
      }
    });
  });
}
