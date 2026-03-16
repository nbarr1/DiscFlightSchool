import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/scoring_service.dart';
import '../../models/roulette_scoring.dart';

class ScorecardScreen extends StatelessWidget {
  const ScorecardScreen({Key? key}) : super(key: key);

  String _formatScore(int score) {
    if (score == 0) return 'E';
    if (score > 0) return '+$score';
    return '$score';
  }

  @override
  Widget build(BuildContext context) {
    final scoringService = Provider.of<ScoringService>(context);
    final round = scoringService.currentRound;

    if (round == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: const Center(child: Text('No active round')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scorecard'),
        actions: [
          if (round.isComplete)
            IconButton(
              icon: const Icon(Icons.home),
              onPressed: () {
                scoringService.clearCurrentRound();
                Navigator.popUntil(context, (route) => route.isFirst);
              },
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              round.isComplete ? 'Final Scorecard' : 'Current Scorecard',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Started: ${_formatDateTime(round.startedAt)}',
              style: TextStyle(color: Colors.grey[600]),
            ),
            if (round.isComplete && round.completedAt != null)
              Text(
                'Completed: ${_formatDateTime(round.completedAt!)}',
                style: TextStyle(color: Colors.grey[600]),
              ),
            const SizedBox(height: 24),
            // Display scores for each player
            ...round.playerNames.map((playerName) {
              return _buildPlayerScorecard(context, round, playerName);
            }).toList(),
            if (round.isComplete) ...[
              const SizedBox(height: 24),
              _buildLeaderboard(context, round),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerScorecard(BuildContext context, ScoredRound round, String playerName) {
    final playerScores = round.scores.where((s) => s.playerName == playerName).toList();
    final totalRaw = round.getTotalRawStrokes(playerName);
    final scoreToPar = round.getRawScoreToPar(playerName);
    final totalWeighted = round.getTotalWeightedScore(playerName);

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  playerName,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.purple,
                      ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _getScoreColor(scoreToPar),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _formatScore(scoreToPar),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            // Hole-by-hole scores
            if (playerScores.isNotEmpty) ...[
              const Text(
                'Hole-by-Hole',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 12),
              _buildHoleScoresGrid(playerScores, round.coursePars),
              const SizedBox(height: 16),
            ],
            // Summary statistics
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatColumn('Total Strokes', '$totalRaw'),
                _buildStatColumn('Par', '${round.totalPar}'),
                _buildStatColumn('Score', _formatScore(scoreToPar)),
                if (round.useWeighting)
                  _buildStatColumn('Weighted', totalWeighted.toStringAsFixed(1)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHoleScoresGrid(List<HoleScore> scores, List<int> pars) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 9,
        childAspectRatio: 1.0,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: scores.length,
      itemBuilder: (context, index) {
        final score = scores[index];
        final scoreToPar = score.strokes - score.par;
        
        return Container(
          decoration: BoxDecoration(
            color: _getScoreColor(scoreToPar).withOpacity(0.2),
            border: Border.all(color: _getScoreColor(scoreToPar)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${score.holeNumber}',
                style: const TextStyle(
                  fontSize: 10,
                  color: Colors.grey,
                ),
              ),
              Text(
                '${score.strokes}',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: _getScoreColor(scoreToPar),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatColumn(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildLeaderboard(BuildContext context, ScoredRound round) {
    // Create a list of players with their scores
    final playerStats = round.playerNames.map((playerName) {
      return {
        'name': playerName,
        'rawScore': round.getRawScoreToPar(playerName),
        'weightedScore': round.getTotalWeightedScore(playerName),
      };
    }).toList();

    // Sort by weighted score if weighting is enabled, otherwise by raw score
    playerStats.sort((a, b) {
      if (round.useWeighting) {
        return (a['weightedScore'] as double).compareTo(b['weightedScore'] as double);
      } else {
        return (a['rawScore'] as int).compareTo(b['rawScore'] as int);
      }
    });

    return Card(
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.emoji_events, color: Colors.amber, size: 32),
                const SizedBox(width: 12),
                Text(
                  'Final Standings',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const Divider(height: 24),
            ...playerStats.asMap().entries.map((entry) {
              final index = entry.key;
              final stats = entry.value;
              final isWinner = index == 0;

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isWinner ? Colors.amber.shade100 : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isWinner ? Colors.amber : Colors.grey.shade300,
                    width: isWinner ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: isWinner ? Colors.amber : Colors.grey.shade300,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isWinner ? Colors.white : Colors.black,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        stats['name'] as String,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: isWinner ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _formatScore(stats['rawScore'] as int),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (round.useWeighting)
                          Text(
                            'Weighted: ${(stats['weightedScore'] as double).toStringAsFixed(1)}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            }).toList(),
          ],
        ),
      ),
    );
  }

  Color _getScoreColor(int scoreToPar) {
    if (scoreToPar <= -2) return Colors.purple; // Eagle or better
    if (scoreToPar == -1) return Colors.blue; // Birdie
    if (scoreToPar == 0) return Colors.green; // Par
    if (scoreToPar == 1) return Colors.orange; // Bogey
    return Colors.red; // Double bogey or worse
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.month}/${dateTime.day}/${dateTime.year} ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}