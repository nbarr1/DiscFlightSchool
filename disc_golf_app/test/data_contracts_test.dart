import 'package:flutter_test/flutter_test.dart';
import 'package:disc_golf_app/models/detector_model_metadata.dart';
import 'package:disc_golf_app/models/form_session_record.dart';
import 'package:disc_golf_app/models/roulette_data.dart';
import 'package:disc_golf_app/models/roulette_scoring.dart';
import 'package:disc_golf_app/models/training_sample.dart';

void main() {
  test('TrainingSample preserves legacy uploaded default and YOLO formatting', () {
    final sample = TrainingSample.fromJson({
      'id': 'sample-1',
      'imagePath': '/tmp/full.jpg',
      'cropPath': '/tmp/crop.jpg',
      'centerX': 0.5,
      'centerY': 0.25,
      'boxWidth': 0.125,
      'boxHeight': 0.0625,
      'frameIndex': 3,
      'imageWidth': 640,
      'imageHeight': 360,
      'createdAt': '2026-05-07T00:00:00.000Z',
    });

    expect(sample.uploaded, isFalse);
    expect(sample.toYoloLabel(), '0 0.500000 0.250000 0.125000 0.062500');
  });

  test('HoleScore still reads legacy single challenge JSON', () {
    final challenge = RouletteResult(
      shotType: ShotType.hyzer,
      powerModifier: PowerModifier.standstill,
      hindrance: Hindrance.none,
      timestamp: DateTime.utc(2026, 5, 7),
    );

    final score = HoleScore.fromJson({
      'holeNumber': 1,
      'par': 3,
      'strokes': 4,
      'challenge': challenge.toJson(),
      'playerName': 'Player 1',
    });

    expect(score.throws, hasLength(1));
    expect(score.throws.single.throwNumber, 1);
    expect(score.playerName, 'Player 1');
  });

  test('FormSessionRecord preserves default throw type for legacy JSON', () {
    final record = FormSessionRecord.fromJson({
      'id': 'form-1',
      'date': '2026-05-07T00:00:00.000Z',
      'score': 87,
      'frameCount': 4,
      'avgAngles': {'elbow': 123.4},
    });

    expect(record.throwType, 'BH');
    expect(record.avgAngles['elbow'], 123.4);
  });

  test('DetectorModelVersion exposes no-model sentinel', () {
    final version = DetectorModelVersion.fromJson({
      'version': 'none',
      'sha256': '',
      'url': '',
    });

    expect(version.hasModel, isFalse);
  });
}
