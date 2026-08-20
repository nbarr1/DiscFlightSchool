import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/disc_detection_service.dart';

/// Determinate progress for a full-auto detection run.
///
/// Automatic detection walks the clip frame by frame and can take a while, so
/// unlike the app's other loading dialogs this one shows real progress and
/// offers a way out. It reads [DiscDetectionService] directly — the service is
/// already an app-scoped [ChangeNotifier] publishing `progress` and
/// `statusMessage`, so no extra plumbing is needed to drive it.
class DetectionProgressDialog extends StatelessWidget {
  final VoidCallback onCancel;

  const DetectionProgressDialog({super.key, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    // The run holds a lock and must be cancelled properly, so the Android back
    // button must not be able to dismiss the dialog out from under it.
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Finding the disc'),
        content: Consumer<DiscDetectionService>(
          builder: (context, service, _) {
            final progress = service.progress.clamp(0.0, 1.0);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: progress,
                          backgroundColor: Colors.white24,
                          color: Colors.deepPurpleAccent,
                          minHeight: 4,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text('${(progress * 100).round()}%'),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  service.statusMessage.isEmpty
                      ? 'Starting...'
                      : service.statusMessage,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Keep the app open — this can take a minute.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: onCancel,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
