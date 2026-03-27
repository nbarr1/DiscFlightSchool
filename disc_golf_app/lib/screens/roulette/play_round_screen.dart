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

class _PlayRoundScreenState extends State<PlayRoundScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  int _currentHoleNumber = 1;
  bool _isSpinning = false;
  bool _isPutting = false;

  // Per-throw state for current player
  RouletteResult? _currentThrowChallenge;
  List<ThrowRecord> _currentThrows = [];

  // Multi-player tracking per hole
  final Map<String, List<ThrowRecord>> _playerThrows = {};
  final Map<String, int> _playerStrokes = {};
  final Set<String> _completedPlayers = {};

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

  List<String> get _availableDiscs =>
      _isPutting ? DiscLists.putting : DiscLists.scoringRound;

  void _spinRoulette() {
    setState(() {
      _isSpinning = true;
      _currentThrowChallenge = null;
    });

    _animationController.forward(from: 0).then((_) {
      setState(() {
        if (_isPutting) {
          _currentThrowChallenge =
              RouletteResult.generatePutt(_availableDiscs);
        } else {
          _currentThrowChallenge =
              RouletteResult.generate(_availableDiscs);
        }
        _isSpinning = false;
      });
    });
  }

  void _recordThrow() {
    if (_currentThrowChallenge == null) return;

    final throwRecord = ThrowRecord(
      throwNumber: _currentThrows.length + 1,
      challenge: _currentThrowChallenge!,
      isPutt: _isPutting,
    );

    setState(() {
      _currentThrows.add(throwRecord);
      _currentThrowChallenge = null;
      // Reset putting toggle for next throw
      _isPutting = false;
    });
  }

  void _holedOut() {
    // Record the final throw if there's an active challenge
    if (_currentThrowChallenge != null) {
      final throwRecord = ThrowRecord(
        throwNumber: _currentThrows.length + 1,
        challenge: _currentThrowChallenge!,
        isPutt: _isPutting,
      );
      _currentThrows.add(throwRecord);
    }

    final scoringService =
        Provider.of<ScoringService>(context, listen: false);
    final round = scoringService.currentRound!;
    final currentPlayer = scoringService.currentPlayer!;

    final strokes = _currentThrows.length;

    final holeScore = HoleScore(
      holeNumber: _currentHoleNumber,
      par: round.coursePars[_currentHoleNumber - 1],
      strokes: strokes,
      throws: List.from(_currentThrows),
      playerName: currentPlayer,
    );

    scoringService.addHoleScore(holeScore);

    setState(() {
      _completedPlayers.add(currentPlayer);
      _playerStrokes[currentPlayer] = strokes;
      _playerThrows[currentPlayer] = List.from(_currentThrows);
      _currentThrows = [];
      _currentThrowChallenge = null;
      _isPutting = false;

      // Move to next remaining player
      final remaining = round.playerNames
          .where((p) => !_completedPlayers.contains(p))
          .toList();
      if (remaining.isNotEmpty) {
        scoringService.setCurrentPlayer(remaining.first);
        _currentThrows = _playerThrows[remaining.first] ?? [];
      }
    });
  }

  void _moveToNextHole() {
    final scoringService =
        Provider.of<ScoringService>(context, listen: false);
    final round = scoringService.currentRound!;

    setState(() {
      _currentHoleNumber++;
      _completedPlayers.clear();
      _playerThrows.clear();
      _playerStrokes.clear();
      _currentThrows = [];
      _currentThrowChallenge = null;
      _isPutting = false;

      scoringService.setCurrentPlayer(round.playerNames.first);
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
    if (_currentHoleNumber > round.coursePars.length &&
        _completedPlayers.length == round.playerNames.length) {
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

    final remainingPlayers = round.playerNames
        .where((p) => !_completedPlayers.contains(p))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Hole $_currentHoleNumber'),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const ScorecardScreen(),
              ),
            ),
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
                    _buildStatItem(
                        'Hole', '$_currentHoleNumber/${round.coursePars.length}'),
                    _buildStatItem('Par', '$holePar'),
                    _buildStatItem('Completed',
                        '${_completedPlayers.length}/${round.playerNames.length}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Completed players for this hole
            if (_completedPlayers.isNotEmpty) ...[
              _buildCompletedPlayersCard(holePar),
              const SizedBox(height: 16),
            ],

            if (remainingPlayers.isNotEmpty) ...[
              // Player selector
              _buildPlayerSelector(
                  scoringService, round, currentPlayer, remainingPlayers),
              const SizedBox(height: 16),

              // Throw history for current player
              if (_currentThrows.isNotEmpty) ...[
                _buildThrowHistory(),
                const SizedBox(height: 16),
              ],

              // Putting toggle
              _buildPuttingToggle(),
              const SizedBox(height: 16),

              // Spin or challenge display
              if (_currentThrowChallenge == null) ...[
                _buildSpinArea(),
              ] else ...[
                _buildChallengeCard(),
                const SizedBox(height: 24),
                _buildThrowActions(),
              ],
            ] else ...[
              // All players done — next hole
              _buildHoleCompleteCard(round),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value) {
    return Column(
      children: [
        Text(label,
            style: const TextStyle(fontSize: 14, color: Colors.black87)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black)),
      ],
    );
  }

  Widget _buildCompletedPlayersCard(int holePar) {
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Completed This Hole:',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.black)),
            const SizedBox(height: 8),
            ..._completedPlayers.map((player) {
              final strokes = _playerStrokes[player] ?? 0;
              final scoreToPar = strokes - holePar;
              final throws = _playerThrows[player] ?? [];
              final avgMult = throws.isEmpty
                  ? 1.0
                  : throws.fold(0.0, (s, t) => s + t.multiplier) /
                      throws.length;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(player,
                        style: const TextStyle(
                            fontSize: 14, color: Colors.black)),
                    Text(
                      '$strokes (${_formatScore(scoreToPar)}) ${avgMult.toStringAsFixed(1)}x',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: _getScoreColor(scoreToPar),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerSelector(ScoringService scoringService,
      ScoredRound round, String currentPlayer, List<String> remainingPlayers) {
    return Card(
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text('Current Player',
                style: const TextStyle(fontSize: 14, color: Colors.black87)),
            const SizedBox(height: 8),
            DropdownButton<String>(
              value: remainingPlayers.contains(currentPlayer)
                  ? currentPlayer
                  : remainingPlayers.first,
              isExpanded: true,
              items: remainingPlayers
                  .map((player) => DropdownMenuItem(
                        value: player,
                        child: Text(player,
                            style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.black)),
                      ))
                  .toList(),
              onChanged: (newPlayer) {
                if (newPlayer == null) return;
                // Save current player's throws
                _playerThrows[currentPlayer] = List.from(_currentThrows);

                scoringService.setCurrentPlayer(newPlayer);
                setState(() {
                  _currentThrows = _playerThrows[newPlayer] ?? [];
                  _currentThrowChallenge = null;
                  _isPutting = false;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThrowHistory() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Throws: ${_currentThrows.length}',
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.black),
                ),
                if (_currentThrows.isNotEmpty)
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _currentThrows.removeLast();
                      });
                    },
                    icon: const Icon(Icons.undo, size: 16),
                    label: const Text('Undo'),
                  ),
              ],
            ),
            const Divider(),
            ..._currentThrows.map((t) {
              final challenge = t.challenge;
              final label = t.isPutt
                  ? challenge.getPuttStyleDescription()
                  : '${challenge.getShotTypeDescription().split(' - ').first} · '
                      '${challenge.discName ?? "Any"} · '
                      '${challenge.hindrance == Hindrance.none ? "No Hindrance" : challenge.getHindranceName()}';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: t.isPutt
                            ? Colors.teal.shade100
                            : Colors.purple.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                          child: Text('${t.throwNumber}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  color: Colors.black))),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(label,
                          style: const TextStyle(
                              fontSize: 13, color: Colors.black),
                          overflow: TextOverflow.ellipsis),
                    ),
                    Text('${t.multiplier.toStringAsFixed(1)}x',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: _getDifficultyColor(t.multiplier))),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildPuttingToggle() {
    return Card(
      color: _isPutting ? Colors.teal.shade50 : null,
      child: SwitchListTile(
        title: Text(
          _isPutting ? 'Putting Mode' : 'Throwing Mode',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: _isPutting ? Colors.teal.shade800 : Colors.black,
          ),
        ),
        subtitle: Text(
          _isPutting
              ? 'Challenges: Putt Style (Putter Only)'
              : 'Challenges: Shot Type, Disc, Power, Hindrance',
          style: TextStyle(color: Colors.black87.withAlpha(180)),
        ),
        secondary: Icon(
          _isPutting ? Icons.gps_fixed : Icons.sports_golf,
          color: _isPutting ? Colors.teal : Colors.purple,
        ),
        value: _isPutting,
        activeThumbColor: Colors.teal,
        onChanged: _currentThrowChallenge != null
            ? null // Disable toggle when a challenge is active
            : (value) {
                setState(() {
                  _isPutting = value;
                });
              },
      ),
    );
  }

  Widget _buildSpinArea() {
    return Column(
      children: [
        Text(
          _currentThrows.isEmpty
              ? 'Tap The Wheel To Spin For Throw #1!'
              : 'Tap The Wheel To Spin For Throw #${_currentThrows.length + 1}!',
          style: const TextStyle(
              fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 250,
          child: Center(
            child: GestureDetector(
              onTap: _isSpinning ? null : _spinRoulette,
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
        ),
      ],
    );
  }

  Widget _buildChallengeCard() {
    final challenge = _currentThrowChallenge!;
    final difficulty = challenge.getDifficultyMultiplier();

    return Card(
      color: _isPutting ? Colors.teal.shade50 : Colors.purple.shade50,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Throw #${_currentThrows.length + 1}${challenge.isPutt ? " (Putt)" : ""}',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold, color: Colors.black),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _getDifficultyColor(difficulty),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${difficulty.toStringAsFixed(1)}x',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            if (challenge.isPutt) ...[
              _buildChallengeRow(
                'Putt Style',
                challenge.getPuttStyleDescription(),
                Icons.gps_fixed,
                color: Colors.teal,
              ),
              const SizedBox(height: 12),
              _buildChallengeRow(
                'Disc',
                challenge.discName ?? 'Putter',
                Icons.album,
              ),
            ] else ...[
              _buildChallengeRow(
                'Shot Type',
                challenge.getShotTypeDescription(),
                Icons.sports_golf,
              ),
              const SizedBox(height: 12),
              _buildChallengeRow(
                'Disc',
                challenge.discName ?? 'Any Disc',
                Icons.album,
              ),
              const SizedBox(height: 12),
              _buildChallengeRow(
                'Power',
                challenge.getPowerModifierName(),
                Icons.flash_on,
              ),
              const SizedBox(height: 12),
              _buildChallengeRow(
                'Challenge',
                challenge.getHindranceName(),
                challenge.hindrance == Hindrance.none
                    ? Icons.check_circle
                    : Icons.warning,
                color: challenge.hindrance == Hindrance.none
                    ? Colors.green
                    : Colors.orange,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChallengeRow(String label, String value, IconData icon,
      {Color? color}) {
    return Row(
      children: [
        Icon(icon, color: color ?? Colors.purple),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(fontSize: 12, color: Colors.black87)),
              Text(value,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.black)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildThrowActions() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _currentThrowChallenge = null;
                });
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Re-spin'),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: _recordThrow,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Next Throw'),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _holedOut,
            icon: const Icon(Icons.flag),
            label: const Text('Holed Out!'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: const TextStyle(fontSize: 18),
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHoleCompleteCard(ScoredRound round) {
    return Card(
      color: Colors.purple.shade50,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Icon(Icons.check_circle, size: 64, color: Colors.green),
            const SizedBox(height: 16),
            const Text('Hole Complete!',
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _moveToNextHole,
              icon: const Icon(Icons.arrow_forward),
              label: Text(_currentHoleNumber < round.coursePars.length
                  ? 'Next Hole'
                  : 'Finish Round'),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 18),
                backgroundColor: Colors.purple,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showUndoDialog() {
    final scoringService =
        Provider.of<ScoringService>(context, listen: false);
    final round = scoringService.currentRound;

    if (round == null || round.scores.isEmpty) return;

    final lastScore = round.scores.last;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Undo Last Score'),
        content: Text(
          'Remove Score For ${lastScore.playerName} On Hole ${lastScore.holeNumber}?\n\n'
          'Strokes: ${lastScore.strokes} (${lastScore.throws.length} Throws)\n'
          'Par: ${lastScore.par}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              _undoLastScore();
              Navigator.pop(ctx);
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
    final scoringService =
        Provider.of<ScoringService>(context, listen: false);
    scoringService.undoLastScore();

    setState(() {
      final round = scoringService.currentRound!;

      // Find current hole
      _currentHoleNumber = 1;
      for (int hole = 1; hole <= round.coursePars.length; hole++) {
        int completedCount = 0;
        for (var player in round.playerNames) {
          if (round.scores.any(
              (s) => s.holeNumber == hole && s.playerName == player)) {
            completedCount++;
          }
        }
        if (completedCount < round.playerNames.length) {
          _currentHoleNumber = hole;
          break;
        }
      }

      // Rebuild completed players
      _completedPlayers.clear();
      _playerThrows.clear();
      _playerStrokes.clear();
      for (var player in round.playerNames) {
        final holeScore = round.scores.cast<HoleScore?>().firstWhere(
              (s) =>
                  s!.holeNumber == _currentHoleNumber &&
                  s.playerName == player,
              orElse: () => null,
            );
        if (holeScore != null) {
          _completedPlayers.add(player);
          _playerStrokes[player] = holeScore.strokes;
          _playerThrows[player] = holeScore.throws;
        }
      }

      _currentThrows = [];
      _currentThrowChallenge = null;
      _isPutting = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Score Removed')),
    );
  }

  Color _getDifficultyColor(double difficulty) {
    if (difficulty < 1.3) return Colors.green;
    if (difficulty < 2.0) return Colors.orange;
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
