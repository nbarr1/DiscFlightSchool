import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';

class ManualTrackingPage extends StatefulWidget {
  final String videoPath;

  const ManualTrackingPage({super.key, required this.videoPath});

  @override
  State<ManualTrackingPage> createState() => _ManualTrackingPageState();
}

class _ManualTrackingPageState extends State<ManualTrackingPage> {
  VideoPlayerController? _controller;
  List<TrackPoint> trackedPoints = [];
  int currentFrame = 0;
  bool isPlaying = false;

  /// Estimated FPS of the loaded video (defaults to 30 until known).
  double _videoFps = 30.0;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath));
    await _controller!.initialize();
    // Estimate FPS from video duration and use it everywhere instead of
    // assuming 30 FPS.  VideoPlayerController doesn't expose FPS directly,
    // so we fall back to 30 when duration is unavailable.
    final durationMs = _controller!.value.duration.inMilliseconds;
    if (durationMs > 0) {
      // Most phone cameras shoot at 30 or 60 fps; default to 30.
      _videoFps = 30.0;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  int _currentFrameIndex() {
    if (_controller == null) return 0;
    return (_controller!.value.position.inMilliseconds * _videoFps / 1000).round();
  }

  void _addTrackPoint(Offset position) {
    if (_controller == null) return;
    final frame = _currentFrameIndex();

    setState(() {
      trackedPoints.add(TrackPoint(
        frame: frame,
        position: position,
        timestamp: _controller!.value.position,
      ));
      trackedPoints.sort((a, b) => a.frame.compareTo(b.frame));
    });
  }

  List<TrackPoint> _interpolatePoints() {
    if (trackedPoints.length < 2) return trackedPoints;

    List<TrackPoint> interpolated = [];
    
    for (int i = 0; i < trackedPoints.length - 1; i++) {
      final start = trackedPoints[i];
      final end = trackedPoints[i + 1];
      
      interpolated.add(start);
      
      // Interpolate between frames
      final frameDiff = end.frame - start.frame;
      if (frameDiff > 1) {
        for (int f = 1; f < frameDiff; f++) {
          final t = f / frameDiff;
          final x = start.position.dx + (end.position.dx - start.position.dx) * t;
          final y = start.position.dy + (end.position.dy - start.position.dy) * t;
          
          interpolated.add(TrackPoint(
            frame: start.frame + f,
            position: Offset(x, y),
            timestamp: Duration(milliseconds: ((start.frame + f) * 1000 / _videoFps).round()),
            isInterpolated: true,
          ));
        }
      }
    }
    
    interpolated.add(trackedPoints.last);
    return interpolated;
  }

  void _nextFrame() {
    if (_controller == null) return;
    final frameDuration = Duration(milliseconds: (1000 / _videoFps).round());
    final newPosition = _controller!.value.position + frameDuration;
    _controller!.seekTo(newPosition);
  }

  void _previousFrame() {
    if (_controller == null) return;
    final frameDuration = Duration(milliseconds: (1000 / _videoFps).round());
    final newPosition = _controller!.value.position - frameDuration;
    _controller!.seekTo(newPosition.isNegative ? Duration.zero : newPosition);
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manual Tracking'),
        backgroundColor: const Color(0xFF0f3460),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              setState(() {
                trackedPoints.clear();
              });
            },
            tooltip: 'Clear all points',
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () {
              final interpolated = _interpolatePoints();
              // Save interpolated points
              Navigator.pop(context, interpolated);
            },
            tooltip: 'Save & Interpolate',
          ),
        ],
      ),
      body: Column(
        children: [
          // Video Player with Tap Detection
          Expanded(
            flex: 3,
            child: GestureDetector(
              onTapDown: (details) {
                final renderBox = context.findRenderObject() as RenderBox;
                final localPosition = renderBox.globalToLocal(details.globalPosition);
                _addTrackPoint(localPosition);
              },
              child: Stack(
                children: [
                  Center(
                    child: AspectRatio(
                      aspectRatio: _controller!.value.aspectRatio,
                      child: VideoPlayer(_controller!),
                    ),
                  ),
                  CustomPaint(
                    painter: TrackingOverlayPainter(
                      points: trackedPoints,
                      currentFrame: _currentFrameIndex(),
                    ),
                    size: Size.infinite,
                  ),
                ],
              ),
            ),
          ),

          // Controls
          Container(
            color: const Color(0xFF16213e),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // Progress Bar
                VideoProgressIndicator(
                  _controller!,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Colors.blue,
                    bufferedColor: Colors.grey,
                  ),
                ),
                const SizedBox(height: 16),

                // Frame Controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: _previousFrame,
                      iconSize: 32,
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      icon: Icon(
                        _controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                      onPressed: () {
                        setState(() {
                          _controller!.value.isPlaying
                              ? _controller!.pause()
                              : _controller!.play();
                        });
                      },
                      iconSize: 48,
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: _nextFrame,
                      iconSize: 32,
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Stats
                Text(
                  'Frame: ${_currentFrameIndex()} | '
                  'Points: ${trackedPoints.length}',
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),

          // Point List
          Expanded(
            flex: 1,
            child: Container(
              color: const Color(0xFF0f3460),
              child: ListView.builder(
                itemCount: trackedPoints.length,
                itemBuilder: (context, index) {
                  final point = trackedPoints[index];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.blue,
                      child: Text('${index + 1}'),
                    ),
                    title: Text('Frame ${point.frame}'),
                    subtitle: Text(
                      'Position: (${point.position.dx.toInt()}, ${point.position.dy.toInt()})',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () {
                        setState(() {
                          trackedPoints.removeAt(index);
                        });
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Tracking Overlay Painter
// ============================================================================

class TrackingOverlayPainter extends CustomPainter {
  final List<TrackPoint> points;
  final int currentFrame;

  TrackingOverlayPainter({required this.points, required this.currentFrame});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    // Draw path
    final pathPaint = Paint()
      ..color = Colors.blue.withValues(alpha: 0.5)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    final path = Path();
    bool first = true;

    for (var point in points) {
      if (first) {
        path.moveTo(point.position.dx, point.position.dy);
        first = false;
      } else {
        path.lineTo(point.position.dx, point.position.dy);
      }
    }

    canvas.drawPath(path, pathPaint);

    // Draw points
    for (int i = 0; i < points.length; i++) {
      final point = points[i];
      final paint = Paint()
        ..color = point.isInterpolated ? Colors.green : Colors.red
        ..style = PaintingStyle.fill;

      canvas.drawCircle(point.position, 6, paint);

      // Draw frame number
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(point.position.dx + 10, point.position.dy - 6),
      );
    }

    // Highlight current frame point
    final currentPoint = points.where((p) => p.frame == currentFrame).firstOrNull;
    if (currentPoint != null) {
      final highlightPaint = Paint()
        ..color = Colors.yellow
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke;

      canvas.drawCircle(currentPoint.position, 10, highlightPaint);
    }
  }

  @override
  bool shouldRepaint(TrackingOverlayPainter oldDelegate) => true;
}

// ============================================================================
// Data Model
// ============================================================================

class TrackPoint {
  final int frame;
  final Offset position;
  final Duration timestamp;
  final bool isInterpolated;

  TrackPoint({
    required this.frame,
    required this.position,
    required this.timestamp,
    this.isInterpolated = false,
  });

  Map<String, dynamic> toJson() => {
        'frame': frame,
        'x': position.dx,
        'y': position.dy,
        'timestamp_ms': timestamp.inMilliseconds,
        'interpolated': isInterpolated,
      };
}