// ARCHIVED — Frame-by-frame pro comparison using Catmull-Rom interpolated frames.
// Interpolated frames are synthesized estimates, not measured data.
// The only defensible pro comparison is PhaseComparisonScreen (4 measured snapshots).
// Keep this file for potential future use if per-frame pro video data is ever collected.

import 'package:flutter/material.dart';
import '../../models/form_analysis.dart';

class ComparisonScreen extends StatefulWidget {
  final FormAnalysis userAnalysis;
  final FormAnalysis proAnalysis;
  final String proName;

  const ComparisonScreen({
    Key? key,
    required this.userAnalysis,
    required this.proAnalysis,
    required this.proName,
  }) : super(key: key);

  @override
  State<ComparisonScreen> createState() => _ComparisonScreenState();
}

class _ComparisonScreenState extends State<ComparisonScreen> {
  int _currentFrame = 0;

  int get _maxFrames {
    final userLen = widget.userAnalysis.frames.length;
    final proLen = widget.proAnalysis.frames.length;
    return userLen < proLen ? userLen : proLen;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('vs ${widget.proName}'),
      ),
      body: _maxFrames == 0
          ? const Center(child: Text('No frame data to compare'))
          : Column(
              children: [
                // Frame slider
                _buildFrameSlider(),

                // Angle comparison table
                Expanded(
                  child: _buildAngleComparison(),
                ),

                // Overall match score
                _buildMatchScore(),
              ],
            ),
    );
  }

  Widget _buildFrameSlider() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.black87,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, color: Colors.white, size: 20),
            onPressed: _currentFrame > 0
                ? () => setState(() => _currentFrame--)
                : null,
          ),
          Expanded(
            child: Slider(
              value: _currentFrame.toDouble(),
              min: 0,
              max: (_maxFrames - 1).toDouble().clamp(0, double.infinity),
              divisions: _maxFrames > 1 ? _maxFrames - 1 : 1,
              onChanged: (value) {
                setState(() {
                  _currentFrame = value.toInt();
                });
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.skip_next, color: Colors.white, size: 20),
            onPressed: _currentFrame < _maxFrames - 1
                ? () => setState(() => _currentFrame++)
                : null,
          ),
          Text(
            'Frame ${_currentFrame + 1} / $_maxFrames',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildAngleComparison() {
    if (_currentFrame >= widget.userAnalysis.frames.length ||
        _currentFrame >= widget.proAnalysis.frames.length) {
      return const Center(child: Text('No data for this frame'));
    }

    final userFrame = widget.userAnalysis.frames[_currentFrame];
    final proFrame = widget.proAnalysis.frames[_currentFrame];

    final allAngles = <String>{
      ...userFrame.angles.keys,
      ...proFrame.angles.keys,
    }.toList();

    return Card(
      margin: const EdgeInsets.all(8),
      child: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const Expanded(flex: 2, child: Text('Angle', style: TextStyle(fontWeight: FontWeight.bold))),
                const Expanded(child: Text('You', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue))),
                Expanded(child: Text(widget.proName, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green))),
                const Expanded(child: Text('Diff', style: TextStyle(fontWeight: FontWeight.bold))),
              ],
            ),
          ),
          const Divider(height: 1),
          ...allAngles.map((angleName) {
            final userVal = userFrame.angles[angleName] ?? 0;
            final proVal = proFrame.angles[angleName] ?? 0;
            final diff = (userVal - proVal).abs();
            final diffColor = diff < 10 ? Colors.green : diff < 25 ? Colors.orange : Colors.red;

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(
                      _formatAngleName(angleName),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${userVal.toStringAsFixed(1)}°',
                      style: const TextStyle(fontSize: 12, color: Colors.blue),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${proVal.toStringAsFixed(1)}°',
                      style: const TextStyle(fontSize: 12, color: Colors.green),
                    ),
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          diff < 10 ? Icons.check_circle : Icons.warning,
                          size: 14,
                          color: diffColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${diff.toStringAsFixed(1)}°',
                          style: TextStyle(fontSize: 12, color: diffColor, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildMatchScore() {
    // Calculate overall match percentage across all frames
    double totalDiff = 0;
    int count = 0;

    final frameCount = _maxFrames;
    for (int i = 0; i < frameCount; i++) {
      final userFrame = widget.userAnalysis.frames[i];
      final proFrame = widget.proAnalysis.frames[i];

      for (var angleName in userFrame.angles.keys) {
        final userVal = userFrame.angles[angleName] ?? 0;
        final proVal = proFrame.angles[angleName] ?? 0;
        totalDiff += (userVal - proVal).abs();
        count++;
      }
    }

    final avgDiff = count > 0 ? totalDiff / count : 0.0;
    final matchPercent = (100 - avgDiff).clamp(0, 100).toDouble();
    final color = matchPercent >= 80
        ? Colors.green
        : matchPercent >= 60
            ? Colors.orange
            : Colors.red;

    return Container(
      padding: const EdgeInsets.all(16),
      color: color.withAlpha(30),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.compare_arrows, color: color),
          const SizedBox(width: 12),
          Text(
            'Form Match: ${matchPercent.toStringAsFixed(1)}%',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '(avg ${avgDiff.toStringAsFixed(1)}° off)',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
        ],
      ),
    );
  }

  String _formatAngleName(String name) {
    return name
        .replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(0)}')
        .replaceFirst(name[0], name[0].toUpperCase())
        .trim();
  }
}
