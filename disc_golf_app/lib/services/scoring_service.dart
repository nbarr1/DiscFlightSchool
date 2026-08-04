import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/roulette_scoring.dart';

class ScoringService extends ChangeNotifier {
  ScoredRound? _currentRound;
  List<ScoredRound> _savedRounds = [];
  String? _currentPlayer;
  late final Future<void> _loadFuture;

  ScoredRound? get currentRound => _currentRound;
  List<ScoredRound> get savedRounds => List.unmodifiable(_savedRounds);
  String? get currentPlayer => _currentPlayer;

  ScoringService() {
    // Swallow load failures here so a corrupt store can't surface as an
    // unhandled async error from the constructor. `_loadRounds` already
    // reports per-entry problems and leaves `_savedRounds` usable.
    _loadFuture = _loadRounds().catchError((Object e, StackTrace s) {
      debugPrint('Failed to load saved rounds: $e');
    });
  }

  void startNewRound({
    required List<String> playerNames,
    List<int>? customPars,
    bool useWeighting = true,
  }) {
    _currentRound = ScoredRound(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      playerNames: playerNames,
      startedAt: DateTime.now(),
      coursePars: customPars ?? ScoredRound.defaultCourse(),
      scores: [],
      useWeighting: useWeighting,
    );
    _currentPlayer = playerNames.first;
    notifyListeners();
  }

  void setCurrentPlayer(String playerName) {
    _currentPlayer = playerName;
    notifyListeners();
  }

  void addHoleScore(HoleScore score) {
    if (_currentRound == null || _currentPlayer == null) return;

    final updatedScores = List<HoleScore>.from(_currentRound!.scores)..add(score);
    final willBeComplete = _currentRound!.playerNames.every((player) {
      return updatedScores.where((s) => s.playerName == player).length >=
          _currentRound!.coursePars.length;
    });

    _currentRound = ScoredRound(
      id: _currentRound!.id,
      playerNames: _currentRound!.playerNames,
      startedAt: _currentRound!.startedAt,
      completedAt: willBeComplete ? DateTime.now() : null,
      coursePars: _currentRound!.coursePars,
      scores: updatedScores,
      useWeighting: _currentRound!.useWeighting,
    );

    if (_currentRound!.isComplete) {
      // Fire-and-forget: the UI does not block on persistence, but the future
      // still needs a terminal handler or a storage failure becomes an
      // unhandled async error.
      unawaited(_saveRound().catchError((Object e, StackTrace s) {
        debugPrint('Failed to save completed round: $e');
      }));
    }

    notifyListeners();
  }

  void undoLastScore() {
    if (_currentRound == null || _currentRound!.scores.isEmpty) return;

    final updatedScores = List<HoleScore>.from(_currentRound!.scores)..removeLast();
    
    _currentRound = ScoredRound(
      id: _currentRound!.id,
      playerNames: _currentRound!.playerNames,
      startedAt: _currentRound!.startedAt,
      completedAt: null, // Reset completion since we're undoing
      coursePars: _currentRound!.coursePars,
      scores: updatedScores,
      useWeighting: _currentRound!.useWeighting,
    );

    notifyListeners();
  }

  Future<void> _saveRound() async {
    if (_currentRound == null || !_currentRound!.isComplete) return;

    // Ensure the initial load has finished before mutating _savedRounds, so
    // a round saved shortly after startup can't be clobbered by the load's
    // unconditional overwrite once it resolves.
    await _loadFuture;

    final round = _currentRound;
    if (round == null || !round.isComplete) return;

    // Save by id, not by append. Completing a round, undoing the last hole,
    // and re-entering it re-triggers this path — appending would persist the
    // same round twice and double-count it in getStatistics().
    final existing = _savedRounds.indexWhere((r) => r.id == round.id);
    if (existing == -1) {
      _savedRounds.add(round);
    } else {
      _savedRounds[existing] = round;
    }
    await _persistRounds();
  }

  Future<void> _persistRounds() async {
    final prefs = await SharedPreferences.getInstance();
    final roundsJson = _savedRounds.map((r) => jsonEncode(r.toJson())).toList();
    await prefs.setStringList('saved_rounds', roundsJson);
  }

  Future<void> _loadRounds() async {
    final prefs = await SharedPreferences.getInstance();
    final roundsJson = prefs.getStringList('saved_rounds') ?? [];

    // Decode entry by entry: one corrupt record must not discard the rest of
    // the user's round history.
    final loaded = <ScoredRound>[];
    var skipped = 0;
    for (final entry in roundsJson) {
      try {
        loaded.add(ScoredRound.fromJson(
            jsonDecode(entry) as Map<String, dynamic>));
      } catch (e) {
        skipped++;
        debugPrint('Skipping unreadable saved round: $e');
      }
    }

    _savedRounds = loaded;
    if (skipped > 0) {
      debugPrint('Dropped $skipped unreadable round(s) of ${roundsJson.length}');
    }

    notifyListeners();
  }

  Future<void> deleteRound(String id) async {
    await _loadFuture;
    _savedRounds.removeWhere((r) => r.id == id);
    await _persistRounds();
    notifyListeners();
  }

  void clearCurrentRound() {
    _currentRound = null;
    _currentPlayer = null;
    notifyListeners();
  }

  Map<String, dynamic> getStatistics() {
    if (_savedRounds.isEmpty) return {};

    final completedRounds = _savedRounds.where((r) => r.isComplete).toList();
    if (completedRounds.isEmpty) return {};

    // Calculate statistics across all completed rounds
    Map<String, List<int>> playerScores = {};
    Map<String, int> playerRoundsPlayed = {};
    
    for (var round in completedRounds) {
      for (var player in round.playerNames) {
        playerScores.putIfAbsent(player, () => []);
        playerRoundsPlayed.putIfAbsent(player, () => 0);
        
        playerScores[player]!.add(round.getRawScoreToPar(player));
        playerRoundsPlayed[player] = playerRoundsPlayed[player]! + 1;
      }
    }

    // Calculate averages
    Map<String, double> playerAverages = {};
    playerScores.forEach((player, scores) {
      if (scores.isNotEmpty) {
        playerAverages[player] = scores.reduce((a, b) => a + b) / scores.length;
      }
    });

    return {
      'totalRounds': completedRounds.length,
      'playerScores': playerScores,
      'playerRoundsPlayed': playerRoundsPlayed,
      'playerAverages': playerAverages,
    };
  }

  List<ScoredRound> getRoundsForPlayer(String playerName) {
    return _savedRounds
        .where((round) => round.playerNames.contains(playerName))
        .toList();
  }

  ScoredRound? getRoundById(String id) {
    final index = _savedRounds.indexWhere((round) => round.id == id);
    return index == -1 ? null : _savedRounds[index];
  }
}