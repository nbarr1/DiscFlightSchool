import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/roulette_data.dart';
import '../../services/roulette_history_service.dart';

class RouletteHistoryScreen extends StatelessWidget {
  const RouletteHistoryScreen({super.key});

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return 'Today $h:$m';
    }
    if (diff.inDays == 1) return 'Yesterday';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  Color _difficultyColor(double d) {
    if (d < 1.4) return Colors.green;
    if (d < 2.0) return Colors.orange;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Spin History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear history',
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Clear Spin History'),
                  content: const Text(
                      'This will permanently delete all saved spins.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Clear',
                            style: TextStyle(color: Colors.red))),
                  ],
                ),
              );
              if (confirm == true && context.mounted) {
                context.read<RouletteHistoryService>().clearHistory();
              }
            },
          ),
        ],
      ),
      body: Consumer<RouletteHistoryService>(
        builder: (context, svc, _) {
          final history = svc.history;
          if (history.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.casino, size: 64, color: Colors.white24),
                  SizedBox(height: 16),
                  Text(
                    'No spins yet',
                    style: TextStyle(color: Colors.white54, fontSize: 16),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Head to Disc Roulette and spin to start your log.',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          // Summary row
          final total = history.length;
          final avgDiff = history.fold(0.0, (s, r) => s + r.difficultyMultiplier) / total;

          return Column(
            children: [
              _buildSummaryBar(context, total, avgDiff),
              Expanded(
                child: ListView.builder(
                  itemCount: history.length,
                  itemBuilder: (context, i) =>
                      _buildCard(context, history[i]),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSummaryBar(
      BuildContext context, int total, double avgDiff) {
    return Container(
      color: Colors.purple.withAlpha(30),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _statChip(context, '$total', 'Total Spins', Icons.casino),
          _statChip(context, avgDiff.toStringAsFixed(2), 'Avg Difficulty',
              Icons.bar_chart),
        ],
      ),
    );
  }

  Widget _statChip(
      BuildContext context, String value, String label, IconData icon) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.purple.shade300),
            const SizedBox(width: 4),
            Text(value,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
        Text(label,
            style: const TextStyle(fontSize: 11, color: Colors.white54)),
      ],
    );
  }

  Widget _buildCard(BuildContext context, RouletteResult r) {
    final diff = r.difficultyMultiplier;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            // Difficulty circle
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _difficultyColor(diff).withAlpha(40),
                border:
                    Border.all(color: _difficultyColor(diff), width: 1.5),
              ),
              child: Center(
                child: Text(
                  diff.toStringAsFixed(1),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: _difficultyColor(diff),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.isPutt
                        ? r.getPuttStyleDescription()
                        : '${r.getShotTypeDescription()} · ${r.discName ?? "Any"}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  if (!r.isPutt)
                    Text(
                      '${r.getPowerModifierName()} · ${r.getHindranceName()}',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white54),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // Date
            Text(
              _formatDate(r.timestamp),
              style:
                  const TextStyle(fontSize: 11, color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }
}
