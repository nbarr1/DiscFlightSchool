import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import '../../services/video_frame_extractor.dart';
import 'phase_frame_selector_screen.dart';

class VideoTrimScreen extends StatefulWidget {
  final String videoPath;
  final String? proPlayer;
  final String throwType;
  final bool isLeftHanded;
  /// Optional callback for generic trim usage (e.g., flight tracker).
  /// When provided, this is called instead of navigating to PostureAnalysisScreen.
  final void Function(int startMs, int endMs, int frameCount)? onTrimComplete;

  const VideoTrimScreen({
    Key? key,
    required this.videoPath,
    this.proPlayer,
    this.throwType = 'BH',
    this.isLeftHanded = false,
    this.onTrimComplete,
  }) : super(key: key);

  @override
  State<VideoTrimScreen> createState() => _VideoTrimScreenState();
}

class _VideoTrimScreenState extends State<VideoTrimScreen> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  RangeValues _trimRange = const RangeValues(0, 1);
  double _totalDurationMs = 1;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath));
    await _controller!.initialize();
    final durationMs = _controller!.value.duration.inMilliseconds.toDouble();
    setState(() {
      _isInitialized = true;
      _totalDurationMs = durationMs;
      // Default: first 6 seconds or full video, whichever is shorter
      final defaultEnd = durationMs.clamp(0.0, 6000.0);
      _trimRange = RangeValues(0, defaultEnd);
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  String _formatSeconds(double ms) {
    final totalSeconds = ms / 1000;
    return '${totalSeconds.toStringAsFixed(1)}s';
  }

  void _seekToStart() {
    _controller?.seekTo(Duration(milliseconds: _trimRange.start.round()));
  }

  void _seekToEnd() {
    _controller?.seekTo(Duration(milliseconds: _trimRange.end.round()));
  }

  void _playSelection() async {
    if (_controller == null) return;
    await _controller!.seekTo(Duration(milliseconds: _trimRange.start.round()));
    await _controller!.play();

    // Stop at end of selection
    _controller!.addListener(_playbackListener);
  }

  void _playbackListener() {
    if (_controller == null) return;
    final pos = _controller!.value.position.inMilliseconds;
    if (pos >= _trimRange.end.round()) {
      _controller!.pause();
      _controller!.removeListener(_playbackListener);
    }
  }

  void _analyzeSelection() {
    final startMs = _trimRange.start.round();
    final endMs = _trimRange.end.round();
    final durationMs = endMs - startMs;
    // Calculate frame count: one frame every 200ms
    final frameCount = (durationMs / VideoFrameExtractor.defaultIntervalMs).ceil().clamp(1, 300);

    if (widget.onTrimComplete != null) {
      widget.onTrimComplete!(startMs, endMs, frameCount);
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => PhaseFrameSelectorScreen(
            videoPath: widget.videoPath,
            proPlayer: widget.proPlayer,
            analysisStartMs: startMs,
            analysisEndMs: endMs,
            analysisFrameCount: frameCount,
            throwType: widget.throwType,
            isLeftHanded: widget.isLeftHanded,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trim Video'),
      ),
      body: !_isInitialized
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Video preview
                Expanded(
                  flex: 3,
                  child: Container(
                    color: Colors.black,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: _controller!.value.aspectRatio,
                        child: VideoPlayer(_controller!),
                      ),
                    ),
                  ),
                ),

                // Trim controls
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Select analysis range',
                          style: Theme.of(context).textTheme.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),

                        // Range labels
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            GestureDetector(
                              onTap: _seekToStart,
                              child: Text(
                                'Start: ${_formatSeconds(_trimRange.start)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green,
                                ),
                              ),
                            ),
                            Text(
                              'Duration: ${_formatSeconds(_trimRange.end - _trimRange.start)}',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                            GestureDetector(
                              onTap: _seekToEnd,
                              child: Text(
                                'End: ${_formatSeconds(_trimRange.end)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.red,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),

                        // Range slider
                        RangeSlider(
                          values: _trimRange,
                          min: 0,
                          max: _totalDurationMs,
                          divisions: (_totalDurationMs / 100).round().clamp(1, 1000),
                          labels: RangeLabels(
                            _formatSeconds(_trimRange.start),
                            _formatSeconds(_trimRange.end),
                          ),
                          onChanged: (values) {
                            setState(() {
                              _trimRange = values;
                            });
                          },
                          onChangeEnd: (values) {
                            // Seek to the most recently changed handle
                            _controller?.seekTo(
                              Duration(milliseconds: values.start.round()),
                            );
                          },
                        ),

                        // Frame count info
                        Text(
                          '${((_trimRange.end - _trimRange.start) / VideoFrameExtractor.defaultIntervalMs).ceil()} frames · Next: mark the 4 key throw phases',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.center,
                        ),

                        const Spacer(),

                        // Action buttons
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _playSelection,
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Preview'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: ElevatedButton.icon(
                                onPressed: _analyzeSelection,
                                icon: Icon(widget.onTrimComplete != null
                                    ? Icons.check
                                    : Icons.flag),
                                label: Text(widget.onTrimComplete != null
                                    ? 'Use Selection'
                                    : 'Select Phases'),
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.all(14),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
