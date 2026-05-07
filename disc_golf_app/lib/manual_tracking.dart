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
  final GlobalKey _videoStackKey = GlobalKey();

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

  void _addTrackPoint(Offset normalizedPosition) {
    if (_controller == null) return;
    final frame = _currentFrameIndex();

    setState(() {
      trackedPoints.add(TrackPoint(
        frame: frame,
        position: Offset(
          normalizedPosition.dx.clamp(0.0, 1.0),
          normalizedPosition.dy.clamp(0.0, 1.0),
        ),
        timestamp: _controller!.value.position,
      ));
      trackedPoints.sort((a, b) => a.frame.compareTo(b.frame));
    });
  }

  Rect _actualVideoRect(Size containerSize) {
    final aspectRatio = _controller?.value.aspectRatio ?? 1.0;
    if (containerSize.width <= 0 ||
        containerSize.height <= 0 ||
        aspectRatio <= 0) {
      return Rect.zero;
    }

    final containerAspect = containerSize.width / containerSize.height;
    if (containerAspect > aspectRatio) {
      final videoHeight = containerSize.height;
      final videoWidth = videoHeight * aspectRatio;
      final left = (containerSize.width - videoWidth) / 2;
      return Rect.fromLTWH(left, 0, videoWidth, videoHeight);
    }

    final videoWidth = containerSize.width;
    final videoHeight = videoWidth / aspectRatio;
    final top = (containerSize.height - videoHeight) / 2;
    return Rect.fromLTWH(0, top, videoWidth, videoHeight);
  }

  Offset? _normalizedVideoPosition(Offset stackPosition, Size stackSize) {
    final videoRect = _actualVideoRect(stackSize);
    if (videoRect.isEmpty || !videoRect.contains(stackPosition)) return null;

    return Offset(
      (stackPosition.dx - videoRect.left) / videoRect.width,
      (stackPosition.dy - videoRect.top) / videoRect.height,
    );
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
                final renderObject =
                    _videoStackKey.currentContext?.findRenderObject();
                if (renderObject is! RenderBox) return;
                final stackPosition =
                    renderObject.globalToLocal(details.globalPosition);
                final normalizedPosition = _normalizedVideoPosition(
                  stackPosition,
                  renderObject.size,
                );
                if (normalizedPosition == null) return;
                _addTrackPoint(normalizedPosition);
              },
              child: Stack(
                key: _videoStackKey,
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
                      videoAspectRatio: _controller!.value.aspectRatio,
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
                      'Normalized: (${point.position.dx.toStringAsFixed(3)}, ${point.position.dy.toStringAsFixed(3)})',
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
  final double videoAspectRatio;

  TrackingOverlayPainter({
    required this.points,
    required this.currentFrame,
    required this.videoAspectRatio,
  });

  Rect _actualVideoRect(Size containerSize) {
    if (containerSize.width <= 0 ||
        containerSize.height <= 0 ||
        videoAspectRatio <= 0) {
      return Rect.zero;
    }

    final containerAspect = containerSize.width / containerSize.height;
    if (containerAspect > videoAspectRatio) {
      final videoHeight = containerSize.height;
      final videoWidth = videoHeight * videoAspectRatio;
      final left = (containerSize.width - videoWidth) / 2;
      return Rect.fromLTWH(left, 0, videoWidth, videoHeight);
    }

    final videoWidth = containerSize.width;
    final videoHeight = videoWidth / videoAspectRatio;
    final top = (containerSize.height - videoHeight) / 2;
    return Rect.fromLTWH(0, top, videoWidth, videoHeight);
  }

  Offset _toCanvasPosition(Offset normalizedPosition, Rect videoRect) {
    return Offset(
      videoRect.left + normalizedPosition.dx * videoRect.width,
      videoRect.top + normalizedPosition.dy * videoRect.height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final videoRect = _actualVideoRect(size);
    if (videoRect.isEmpty) return;

    // Draw path
    final pathPaint = Paint()
      ..color = Colors.blue.withValues(alpha: 0.5)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    final path = Path();
    bool first = true;

    for (var point in points) {
      final canvasPosition = _toCanvasPosition(point.position, videoRect);
      if (first) {
        path.moveTo(canvasPosition.dx, canvasPosition.dy);
        first = false;
      } else {
        path.lineTo(canvasPosition.dx, canvasPosition.dy);
      }
    }

    canvas.drawPath(path, pathPaint);

    // Draw points
    for (int i = 0; i < points.length; i++) {
      final point = points[i];
      final canvasPosition = _toCanvasPosition(point.position, videoRect);
      final paint = Paint()
        ..color = point.isInterpolated ? Colors.green : Colors.red
        ..style = PaintingStyle.fill;

      canvas.drawCircle(canvasPosition, 6, paint);

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
        Offset(canvasPosition.dx + 10, canvasPosition.dy - 6),
      );
    }

    // Highlight current frame point
    final currentPoint = points.where((p) => p.frame == currentFrame).firstOrNull;
    if (currentPoint != null) {
      final canvasPosition = _toCanvasPosition(currentPoint.position, videoRect);
      final highlightPaint = Paint()
        ..color = Colors.yellow
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke;

      canvas.drawCircle(canvasPosition, 10, highlightPaint);
    }
  }

  @override
  bool shouldRepaint(TrackingOverlayPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.currentFrame != currentFrame ||
        oldDelegate.videoAspectRatio != videoAspectRatio;
  }
}

// ============================================================================
// Data Model
// ============================================================================

class TrackPoint {
  final int frame;
  /// Normalized video-space position, where both axes are in the range 0.0-1.0.
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