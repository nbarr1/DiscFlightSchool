import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import '../../services/feedback_service.dart';
import '../../services/posture_analysis_service.dart';
import '../../services/video_frame_extractor.dart';
import '../../models/form_analysis.dart';
import '../../utils/pro_data_parser.dart';
import '../../widgets/skeleton_overlay.dart';
import 'phase_comparison_screen.dart';
import 'dart:io';

class PostureAnalysisScreen extends StatefulWidget {
  final String? videoPath;
  final FormAnalysis? analysis;
  final String? proPlayer;
  final int? analysisStartMs;
  final int? analysisEndMs;
  final int? analysisFrameCount;

  const PostureAnalysisScreen({
    Key? key,
    this.videoPath,
    this.analysis,
    this.proPlayer,
    this.analysisStartMs,
    this.analysisEndMs,
    this.analysisFrameCount,
  }) : super(key: key);

  @override
  State<PostureAnalysisScreen> createState() => _PostureAnalysisScreenState();
}

class _PostureAnalysisScreenState extends State<PostureAnalysisScreen> {
  static const _frameIntervalMs = VideoFrameExtractor.defaultIntervalMs;

  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isAnalyzing = false;
  FormAnalysis? _analysis;
  int _currentFrame = 0;
  bool _inAnalysisRange = false;
  bool _showSkeleton = true;
  bool _showThresholds = true;
  bool _phaseSelectionMode = false;
  final Map<String, int> _phaseFrames = {};

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
      if (_analysis != null) {
        final position = _controller!.value.position.inMilliseconds;
        final startMs = widget.analysisStartMs ?? 0;
        final endMs = widget.analysisEndMs ?? (startMs + _analysis!.frames.length * _frameIntervalMs);
        final inRange = position >= startMs && position <= endMs;
        // Frames extracted at _frameIntervalMs intervals from the trim start
        final frameNumber = ((position - startMs) / _frameIntervalMs).floor().clamp(0, _analysis!.frames.length - 1);
        if (frameNumber != _currentFrame || inRange != _inAnalysisRange) {
          setState(() {
            _currentFrame = frameNumber;
            _inAnalysisRange = inRange;
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
    final analysis = await postureService.analyzeForm(
      widget.videoPath!,
      startMs: widget.analysisStartMs ?? 0,
      frameCount: widget.analysisFrameCount ?? 30,
    );

    setState(() {
      _analysis = analysis;
      _isAnalyzing = false;
    });

    // Show verification banner after delay so user can inspect the overlay
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted || _analysis == null) return;
      _showFormVerificationBanner();
    });
  }

  void _showFormVerificationBanner() {
    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        content: const Text('Does the pose overlay match your body?'),
        leading: const Icon(Icons.help_outline),
        actions: [
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              FeedbackService.log({
                'verified': false,
                'type': 'form_analysis',
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      'Tip: Use a side-view camera angle with good lighting for best results.'),
                  duration: Duration(seconds: 5),
                ),
              );
            },
            child: const Text("It's Off"),
          ),
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              FeedbackService.log({
                'verified': true,
                'type': 'form_analysis',
              });
            },
            child: const Text('Looks Good'),
          ),
        ],
      ),
    );
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
        actions: [
          if (_analysis != null)
            IconButton(
              icon: Icon(
                _showSkeleton ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () {
                setState(() {
                  _showSkeleton = !_showSkeleton;
                });
              },
              tooltip: _showSkeleton ? 'Hide Skeleton' : 'Show Skeleton',
            ),
          if (_analysis != null)
            IconButton(
              icon: Icon(
                _showThresholds ? Icons.straighten : Icons.straighten_outlined,
              ),
              onPressed: () {
                setState(() {
                  _showThresholds = !_showThresholds;
                });
              },
              tooltip: _showThresholds ? 'Hide Ideal Angles' : 'Show Ideal Angles',
            ),
        ],
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
                    'Detecting pose and calculating joint angles',
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
                      // Video player with skeleton overlay
                      if (_isInitialized && _controller != null)
                        _buildVideoWithOverlay(),

                      // Video controls
                      if (_isInitialized && _controller != null)
                        _buildVideoControls(),

                      // Score card
                      _buildScoreCard(),

                      // Phase selection / comparison
                      if (widget.proPlayer != null && _analysis != null)
                        _buildPhaseComparisonSection(),

                      // Angle charts
                      _buildAngleCharts(),

                      // Suggestions
                      _buildSuggestions(postureService),
                    ],
                  ),
                ),
    );
  }

  Widget _buildVideoWithOverlay() {
    return Stack(
      children: [
        AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: VideoPlayer(_controller!),
        ),
        if (_showSkeleton && _inAnalysisRange && _analysis != null && _analysis!.frames.isNotEmpty)
          Positioned.fill(
            child: AspectRatio(
              aspectRatio: _controller!.value.aspectRatio,
              child: CustomPaint(
                painter: SkeletonOverlay(
                  analysis: _analysis!,
                  currentFrame: _currentFrame,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildVideoControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.black87,
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white),
                onPressed: () {
                  final pos = _controller!.value.position -
                      Duration(milliseconds: _frameIntervalMs);
                  _controller!.seekTo(pos.isNegative ? Duration.zero : pos);
                  setState(() {
                    _currentFrame = (_currentFrame - 1).clamp(0, (_analysis?.frames.length ?? 1) - 1);
                  });
                },
                tooltip: 'Previous Frame',
              ),
              IconButton(
                icon: Icon(
                  _controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: () {
                  setState(() {
                    _controller!.value.isPlaying
                        ? _controller!.pause()
                        : _controller!.play();
                  });
                },
              ),
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white),
                onPressed: () {
                  final pos = _controller!.value.position +
                      Duration(milliseconds: _frameIntervalMs);
                  _controller!.seekTo(pos);
                  setState(() {
                    _currentFrame = (_currentFrame + 1).clamp(0, (_analysis?.frames.length ?? 1) - 1);
                  });
                },
                tooltip: 'Next Frame',
              ),
              Expanded(
                child: Slider(
                  value: _controller!.value.position.inMilliseconds
                      .toDouble()
                      .clamp(0, _controller!.value.duration.inMilliseconds.toDouble()),
                  min: 0,
                  max: _controller!.value.duration.inMilliseconds.toDouble(),
                  onChanged: (value) {
                    _controller!.seekTo(Duration(milliseconds: value.toInt()));
                    if (_analysis != null) {
                      final frame = (value / _frameIntervalMs).floor().clamp(0, _analysis!.frames.length - 1);
                      setState(() {
                        _currentFrame = frame;
                      });
                    }
                  },
                ),
              ),
              Text(
                '${_formatDuration(_controller!.value.position)} / ${_formatDuration(_controller!.value.duration)}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
          if (_analysis != null)
            Text(
              'Frame ${_currentFrame + 1} / ${_analysis!.frames.length}',
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
        ],
      ),
    );
  }

  Widget _buildScoreCard() {
    final score = _analysis!.score;
    final color = _getScoreColor(score);

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
            const SizedBox(height: 12),
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 120,
                  height: 120,
                  child: CircularProgressIndicator(
                    value: score / 100,
                    strokeWidth: 10,
                    backgroundColor: Colors.grey[800],
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
                Column(
                  children: [
                    Text(
                      score.toStringAsFixed(1),
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                            color: color,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    Text(
                      _getScoreLabel(score),
                      style: TextStyle(color: color, fontSize: 12),
                    ),
                  ],
                ),
              ],
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
    if (score >= 60) return 'Needs Work';
    return 'Poor';
  }

  Widget _buildPhaseComparisonSection() {
    // Determine throw type — default to BH
    final throwType = 'BH';
    final phases = ProBaselineParser.getPhaseNames(throwType);

    if (!_phaseSelectionMode) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: ElevatedButton.icon(
          onPressed: () {
            setState(() {
              _phaseSelectionMode = true;
              _phaseFrames.clear();
            });
          },
          icon: const Icon(Icons.compare_arrows),
          label: const Text('Compare Phases vs Pro'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.all(14),
          ),
        ),
      );
    }

    final allPhasesSet = phases.every((p) => _phaseFrames.containsKey(p));

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.compare_arrows, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Select Phase Frames',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    setState(() {
                      _phaseSelectionMode = false;
                      _phaseFrames.clear();
                    });
                  },
                ),
              ],
            ),
            const Text(
              'Navigate to the correct frame, then tap the phase button to assign it.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: phases.map((phase) {
                final isSet = _phaseFrames.containsKey(phase);
                final label = _formatPhaseName(phase);
                return ChoiceChip(
                  label: Text(
                    isSet
                        ? '$label (F${_phaseFrames[phase]! + 1})'
                        : label,
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: isSet,
                  selectedColor: Colors.green.withAlpha(60),
                  onSelected: (_) {
                    setState(() {
                      _phaseFrames[phase] = _currentFrame;
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: allPhasesSet
                  ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => PhaseComparisonScreen(
                            userAnalysis: _analysis!,
                            phaseFrames: Map.from(_phaseFrames),
                            proName: widget.proPlayer!,
                            throwType: throwType,
                          ),
                        ),
                      );
                    }
                  : null,
              icon: const Icon(Icons.analytics),
              label: Text(allPhasesSet
                  ? 'Compare'
                  : '${_phaseFrames.length}/${phases.length} phases set'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatPhaseName(String name) {
    return name
        .split('_')
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  Widget _buildAngleCharts() {
    if (_analysis == null || _analysis!.frames.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: Text('No frame data available')),
      );
    }

    final postureService = Provider.of<PostureAnalysisService>(context, listen: false);
    final proFrames = postureService.proAnalysis?.frames;

    final angles = _analysis!.frames.first.angles.keys.toList();

    return Column(
      children: angles.map((angleName) {
        final referenceData = proFrames
            ?.map((f) => f.angles[angleName] ?? 0.0)
            .toList();
        return _buildAngleChart(
          angleName,
          referenceData: referenceData,
        );
      }).toList(),
    );
  }

  Widget _buildAngleChart(String angleName, {List<double>? referenceData}) {
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
                  return GestureDetector(
                    onTapDown: (details) {
                      final fraction = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                      final frame = (fraction * (_analysis!.frames.length - 1)).round();
                      _seekToFrame(frame);
                    },
                    onHorizontalDragUpdate: (details) {
                      final fraction = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                      final frame = (fraction * (_analysis!.frames.length - 1)).round();
                      _seekToFrame(frame);
                    },
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, 80),
                      painter: AngleWaveformPainter(
                        angleData: angleData,
                        currentFrame: _currentFrame,
                        referenceData: referenceData,
                        showThreshold: _showThresholds,
                      ),
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

  void _seekToFrame(int frame) {
    if (_controller == null || _analysis == null) return;
    final clampedFrame = frame.clamp(0, _analysis!.frames.length - 1);
    final startMs = widget.analysisStartMs ?? 0;
    _controller!.seekTo(Duration(milliseconds: startMs + clampedFrame * _frameIntervalMs));
    setState(() {
      _currentFrame = clampedFrame;
    });
  }

  String _formatAngleName(String name) {
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
        color: Colors.blue.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.withAlpha(80)),
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
                    const Icon(Icons.lightbulb_outline, size: 16, color: Colors.amber),
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
  final List<double>? referenceData;
  final bool showThreshold;

  AngleWaveformPainter({
    required this.angleData,
    required this.currentFrame,
    this.referenceData,
    this.showThreshold = true,
  });

  /// Resample reference data to match target length via linear interpolation.
  List<double> _resampleReference(List<double> ref, int targetLength) {
    if (ref.length == targetLength) return ref;
    if (targetLength <= 1) return [ref.first];
    return List.generate(targetLength, (i) {
      final t = i / (targetLength - 1) * (ref.length - 1);
      final lo = t.floor().clamp(0, ref.length - 2);
      final frac = t - lo;
      return ref[lo] * (1 - frac) + ref[lo + 1] * frac;
    });
  }

  /// Multi-pass smoothing: median filter to remove spikes, then moving average.
  List<double> _smooth(List<double> data) {
    if (data.length < 3) return data;
    // Pass 1: 3-point median filter to kill outlier spikes
    var result = _medianFilter(data, 3);
    // Pass 2-3: 9-point then 7-point moving average
    result = _movingAvg(result, 9);
    result = _movingAvg(result, 7);
    return result;
  }

  List<double> _medianFilter(List<double> data, int window) {
    final half = window ~/ 2;
    return List.generate(data.length, (i) {
      final start = (i - half).clamp(0, data.length - 1);
      final end = (i + half).clamp(0, data.length - 1);
      final seg = data.sublist(start, end + 1)..sort();
      return seg[seg.length ~/ 2];
    });
  }

  List<double> _movingAvg(List<double> data, int window) {
    if (data.length < window) return data;
    final half = window ~/ 2;
    return List.generate(data.length, (i) {
      final start = (i - half).clamp(0, data.length - 1);
      final end = (i + half).clamp(0, data.length - 1);
      double sum = 0;
      int count = 0;
      for (int j = start; j <= end; j++) {
        sum += data[j];
        count++;
      }
      return sum / count;
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (angleData.isEmpty) return;

    // Apply smoothing to reduce pose estimation noise
    final smoothed = _smooth(angleData);

    final paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..color = Colors.blue.withAlpha(50)
      ..style = PaintingStyle.fill;

    final currentFramePaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 2;

    // Resample reference to match user frame count
    final resampled = (showThreshold && referenceData != null && referenceData!.isNotEmpty)
        ? _resampleReference(referenceData!, smoothed.length)
        : null;

    // Find min and max for scaling (expand to include reference if shown)
    var minAngle = smoothed.reduce((a, b) => a < b ? a : b);
    var maxAngle = smoothed.reduce((a, b) => a > b ? a : b);
    if (resampled != null) {
      final refMin = resampled.reduce((a, b) => a < b ? a : b);
      final refMax = resampled.reduce((a, b) => a > b ? a : b);
      if (refMin < minAngle) minAngle = refMin - 5;
      if (refMax > maxAngle) maxAngle = refMax + 5;
    }
    final range = maxAngle - minAngle;

    if (range == 0) return;

    // Draw waveform
    final path = Path();
    final fillPath = Path();

    for (int i = 0; i < smoothed.length; i++) {
      final x = (i / (smoothed.length - 1)) * size.width;
      final normalizedValue = (smoothed[i] - minAngle) / range;
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

    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);

    // Draw current frame indicator
    final clampedFrame = currentFrame.clamp(0, smoothed.length - 1);
    final x = (clampedFrame / (smoothed.length - 1)) * size.width;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      currentFramePaint,
    );

    // Draw grid lines
    final gridPaint = Paint()
      ..color = Colors.grey.withAlpha(76)
      ..strokeWidth = 1;

    for (int i = 0; i <= 4; i++) {
      final y = (i / 4) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Draw pro reference curve
    if (resampled != null) {
      final refPaint = Paint()
        ..color = Colors.green.withAlpha(150)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      // Draw dashed curve
      const dashLen = 6.0;
      const gapLen = 4.0;
      double accumulated = 0;
      bool drawing = true;

      for (int i = 0; i < resampled.length - 1; i++) {
        final x1 = (i / (resampled.length - 1)) * size.width;
        final y1 = size.height - ((resampled[i] - minAngle) / range) * size.height;
        final x2 = ((i + 1) / (resampled.length - 1)) * size.width;
        final y2 = size.height - ((resampled[i + 1] - minAngle) / range) * size.height;

        final dx = x2 - x1;
        final dy = y2 - y1;
        final segLen = (dx * dx + dy * dy).abs();
        final segDist = segLen > 0 ? segLen * 0.5 + (x2 - x1).abs() : 0.0; // approximate

        if (drawing) {
          canvas.drawLine(Offset(x1, y1), Offset(x2, y2), refPaint);
        }

        accumulated += segDist > 0 ? segDist : (x2 - x1).abs();
        final threshold = drawing ? dashLen : gapLen;
        if (accumulated >= threshold) {
          accumulated = 0;
          drawing = !drawing;
        }
      }

      // "Pro" label at right end of curve
      final lastY = size.height - ((resampled.last - minAngle) / range) * size.height;
      final labelPainter = TextPainter(
        text: TextSpan(
          text: 'Pro',
          style: TextStyle(
            color: Colors.green.withAlpha(200),
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      labelPainter.layout();
      final labelX = size.width - labelPainter.width - 2;
      final labelY = (lastY - labelPainter.height - 4).clamp(0.0, size.height - labelPainter.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(labelX - 2, labelY - 1, labelPainter.width + 4, labelPainter.height + 2),
          const Radius.circular(3),
        ),
        Paint()..color = Colors.black.withAlpha(160),
      );
      labelPainter.paint(canvas, Offset(labelX, labelY));
    }
  }

  @override
  bool shouldRepaint(covariant AngleWaveformPainter oldDelegate) {
    return oldDelegate.currentFrame != currentFrame ||
        oldDelegate.angleData != angleData ||
        oldDelegate.referenceData != referenceData ||
        oldDelegate.showThreshold != showThreshold;
  }
}
