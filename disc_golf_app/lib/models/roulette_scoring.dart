import 'roulette_data.dart';

class HoleScore {
  final int holeNumber;
  final int par;
  final int strokes;
  final RouletteResult challenge;
  final double difficultyMultiplier;
  final String playerName; // Add player tracking
  
  HoleScore({
    required this.holeNumber,
    required this.par,
    required this.strokes,
    required this.challenge,
    required this.difficultyMultiplier,
    required this.playerName,
  });

  int get rawScore => strokes - par;
  double get weightedScore => rawScore * difficultyMultiplier;

  Map<String, dynamic> toJson() {
    return {
      'holeNumber': holeNumber,
      'par': par,
      'strokes': strokes,
      'challenge': challenge.toJson(),
      'difficultyMultiplier': difficultyMultiplier,
      'playerName': playerName,
    };
  }

  factory HoleScore.fromJson(Map<String, dynamic> json) {
    return HoleScore(
      holeNumber: json['holeNumber'],
      par: json['par'],
      strokes: json['strokes'],
      challenge: RouletteResult.fromJson(json['challenge']),
      difficultyMultiplier: json['difficultyMultiplier'],
      playerName: json['playerName'],
    );
  }
}

class ScoredRound {
  final String id;
  final List<String> playerNames;
  final DateTime startedAt;
  final DateTime? completedAt;
  final List<int> coursePars;
  final List<HoleScore> scores;
  final bool useWeighting;

  ScoredRound({
    required this.id,
    required this.playerNames,
    required this.startedAt,
    this.completedAt,
    required this.coursePars,
    required this.scores,
    this.useWeighting = true,
  });

  int getTotalRawStrokes(String playerName) {
    return scores
        .where((s) => s.playerName == playerName)
        .fold(0, (sum, score) => sum + score.strokes);
  }

  int get totalPar => coursePars.fold(0, (sum, par) => sum + par);
  
  int getRawScoreToPar(String playerName) {
    return getTotalRawStrokes(playerName) - totalPar;
  }
  
  double getTotalWeightedScore(String playerName) {
    return scores
        .where((s) => s.playerName == playerName)
        .fold(0.0, (sum, score) => sum + score.weightedScore);
  }
  
  bool get isComplete {
    for (var player in playerNames) {
      final playerScores = scores.where((s) => s.playerName == player).length;
      if (playerScores < coursePars.length) return false;
    }
    return true;
  }

  int getCurrentHole(String playerName) {
    return scores.where((s) => s.playerName == playerName).length + 1;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'playerNames': playerNames,
      'startedAt': startedAt.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'coursePars': coursePars,
      'scores': scores.map((s) => s.toJson()).toList(),
      'useWeighting': useWeighting,
    };
  }

  factory ScoredRound.fromJson(Map<String, dynamic> json) {
    return ScoredRound(
      id: json['id'],
      playerNames: List<String>.from(json['playerNames']),
      startedAt: DateTime.parse(json['startedAt']),
      completedAt: json['completedAt'] != null ? DateTime.parse(json['completedAt']) : null,
      coursePars: List<int>.from(json['coursePars']),
      scores: (json['scores'] as List).map((s) => HoleScore.fromJson(s)).toList(),
      useWeighting: json['useWeighting'] ?? true,
    );
  }

  static List<int> defaultCourse({int holes = 18, int defaultPar = 3}) {
    return List.filled(holes, defaultPar);
  }
}