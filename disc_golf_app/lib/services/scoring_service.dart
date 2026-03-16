import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/roulette_scoring.dart';

class ScoringService extends ChangeNotifier {
  ScoredRound? _currentRound;
  List<ScoredRound> _savedRounds = [];
  String? _currentPlayer;

  ScoredRound? get currentRound => _currentRound;
  List<ScoredRound> get savedRounds => List.unmodifiable(_savedRounds);
  String? get currentPlayer => _currentPlayer;

  ScoringService() {
    _loadRounds();
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
    
    _currentRound = ScoredRound(
      id: _currentRound!.id,
      playerNames: _currentRound!.playerNames,
      startedAt: _currentRound!.startedAt,
      completedAt: _currentRound!.isComplete ? DateTime.now() : null,
      coursePars: _currentRound!.coursePars,
      scores: updatedScores,
      useWeighting: _currentRound!.useWeighting,
    );

    if (_currentRound!.isComplete) {
      _saveRound();
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

  void _saveRound() {
    if (_currentRound == null || !_currentRound!.isComplete) return;
    
    _savedRounds.add(_currentRound!);
    _persistRounds();
  }

  Future<void> _persistRounds() async {
    final prefs = await SharedPreferences.getInstance();
    final roundsJson = _savedRounds.map((r) => jsonEncode(r.toJson())).toList();
    await prefs.setStringList('saved_rounds', roundsJson);
  }

  Future<void> _loadRounds() async {
    final prefs = await SharedPreferences.getInstance();
    final roundsJson = prefs.getStringList('saved_rounds') ?? [];
    
    _savedRounds = roundsJson
        .map((json) => ScoredRound.fromJson(jsonDecode(json)))
        .toList();
    
    notifyListeners();
  }

  void deleteRound(String id) {
    _savedRounds.removeWhere((r) => r.id == id);
    _persistRounds();
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
    try {
      return _savedRounds.firstWhere((round) => round.id == id);
    } catch (e) {
      return null;
    }
  }
}