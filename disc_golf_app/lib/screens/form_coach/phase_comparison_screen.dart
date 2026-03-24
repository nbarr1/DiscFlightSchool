import 'package:flutter/material.dart';
import '../../models/form_analysis.dart';
import '../../utils/pro_data_parser.dart';

class PhaseComparisonScreen extends StatefulWidget {
  final FormAnalysis userAnalysis;
  final Map<String, int> phaseFrames; // phase name → user's frame index
  final String proName;
  final String throwType;

  const PhaseComparisonScreen({
    super.key,
    required this.userAnalysis,
    required this.phaseFrames,
    required this.proName,
    required this.throwType,
  });

  @override
  State<PhaseComparisonScreen> createState() => _PhaseComparisonScreenState();
}

class _PhaseComparisonScreenState extends State<PhaseComparisonScreen> {
  Map<String, Map<String, double>>? _proPhaseAngles;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProData();
  }

  Future<void> _loadProData() async {
    final proAngles = await ProBaselineParser.getPhaseAngles(
      widget.proName,
      widget.throwType,
    );
    setState(() {
      _proPhaseAngles = proAngles;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final phases = ProBaselineParser.getPhaseNames(widget.throwType);

    return Scaffold(
      appBar: AppBar(
        title: Text('vs ${widget.proName}'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: phases.length + 1, // +1 for overall score
              itemBuilder: (context, index) {
                if (index == phases.length) {
                  return _buildOverallScore(phases);
                }
                return _buildPhaseCard(phases[index]);
              },
            ),
    );
  }

  Widget _buildPhaseCard(String phaseName) {
    final frameIndex = widget.phaseFrames[phaseName];
    if (frameIndex == null) return const SizedBox.shrink();

    final userFrame = widget.userAnalysis.frames[frameIndex];
    final proAngles = _proPhaseAngles![phaseName] ?? {};

    // Angle names that both user and pro have
    final angleNames = proAngles.keys
        .where((name) => userFrame.angles.containsKey(name))
        .toList();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text(
          _formatPhaseName(phaseName),
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Builder(
          builder: (context) {
            double phaseTotal = 0;
            for (final name in angleNames) {
              phaseTotal += (userFrame.angles[name]! - proAngles[name]!).abs();
            }
            final avgDiff = angleNames.isNotEmpty ? phaseTotal / angleNames.length : 0.0;
            final matchPct = (100 - avgDiff).clamp(0.0, 100.0);
            return Text(
              'Phase Match: ${matchPct.toStringAsFixed(0)}%',
              style: TextStyle(
                color: _getMatchColor(matchPct),
                fontWeight: FontWeight.w600,
              ),
            );
          },
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Table(
              columnWidths: const {
                0: FlexColumnWidth(2.5),
                1: FlexColumnWidth(1.2),
                2: FlexColumnWidth(1.2),
                3: FlexColumnWidth(1.2),
              },
              children: [
                const TableRow(
                  children: [
                    Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('Angle',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                    Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('You',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13),
                          textAlign: TextAlign.center),
                    ),
                    Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('Pro',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13),
                          textAlign: TextAlign.center),
                    ),
                    Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('Diff',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13),
                          textAlign: TextAlign.center),
                    ),
                  ],
                ),
                ...angleNames.map((name) {
                  final userVal = userFrame.angles[name]!;
                  final proVal = proAngles[name]!;
                  final diff = (userVal - proVal).abs();
                  return TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(_formatAngleName(name), style: const TextStyle(fontSize: 13)),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text('${userVal.toStringAsFixed(0)}°',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13)),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text('${proVal.toStringAsFixed(0)}°',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13)),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          '${diff.toStringAsFixed(0)}°',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _getDiffColor(diff),
                          ),
                        ),
                      ),
                    ],
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverallScore(List<String> phases) {
    double totalDiff = 0;
    int totalCount = 0;

    for (final phase in phases) {
      final frameIndex = widget.phaseFrames[phase];
      if (frameIndex == null) continue;
      final userFrame = widget.userAnalysis.frames[frameIndex];
      final proAngles = _proPhaseAngles![phase] ?? {};
      for (final name in proAngles.keys) {
        if (userFrame.angles.containsKey(name)) {
          totalDiff += (userFrame.angles[name]! - proAngles[name]!).abs();
          totalCount++;
        }
      }
    }

    final avgDiff = totalCount > 0 ? totalDiff / totalCount : 0.0;
    final overallMatch = (100 - avgDiff).clamp(0.0, 100.0);

    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Text(
              'Overall Form Match',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              '${overallMatch.toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.bold,
                color: _getMatchColor(overallMatch),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Avg difference: ${avgDiff.toStringAsFixed(1)}° across $totalCount angles',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Color _getDiffColor(double diff) {
    if (diff < 10) return Colors.green;
    if (diff < 25) return Colors.orange;
    return Colors.red;
  }

  Color _getMatchColor(double matchPct) {
    if (matchPct >= 90) return Colors.green;
    if (matchPct >= 75) return Colors.orange;
    return Colors.red;
  }

  String _formatPhaseName(String name) {
    return name
        .split('_')
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  String _formatAngleName(String name) {
    final result = name.replaceAllMapped(
      RegExp(r'([A-Z])'),
      (match) => ' ${match.group(0)}',
    );
    return result[0].toUpperCase() +
        result.substring(1).replaceAll('Angle', '').trim();
  }
}
