import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/scoring_service.dart';
import '../../models/roulette_scoring.dart';
import 'play_round_screen.dart';

class StartRoundScreen extends StatefulWidget {
  const StartRoundScreen({Key? key}) : super(key: key);

  @override
  State<StartRoundScreen> createState() => _StartRoundScreenState();
}

class _StartRoundScreenState extends State<StartRoundScreen> {
  final List<TextEditingController> _nameControllers = [TextEditingController()];
  bool _useWeighting = true;
  bool _customPars = false;
  List<int> _pars = ScoredRound.defaultCourse();

  @override
  void dispose() {
    for (var controller in _nameControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _addPlayer() {
    setState(() {
      _nameControllers.add(TextEditingController());
    });
  }

  void _removePlayer(int index) {
    if (_nameControllers.length > 1) {
      setState(() {
        _nameControllers[index].dispose();
        _nameControllers.removeAt(index);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Start New Round'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: Colors.deepPurple.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Players',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.black),
                        ),
                        ElevatedButton.icon(
                          onPressed: _addPlayer,
                          icon: const Icon(Icons.add),
                          label: const Text('Add Player'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ..._nameControllers.asMap().entries.map((entry) {
                      int index = entry.key;
                      TextEditingController controller = entry.value;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: controller,
                                decoration: InputDecoration(
                                  labelText: 'Player ${index + 1} Name',
                                  border: const OutlineInputBorder(),
                                  prefixIcon: const Icon(Icons.person),
                                ),
                              ),
                            ),
                            if (_nameControllers.length > 1) ...[
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.remove_circle, color: Colors.red),
                                onPressed: () => _removePlayer(index),
                              ),
                            ],
                          ],
                        ),
                      );
                    }).toList(),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              color: Colors.deepPurple.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Scoring Options',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.black),
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: const Text('Use Difficulty Weighting'),
                      subtitle: const Text('Harder Challenges Earn Bonus Points'),
                      value: _useWeighting,
                      onChanged: (value) {
                        setState(() {
                          _useWeighting = value;
                        });
                      },
                    ),
                    const Divider(),
                    SwitchListTile(
                      title: const Text('Custom Pars'),
                      subtitle: const Text('Set Par For Each Hole'),
                      value: _customPars,
                      onChanged: (value) {
                        setState(() {
                          _customPars = value;
                        });
                      },
                    ),
                  ],
                ),
              ),
            ),
            if (_customPars) ...[
              const SizedBox(height: 16),
              Card(
                color: Colors.deepPurple.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Course Setup',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.black),
                          ),
                          TextButton(
                            onPressed: () {
                              setState(() {
                                _pars = ScoredRound.defaultCourse();
                              });
                            },
                            child: const Text('Reset To Par 3'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildParGrid(),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _startRound,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start Round'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildParGrid() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        childAspectRatio: 1.5,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: 18,
      itemBuilder: (context, index) {
        return Card(
          color: Colors.deepPurple.shade50,
          child: InkWell(
            onTap: () => _showParPicker(index),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${index + 1}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.black87,
                  ),
                ),
                Text(
                  '${_pars[index]}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showParPicker(int holeIndex) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hole ${holeIndex + 1} Par'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [3, 4, 5].map((par) {
            return ListTile(
              title: Text('Par $par'),
              selected: _pars[holeIndex] == par,
              onTap: () {
                setState(() {
                  _pars[holeIndex] = par;
                });
                Navigator.pop(context);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  void _startRound() {
    // Validate that at least one player has a name
    final playerNames = _nameControllers
        .map((controller) => controller.text.trim())
        .where((name) => name.isNotEmpty)
        .toList();

    if (playerNames.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please Enter At Least One Player Name')),
      );
      return;
    }

    // Start the round
    final scoringService = Provider.of<ScoringService>(context, listen: false);
    scoringService.startNewRound(
      playerNames: playerNames,
      customPars: _customPars ? _pars : null,
      useWeighting: _useWeighting,
    );

    // Navigate to play round screen
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => const PlayRoundScreen(),
      ),
    );
  }
}