import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import '../../services/posture_analysis_service.dart';
import '../../models/form_analysis.dart';
import 'dart:io';

class PostureAnalysisScreen extends StatefulWidget {
  final String? videoPath;
  final FormAnalysis? analysis;
  final String? proPlayer;

  const PostureAnalysisScreen({
    Key? key,
    this.videoPath,
    this.analysis,
    this.proPlayer,
  }) : super(key: key);

  @override
  State<PostureAnalysisScreen> createState() => _PostureAnalysisScreenState();
}

class _PostureAnalysisScreenState extends State<PostureAnalysisScreen> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isAnalyzing = false;
  FormAnalysis? _analysis;
  int _currentFrame = 0;

  @override
  void initState() {
    super.initState();
    _analysis = widget.analysis;
    if (widget.videoPath != null) {
      _initializeVideo();
      _startAnalysis();
    }
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath!));
    await _controller!.initialize();
    setState(() {
      _isInitialized = true;
    });
    _controller!.addListener(() {
      if (_analysis != null && _controller!.value.isPlaying) {
        final position = _controller!.value.position.inMilliseconds;
        final frameNumber = (position / 33).floor(); // Assuming 30fps
        if (frameNumber < _analysis!.frames.length) {
          setState(() {
            _currentFrame = frameNumber;
          });
        }
      }
    });
  }

  Future<void> _startAnalysis() async {
    setState(() {
      _isAnalyzing = true;
    });

    final postureService = Provider.of<PostureAnalysisService>(context, listen: false);
    final analysis = await postureService.analyzeForm(widget.videoPath!);

    setState(() {
      _analysis = analysis;
      _isAnalyzing = false;
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final postureService = Provider.of<PostureAnalysisService>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Form Analysis'),
      ),
      body: _isAnalyzing
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Analyzing your form...'),
                  SizedBox(height: 8),
                  Text(
                    'This may take a few moments',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            )
          : _analysis == null
              ? const Center(child: Text('No analysis available'))
              : SingleChildScrollView(
                  child: Column(
                    children: [
                      // Video player
                      if (_isInitialized && _controller != null)
                        AspectRatio(
                          aspectRatio: _controller!.value.aspectRatio,
                          child: VideoPlayer(_controller!),
                        ),
                      
                      // Video controls
                      if (_isInitialized && _controller != null)
                        _buildVideoControls(),
                      
                      // Score card
                      _buildScoreCard(),
                      
                      // Angle charts
                      _buildAngleCharts(),
                      
                      // Suggestions
                      _buildSuggestions(postureService),
                    ],
                  ),
                ),
    );
  }

  Widget _buildVideoControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.black87,
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              _controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
            ),
            onPressed: () {
              setState(() {
                _controller!.value.isPlaying ? _controller!.pause() : _controller!.play();
              });
            },
          ),
          Expanded(
            child: Slider(
              value: _controller!.value.position.inMilliseconds.toDouble(),
              min: 0,
              max: _controller!.value.duration.inMilliseconds.toDouble(),
              onChanged: (value) {
                _controller!.seekTo(Duration(milliseconds: value.toInt()));
              },
            ),
          ),
          Text(
            '${_formatDuration(_controller!.value.position)} / ${_formatDuration(_controller!.value.duration)}',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreCard() {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              'Form Score',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '${_analysis!.score.toStringAsFixed(1)}',
              style: Theme.of(context).textTheme.displayMedium?.copyWith(
                    color: _getScoreColor(_analysis!.score),
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              _getScoreLabel(_analysis!.score),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getScoreColor(double score) {
    if (score >= 80) return Colors.green;
    if (score >= 60) return Colors.orange;
    return Colors.red;
  }

  String _getScoreLabel(double score) {
    if (score >= 90) return 'Excellent';
    if (score >= 80) return 'Good';
    if (score >= 70) return 'Fair';
    if (score >= 60) return 'Needs Improvement';
    return 'Poor';
  }

  Widget _buildAngleCharts() {
    if (_analysis == null || _analysis!.frames.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: Text('No frame data available')),
      );
    }

    final angles = _analysis!.frames.first.angles.keys.toList();

    return Column(
      children: angles.map((angleName) => _buildAngleChart(angleName)).toList(),
    );
  }

  Widget _buildAngleChart(String angleName) {
    final angleData = _analysis!.frames.map((frame) {
      return frame.angles[angleName] ?? 0.0;
    }).toList();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _formatAngleName(angleName),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 80,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return CustomPaint(
                    size: Size(constraints.maxWidth, 80),
                    painter: AngleWaveformPainter(
                      angleData: angleData,
                      currentFrame: _currentFrame,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Current: ${angleData[_currentFrame.clamp(0, angleData.length - 1)].toStringAsFixed(1)}°',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _formatAngleName(String name) {
    // Convert camelCase to Title Case
    final result = name.replaceAllMapped(
      RegExp(r'([A-Z])'),
      (match) => ' ${match.group(0)}',
    );
    return result[0].toUpperCase() + result.substring(1);
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  Widget _buildSuggestions(PostureAnalysisService postureService) {
    final suggestions = postureService.generateSuggestions();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Suggestions',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          ...suggestions.map((suggestion) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle, size: 16, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        suggestion,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

// Custom painter for angle waveform
class AngleWaveformPainter extends CustomPainter {
  final List<double> angleData;
  final int currentFrame;

  AngleWaveformPainter({
    required this.angleData,
    required this.currentFrame,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (angleData.isEmpty) return;

    final paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..color = Colors.blue.withOpacity(0.2)
      ..style = PaintingStyle.fill;

    final currentFramePaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 2;

    // Find min and max for scaling
    final minAngle = angleData.reduce((a, b) => a < b ? a : b);
    final maxAngle = angleData.reduce((a, b) => a > b ? a : b);
    final range = maxAngle - minAngle;

    if (range == 0) return;

    // Draw waveform
    final path = Path();
    final fillPath = Path();
    
    for (int i = 0; i < angleData.length; i++) {
      final x = (i / (angleData.length - 1)) * size.width;
      final normalizedValue = (angleData[i] - minAngle) / range;
      final y = size.height - (normalizedValue * size.height);

      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    // Complete fill path
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    // Draw fill and stroke
    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);

    // Draw current frame indicator
    final clampedFrame = currentFrame.clamp(0, angleData.length - 1);
    final x = (clampedFrame / (angleData.length - 1)) * size.width;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      currentFramePaint,
    );

    // Draw grid lines
    final gridPaint = Paint()
      ..color = Colors.grey.withOpacity(0.3)
      ..strokeWidth = 1;

    for (int i = 0; i <= 4; i++) {
      final y = (i / 4) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant AngleWaveformPainter oldDelegate) {
    return oldDelegate.currentFrame != currentFrame ||
        oldDelegate.angleData != angleData;
  }
}