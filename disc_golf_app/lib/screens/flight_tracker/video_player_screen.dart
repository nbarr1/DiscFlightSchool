import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:gal/gal.dart';
import '../../services/disc_detection_service.dart';
import '../../widgets/follow_flight_overlay.dart';
import 'dart:io';
import 'dart:ui' as ui;

/// A keyframe marked by the user — disc position at a specific frame.
class _FlightKeyframe {
  final int frameIndex;
  final double x; // Normalized 0-1
  final double y; // Normalized 0-1

  _FlightKeyframe({
    required this.frameIndex,
    required this.x,
    required this.y,
  });
}

class VideoPlayerScreen extends StatefulWidget {
  final String videoPath;
  final dynamic disc;

  const VideoPlayerScreen({
    super.key,
    required this.videoPath,
    this.disc,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _showOverlay = true;
  int _currentFrame = 0;
  FlightTrackingResult? _trackingResult;

  // Manual keyframe data
  final List<_FlightKeyframe> _keyframes = [];
  Size _videoWidgetSize = Size.zero;

  // Zoom/magnifier state
  bool _isZoomMode = false;
  Offset? _zoomPosition; // Touch position in video widget coords
  ui.Image? _capturedFrame;
  final _videoBoundaryKey = GlobalKey();
  bool _wasPlayingBeforeZoom = false;

  // Frame rate used for frame indexing (10fps = 1 frame per 100ms)
  static const double _frameFps = 10.0;

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
    _controller.addListener(_onVideoProgress);
  }

  void _onVideoProgress() {
    if (!mounted) return;
    final posMs = _controller.value.position.inMilliseconds;
    final frame = (posMs * _frameFps / 1000).round();
    if (frame != _currentFrame) {
      setState(() {
        _currentFrame = frame;
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onVideoProgress);
    _controller.dispose();
    _capturedFrame?.dispose();
    super.dispose();
  }

  // --- Zoom / Magnifier ---

  Future<void> _onLongPressStart(LongPressStartDetails details) async {
    // Pause video during zoom
    _wasPlayingBeforeZoom = _controller.value.isPlaying;
    if (_wasPlayingBeforeZoom) {
      _controller.pause();
    }

    // Capture current video frame for the magnifier
    final boundary = _videoBoundaryKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary != null) {
      try {
        final image = await boundary.toImage(pixelRatio: 2.0);
        if (mounted) {
          setState(() {
            _capturedFrame = image;
            _isZoomMode = true;
            _zoomPosition = details.localPosition;
          });
        }
      } catch (_) {
        // Fallback: just show crosshair without magnification
        if (mounted) {
          setState(() {
            _isZoomMode = true;
            _zoomPosition = details.localPosition;
          });
        }
      }
    }
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!_isZoomMode) return;
    setState(() {
      _zoomPosition = details.localPosition;
    });
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (_zoomPosition != null && _videoWidgetSize != Size.zero) {
      _placeKeyframe(_zoomPosition!);
    }

    setState(() {
      _isZoomMode = false;
      _zoomPosition = null;
    });
    _capturedFrame?.dispose();
    _capturedFrame = null;
  }

  // --- Keyframe handling ---

  void _placeKeyframe(Offset localPosition) {
    if (_videoWidgetSize == Size.zero) return;

    final normalizedX =
        (localPosition.dx / _videoWidgetSize.width).clamp(0.0, 1.0);
    final normalizedY =
        (localPosition.dy / _videoWidgetSize.height).clamp(0.0, 1.0);

    setState(() {
      _keyframes.removeWhere((kf) => kf.frameIndex == _currentFrame);
      _keyframes.add(_FlightKeyframe(
        frameIndex: _currentFrame,
        x: normalizedX,
        y: normalizedY,
      ));
      _keyframes.sort((a, b) => a.frameIndex.compareTo(b.frameIndex));
      _trackingResult = null;
    });
  }

  void _addKeyframeFromTap(TapDownDetails details) {
    _placeKeyframe(details.localPosition);
  }

  void _undoLastKeyframe() {
    if (_keyframes.isEmpty) return;
    setState(() {
      _keyframes.removeLast();
      _trackingResult = null;
    });
  }

  void _clearAll() {
    setState(() {
      _keyframes.clear();
      _trackingResult = null;
    });
  }

  /// Generate smooth flight path from keyframes using Catmull-Rom spline.
  void _processKeyframes() {
    if (_keyframes.length < 2) return;

    final detections = <DiscDetection>[];

    for (int i = 0; i < _keyframes.length - 1; i++) {
      final kfStart = _keyframes[i];
      final kfEnd = _keyframes[i + 1];

      final p0 = i > 0 ? _keyframes[i - 1] : kfStart;
      final p3 = i < _keyframes.length - 2 ? _keyframes[i + 2] : kfEnd;

      final frameSpan = kfEnd.frameIndex - kfStart.frameIndex;
      if (frameSpan <= 0) continue;

      final isLastSegment = i == _keyframes.length - 2;
      final endF = isLastSegment ? frameSpan : frameSpan - 1;

      for (int f = 0; f <= endF; f++) {
        final t = f / frameSpan;
        final x = _catmullRom(p0.x, kfStart.x, kfEnd.x, p3.x, t);
        final y = _catmullRom(p0.y, kfStart.y, kfEnd.y, p3.y, t);
        final frameIdx = kfStart.frameIndex + f;

        final isKeyframe =
            _keyframes.any((kf) => kf.frameIndex == frameIdx);

        detections.add(DiscDetection(
          frameIndex: frameIdx,
          x: x.clamp(0.0, 1.0),
          y: y.clamp(0.0, 1.0),
          width: 0.03,
          height: 0.03,
          confidence: isKeyframe ? 1.0 : 0.5,
          timestamp: Duration(
            milliseconds: (frameIdx * 1000 / _frameFps).round(),
          ),
        ));
      }
    }

    setState(() {
      _trackingResult = FlightTrackingResult(
        detections: detections,
        videoWidth: _controller.value.size.width,
        videoHeight: _controller.value.size.height,
        fps: _frameFps,
        totalFrames:
            (_controller.value.duration.inMilliseconds * _frameFps / 1000)
                .round(),
      );
    });
  }

  double _catmullRom(
      double p0, double p1, double p2, double p3, double t) {
    final t2 = t * t;
    final t3 = t2 * t;
    return 0.5 *
        ((2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
  }

  // --- Save video with overlay ---

  Future<void> _saveVideoWithOverlay() async {
    if (_trackingResult == null) return;

    // Show loading dialog
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Saving video...'),
            ],
          ),
        ),
      );
    }

    try {
      // Request gallery access
      await Gal.requestAccess(toAlbum: true);

      // 1. Render full flight path overlay as transparent PNG at video resolution
      final videoWidth = _controller.value.size.width;
      final videoHeight = _controller.value.size.height;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, videoWidth, videoHeight),
      );

      final painter = FollowFlightPainter(
        trackingResult: _trackingResult!,
        currentFrame: _trackingResult!.totalFrames,
        showFullTrail: true,
        showCurrentDisc: false,
      );
      painter.paint(canvas, Size(videoWidth, videoHeight));

      final picture = recorder.endRecording();
      final overlayImage = await picture.toImage(
        videoWidth.toInt(),
        videoHeight.toInt(),
      );
      final byteData = await overlayImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      overlayImage.dispose();

      if (byteData == null) throw Exception('Failed to render overlay');

      // 2. Save overlay PNG to temp file
      final tempDir = await getTemporaryDirectory();
      final overlayPath = '${tempDir.path}/flight_overlay.png';
      await File(overlayPath).writeAsBytes(byteData.buffer.asUint8List());

      // 3. Use ffmpeg to composite overlay onto video
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${tempDir.path}/flight_path_$timestamp.mp4';

      final session = await FFmpegKit.execute(
        '-y -i "${widget.videoPath}" -i "$overlayPath" '
        '-filter_complex "[0:v][1:v]overlay=0:0:format=auto" '
        '-codec:a copy "$outputPath"',
      );

      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getAllLogsAsString();
        throw Exception('FFmpeg failed: $logs');
      }

      // 4. Save to gallery
      await Gal.putVideo(outputPath);

      // 5. Cleanup temp files
      try {
        await File(overlayPath).delete();
        await File(outputPath).delete();
      } catch (_) {}

      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video saved to gallery!')),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }

  // --- Frame stepping ---

  void _stepFrame(bool forward) {
    if (!_isInitialized) return;
    final currentPosition = _controller.value.position;
    final frameDuration =
        Duration(milliseconds: (1000 / _frameFps).round());

    final newPosition = forward
        ? currentPosition + frameDuration
        : currentPosition - frameDuration;

    if (newPosition >= Duration.zero &&
        newPosition <= _controller.value.duration) {
      _controller.seekTo(newPosition);
    }
  }

  // --- Build UI ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flight Tracker'),
        actions: [
          if (_trackingResult != null)
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _saveVideoWithOverlay,
              tooltip: 'Save Video',
            ),
          IconButton(
            icon: Icon(
                _showOverlay ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _showOverlay = !_showOverlay),
            tooltip: 'Toggle Overlay',
          ),
        ],
      ),
      body: !_isInitialized
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Instructions
                if (_keyframes.isEmpty && _trackingResult == null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    color: Colors.blue.withAlpha(40),
                    child: const Text(
                      'Tap to mark disc, or hold to zoom in for precision. '
                      'Mark 2+ keyframes, then tap Process.',
                      style:
                          TextStyle(color: Colors.white70, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),

                // Video with overlays
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          _videoWidgetSize = constraints.biggest;

                          return GestureDetector(
                            onTapDown: _addKeyframeFromTap,
                            onLongPressStart: _onLongPressStart,
                            onLongPressMoveUpdate:
                                _onLongPressMoveUpdate,
                            onLongPressEnd: _onLongPressEnd,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                // Video (wrapped in RepaintBoundary for capture)
                                RepaintBoundary(
                                  key: _videoBoundaryKey,
                                  child: VideoPlayer(_controller),
                                ),

                                // Follow-flight trail overlay
                                if (_showOverlay &&
                                    _trackingResult != null &&
                                    _trackingResult!
                                        .detections.isNotEmpty)
                                  Positioned.fill(
                                    child: CustomPaint(
                                      painter: FollowFlightPainter(
                                        trackingResult:
                                            _trackingResult!,
                                        currentFrame: _currentFrame,
                                      ),
                                    ),
                                  ),

                                // Keyframe markers (before processing)
                                if (_showOverlay &&
                                    _trackingResult == null)
                                  ..._keyframes
                                      .asMap()
                                      .entries
                                      .map((entry) =>
                                          _buildKeyframeMarker(
                                            entry.key,
                                            entry.value,
                                            constraints.biggest,
                                          )),

                                // Zoom magnifier overlay
                                if (_isZoomMode &&
                                    _zoomPosition != null)
                                  _buildMagnifier(constraints.biggest),

                                // Touch point indicator during zoom
                                if (_isZoomMode &&
                                    _zoomPosition != null)
                                  _buildTouchIndicator(),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),

                // Frame controls
                _buildFrameControls(),

                // Action buttons
                _buildActionButtons(),

                // Stats
                _buildStats(),
              ],
            ),
    );
  }

  /// The magnifier bubble — shows a zoomed view of the video area
  /// around the touch point, offset above the finger.
  Widget _buildMagnifier(Size videoSize) {
    const magnifierDiameter = 150.0;
    const magnifierRadius = magnifierDiameter / 2;
    const offsetAbove = 110.0;

    final touchX = _zoomPosition!.dx;
    final touchY = _zoomPosition!.dy;

    // Position magnifier above the finger; flip below if near top
    final magnifierTop = touchY - magnifierDiameter - offsetAbove;
    final flipBelow = magnifierTop < -magnifierRadius;
    final top = flipBelow
        ? touchY + offsetAbove * 0.4
        : touchY - magnifierDiameter - offsetAbove;

    final left =
        (touchX - magnifierRadius).clamp(-magnifierRadius, videoSize.width - magnifierRadius);

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Container(
          width: magnifierDiameter,
          height: magnifierDiameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(150),
                blurRadius: 12,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipOval(
            child: _capturedFrame != null
                ? CustomPaint(
                    size: const Size(magnifierDiameter, magnifierDiameter),
                    painter: _MagnifierPainter(
                      image: _capturedFrame!,
                      focusPoint: _zoomPosition!,
                      sourceSize: videoSize,
                      magnifierRadius: magnifierRadius,
                      zoomFactor: 3.0,
                    ),
                  )
                : Container(
                    color: Colors.black87,
                    child: const Center(
                      child: Icon(Icons.zoom_in,
                          color: Colors.white54, size: 32),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  /// Small crosshair at the actual touch point.
  Widget _buildTouchIndicator() {
    return Positioned(
      left: _zoomPosition!.dx - 16,
      top: _zoomPosition!.dy - 16,
      child: IgnorePointer(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CustomPaint(
            painter: _CrosshairPainter(),
          ),
        ),
      ),
    );
  }

  Widget _buildKeyframeMarker(
      int index, _FlightKeyframe kf, Size videoSize) {
    final x = kf.x * videoSize.width - 12;
    final y = kf.y * videoSize.height - 12;

    final isCurrentFrame = kf.frameIndex == _currentFrame;

    return Positioned(
      left: x,
      top: y,
      child: IgnorePointer(
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: isCurrentFrame
                ? Colors.green
                : Colors.red.withAlpha(200),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(120),
                blurRadius: 4,
              ),
            ],
          ),
          child: Center(
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFrameControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: Colors.black87,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous,
                    color: Colors.white),
                onPressed: () => _stepFrame(false),
                tooltip: 'Previous Frame',
              ),
              const SizedBox(width: 20),
              IconButton(
                icon: Icon(
                  _controller.value.isPlaying
                      ? Icons.pause
                      : Icons.play_arrow,
                  color: Colors.white,
                  size: 32,
                ),
                onPressed: () {
                  setState(() {
                    _controller.value.isPlaying
                        ? _controller.pause()
                        : _controller.play();
                  });
                },
              ),
              const SizedBox(width: 20),
              IconButton(
                icon:
                    const Icon(Icons.skip_next, color: Colors.white),
                onPressed: () => _stepFrame(true),
                tooltip: 'Next Frame',
              ),
            ],
          ),
          Row(
            children: [
              Text(
                _formatDuration(_controller.value.position),
                style: const TextStyle(
                    color: Colors.white, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: _controller.value.position.inMilliseconds
                      .toDouble()
                      .clamp(
                          0,
                          _controller.value.duration.inMilliseconds
                              .toDouble()),
                  min: 0,
                  max: _controller.value.duration.inMilliseconds
                      .toDouble(),
                  onChanged: (value) {
                    _controller.seekTo(
                        Duration(milliseconds: value.toInt()));
                  },
                ),
              ),
              Text(
                _formatDuration(_controller.value.duration),
                style: const TextStyle(
                    color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    final hasEnoughKeyframes = _keyframes.length >= 2;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          ElevatedButton.icon(
            onPressed:
                _keyframes.isEmpty ? null : _undoLastKeyframe,
            icon: const Icon(Icons.undo, size: 18),
            label: const Text('Undo', style: TextStyle(fontSize: 13)),
          ),
          ElevatedButton.icon(
            onPressed: hasEnoughKeyframes ? _processKeyframes : null,
            icon: const Icon(Icons.auto_awesome, size: 18),
            label:
                const Text('Process', style: TextStyle(fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  hasEnoughKeyframes ? Colors.green : null,
              foregroundColor:
                  hasEnoughKeyframes ? Colors.white : null,
            ),
          ),
          ElevatedButton.icon(
            onPressed: (_keyframes.isEmpty && _trackingResult == null)
                ? null
                : _clearAll,
            icon: const Icon(Icons.clear, size: 18),
            label:
                const Text('Clear', style: TextStyle(fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStats() {
    final result = _trackingResult;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: const Color(0xFF16213e),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatChip(
            'Keyframes',
            '${_keyframes.length}',
            Colors.green,
          ),
          if (result != null)
            _buildStatChip(
              'Points',
              '${result.detections.length}',
              Colors.orange,
            ),
          _buildStatChip(
            'Frame',
            '$_currentFrame',
            Colors.blue,
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.grey, fontSize: 10),
        ),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}

/// Paints a zoomed portion of a captured frame inside the magnifier circle.
class _MagnifierPainter extends CustomPainter {
  final ui.Image image;
  final Offset focusPoint;
  final Size sourceSize;
  final double magnifierRadius;
  final double zoomFactor;

  _MagnifierPainter({
    required this.image,
    required this.focusPoint,
    required this.sourceSize,
    required this.magnifierRadius,
    required this.zoomFactor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(magnifierRadius, magnifierRadius);

    // Clip to circle
    canvas.save();
    canvas.clipPath(
        Path()..addOval(Rect.fromCircle(center: center, radius: magnifierRadius)));

    // Map touch point to image pixel coordinates
    // The captured image is at 2x pixel ratio
    const pixelRatio = 2.0;
    final imgX = (focusPoint.dx / sourceSize.width) * image.width;
    final imgY = (focusPoint.dy / sourceSize.height) * image.height;

    // Source rect: the area of the captured image we want to zoom into
    final srcHalfW = (magnifierRadius / zoomFactor) * pixelRatio;
    final srcHalfH = (magnifierRadius / zoomFactor) * pixelRatio;

    final srcRect = Rect.fromCenter(
      center: Offset(imgX, imgY),
      width: srcHalfW * 2,
      height: srcHalfH * 2,
    );

    // Destination: fill the magnifier circle
    final dstRect = Rect.fromCircle(center: center, radius: magnifierRadius);

    canvas.drawImageRect(image, srcRect, dstRect, Paint()..filterQuality = FilterQuality.medium);

    // Draw crosshair
    final crossPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5;

    const crossLen = 12.0;
    // Horizontal
    canvas.drawLine(
      Offset(center.dx - crossLen, center.dy),
      Offset(center.dx + crossLen, center.dy),
      crossPaint,
    );
    // Vertical
    canvas.drawLine(
      Offset(center.dx, center.dy - crossLen),
      Offset(center.dx, center.dy + crossLen),
      crossPaint,
    );

    // Center dot
    canvas.drawCircle(
        center, 2.5, Paint()..color = Colors.red);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_MagnifierPainter oldDelegate) {
    return oldDelegate.focusPoint != focusPoint;
  }
}

/// Paints a crosshair at the touch point during zoom mode.
class _CrosshairPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Outer ring
    final ringPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, 12, ringPaint);

    // Inner dot
    canvas.drawCircle(center, 3, Paint()..color = Colors.red);

    // Cross lines extending past the ring
    final linePaint = Paint()
      ..color = Colors.white.withAlpha(180)
      ..strokeWidth = 1;

    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), linePaint);
    canvas.drawLine(Offset(center.dx, 0), Offset(center.dx, size.height), linePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
