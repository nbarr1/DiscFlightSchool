import 'package:flutter/material.dart';
import '../../models/roulette_data.dart';
import '../../widgets/roulette_wheel.dart';
import 'dart:math';

class RouletteScreen extends StatefulWidget {
  const RouletteScreen({Key? key}) : super(key: key);

  @override
  State<RouletteScreen> createState() => _RouletteScreenState();
}

class _RouletteScreenState extends State<RouletteScreen> with SingleTickerProviderStateMixin {
  RouletteResult? _currentResult;
  bool _isSpinning = false;
  bool _isPutting = false;
  late AnimationController _animationController;

  List<String> get _availableDiscs =>
      _isPutting ? DiscLists.putting : DiscLists.all;

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
    });

    _animationController.forward(from: 0).then((_) {
      setState(() {
        _currentResult = _isPutting
            ? RouletteResult.generatePutt(_availableDiscs)
            : RouletteResult.generate(_availableDiscs);
        _isSpinning = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Disc Golf Roulette'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Text(
                      'Spin for Your Challenge!',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Add excitement to your round with random shot challenges',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildPuttingToggle(),
            const SizedBox(height: 12),
            Expanded(
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
            const SizedBox(height: 24),
            if (_currentResult != null) _buildResultCard(),
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
              ? 'Challenges: putt style (putter only)'
              : 'Challenges: shot type, disc, power, hindrance',
          style: TextStyle(color: Colors.grey.shade700),
        ),
        secondary: Icon(
          _isPutting ? Icons.gps_fixed : Icons.album,
          color: _isPutting ? Colors.teal : Colors.purple,
        ),
        value: _isPutting,
        activeThumbColor: Colors.teal,
        onChanged: _isSpinning
            ? null
            : (value) {
                setState(() {
                  _isPutting = value;
                  _currentResult = null;
                });
              },
      ),
    );
  }

  Widget _buildResultCard() {
    if (_currentResult == null) return const SizedBox.shrink();

    return Card(
      color: Colors.purple.shade50,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            Text(
              'Your Challenge',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
            ),
            const Divider(height: 24),
            if (_currentResult!.isPutt) ...[
              _buildResultRow(
                'Putt Style',
                _currentResult!.getPuttStyleDescription(),
                Icons.gps_fixed,
                color: Colors.teal,
              ),
              const SizedBox(height: 12),
              _buildResultRow(
                'Disc',
                _currentResult!.discName ?? 'Putter',
                Icons.album,
              ),
            ] else ...[
              _buildResultRow(
                'Shot Type',
                _currentResult!.getShotTypeDescription(),
                Icons.album,
              ),
              const SizedBox(height: 12),
              _buildResultRow(
                'Disc',
                _currentResult!.discName ?? 'Any Disc',
                Icons.album,
              ),
              const SizedBox(height: 12),
              _buildResultRow(
                'Power',
                _currentResult!.powerModifier.name,
                Icons.flash_on,
              ),
              const SizedBox(height: 12),
              _buildResultRow(
                'Challenge',
                _currentResult!.hindrance.name == 'none'
                    ? 'No Hindrance'
                    : _currentResult!.hindrance.name,
                _currentResult!.hindrance == Hindrance.none
                    ? Icons.check_circle
                    : Icons.warning,
                color: _currentResult!.hindrance == Hindrance.none
                    ? Colors.green
                    : Colors.orange,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultRow(String label, String value, IconData icon, {Color? color}) {
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
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade700,
                ),
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}