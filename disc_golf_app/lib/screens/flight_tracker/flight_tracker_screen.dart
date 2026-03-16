import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/tracking_service.dart';
import '../../services/video_service.dart';
import 'manual_tracking_screen.dart';
import 'video_player_screen.dart';

class FlightTrackerScreen extends StatefulWidget {
  const FlightTrackerScreen({super.key});

  @override
  State<FlightTrackerScreen> createState() => _FlightTrackerScreenState();
}

class _FlightTrackerScreenState extends State<FlightTrackerScreen> {
  @override
  Widget build(BuildContext context) {
    final trackingService = Provider.of<TrackingService>(context);
    final videoService = Provider.of<VideoService>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Flight Tracker'),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Track Disc Flight',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Record or upload a video to track disc flight path',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 24),
              
              _buildActionCard(
                context,
                title: 'Record Video',
                description: 'Use camera to record a throw',
                icon: Icons.videocam,
                color: Colors.red,
                onTap: () async {
                  final videoPath = await videoService.captureVideo();
                  if (videoPath != null && mounted) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => VideoPlayerScreen(
                          videoPath: videoPath,
                          disc: null,
                        ),
                      ),
                    );
                  }
                },
              ),
              const SizedBox(height: 16),
              
              _buildActionCard(
                context,
                title: 'Upload Video',
                description: 'Select a video from gallery',
                icon: Icons.upload_file,
                color: Colors.blue,
                onTap: () async {
                  final videoPath = await videoService.selectVideo();
                  if (videoPath != null && mounted) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => VideoPlayerScreen(
                          videoPath: videoPath,
                          disc: null,
                        ),
                      ),
                    );
                  }
                },
              ),
              const SizedBox(height: 16),
              
              _buildActionCard(
                context,
                title: 'Manual Tracking',
                description: 'Track disc path by tapping points',
                icon: Icons.touch_app,
                color: Colors.green,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ManualTrackingScreen(),
                    ),
                  );
                },
              ),
              
              const SizedBox(height: 32),
              
              if (trackingService.trackingPoints.isNotEmpty) ...[
                const Divider(),
                const SizedBox(height: 16),
                const Text(
                  'Recent Results',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                _buildRecentResults(trackingService),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: () {
                    trackingService.clearPoints();
                  },
                  child: const Text('Clear Points'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionCard(
    BuildContext context, {
    required String title,
    required String description,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 4,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: 32,
                  color: color,
                ),
              ),
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
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                color: Colors.grey[400],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentResults(TrackingService trackingService) {
    final points = trackingService.trackingPoints;
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildResultRow('Points Tracked', '${points.length}'),
            if (points.length >= 2) ...[
              _buildResultRow('Start Point', '(${points.first.dx.toStringAsFixed(0)}, ${points.first.dy.toStringAsFixed(0)})'),
              _buildResultRow('End Point', '(${points.last.dx.toStringAsFixed(0)}, ${points.last.dy.toStringAsFixed(0)})'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              color: Colors.blue,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}