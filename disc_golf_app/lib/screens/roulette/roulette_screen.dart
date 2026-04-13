import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/roulette_data.dart';
import '../../services/roulette_history_service.dart';
import '../../widgets/roulette_wheel.dart';
import 'dart:math';
import 'roulette_history_screen.dart';

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
      final result = _isPutting
          ? RouletteResult.generatePutt(_availableDiscs)
          : RouletteResult.generate(_availableDiscs);
      setState(() {
        _currentResult = result;
        _isSpinning = false;
      });
      context.read<RouletteHistoryService>().addResult(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Disc Golf Roulette'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Spin History',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const RouletteHistoryScreen(),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Card(
              color: Colors.purple.withAlpha(40),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Text(
                      'Spin for Your Challenge!',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Add Excitement To Your Round With Random Shot Challenges',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade400),
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
      color: _isPutting ? Colors.teal.withAlpha(40) : Colors.purple.withAlpha(40),
      child: SwitchListTile(
        title: Text(
          _isPutting ? 'Putting Mode' : 'Throwing Mode',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: _isPutting ? Colors.teal.shade300 : Colors.purple.shade300,
          ),
        ),
        subtitle: Text(
          _isPutting
              ? 'Challenges: Putt Style (Putter Only)'
              : 'Challenges: Shot Type, Disc, Power, Hindrance',
          style: TextStyle(color: Colors.grey.shade400),
        ),
        secondary: Icon(
          _isPutting ? Icons.gps_fixed : Icons.album,
          color: _isPutting ? Colors.teal : Colors.purple,
        ),
        value: _isPutting,
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
      color: Colors.purple.withAlpha(40),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            Text(
              'Your Challenge',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
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
                _currentResult!.getPowerModifierName(),
                Icons.flash_on,
              ),
              const SizedBox(height: 12),
              _buildResultRow(
                'Challenge',
                _currentResult!.getHindranceName(),
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
        Icon(icon, color: color ?? Colors.purple.shade300),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade400,
                ),
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
