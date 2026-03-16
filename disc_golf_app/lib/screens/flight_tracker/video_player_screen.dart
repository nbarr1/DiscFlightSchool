import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import '../../services/tracking_service.dart';
import '../../widgets/flight_path_overlay.dart';
import 'dart:io';

class VideoPlayerScreen extends StatefulWidget {
  final String videoPath;
  final dynamic disc;

  const VideoPlayerScreen({
    Key? key,
    required this.videoPath,
    this.disc,
  }) : super(key: key);

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _showTrackingOverlay = true;
  Offset? _videoOffset;
  Size? _videoSize;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath));
    await _controller.initialize();
    setState(() {
      _isInitialized = true;
    });
    _controller.addListener(() {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _calculateVideoLayout() {
    if (!_isInitialized) return;

    final videoAspectRatio = _controller.value.aspectRatio;
    final screenSize = MediaQuery.of(context).size;
    final screenWidth = screenSize.width;
    final screenHeight = screenSize.height - 200; // Account for controls

    double videoWidth;
    double videoHeight;

    if (screenWidth / screenHeight > videoAspectRatio) {
      videoHeight = screenHeight;
      videoWidth = videoHeight * videoAspectRatio;
    } else {
      videoWidth = screenWidth;
      videoHeight = videoWidth / videoAspectRatio;
    }

    final xOffset = (screenWidth - videoWidth) / 2;
    final yOffset = (screenHeight - videoHeight) / 2;

    _videoOffset = Offset(xOffset, yOffset);
    _videoSize = Size(videoWidth, videoHeight);
  }

  void _stepFrame(bool forward) {
    if (!_isInitialized) return;
    
    final currentPosition = _controller.value.position;
    final frameDuration = const Duration(milliseconds: 33); // ~30fps
    
    final newPosition = forward
        ? currentPosition + frameDuration
        : currentPosition - frameDuration;
    
    if (newPosition >= Duration.zero && newPosition <= _controller.value.duration) {
      _controller.seekTo(newPosition);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trackingService = Provider.of<TrackingService>(context);
    
    if (_isInitialized) {
      _calculateVideoLayout();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Flight Tracker'),
        actions: [
          IconButton(
            icon: Icon(
              trackingService.isManualMode ? Icons.touch_app : Icons.auto_fix_high,
            ),
            onPressed: () {
              trackingService.toggleManualMode();
            },
            tooltip: trackingService.isManualMode ? 'Manual Mode' : 'Auto Mode',
          ),
          IconButton(
            icon: Icon(_showTrackingOverlay ? Icons.visibility : Icons.visibility_off),
            onPressed: () {
              setState(() {
                _showTrackingOverlay = !_showTrackingOverlay;
              });
            },
            tooltip: 'Toggle Overlay',
          ),
        ],
      ),
      body: !_isInitialized
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTapDown: trackingService.isManualMode
                        ? (details) => _handleTap(details, trackingService)
                        : null,
                    child: Stack(
                      children: [
                        Center(
                          child: AspectRatio(
                            aspectRatio: _controller.value.aspectRatio,
                            child: VideoPlayer(_controller),
                          ),
                        ),
                        if (_showTrackingOverlay && trackingService.flightPoints.isNotEmpty && _videoOffset != null && _videoSize != null)
                          Positioned(
                            left: _videoOffset!.dx,
                            top: _videoOffset!.dy,
                            child: CustomPaint(
                              size: _videoSize!,
                              painter: FlightPathPainter(
                                points: trackingService.flightPoints,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                _buildFrameControls(trackingService),
                _buildVideoControls(trackingService),
              ],
            ),
    );
  }

  Widget _buildFrameControls(TrackingService trackingService) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.black87,
      child: Column(
        children: [
          // Frame-by-frame controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white),
                onPressed: () => _stepFrame(false),
                tooltip: 'Previous Frame',
              ),
              const SizedBox(width: 20),
              IconButton(
                icon: Icon(
                  _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  size: 32,
                ),
                onPressed: () {
                  setState(() {
                    _controller.value.isPlaying ? _controller.pause() : _controller.play();
                  });
                },
              ),
              const SizedBox(width: 20),
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white),
                onPressed: () => _stepFrame(true),
                tooltip: 'Next Frame',
              ),
            ],
          ),
          // Video slider
          Row(
            children: [
              Text(
                _formatDuration(_controller.value.position),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: _controller.value.position.inMilliseconds.toDouble(),
                  min: 0,
                  max: _controller.value.duration.inMilliseconds.toDouble(),
                  onChanged: (value) {
                    _controller.seekTo(Duration(milliseconds: value.toInt()));
                  },
                ),
              ),
              Text(
                _formatDuration(_controller.value.duration),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVideoControls(TrackingService trackingService) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton.icon(
                onPressed: trackingService.isTracking
                    ? null
                    : () async {
                        await trackingService.autoTrackVideo(widget.videoPath, widget.disc?.id ?? 'unknown');
                      },
                icon: trackingService.isTracking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(trackingService.isTracking ? 'Tracking...' : 'Auto Track'),
              ),
              ElevatedButton.icon(
                onPressed: trackingService.flightPoints.length < 2
                    ? null
                    : () {
                        final smoothPoints = trackingService.interpolatePoints(trackingService.flightPoints, 50);
                        trackingService.setPoints(smoothPoints);
                      },
                icon: const Icon(Icons.timeline),
                label: const Text('Smooth Path'),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  trackingService.clearPoints();
                },
                icon: const Icon(Icons.clear),
                label: const Text('Clear'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
          if (trackingService.isManualMode)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Tap on the video to mark disc positions',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
        ],
      ),
    );
  }

  void _handleTap(TapDownDetails details, TrackingService trackingService) {
    if (_videoOffset == null || _videoSize == null) return;

    final localPosition = details.localPosition;
    
    // Adjust for video offset and scale
    final adjustedX = localPosition.dx - _videoOffset!.dx;
    final adjustedY = localPosition.dy - _videoOffset!.dy;
    
    // Check if tap is within video bounds
    if (adjustedX >= 0 && adjustedX <= _videoSize!.width &&
        adjustedY >= 0 && adjustedY <= _videoSize!.height) {
      trackingService.addManualPoint(Offset(adjustedX, adjustedY));
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}