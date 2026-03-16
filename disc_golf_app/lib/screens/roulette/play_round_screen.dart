import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/scoring_service.dart';
import '../../models/roulette_data.dart';
import '../../models/roulette_scoring.dart';
import '../../widgets/roulette_wheel.dart';
import 'dart:math';
import 'scorecard_screen.dart';

class PlayRoundScreen extends StatefulWidget {
  const PlayRoundScreen({Key? key}) : super(key: key);

  @override
  State<PlayRoundScreen> createState() => _PlayRoundScreenState();
}

class _PlayRoundScreenState extends State<PlayRoundScreen> with SingleTickerProviderStateMixin {
  RouletteResult? _currentChallenge;
  bool _isSpinning = false;
  late AnimationController _animationController;
  int _strokes = 1;
  int _currentHoleNumber = 1;
  Map<String, RouletteResult> _playerChallenges = {};
  Map<String, int> _playerStrokes = {};
  Set<String> _completedPlayers = {};

  final List<String> _discs = [
    'Putter',
    'Approach',
    'Utility',
    'Midrange',
    'Fairway Driver',
    'Distance Driver',
  ];

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _spinRoulette() {
    setState(() {
      _isSpinning = true;
      _currentChallenge = null;
    });

    _animationController.forward(from: 0).then((_) {
      setState(() {
        _currentChallenge = RouletteResult.generate(_discs);
        _isSpinning = false;
        _strokes = 1;
      });
    });
  }

  String _formatScore(int score) {
    if (score == 0) return 'E';
    if (score > 0) return '+$score';
    return '$score';
  }

  @override
  Widget build(BuildContext context) {
    final scoringService = Provider.of<ScoringService>(context);
    final round = scoringService.currentRound;
    final currentPlayer = scoringService.currentPlayer;

    if (round == null || currentPlayer == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: const Center(child: Text('No active round')),
      );
    }

    // Check if round is complete
    if (_currentHoleNumber > round.coursePars.length && _completedPlayers.length == round.playerNames.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => const ScorecardScreen(),
          ),
        );
      });
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final holePar = _currentHoleNumber <= round.coursePars.length 
        ? round.coursePars[_currentHoleNumber - 1] 
        : 3;

    // Get players who haven't completed this hole yet
    final remainingPlayers = round.playerNames
        .where((player) => !_completedPlayers.contains(player))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Hole $_currentHoleNumber'),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ScorecardScreen(),
                ),
              );
            },
          ),
          if (round.scores.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.undo),
              onPressed: _showUndoDialog,
              tooltip: 'Undo Last Score',
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Hole info card
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildStatItem('Hole', '$_currentHoleNumber/18'),
                    _buildStatItem('Par', '$holePar'),
                    _buildStatItem('Completed', '${_completedPlayers.length}/${round.playerNames.length}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Show completed players for this hole
            if (_completedPlayers.isNotEmpty) ...[
              Card(
                color: Colors.green.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Completed This Hole:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ..._completedPlayers.map((player) {
                        final strokes = _playerStrokes[player] ?? 0;
                        final scoreToPar = strokes - holePar;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                player,
                                style: const TextStyle(fontSize: 14),
                              ),
                              Text(
                                '$strokes (${_formatScore(scoreToPar)})',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: _getScoreColor(scoreToPar),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Current player selector
            if (remainingPlayers.isNotEmpty) ...[
              Card(
                color: Colors.amber.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      const Text(
                        'Current Player',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButton<String>(
                        value: remainingPlayers.contains(currentPlayer) 
                            ? currentPlayer 
                            : remainingPlayers.first,
                        isExpanded: true,
                        items: remainingPlayers.map((player) {
                          return DropdownMenuItem(
                            value: player,
                            child: Text(
                              player,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          );
                        }).toList(),
                        onChanged: (newPlayer) {
                          if (newPlayer != null) {
                            scoringService.setCurrentPlayer(newPlayer);
                            // Restore saved challenge and strokes if available
                            setState(() {
                              _currentChallenge = _playerChallenges[newPlayer];
                              _strokes = _playerStrokes[newPlayer] ?? 1;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Challenge area
              if (_currentChallenge == null) ...[
                const Text(
                  'Spin for Your Challenge!',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 250,
                  child: Center(
                    child: AnimatedBuilder(
                      animation: _animationController,
                      builder: (context, child) {
                        return Transform.rotate(
                          angle: _animationController.value * 2 * pi * 3,
                          child: RouletteWheel(isSpinning: _isSpinning),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _isSpinning ? null : _spinRoulette,
                  icon: const Icon(Icons.casino),
                  label: Text(_isSpinning ? 'Spinning...' : 'Spin Roulette'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    textStyle: const TextStyle(fontSize: 18),
                  ),
                ),
              ] else ...[
                _buildChallengeCard(),
                const SizedBox(height: 24),
                _buildStrokeCounter(),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        setState(() {
                          _currentChallenge = null;
                          _playerChallenges.remove(currentPlayer);
                          _playerStrokes.remove(currentPlayer);
                          _strokes = 1;
                        });
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Re-spin'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 16),
                    ElevatedButton.icon(
                      onPressed: _submitScore,
                      icon: const Icon(Icons.check),
                      label: const Text('Submit Score'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        textStyle: const TextStyle(fontSize: 18),
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ] else ...[
              // All players completed, move to next hole
              Card(
                color: Colors.purple.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        size: 64,
                        color: Colors.green,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Hole Complete!',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _moveToNextHole,
                        icon: const Icon(Icons.arrow_forward),
                        label: Text(_currentHoleNumber < round.coursePars.length 
                            ? 'Next Hole' 
                            : 'Finish Round'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                          textStyle: const TextStyle(fontSize: 18),
                          backgroundColor: Colors.purple,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildChallengeCard() {
    final difficulty = _currentChallenge!.getDifficultyMultiplier();

    return Card(
      color: Colors.purple.shade50,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Your Challenge',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _getDifficultyColor(difficulty),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${difficulty.toStringAsFixed(1)}x',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _buildChallengeRow(
              'Shot Type',
              _currentChallenge!.getShotTypeDescription(),
              Icons.sports_golf,
            ),
            const SizedBox(height: 12),
            _buildChallengeRow(
              'Disc',
              _currentChallenge!.discName ?? 'Any Disc',
              Icons.album,
            ),
            const SizedBox(height: 12),
            _buildChallengeRow(
              'Power',
              _currentChallenge!.powerModifier.name,
              Icons.flash_on,
            ),
            const SizedBox(height: 12),
            _buildChallengeRow(
              'Challenge',
              _currentChallenge!.hindrance == Hindrance.none
                  ? 'No Hindrance'
                  : _currentChallenge!.hindrance.name,
              _currentChallenge!.hindrance == Hindrance.none
                  ? Icons.check_circle
                  : Icons.warning,
              color: _currentChallenge!.hindrance == Hindrance.none
                  ? Colors.green
                  : Colors.orange,
            ),
          ],
        ),
      ),
    );
  }

    Widget _buildChallengeRow(String label, String value, IconData icon, {Color? color}) {
    return Row(
      children: [
        Icon(icon, color: color ?? Colors.purple),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStrokeCounter() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.remove_circle, size: 36),
              onPressed: _strokes > 1 ? () {
                setState(() {
                  _strokes--;
                  final scoringService = Provider.of<ScoringService>(context, listen: false);
                  _playerStrokes[scoringService.currentPlayer!] = _strokes;
                });
              } : null,
            ),
            const SizedBox(width: 24),
            Column(
              children: [
                const Text(
                  'Strokes',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                  ),
                ),
                Text(
                  '$_strokes',
                  style: const TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 24),
            IconButton(
              icon: const Icon(Icons.add_circle, size: 36),
              onPressed: () {
                setState(() {
                  _strokes++;
                  final scoringService = Provider.of<ScoringService>(context, listen: false);
                  _playerStrokes[scoringService.currentPlayer!] = _strokes;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  void _submitScore() {
    final scoringService = Provider.of<ScoringService>(context, listen: false);
    final round = scoringService.currentRound!;
    final currentPlayer = scoringService.currentPlayer!;

    // Create a new HoleScore for the current hole
    HoleScore newScore = HoleScore(
      holeNumber: _currentHoleNumber,
      par: round.coursePars[_currentHoleNumber - 1],
      strokes: _strokes,
      challenge: _currentChallenge!,
      difficultyMultiplier: _currentChallenge!.getDifficultyMultiplier(),
      playerName: currentPlayer,
    );

    scoringService.addHoleScore(newScore);
    
    // Mark player as completed for this hole
    setState(() {
      _completedPlayers.add(currentPlayer);
      _playerStrokes[currentPlayer] = _strokes;
      _playerChallenges[currentPlayer] = _currentChallenge!;
      _currentChallenge = null;
      _strokes = 1;
      
      // Move to next player who hasn't completed this hole
      final remainingPlayers = round.playerNames
          .where((player) => !_completedPlayers.contains(player))
          .toList();
      
      if (remainingPlayers.isNotEmpty) {
        scoringService.setCurrentPlayer(remainingPlayers.first);
        // Restore their challenge if they have one
        _currentChallenge = _playerChallenges[remainingPlayers.first];
        _strokes = _playerStrokes[remainingPlayers.first] ?? 1;
      }
    });
  }

  void _moveToNextHole() {
    final scoringService = Provider.of<ScoringService>(context, listen: false);
    final round = scoringService.currentRound!;
    
    setState(() {
      _currentHoleNumber++;
      _completedPlayers.clear();
      _playerChallenges.clear();
      _playerStrokes.clear();
      _currentChallenge = null;
      _strokes = 1;
      
      // Reset to first player
      scoringService.setCurrentPlayer(round.playerNames.first);
    });
  }

  void _showUndoDialog() {
    final scoringService = Provider.of<ScoringService>(context, listen: false);
    final round = scoringService.currentRound;
    
    if (round == null || round.scores.isEmpty) return;
    
    final lastScore = round.scores.last;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Undo Last Score'),
        content: Text(
          'Remove score for ${lastScore.playerName} on Hole ${lastScore.holeNumber}?\n\n'
          'Strokes: ${lastScore.strokes}\n'
          'Par: ${lastScore.par}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              _undoLastScore();
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Undo'),
          ),
        ],
      ),
    );
  }

  void _undoLastScore() {
    final scoringService = Provider.of<ScoringService>(context, listen: false);
    final round = scoringService.currentRound;
    if (round != null && round.scores.isNotEmpty) {
      round.scores.removeLast();
    }
    
    setState(() {
      // Recalculate the current hole and completed players
      final round = scoringService.currentRound!;
      
      // Find the current hole (lowest hole number with incomplete players)
      _currentHoleNumber = 1;
      for (int hole = 1; hole <= round.coursePars.length; hole++) {
        int completedCount = 0;
        for (var player in round.playerNames) {
          if (round.scores.any((s) => s.holeNumber == hole && s.playerName == player)) {
            completedCount++;
          }
        }
        if (completedCount < round.playerNames.length) {
          _currentHoleNumber = hole;
          break;
        }
      }
      
      // Rebuild completed players set for current hole
      _completedPlayers.clear();
      for (var player in round.playerNames) {
        if (round.scores.any((s) => s.holeNumber == _currentHoleNumber && s.playerName == player)) {
          _completedPlayers.add(player);
          // Restore their strokes
          final score = round.scores.firstWhere(
            (s) => s.holeNumber == _currentHoleNumber && s.playerName == player,
          );
          _playerStrokes[player] = score.strokes;
        }
      }
      
      _currentChallenge = null;
      _strokes = 1;
      _playerChallenges.clear();
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Score removed')),
    );
  }

  Color _getDifficultyColor(double difficulty) {
    if (difficulty < 1.0) return Colors.green;
    if (difficulty < 1.5) return Colors.yellow.shade700;
    return Colors.red;
  }

  Color _getScoreColor(int scoreToPar) {
    if (scoreToPar <= -2) return Colors.purple;
    if (scoreToPar == -1) return Colors.blue;
    if (scoreToPar == 0) return Colors.green;
    if (scoreToPar == 1) return Colors.orange;
    return Colors.red;
  }
}