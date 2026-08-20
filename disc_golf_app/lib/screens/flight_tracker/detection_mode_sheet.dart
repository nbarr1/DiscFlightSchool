import 'package:flutter/material.dart';

/// How the user wants the disc found in a clip.
enum FlightSetupMode {
  /// Run the detector over the clip with no user input.
  auto,

  /// Tap the disc by hand, the existing anchoring/marking flow.
  manual,
}

/// Asks whether to auto-detect the disc or mark it by hand.
///
/// Presented once, before the camera-stability question, so choosing auto
/// skips straight past the manual setup entirely.
class DetectionModeSheet extends StatelessWidget {
  final VoidCallback onAuto;
  final VoidCallback onManual;

  const DetectionModeSheet({
    super.key,
    required this.onAuto,
    required this.onManual,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'How should we find the disc?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Auto-detect scans the clip for you — marking by hand is slower, '
              'but more reliable on busy backgrounds.',
              style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 14),
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onManual,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Mark manually'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: onAuto,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Auto-detect'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
