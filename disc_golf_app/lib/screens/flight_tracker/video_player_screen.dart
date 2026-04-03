import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:gal/gal.dart';
import 'package:provider/provider.dart';
import '../../services/disc_detection_service.dart';
import '../../services/feedback_service.dart';
import '../../services/training_data_service.dart';
import '../../services/video_service.dart';
import '../../widgets/follow_flight_overlay.dart';
import '../gallery/video_gallery_screen.dart';
import 'dart:io';
import 'dart:ui' as ui;

/// A keyframe marked by the user — disc position at a specific frame.
class _FlightKeyframe {
  final int frameIndex;
  final double x; // Normalized 0-1
  final double y; // Normalized 0-1
  final double? boxWidth; // Normalized 0-1 (from two-tap box mode)
  final double? boxHeight; // Normalized 0-1 (from two-tap box mode)

  _FlightKeyframe({
    required this.frameIndex,
    required this.x,
    required this.y,
    this.boxWidth,
    this.boxHeight,
  });
}

class VideoPlayerScreen extends StatefulWidget {
  final String videoPath;
  final dynamic disc;
  final int? trimStartMs;
  final int? trimEndMs;

  const VideoPlayerScreen({
    super.key,
    required this.videoPath,
    this.disc,
    this.trimStartMs,
    this.trimEndMs,
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

  // Box mode state (two-tap bounding box for training)
  bool _boxMode = false;
  Offset? _firstBoxCorner; // Normalized 0-1, first corner of bounding box

  // Stabilization state
  bool _stabilizeEnabled = false;
  String? _stabilizedVideoPath; // Path to FFmpeg-stabilized temp file
  bool _isStabilizing = false;

  // Frame rate used for frame indexing (10fps = 1 frame per 100ms)
  static const double _frameFps = 10.0;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo([String? overridePath]) async {
    final path = overridePath ?? widget.videoPath;
    _controller = VideoPlayerController.file(File(path));
    await _controller.initialize();
    if (widget.trimStartMs != null) {
      await _controller.seekTo(Duration(milliseconds: widget.trimStartMs!));
    }
    setState(() {
      _isInitialized = true;
    });
    _controller.addListener(_onVideoProgress);
  }

  void _onVideoProgress() {
    if (!mounted) return;
    final posMs = _controller.value.position.inMilliseconds;
    // Pause at trim end if playing past it
    if (widget.trimEndMs != null &&
        posMs >= widget.trimEndMs! &&
        _controller.value.isPlaying) {
      _controller.pause();
      _controller.seekTo(Duration(milliseconds: widget.trimEndMs!));
    }
    final effectiveMs = posMs - (widget.trimStartMs ?? 0);
    final frame = (effectiveMs * _frameFps / 1000).round();
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
    // Clean up stabilized temp file when leaving the screen
    if (_stabilizedVideoPath != null) {
      final videoService = Provider.of<VideoService>(context, listen: false);
      videoService.deleteStabilizedVideo(_stabilizedVideoPath!);
    }
    super.dispose();
  }

  // --- Zoom / Magnifier ---

  Future<void> _onLongPressStart(LongPressStartDetails details) async {
    // Pause video during zoom
    _wasPlayingBeforeZoom = _controller.value.isPlaying;
    if (_wasPlayingBeforeZoom) {
      _controller.pause();
    }

    // Set zoom position immediately so it's available even if the user
    // releases before the async frame capture completes.
    setState(() {
      _isZoomMode = true;
      _zoomPosition = details.localPosition;
    });

    // Capture current video frame for the magnifier
    final boundary = _videoBoundaryKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary != null) {
      try {
        final image = await boundary.toImage(pixelRatio: 2.0);
        if (mounted) {
          setState(() {
            _capturedFrame = image;
          });
        }
      } catch (_) {
        // Fallback: crosshair without magnification (already showing)
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
    // Use the tracked zoom position, falling back to the release position
    final position = _zoomPosition ?? details.localPosition;
    if (_videoWidgetSize != Size.zero) {
      _placeKeyframe(position);
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

    if (_boxMode && _firstBoxCorner == null) {
      // First tap in box mode — store corner and wait for second
      setState(() {
        _firstBoxCorner = Offset(normalizedX, normalizedY);
      });
      return;
    }

    double? boxW;
    double? boxH;

    if (_boxMode && _firstBoxCorner != null) {
      // Second tap in box mode — compute bounding box from two corners
      final cx = (_firstBoxCorner!.dx + normalizedX) / 2;
      final cy = (_firstBoxCorner!.dy + normalizedY) / 2;
      boxW = (normalizedX - _firstBoxCorner!.dx).abs();
      boxH = (normalizedY - _firstBoxCorner!.dy).abs();

      setState(() {
        _keyframes.removeWhere((kf) => kf.frameIndex == _currentFrame);
        _keyframes.add(_FlightKeyframe(
          frameIndex: _currentFrame,
          x: cx,
          y: cy,
          boxWidth: boxW,
          boxHeight: boxH,
        ));
        _keyframes.sort((a, b) => a.frameIndex.compareTo(b.frameIndex));
        _trackingResult = null;
        _firstBoxCorner = null;
      });
      return;
    }

    // Normal mode — single point keyframe
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

  void _addKeyframeFromTap(TapUpDetails details) {
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
      _firstBoxCorner = null;
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

    // Collect training data if opted in
    _collectTrainingData();

    // Show verification banner after delay so user can inspect the overlay
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted || _trackingResult == null) return;
      _showFlightVerificationBanner();
    });
  }

  void _showFlightVerificationBanner() {
    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        content: const Text('Does this flight path look correct?'),
        leading: const Icon(Icons.help_outline),
        actions: [
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              FeedbackService.log({
                'verified': false,
                'type': 'flight_path',
                'keyframes': _keyframes.length,
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      'Adjust keyframes and tap Process again to refine.'),
                ),
              );
            },
            child: const Text('Needs Adjustment'),
          ),
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              FeedbackService.log({
                'verified': true,
                'type': 'flight_path',
                'keyframes': _keyframes.length,
              });
            },
            child: const Text('Looks Good'),
          ),
        ],
      ),
    );
  }

  Future<void> _collectTrainingData() async {
    final trainingService =
        Provider.of<TrainingDataService>(context, listen: false);
    if (!trainingService.isOptedIn) return;

    final keyframeData = _keyframes
        .map((kf) => KeyframeData(
              frameIndex: kf.frameIndex,
              x: kf.x,
              y: kf.y,
              boxWidth: kf.boxWidth,
              boxHeight: kf.boxHeight,
            ))
        .toList();

    final saved = await trainingService.collectFromKeyframes(
      keyframeData,
      widget.videoPath,
      _frameFps,
    );

    if (saved > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved $saved training samples')),
      );

      // Auto-upload if server is configured
      if (trainingService.serverUrl.isNotEmpty) {
        trainingService.uploadPending();
      }
    }
  }

  // --- Stabilization ---

  /// Toggle video stabilization on or off.
  ///
  /// When enabling: runs the two-pass FFmpeg vidstab pipeline via [VideoService],
  /// then re-initializes the video player with the stabilized output.  Keyframes
  /// placed after stabilization are frame-relative to the locked background, so
  /// the rendered trail stays anchored to the environment even when the camera
  /// panned during filming.
  ///
  /// When disabling: reverts to the original video and cleans up the temp file.
  Future<void> _toggleStabilization() async {
    if (_isStabilizing) return;

    if (_stabilizeEnabled) {
      // Turn off — revert to original
      setState(() {
        _stabilizeEnabled = false;
        _isInitialized = false;
        _keyframes.clear();
        _trackingResult = null;
      });
      _controller.removeListener(_onVideoProgress);
      await _controller.dispose();

      final videoService = Provider.of<VideoService>(context, listen: false);
      if (_stabilizedVideoPath != null) {
        await videoService.deleteStabilizedVideo(_stabilizedVideoPath!);
        _stabilizedVideoPath = null;
      }

      await _initializeVideo();
      return;
    }

    // Turn on — stabilize then reload
    setState(() => _isStabilizing = true);

    try {
      final videoService = Provider.of<VideoService>(context, listen: false);
      final stabilized = await videoService.stabilizeVideo(
        widget.videoPath,
        onStatus: (msg) => debugPrint('[stabilization] $msg'),
      );

      _controller.removeListener(_onVideoProgress);
      await _controller.dispose();

      setState(() {
        _stabilizedVideoPath = stabilized;
        _stabilizeEnabled = true;
        _isInitialized = false;
        _keyframes.clear();
        _trackingResult = null;
      });

      await _initializeVideo(stabilized);
    } catch (e) {
      debugPrint('Stabilization failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stabilization failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isStabilizing = false);
    }
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

  Future<ui.Image> _renderOverlayImage(
    double width,
    double height,
    int currentFrame, {
    bool showDisc = false,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width, height),
    );
    final painter = FollowFlightPainter(
      trackingResult: _trackingResult!,
      currentFrame: currentFrame,
      showFullTrail: false,
      showCurrentDisc: showDisc,
    );
    painter.paint(canvas, Size(width, height));
    final picture = recorder.endRecording();
    return picture.toImage(width.toInt(), height.toInt());
  }

  Future<void> _saveVideoWithOverlay() async {
    if (_trackingResult == null || _trackingResult!.detections.isEmpty) return;

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
              Text('Rendering flight path...'),
            ],
          ),
        ),
      );
    }

    try {
      final hasAccess = await Gal.requestAccess(toAlbum: true);
      if (!hasAccess) throw Exception('Gallery permission denied');

      final videoWidth = _controller.value.size.width;
      final videoHeight = _controller.value.size.height;
      final trackingFps = _trackingResult!.fps;

      final tempDir = await getTemporaryDirectory();
      final overlayDir = Directory('${tempDir.path}/flight_overlays');
      if (overlayDir.existsSync()) overlayDir.deleteSync(recursive: true);
      overlayDir.createSync();

      // Calculate flight time window
      // Detection timestamps are relative to trim start (frame 0 = 0ms).
      // FFmpeg video clock starts from the original video's beginning,
      // so we must add the trim offset to align overlays correctly.
      final trimOffsetSec = (widget.trimStartMs ?? 0) / 1000.0;
      final detections = _trackingResult!.detections;
      final firstSec = detections.first.timestamp.inMilliseconds / 1000.0;
      final lastSec = detections.last.timestamp.inMilliseconds / 1000.0;
      final flightDuration = lastSec - firstSec;

      // Render chunked overlays (~8 segments)
      const segmentCount = 8;
      final segmentDur = flightDuration / segmentCount;
      final overlayPaths = <String>[];
      final segmentTimes = <double>[];

      for (int i = 0; i < segmentCount; i++) {
        final checkpointSec = firstSec + (i + 1) * segmentDur;
        final checkpointFrame = (checkpointSec * trackingFps).round();

        final image = await _renderOverlayImage(
          videoWidth,
          videoHeight,
          checkpointFrame,
          showDisc: i == segmentCount - 1,
        );
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (byteData == null) continue;

        final path = '${overlayDir.path}/seg_$i.png';
        await File(path).writeAsBytes(byteData.buffer.asUint8List());
        overlayPaths.add(path);
        segmentTimes.add(trimOffsetSec + firstSec + i * segmentDur);
      }

      if (overlayPaths.isEmpty) throw Exception('No overlay segments rendered');

      // Build FFmpeg command with chained overlay filters
      final inputs = StringBuffer('-y -i "${widget.videoPath}" ');
      for (final path in overlayPaths) {
        inputs.write('-i "$path" ');
      }

      final filters = StringBuffer();
      final n = overlayPaths.length;
      for (int i = 0; i < n; i++) {
        final inputLabel = i == 0 ? '0:v' : 'v$i';
        final outputLabel = i == n - 1 ? '' : '[v${i + 1}]';
        final tStart = segmentTimes[i].toStringAsFixed(3);
        final tEnd = i < n - 1
            ? segmentTimes[i + 1].toStringAsFixed(3)
            : '9999';
        final enable = "enable='between(t\\,$tStart\\,$tEnd)'";

        if (i == 0) {
          filters.write('[$inputLabel][${i + 1}:v]overlay=$enable:format=auto');
        } else {
          filters.write('[$inputLabel][${i + 1}:v]overlay=$enable:format=auto');
        }
        if (i < n - 1) {
          filters.write('$outputLabel;');
        }
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${tempDir.path}/flight_path_$timestamp.mp4';

      final session = await FFmpegKit.execute(
        '${inputs.toString()}'
        '-filter_complex "${filters.toString()}" '
        '-c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p '
        '-c:a copy "$outputPath"',
      );

      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getAllLogsAsString();
        throw Exception('FFmpeg failed: $logs');
      }

      await Gal.putVideo(outputPath, album: 'Disc Flight School');

      // Save a persistent copy to the internal gallery
      await VideoGalleryScreen.saveToGallery(outputPath);

      // Cleanup temp files
      Future.delayed(const Duration(seconds: 120), () {
        try { overlayDir.deleteSync(recursive: true); } catch (_) {}
        try { File(outputPath).delete(); } catch (_) {}
      });

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Video saved to "Disc Flight School" album in gallery!'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
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
                      'Tap to mark disc position, or hold for zoom precision. '
                      'Mark 2+ keyframes, then tap Process to generate path.',
                      style:
                          TextStyle(color: Colors.white70, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),

                // Stabilization active banner
                if (_stabilizeEnabled)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 6),
                    color: Colors.teal.shade900,
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle,
                            color: Colors.tealAccent, size: 14),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            'Showing stabilized video — flight path will be '
                            'anchored to the environment.',
                            style: TextStyle(
                                color: Colors.tealAccent, fontSize: 12),
                          ),
                        ),
                      ],
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
                            onTapUp: _addKeyframeFromTap,
                            onLongPressStart: _onLongPressStart,
                            onLongPressMoveUpdate: _onLongPressMoveUpdate,
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

                                // Bounding box overlays for keyframes with box data
                                if (_showOverlay && _trackingResult == null)
                                  ..._keyframes
                                      .where((kf) => kf.boxWidth != null)
                                      .map((kf) => _buildBoxOverlay(
                                            kf,
                                            constraints.biggest,
                                          )),

                                // First corner marker in box mode
                                if (_boxMode && _firstBoxCorner != null)
                                  _buildFirstCornerMarker(
                                      constraints.biggest),

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

    final isBoxActive = _boxMode;
    final cornerLabel = isBoxActive
        ? (_firstBoxCorner == null ? 'Corner 1' : 'Corner 2')
        : null;

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: magnifierDiameter,
              height: magnifierDiameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isBoxActive ? Colors.orange : Colors.white,
                  width: 2.5,
                ),
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
            if (cornerLabel != null)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  cornerLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
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

  Widget _buildBoxOverlay(_FlightKeyframe kf, Size videoSize) {
    final w = (kf.boxWidth ?? 0) * videoSize.width;
    final h = (kf.boxHeight ?? 0) * videoSize.height;
    final left = kf.x * videoSize.width - w / 2;
    final top = kf.y * videoSize.height - h / 2;

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.orange, width: 2),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  Widget _buildFirstCornerMarker(Size videoSize) {
    final x = _firstBoxCorner!.dx * videoSize.width;
    final y = _firstBoxCorner!.dy * videoSize.height;

    return Positioned(
      left: x - 10,
      top: y - 10,
      child: IgnorePointer(
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.orange.withAlpha(150),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.orange, width: 2),
          ),
          child: const Center(
            child: Icon(Icons.add, color: Colors.white, size: 12),
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
                          (widget.trimStartMs ?? 0).toDouble(),
                          (widget.trimEndMs ??
                                  _controller.value.duration.inMilliseconds)
                              .toDouble()),
                  min: (widget.trimStartMs ?? 0).toDouble(),
                  max: (widget.trimEndMs ??
                          _controller.value.duration.inMilliseconds)
                      .toDouble(),
                  onChanged: (value) {
                    _controller.seekTo(
                        Duration(milliseconds: value.toInt()));
                  },
                ),
              ),
              Text(
                _formatDuration(Duration(
                    milliseconds: widget.trimEndMs ??
                        _controller.value.duration.inMilliseconds)),
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
    final trainingService =
        Provider.of<TrainingDataService>(context, listen: false);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          _buildStabilizeToggle(),
          if (trainingService.isOptedIn)
            _buildBoxModeToggle(),
          ElevatedButton.icon(
            onPressed:
                _keyframes.isEmpty ? null : _undoLastKeyframe,
            icon: const Icon(Icons.undo, size: 16),
            label: const Text('Undo', style: TextStyle(fontSize: 12)),
          ),
          ElevatedButton.icon(
            onPressed: hasEnoughKeyframes ? _processKeyframes : null,
            icon: const Icon(Icons.auto_awesome, size: 16),
            label:
                const Text('Process', style: TextStyle(fontSize: 12)),
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
            icon: const Icon(Icons.clear, size: 16),
            label:
                const Text('Clear', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStabilizeToggle() {
    return GestureDetector(
      onTap: _isStabilizing ? null : _toggleStabilization,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: _stabilizeEnabled
              ? Colors.teal.shade800
              : Colors.grey.shade800,
          borderRadius: BorderRadius.circular(8),
          border: _stabilizeEnabled
              ? Border.all(color: Colors.tealAccent, width: 1.5)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isStabilizing)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            else
              Icon(
                Icons.videocam_outlined,
                size: 16,
                color: _stabilizeEnabled
                    ? Colors.tealAccent
                    : Colors.grey,
              ),
            const SizedBox(width: 4),
            Text(
              _isStabilizing
                  ? 'Stabilizing…'
                  : (_stabilizeEnabled ? 'Stabilized' : 'Stabilize'),
              style: TextStyle(
                fontSize: 12,
                color: _stabilizeEnabled
                    ? Colors.tealAccent
                    : Colors.grey,
                fontWeight: _stabilizeEnabled
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBoxModeToggle() {
    return GestureDetector(
      onTap: () {
        setState(() {
          _boxMode = !_boxMode;
          _firstBoxCorner = null; // Reset pending corner on toggle
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: _boxMode ? Colors.orange : Colors.grey.shade800,
          borderRadius: BorderRadius.circular(8),
          border: _boxMode
              ? Border.all(color: Colors.orangeAccent, width: 1.5)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.crop_square,
              size: 18,
              color: _boxMode ? Colors.white : Colors.grey,
            ),
            const SizedBox(width: 4),
            Text(
              'Box',
              style: TextStyle(
                fontSize: 13,
                color: _boxMode ? Colors.white : Colors.grey,
                fontWeight: _boxMode ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
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
