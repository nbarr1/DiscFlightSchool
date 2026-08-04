import 'package:flutter_test/flutter_test.dart';

import 'package:disc_golf_app/models/form_analysis.dart';
import 'package:disc_golf_app/services/posture_analysis_service.dart';

FormFrame frame(Map<String, double> angles, {int ms = 0}) => FormFrame(
      timestamp: Duration(milliseconds: ms),
      angles: Map<String, double>.from(angles),
      keyPoints: const {},
    );

void main() {
  group('kneeSideLabel', () {
    // Regression: the suggestion text hardcoded `right == lead`, but
    // reverseAngleKey maps right -> trail for a forehand. Every FH knee tip
    // was therefore labelled with the opposite leg from the pro data it was
    // actually compared against.
    test('backhand: right knee is the lead leg', () {
      expect(
        PostureAnalysisService.kneeSideLabel('rightKneeAngle', 'BH'),
        'lead',
      );
      expect(
        PostureAnalysisService.kneeSideLabel('leftKneeAngle', 'BH'),
        'trail',
      );
    });

    test('forehand: right knee is the trail leg', () {
      expect(
        PostureAnalysisService.kneeSideLabel('rightKneeAngle', 'FH'),
        'trail',
      );
      expect(
        PostureAnalysisService.kneeSideLabel('leftKneeAngle', 'FH'),
        'lead',
      );
    });

    test('the label always matches the pro-data key it is compared against',
        () {
      for (final throwType in ['BH', 'FH']) {
        for (final appKey in ['rightKneeAngle', 'leftKneeAngle']) {
          final label = PostureAnalysisService.kneeSideLabel(appKey, throwType);
          final jsonKey =
              PostureAnalysisService.reverseAngleKey(appKey, throwType);
          expect(
            jsonKey,
            '${label}_knee_flexion_deg',
            reason: '$appKey/$throwType label disagrees with its data key',
          );
        }
      }
    });

    test('returns null for non-knee angles', () {
      expect(PostureAnalysisService.kneeSideLabel('rightElbowAngle', 'BH'),
          isNull);
      expect(PostureAnalysisService.kneeSideLabel('spineAngle', 'FH'), isNull);
      expect(PostureAnalysisService.kneeSideLabel('nonsense', 'BH'), isNull);
    });
  });

  group('reverseAngleKey', () {
    test('maps shared angles identically for both throw types', () {
      for (final key in [
        'rightElbowAngle',
        'rightShoulderAngle',
        'spineAngle',
        'leftElbowAngle',
        'leftShoulderAngle',
        'xFactor',
      ]) {
        expect(
          PostureAnalysisService.reverseAngleKey(key, 'BH'),
          PostureAnalysisService.reverseAngleKey(key, 'FH'),
          reason: '$key should not depend on throw type',
        );
      }
    });

    test('mirrors only the knees between throw types', () {
      expect(
        PostureAnalysisService.reverseAngleKey('rightKneeAngle', 'BH'),
        isNot(PostureAnalysisService.reverseAngleKey('rightKneeAngle', 'FH')),
      );
    });

    test('returns null for an unknown key', () {
      expect(PostureAnalysisService.reverseAngleKey('bogus', 'BH'), isNull);
    });
  });

  group('clampToPhysiologicalLimits', () {
    test('leaves in-range angles untouched', () {
      final result = PostureAnalysisService.clampToPhysiologicalLimits({
        'rightElbowAngle': 95.0,
        'rightKneeAngle': 150.0,
        'spineAngle': 80.0,
      });
      expect(result['rightElbowAngle'], 95.0);
      expect(result['rightKneeAngle'], 150.0);
      expect(result['spineAngle'], 80.0);
    });

    test('clamps values just outside the range to the boundary', () {
      // Elbow range is 40..180; 35 is 5 outside, within the 10 degree tolerance.
      final result = PostureAnalysisService.clampToPhysiologicalLimits({
        'rightElbowAngle': 35.0,
        'rightKneeAngle': 185.0,
      });
      expect(result['rightElbowAngle'], 40.0);
      expect(result['rightKneeAngle'], 180.0);
    });

    test('drops values far outside the range rather than clamping them', () {
      // A 15 degree knee is a bad landmark, not a tight knee. Carrying it
      // forward as a clamped 30 would silently corrupt the score, so the key
      // is omitted and downstream code sees "not measured".
      final result = PostureAnalysisService.clampToPhysiologicalLimits({
        'rightKneeAngle': 15.0,
        'rightElbowAngle': 5.0,
        'spineAngle': 10.0,
      });
      expect(result.containsKey('rightKneeAngle'), isFalse);
      expect(result.containsKey('rightElbowAngle'), isFalse);
      expect(result.containsKey('spineAngle'), isFalse);
    });

    test('passes through angles with no defined range', () {
      final result = PostureAnalysisService.clampToPhysiologicalLimits({
        'xFactor': -35.0,
      });
      expect(result['xFactor'], -35.0);
    });

    test('handles an empty map', () {
      expect(PostureAnalysisService.clampToPhysiologicalLimits({}), isEmpty);
    });
  });

  group('computeProDeviationScore', () {
    final proAngles = {
      'reach_back': {'rightElbowAngle': 100.0},
      'power_pocket': {'rightElbowAngle': 70.0},
      'release': {'rightElbowAngle': 160.0},
      'follow_through': {'rightElbowAngle': 120.0},
    };

    test('returns 0 for empty frames', () {
      expect(
        PostureAnalysisService.computeProDeviationScore([], proAngles, 'BH'),
        0.0,
      );
    });

    test('returns 0 when there is no pro data', () {
      expect(
        PostureAnalysisService.computeProDeviationScore(
            [frame({'rightElbowAngle': 90.0})], {}, 'BH'),
        0.0,
      );
    });

    test('scores a perfect match at 100', () {
      final frames = [
        frame({'rightElbowAngle': 100.0}),
        frame({'rightElbowAngle': 100.0}),
      ];
      final score = PostureAnalysisService.computeProDeviationScore(
        frames,
        proAngles,
        'BH',
        phaseFrameIndices: {'reach_back': 0},
      );
      expect(score, closeTo(100.0, 1e-9));
    });

    test('penalises deviation linearly at 2 points per degree', () {
      final frames = [frame({'rightElbowAngle': 110.0})];
      final score = PostureAnalysisService.computeProDeviationScore(
        frames,
        proAngles,
        'BH',
        phaseFrameIndices: {'reach_back': 0},
      );
      // 10 degrees off -> 100 - 20 = 80
      expect(score, closeTo(80.0, 1e-9));
    });

    test('floors at 0 for extreme deviation rather than going negative', () {
      final frames = [frame({'rightElbowAngle': 0.0})];
      final score = PostureAnalysisService.computeProDeviationScore(
        frames,
        proAngles,
        'BH',
        phaseFrameIndices: {'reach_back': 0},
      );
      expect(score, 0.0);
    });

    test('is always within 0..100', () {
      final frames = [
        frame({'rightElbowAngle': 20.0}),
        frame({'rightElbowAngle': 175.0}),
        frame({'rightElbowAngle': 95.0}),
      ];
      final score =
          PostureAnalysisService.computeProDeviationScore(frames, proAngles, 'BH');
      expect(score, inInclusiveRange(0.0, 100.0));
    });

    test('ignores angles absent from the pro reference', () {
      final frames = [
        frame({'rightElbowAngle': 100.0, 'unmatchedAngle': 999.0}),
      ];
      final score = PostureAnalysisService.computeProDeviationScore(
        frames,
        proAngles,
        'BH',
        phaseFrameIndices: {'reach_back': 0},
      );
      // Only the matched angle contributes, so the outlier cannot drag it down.
      expect(score, closeTo(100.0, 1e-9));
    });

    test('uses forehand phase names for FH', () {
      final fhAngles = {
        'wind_up': {'rightElbowAngle': 90.0},
        'power_pocket': {'rightElbowAngle': 70.0},
        'release': {'rightElbowAngle': 160.0},
        'follow_through': {'rightElbowAngle': 120.0},
      };
      final frames = [frame({'rightElbowAngle': 90.0})];
      final score = PostureAnalysisService.computeProDeviationScore(
        frames,
        fhAngles,
        'FH',
        phaseFrameIndices: {'wind_up': 0},
      );
      expect(score, closeTo(100.0, 1e-9));
    });

    test('snaps each frame to its nearest measured phase anchor', () {
      // Frame 0 is at reach_back (pro 100), frame 10 at release (pro 160).
      // A perfect throw matching both should still score 100.
      final frames = [
        for (var i = 0; i <= 10; i++)
          frame({'rightElbowAngle': i <= 5 ? 100.0 : 160.0})
      ];
      final score = PostureAnalysisService.computeProDeviationScore(
        frames,
        proAngles,
        'BH',
        phaseFrameIndices: {'reach_back': 0, 'release': 10},
      );
      expect(score, closeTo(100.0, 1e-9));
    });

    test('falls back to evenly spaced phases without measured indices', () {
      final frames = [
        for (var i = 0; i < 12; i++) frame({'rightElbowAngle': 100.0})
      ];
      final score =
          PostureAnalysisService.computeProDeviationScore(frames, proAngles, 'BH');
      // Not asserting an exact value — only that the fallback path produces a
      // usable score rather than throwing or returning 0.
      expect(score, greaterThan(0.0));
      expect(score, lessThanOrEqualTo(100.0));
    });

    test('frames with no angles contribute nothing but do not crash', () {
      final frames = [frame({}), frame({'rightElbowAngle': 100.0})];
      final score = PostureAnalysisService.computeProDeviationScore(
        frames,
        proAngles,
        'BH',
        phaseFrameIndices: {'reach_back': 0, 'release': 1},
      );
      expect(score.isNaN, isFalse);
    });
  });

  group('FormAnalysis failure reporting', () {
    test('failureReason round-trips through JSON', () {
      final analysis = FormAnalysis(
        id: 'a1',
        date: DateTime(2026, 1, 1),
        videoPath: '/tmp/x.mp4',
        frames: const [],
        score: 0,
        isMock: true,
        failureReason: 'Analysis failed: boom',
      );

      final restored = FormAnalysis.fromJson(analysis.toJson());
      expect(restored.isMock, isTrue);
      expect(restored.failureReason, 'Analysis failed: boom');
    });

    test('legacy records without failureReason still decode', () {
      final restored = FormAnalysis.fromJson({
        'id': 'legacy',
        'date': DateTime(2026, 1, 1).toIso8601String(),
        'videoPath': '/tmp/x.mp4',
        'frames': <dynamic>[],
        'score': 0.0,
        'isMock': true,
      });
      expect(restored.failureReason, isNull);
      expect(restored.isMock, isTrue);
    });
  });
}
