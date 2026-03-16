import 'dart:math';

enum ShotType {
  hyzer,
  anhyzer,
  flat,
  roller,
  tomahawk,
  thumber,
  grenade,
  scoober,
}

enum PowerModifier {
  fullPower,
  halfPower,
  quarterPower,
  overhand,
  standstill,
  runUp,
  xStep,
}

enum Hindrance {
  none,
  offHand,
  eyesClosed,
  backwards,
  oneLeg,
  sitting,
  kneeling,
  spinFirst,
}

class RouletteResult {
  final ShotType shotType;
  final String? discName;
  final PowerModifier powerModifier;
  final Hindrance hindrance;
  final DateTime timestamp;
  
  double getDifficultyMultiplier() {
  double multiplier = 1.0;
  
  // Shot type difficulty
  switch (shotType) {
    case ShotType.flat:
    case ShotType.hyzer:
      multiplier += 0.0;
      break;
    case ShotType.anhyzer:
      multiplier += 0.2;
      break;
    case ShotType.roller:
      multiplier += 0.3;
      break;
    case ShotType.scoober:
    case ShotType.tomahawk:
    case ShotType.thumber:
      multiplier += 0.5;
      break;
    case ShotType.grenade:
      multiplier += 0.7;
      break;
  }
  
  // Power modifier difficulty
  switch (powerModifier) {
    case PowerModifier.fullPower:
    case PowerModifier.runUp:
    case PowerModifier.xStep:
      multiplier += 0.0;
      break;
    case PowerModifier.halfPower:
      multiplier += 0.1;
      break;
    case PowerModifier.standstill:
      multiplier += 0.2;
      break;
    case PowerModifier.quarterPower:
      multiplier += 0.3;
      break;
    case PowerModifier.overhand:
      multiplier += 0.4;
      break;
  }
  
  // Hindrance difficulty (biggest impact)
  switch (hindrance) {
    case Hindrance.none:
      multiplier += 0.0;
      break;
    case Hindrance.kneeling:
    case Hindrance.sitting:
      multiplier += 0.3;
      break;
    case Hindrance.oneLeg:
      multiplier += 0.5;
      break;
    case Hindrance.spinFirst:
      multiplier += 0.7;
      break;
    case Hindrance.offHand:
      multiplier += 1.0;
      break;
    case Hindrance.backwards:
      multiplier += 1.2;
      break;
    case Hindrance.eyesClosed:
      multiplier += 1.5;
      break;
  }
  
  return multiplier;
}

factory RouletteResult.fromJson(Map<String, dynamic> json) {
  return RouletteResult(
    shotType: ShotType.values.firstWhere((e) => e.name == json['shotType']),
    discName: json['discName'],
    powerModifier: PowerModifier.values.firstWhere((e) => e.name == json['powerModifier']),
    hindrance: Hindrance.values.firstWhere((e) => e.name == json['hindrance']),
    timestamp: DateTime.parse(json['timestamp']),
  );
}

  RouletteResult({
    required this.shotType,
    this.discName,
    required this.powerModifier,
    required this.hindrance,
    required this.timestamp,
  });

  static RouletteResult generate(List<String> availableDiscs) {
    final random = Random();
    
    return RouletteResult(
      shotType: ShotType.values[random.nextInt(ShotType.values.length)],
      discName: availableDiscs.isNotEmpty 
          ? availableDiscs[random.nextInt(availableDiscs.length)]
          : null,
      powerModifier: PowerModifier.values[random.nextInt(PowerModifier.values.length)],
      hindrance: Hindrance.values[random.nextInt(Hindrance.values.length)],
      timestamp: DateTime.now(),
    );
  }

  String getShotTypeDescription() {
    switch (shotType) {
      case ShotType.hyzer:
        return 'Hyzer - Outside edge down';
      case ShotType.anhyzer:
        return 'Anhyzer - Outside edge up';
      case ShotType.flat:
        return 'Flat - Level release';
      case ShotType.roller:
        return 'Roller - Ground roll shot';
      case ShotType.tomahawk:
        return 'Tomahawk - Overhead hyzer';
      case ShotType.thumber:
        return 'Thumber - Overhead anhyzer';
      case ShotType.grenade:
        return 'Grenade - Vertical release';
      case ShotType.scoober:
        return 'Scoober - Upside down';
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'shotType': shotType.name,
      'discName': discName,
      'powerModifier': powerModifier.name,
      'hindrance': hindrance.name,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}

class GameSession {
  final String id;
  final List<String> players;
  final List<RouletteResult> results;
  final DateTime startedAt;
  DateTime? endedAt;

  GameSession({
    required this.id,
    required this.players,
    required this.results,
    required this.startedAt,
    this.endedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'players': players,
      'results': results.map((r) => r.toJson()).toList(),
      'startedAt': startedAt.toIso8601String(),
      'endedAt': endedAt?.toIso8601String(),
    };
  }
}