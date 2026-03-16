import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/video_service.dart';
import '../../services/posture_analysis_service.dart';
import 'posture_analysis_screen.dart';

class FormCoachScreen extends StatefulWidget {
  const FormCoachScreen({Key? key}) : super(key: key);

  @override
  State<FormCoachScreen> createState() => _FormCoachScreenState();
}

class _FormCoachScreenState extends State<FormCoachScreen> {
  String? _selectedPro;
  
  final List<String> _proDgPlayers = [
    'Paul McBeth',
    'Ricky Wysocki',
    'Eagle McMahon',
    'Simon Lizotte',
    'Calvin Heimburg',
  ];

  @override
  Widget build(BuildContext context) {
    final videoService = Provider.of<VideoService>(context);
    final postureService = Provider.of<PostureAnalysisService>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Form Coach'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Compare With Pro',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _selectedPro,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Select a pro player (optional)',
                      ),
                      items: _proDgPlayers.map((pro) {
                        return DropdownMenuItem(
                          value: pro,
                          child: Text(pro),
                        );
                      }).toList(),
                      onChanged: (pro) {
                        setState(() {
                          _selectedPro = pro;
                        });
                        if (pro != null) {
                          postureService.loadProFormData(pro);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () async {
                final videoPath = await videoService.selectVideo();
                if (videoPath != null && mounted) {
                  Navigator.push(context, MaterialPageRoute(builder: (context) => PostureAnalysisScreen(videoPath: videoPath)));
                }
              },
              icon: const Icon(Icons.video_library),
              label: const Text('Upload Form Video'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () async {
                final videoPath = await videoService.captureVideo();
                if (videoPath != null && mounted) {
                  Navigator.push(context, MaterialPageRoute(builder: (context) => PostureAnalysisScreen(videoPath: videoPath)));    
                }
              },
              icon: const Icon(Icons.videocam),
              label: const Text('Record Form Video'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
            ),
            const SizedBox(height: 20),
            if (postureService.currentAnalysis != null) ...[
              Card(
                color: Colors.blue.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Last Analysis',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Frames Analyzed: ${postureService.currentAnalysis!.frames.length}',
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => PostureAnalysisScreen(
                                analysis: postureService.currentAnalysis!,
                              ),
                            ),
                          );
                        },
                        child: const Text('View Analysis'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }  void _navigateToAnalysis(String path) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PostureAnalysisScreen(
          videoPath: path,
          proPlayer: _selectedPro,
        ),
      ),
    );
  }
}