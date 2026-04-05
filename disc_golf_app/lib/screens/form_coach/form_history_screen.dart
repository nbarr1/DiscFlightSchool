import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/form_history_service.dart';

class FormHistoryScreen extends StatelessWidget {
  const FormHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final history = Provider.of<FormHistoryService>(context);
    final sessions = history.sessions;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Form History'),
        actions: [
          if (sessions.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear history',
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear History'),
                    content: const Text(
                        'Delete all saved form sessions? This cannot be undone.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Clear',
                              style: TextStyle(color: Colors.red))),
                    ],
                  ),
                );
                if (confirmed == true) history.clearHistory();
              },
            ),
        ],
      ),
      body: sessions.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No sessions recorded yet',
                      style: TextStyle(fontSize: 18, color: Colors.grey)),
                  SizedBox(height: 8),
                  Text('Analyze a form video to start tracking progress',
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                      textAlign: TextAlign.center),
                ],
              ),
            )
          : Column(
              children: [
                // Mini trend chart for each throw type
                _TrendSection(history: history, throwType: 'BH', label: 'Backhand'),
                _TrendSection(history: history, throwType: 'FH', label: 'Forehand'),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: sessions.length,
                    itemBuilder: (context, i) =>
                        _SessionCard(session: sessions[i]),
                  ),
                ),
              ],
            ),
    );
  }
}

class _TrendSection extends StatelessWidget {
  final FormHistoryService history;
  final String throwType;
  final String label;

  const _TrendSection(
      {required this.history, required this.throwType, required this.label});

  @override
  Widget build(BuildContext context) {
    final trend = history.trend(throwType, n: 10);
    if (trend.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label Trend',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.white70)),
          const SizedBox(height: 6),
          SizedBox(
            height: 60,
            child: CustomPaint(
              painter: _TrendPainter(trend.map((s) => s.score).toList()),
              size: const Size(double.infinity, 60),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${trend.length} sessions',
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
              Text(
                  'Latest: ${trend.last.score.toStringAsFixed(1)}',
                  style: TextStyle(
                      fontSize: 11,
                      color: _scoreColor(trend.last.score),
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Color _scoreColor(double s) {
    if (s >= 80) return Colors.green;
    if (s >= 60) return Colors.orange;
    return Colors.red;
  }
}

class _TrendPainter extends CustomPainter {
  final List<double> scores;
  _TrendPainter(this.scores);

  @override
  void paint(Canvas canvas, Size size) {
    if (scores.length < 2) return;
    const minS = 0.0;
    const maxS = 100.0;
    final stepX = size.width / (scores.length - 1);

    final linePaint = Paint()
      ..color = Colors.blueAccent.withAlpha(200)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..color = Colors.blueAccent.withAlpha(40)
      ..style = PaintingStyle.fill;

    final path = Path();
    final fill = Path();

    for (int i = 0; i < scores.length; i++) {
      final x = i * stepX;
      final y = size.height - (scores[i] - minS) / (maxS - minS) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
        fill.moveTo(x, size.height);
        fill.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fill.lineTo(x, y);
      }
    }
    fill.lineTo((scores.length - 1) * stepX, size.height);
    fill.close();

    canvas.drawPath(fill, fillPaint);
    canvas.drawPath(path, linePaint);

    // Dots at each data point
    final dotPaint = Paint()..color = Colors.blueAccent;
    for (int i = 0; i < scores.length; i++) {
      final x = i * stepX;
      final y = size.height - (scores[i] - minS) / (maxS - minS) * size.height;
      canvas.drawCircle(Offset(x, y), 3, dotPaint);
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.scores != scores;
}

class _SessionCard extends StatelessWidget {
  final FormSessionRecord session;
  const _SessionCard({required this.session});

  Color _scoreColor(double s) {
    if (s >= 80) return Colors.green;
    if (s >= 60) return Colors.orange;
    return Colors.red;
  }

  String _label(double s) {
    if (s >= 90) return 'Excellent';
    if (s >= 80) return 'Good';
    if (s >= 70) return 'Fair';
    if (s >= 60) return 'Needs Work';
    return 'Poor';
  }

  @override
  Widget build(BuildContext context) {
    final color = _scoreColor(session.score);
    final date = session.date;
    final dateStr =
        '${date.month}/${date.day}/${date.year}  ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Score circle
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 2.5),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(session.score.toStringAsFixed(0),
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: color)),
                    Text(_label(session.score),
                        style:
                            TextStyle(fontSize: 8, color: color)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dateStr,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _chip(session.throwType == 'BH' ? 'Backhand' : 'Forehand',
                          Colors.purple),
                      if (session.proPlayer != null) ...[
                        const SizedBox(width: 6),
                        _chip('vs ${session.proPlayer}', Colors.teal),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('${session.frameCount} frames analyzed',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withAlpha(40),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(120)),
        ),
        child:
            Text(label, style: TextStyle(fontSize: 10, color: color)),
      );
}
