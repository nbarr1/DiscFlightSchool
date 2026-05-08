import '../../models/roulette_data.dart';
import '../../models/roulette_scoring.dart';

/// Persistence boundary for Disc Roulette spin and scored-round history.
abstract interface class RouletteRepository {
  Future<List<RouletteResult>> getSpinHistory();
  Future<void> saveSpin(RouletteResult result);
  Future<void> clearSpinHistory();

  Future<List<ScoredRound>> getScoredRounds();
  Future<void> saveScoredRound(ScoredRound round);
  Future<void> deleteScoredRound(String roundId);
}
