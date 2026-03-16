import 'package:flutter/material.dart';

class ManualTrackingScreen extends StatelessWidget {
  const ManualTrackingScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manual Tracking Guide'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            _buildInstructionCard(
              '1. Play the Video',
              'Use the video controls to play or pause the video.',
              Icons.play_circle_outline,
            ),
            _buildInstructionCard(
              '2. Enable Manual Mode',
              'Tap the manual mode icon in the top right.',
              Icons.touch_app,
            ),
            _buildInstructionCard(
              '3. Mark Disc Location',
              'Tap on the disc in each frame to mark its position.',
              Icons.location_on,
            ),
            _buildInstructionCard(
              '4. Interpolate',
              'After marking key frames, use interpolate to fill gaps.',
              Icons.timeline,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInstructionCard(String title, String description, IconData icon) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Icon(icon, size: 40, color: Colors.blue),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(description),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}