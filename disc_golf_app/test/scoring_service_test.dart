import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:disc_golf_app/models/roulette_data.dart';
import 'package:disc_golf_app/models/roulette_scoring.dart';
import 'package:disc_golf_app/services/scoring_service.dart';

RouletteResult challenge() => RouletteResult(
      shotType: ShotType.hyzer,
      powerModifier: PowerModifier.standstill,
      hindrance: Hindrance.none,
      timestamp: DateTime(2026, 1, 1),
    );

/// Build a HoleScore for [player] on [hole].
HoleScore holeScore(String player, int hole, {int strokes = 3, int par = 3}) {
  return HoleScore(
    holeNumber: hole,
    par: par,
    strokes: strokes,
    playerName: player,
    throws: [ThrowRecord(throwNumber: 1, challenge: challenge())],
  );
}

/// Drain pending microtasks and timers so fire-and-forget persistence
/// (addHoleScore -> _saveRound -> SharedPreferences) has completed.
Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Play [holes] complete holes for every player in [players].
Future<void> playRound(
  ScoringService service,
  List<String> players,
  int holes,
) async {
  for (var hole = 1; hole <= holes; hole++) {
    for (final player in players) {
      service.setCurrentPlayer(player);
      service.addHoleScore(holeScore(player, hole));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ScoringService round persistence', () {
    test('a completed round is saved exactly once', () async {
      final service = ScoringService();
      final holes = ScoredRound.defaultCourse().length;
      service.startNewRound(playerNames: ['Alice']);

      await playRound(service, ['Alice'], holes);
      await settle();

      expect(service.savedRounds, hasLength(1));
    });

    test(
      'undoing and re-entering the final hole does not save the round twice',
      () async {
        // Regression: addHoleScore saved whenever the round became complete,
        // and _saveRound appended unconditionally. Undo + re-enter therefore
        // persisted the same round a second time and double-counted it in
        // getStatistics().
        final service = ScoringService();
        final holes = ScoredRound.defaultCourse().length;
        service.startNewRound(playerNames: ['Alice']);

        await playRound(service, ['Alice'], holes);
        await settle();
        expect(service.savedRounds, hasLength(1));

        service.undoLastScore();
        expect(service.currentRound!.isComplete, isFalse);

        service.setCurrentPlayer('Alice');
        service.addHoleScore(holeScore('Alice', holes, strokes: 4));
        await settle();

        expect(
          service.savedRounds,
          hasLength(1),
          reason: 'the round should be updated in place, not appended again',
        );
        // And the correction should be the version that survives.
        final saved = service.savedRounds.single;
        expect(saved.scores.last.strokes, 4);
      },
    );

    test('repeated undo/redo cycles never accumulate duplicates', () async {
      final service = ScoringService();
      final holes = ScoredRound.defaultCourse().length;
      service.startNewRound(playerNames: ['Alice']);
      await playRound(service, ['Alice'], holes);
      await settle();

      for (var i = 0; i < 5; i++) {
        service.undoLastScore();
        service.setCurrentPlayer('Alice');
        service.addHoleScore(holeScore('Alice', holes, strokes: 3 + i));
        await settle();
      }

      expect(service.savedRounds, hasLength(1));
    });

    test('statistics count a round once per player', () async {
      final service = ScoringService();
      final holes = ScoredRound.defaultCourse().length;
      service.startNewRound(playerNames: ['Alice', 'Bob']);

      await playRound(service, ['Alice', 'Bob'], holes);
      await settle();

      service.undoLastScore();
      service.setCurrentPlayer('Bob');
      service.addHoleScore(holeScore('Bob', holes));
      await settle();

      final stats = service.getStatistics();
      expect(stats['totalRounds'], 1);
      expect((stats['playerRoundsPlayed'] as Map)['Alice'], 1);
      expect((stats['playerRoundsPlayed'] as Map)['Bob'], 1);
    });
  });

  group('ScoringService load resilience', () {
    test('one corrupt stored round does not discard the others', () async {
      // Regression: _loadRounds mapped jsonDecode over every entry with no
      // per-entry guard, so a single unreadable record threw and left the
      // service permanently unable to save.
      final good = ScoredRound(
        id: 'good-1',
        playerNames: ['Alice'],
        startedAt: DateTime(2026, 1, 1),
        completedAt: DateTime(2026, 1, 1, 1),
        coursePars: ScoredRound.defaultCourse(),
        scores: [],
      );

      SharedPreferences.setMockInitialValues({
        'saved_rounds': <String>[
          jsonEncode(good.toJson()),
          '{ this is not valid json',
          jsonEncode({'id': 'missing-required-fields'}),
        ],
      });

      final service = ScoringService();
      // Allow the constructor's load future to complete.
      await settle();

      expect(service.savedRounds, hasLength(1));
      expect(service.savedRounds.single.id, 'good-1');
    });

    test('a fully corrupt store still leaves the service usable', () async {
      SharedPreferences.setMockInitialValues({
        'saved_rounds': <String>['nonsense', 'also nonsense'],
      });

      final service = ScoringService();
      await settle();

      expect(service.savedRounds, isEmpty);

      // Saving must still work after a bad load.
      final holes = ScoredRound.defaultCourse().length;
      service.startNewRound(playerNames: ['Alice']);
      await playRound(service, ['Alice'], holes);
      await settle();

      expect(service.savedRounds, hasLength(1));
    });
  });

  group('ScoringService round lifecycle', () {
    test('undo clears the completed timestamp', () async {
      final service = ScoringService();
      final holes = ScoredRound.defaultCourse().length;
      service.startNewRound(playerNames: ['Alice']);
      await playRound(service, ['Alice'], holes);

      expect(service.currentRound!.completedAt, isNotNull);
      service.undoLastScore();
      expect(service.currentRound!.completedAt, isNull);
    });

    test('undo on an empty round is a no-op', () {
      final service = ScoringService();
      service.startNewRound(playerNames: ['Alice']);
      service.undoLastScore();
      expect(service.currentRound!.scores, isEmpty);
    });

    test('addHoleScore without an active round is ignored', () {
      final service = ScoringService();
      service.addHoleScore(holeScore('Alice', 1));
      expect(service.currentRound, isNull);
    });

    test('savedRounds is not externally mutable', () async {
      final service = ScoringService();
      expect(
        () => service.savedRounds.add(
          ScoredRound(
            id: 'x',
            playerNames: const ['A'],
            startedAt: DateTime(2026),
            coursePars: ScoredRound.defaultCourse(),
            scores: const [],
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('getStatistics returns empty when nothing is saved', () {
      final service = ScoringService();
      expect(service.getStatistics(), isEmpty);
    });

    test('getRoundById returns null for an unknown id', () {
      final service = ScoringService();
      expect(service.getRoundById('nope'), isNull);
    });
  });
}
