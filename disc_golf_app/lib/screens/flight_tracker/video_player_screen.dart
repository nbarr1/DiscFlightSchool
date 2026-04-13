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
import 'dart:math' as math;
import 'dart:ui' as ui;

/// A background reference point used for camera motion compensation.
///
/// The user taps the same static landmark (e.g. a tee sign or tree) in two or
/// more frames.  The app computes the 2-D camera pan between those frames and
/// shifts past trail positions accordingly, keeping the flight path
/// world-locked even when the camera moves — equivalent to the After-Effects
/// "Create Null and Camera" workflow.
class _CameraRefPoint {
  final int frameIndex;
  final double x; // normalized 0-1
  final double y; // normalized 0-1
  const _CameraRefPoint({
    required this.frameIndex,
    required this.x,
    required this.y,
  });
}

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
  Offset? _zoomPrevWidgetPos; // Previous keyframe position in widget coords, shown during zoom
  ui.Image? _capturedFrame;
  final _videoBoundaryKey = GlobalKey();
  bool _wasPlayingBeforeZoom = false;

  // Box mode state (two-tap bounding box for training)
  bool _boxMode = false;
  Offset? _firstBoxCorner; // Normalized 0-1, first corner of bounding box

  // Target line state — user draws a reference line (e.g. throw direction to basket)
  bool _targetLineMode = false;
  Offset? _targetLineStart; // Normalized 0-1
  Offset? _targetLineEnd;   // Normalized 0-1

  // Camera lock / motion compensation state
  bool _cameraLockMode = false;
  final List<_CameraRefPoint> _cameraRefPoints = [];

  // Stabilization state
  bool _stabilizeEnabled = false;
  String? _stabilizedVideoPath; // Path to FFmpeg-stabilized temp file
  bool _isStabilizing = false;

  // Cached service references so dispose() doesn't need context
  VideoService? _videoService;
  ScaffoldMessengerState? _scaffoldMessenger;

  // Frame rate used for frame indexing (10fps = 1 frame per 100ms)
  static const double _frameFps = 10.0;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _videoService ??= Provider.of<VideoService>(context, listen: false);
    _scaffoldMessenger = ScaffoldMessenger.of(context);
  }

  Future<void> _initializeVideo([String? overridePath]) async {
    final path = overridePath ?? widget.videoPath;
    _controller = VideoPlayerController.file(File(path));
    await _controller.initialize();
    if (widget.trimStartMs != null) {
      await _controller.seekTo(Duration(milliseconds: widget.trimStartMs!));
    }
    if (!mounted) return;
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
    _scaffoldMessenger?.removeCurrentMaterialBanner();
    _controller.removeListener(_onVideoProgress);
    _controller.dispose();
    _capturedFrame?.dispose();
    // Clean up stabilized temp file when leaving the screen
    if (_stabilizedVideoPath != null) {
      _videoService?.deleteStabilizedVideo(_stabilizedVideoPath!);
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
    // Also compute the previous keyframe position for the direction indicator.
    final priorFrames = _keyframes.where((kf) => kf.frameIndex < _currentFrame).toList();
    setState(() {
      _isZoomMode = true;
      _zoomPosition = details.localPosition;
      _zoomPrevWidgetPos = priorFrames.isNotEmpty
          ? Offset(
              priorFrames.last.x * _videoWidgetSize.width,
              priorFrames.last.y * _videoWidgetSize.height,
            )
          : null;
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
      _zoomPrevWidgetPos = null;
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
    if (_cameraLockMode) {
      _placeCameraRefPoint(details.localPosition);
      return;
    }
    if (_targetLineMode) {
      _placeTargetLinePoint(details.localPosition);
      return;
    }
    _placeKeyframe(details.localPosition);
  }

  void _placeTargetLinePoint(Offset localPosition) {
    if (_videoWidgetSize == Size.zero) return;
    final nx = (localPosition.dx / _videoWidgetSize.width).clamp(0.0, 1.0);
    final ny = (localPosition.dy / _videoWidgetSize.height).clamp(0.0, 1.0);
    setState(() {
      if (_targetLineStart == null) {
        _targetLineStart = Offset(nx, ny);
      } else {
        _targetLineEnd = Offset(nx, ny);
        _targetLineMode = false; // exit mode after second tap
      }
    });
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
      _cameraRefPoints.clear();
      _cameraLockMode = false;
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
      if (!mounted) return;

      if (_stabilizedVideoPath != null) {
        await _videoService?.deleteStabilizedVideo(_stabilizedVideoPath!);
        _stabilizedVideoPath = null;
      }

      await _initializeVideo();
      return;
    }

    // Turn on — stabilize then reload
    setState(() => _isStabilizing = true);

    try {
      final stabilized = await _videoService!.stabilizeVideo(
        widget.videoPath,
        onStatus: (msg) => debugPrint('[stabilization] $msg'),
      );
      if (!mounted) return;

      _controller.removeListener(_onVideoProgress);
      await _controller.dispose();
      if (!mounted) return;

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

  // ---------------------------------------------------------------------------
  // Camera motion compensation
  // ---------------------------------------------------------------------------

  /// Returns the interpolated camera offset (normalized 0-1) at [frame],
  /// relative to the first reference point's frame.
  ///
  /// The offset encodes how much the camera has panned since the base frame:
  ///   offset = refPoint_at_frame - refPoint_at_baseFrame
  ///
  /// [FollowFlightPainter] uses this to shift past trail positions so they
  /// stay locked to the environment as the camera moves.
  Offset _computeCameraOffset(int frame) {
    if (_cameraRefPoints.length < 2) return Offset.zero;
    final sorted = List<_CameraRefPoint>.from(_cameraRefPoints)
      ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));
    final base = sorted.first;

    // Find surrounding reference frames for interpolation
    _CameraRefPoint prev = base;
    _CameraRefPoint next = sorted.last;
    for (final ref in sorted) {
      if (ref.frameIndex <= frame) prev = ref;
    }
    for (final ref in sorted.reversed) {
      if (ref.frameIndex >= frame) { next = ref; break; }
    }

    if (prev.frameIndex == next.frameIndex) {
      return Offset(prev.x - base.x, prev.y - base.y);
    }
    final t = (frame - prev.frameIndex) / (next.frameIndex - prev.frameIndex);
    final ox = (prev.x + (next.x - prev.x) * t) - base.x;
    final oy = (prev.y + (next.y - prev.y) * t) - base.y;
    return Offset(ox, oy);
  }

  /// Builds a map of frame → camera offset for all frames covered by the
  /// current tracking result (or keyframes), for passing to [FollowFlightPainter].
  Map<int, Offset> _buildCameraOffsetMap() {
    if (_cameraRefPoints.length < 2) return {};
    final sorted = List<_CameraRefPoint>.from(_cameraRefPoints)
      ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));
    final base = sorted.first;
    // Only key the reference frames — the painter interpolates between them.
    return {
      for (final ref in sorted)
        ref.frameIndex: Offset(ref.x - base.x, ref.y - base.y),
    };
  }

  /// Places a camera reference point at [localPosition] in the video widget.
  void _placeCameraRefPoint(Offset localPosition) {
    if (_videoWidgetSize == Size.zero) return;
    final nx = (localPosition.dx / _videoWidgetSize.width).clamp(0.0, 1.0);
    final ny = (localPosition.dy / _videoWidgetSize.height).clamp(0.0, 1.0);
    setState(() {
      _cameraRefPoints.removeWhere((r) => r.frameIndex == _currentFrame);
      _cameraRefPoints.add(_CameraRefPoint(
        frameIndex: _currentFrame,
        x: nx,
        y: ny,
      ));
      _cameraRefPoints.sort((a, b) => a.frameIndex.compareTo(b.frameIndex));
      // Invalidate tracking result so compensation is re-applied on next Process
      _trackingResult = null;
    });
    if (_cameraRefPoints.length == 1 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'Landmark set. Scrub to a different frame where the camera has moved, '
          'then tap the same landmark again.',
        ),
        duration: Duration(seconds: 4),
      ));
    }
  }

  // --- Save video with overlay ---

  Future<ui.Image> _renderOverlayImage(
    double width,
    double height,
    int currentFrame, {
    bool showDisc = false,
    Map<int, Offset>? cameraOffsets,
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
      cameraOffsets: cameraOffsets,
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

      // Detection timestamps are relative to trim start (frame 0 = 0 ms).
      // FFmpeg's video clock starts from the original file beginning, so we
      // must add the trim offset to align each overlay with the right frame.
      final trimOffsetSec = (widget.trimStartMs ?? 0) / 1000.0;
      final detections = _trackingResult!.detections;
      final cameraOffsets = _buildCameraOffsetMap();

      // --- Render one overlay image per tracking frame ---
      //
      // Each image shows the full trail up to that frame, creating a smooth
      // "Trim Path draw-on" animation in the exported video — matching the
      // After-Effects workflow.  We cap at 90 frames (~9 s at 10 fps) to keep
      // render time reasonable; frames are sub-sampled evenly if above the cap.
      final allFrames = detections.map((d) => d.frameIndex).toSet().toList()
        ..sort();

      const maxOverlays = 90;
      final List<int> framesToRender;
      if (allFrames.length <= maxOverlays) {
        framesToRender = allFrames;
      } else {
        // Even sub-sample: always include first and last
        final step = (allFrames.length - 1) / (maxOverlays - 1);
        framesToRender = [
          for (int i = 0; i < maxOverlays; i++)
            allFrames[(i * step).round().clamp(0, allFrames.length - 1)],
        ];
      }

      final overlayPaths = <String>[];
      final overlayStartTimes = <double>[];

      for (int i = 0; i < framesToRender.length; i++) {
        final frame = framesToRender[i];
        final detection = _trackingResult!.detectionAtFrame(frame);
        if (detection == null) continue;

        final isLastFrame = i == framesToRender.length - 1;
        final image = await _renderOverlayImage(
          videoWidth,
          videoHeight,
          frame,
          showDisc: isLastFrame,
          cameraOffsets: cameraOffsets,
        );
        final byteData =
            await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (byteData == null) continue;

        final path = '${overlayDir.path}/frame_${i.toString().padLeft(4, '0')}.png';
        await File(path).writeAsBytes(byteData.buffer.asUint8List());
        overlayPaths.add(path);

        // Absolute video time this overlay should appear
        final frameSec = detection.timestamp.inMilliseconds / 1000.0;
        overlayStartTimes.add(trimOffsetSec + frameSec);

        // Yield to the event loop every 10 frames to keep the UI responsive
        if (i % 10 == 0) await Future.delayed(Duration.zero);
      }

      if (overlayPaths.isEmpty) throw Exception('No overlay frames rendered');

      // --- Build FFmpeg filter_complex ---
      //
      // Chain: [0:v][1:v]overlay=enable=between(t,t0,t1)[v1];
      //        [v1][2:v]overlay=enable=between(t,t1,t2)[v2]; ...
      //
      // Each overlay is visible from its start time until the next overlay's
      // start time, so the trail smoothly draws on frame-by-frame.
      final inputs = StringBuffer('-y -i "${widget.videoPath}" ');
      for (final path in overlayPaths) {
        inputs.write('-i "$path" ');
      }

      final filters = StringBuffer();
      final n = overlayPaths.length;
      for (int i = 0; i < n; i++) {
        final inputLabel = i == 0 ? '[0:v]' : '[v$i]';
        final outputLabel = i == n - 1 ? '' : '[v${i + 1}]';
        final tStart = overlayStartTimes[i].toStringAsFixed(3);
        final tEnd = i < n - 1
            ? overlayStartTimes[i + 1].toStringAsFixed(3)
            : '99999';
        final enable = "enable='between(t\\,$tStart\\,$tEnd)'";
        filters.write(
          '$inputLabel[${i + 1}:v]overlay=$enable:format=auto$outputLabel',
        );
        if (i < n - 1) filters.write(';');
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
                                        cameraOffsets:
                                            _buildCameraOffsetMap(),
                                      ),
                                    ),
                                  ),

                                // Keyframe markers (before processing).
                                // Hidden during zoom mode — the magnifier's
                                // direction arrow shows where the previous
                                // disc was without the finger obscuring it.
                                if (_showOverlay &&
                                    _trackingResult == null &&
                                    !_isZoomMode)
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
                                if (_showOverlay && _trackingResult == null && !_isZoomMode)
                                  ..._keyframes
                                      .where((kf) => kf.boxWidth != null)
                                      .map((kf) => _buildBoxOverlay(
                                            kf,
                                            constraints.biggest,
                                          )),

                                // Camera reference point markers
                                if (_cameraRefPoints.isNotEmpty)
                                  ..._cameraRefPoints.map((ref) =>
                                      _buildCameraRefMarker(
                                          ref, constraints.biggest)),

                                // Camera lock mode instruction banner
                                if (_cameraLockMode)
                                  Positioned(
                                    top: 8,
                                    left: 0,
                                    right: 0,
                                    child: Center(
                                      child: IgnorePointer(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: Colors.purple.shade900
                                                .withAlpha(220),
                                            borderRadius:
                                                BorderRadius.circular(20),
                                          ),
                                          child: Text(
                                            _cameraRefPoints.isEmpty
                                                ? 'Tap a static background landmark'
                                                : 'Scrub to another frame, tap same landmark',
                                            style: const TextStyle(
                                                color: Colors.purpleAccent,
                                                fontSize: 13,
                                                fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

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

                                // Previous keyframe direction indicator during zoom
                                if (_isZoomMode &&
                                    _zoomPrevWidgetPos != null &&
                                    _zoomPosition != null)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: _PrevPositionPainter(
                                          prevPos: _zoomPrevWidgetPos!,
                                          currentPos: _zoomPosition!,
                                        ),
                                      ),
                                    ),
                                  ),

                                // Target line overlay
                                if (_targetLineStart != null)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: _TargetLinePainter(
                                          start: _targetLineStart!,
                                          end: _targetLineEnd,
                                          videoSize: constraints.biggest,
                                          // Show partial line to first tap point
                                          // while waiting for second tap
                                          pendingMode: _targetLineMode &&
                                              _targetLineEnd == null,
                                        ),
                                      ),
                                    ),
                                  ),

                                // Target line mode banner
                                if (_targetLineMode)
                                  Positioned(
                                    top: 8,
                                    left: 0,
                                    right: 0,
                                    child: Center(
                                      child: IgnorePointer(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: Colors.green.shade900
                                                .withAlpha(220),
                                            borderRadius:
                                                BorderRadius.circular(20),
                                          ),
                                          child: Text(
                                            _targetLineStart == null
                                                ? 'Tap to set line start'
                                                : 'Tap to set line end',
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                                fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
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

  /// The magnifier bubble — shows a zoomed view of the video area around the
  /// touch point, anchored to the top-right corner so it never flips.
  Widget _buildMagnifier(Size videoSize) {
    const magnifierDiameter = 150.0;
    const magnifierRadius = magnifierDiameter / 2;

    // Compute direction from current touch point toward the last keyframe.
    // Shown as a cyan arrowhead on the magnifier rim so the user can find
    // the previous disc position without the finger covering its marker.
    double? arrowAngle;
    if (_keyframes.isNotEmpty && _zoomPosition != null) {
      final prev = _keyframes.last;
      final dx = prev.x * videoSize.width - _zoomPosition!.dx;
      final dy = prev.y * videoSize.height - _zoomPosition!.dy;
      if (dx * dx + dy * dy > 1.0) {
        arrowAngle = math.atan2(dy, dx);
      }
    }

    final isBoxActive = _boxMode;
    final cornerLabel = isBoxActive
        ? (_firstBoxCorner == null ? 'Corner 1' : 'Corner 2')
        : null;

    return Positioned(
      right: 8,
      top: 8,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: magnifierDiameter,
              height: magnifierDiameter,
              child: Stack(
                clipBehavior: Clip.none,
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
                  if (arrowAngle != null)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _DirectionArrowPainter(angle: arrowAngle),
                      ),
                    ),
                ],
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
          _buildCameraLockButton(),
          if (trainingService.isOptedIn)
            _buildBoxModeToggle(),
          _buildTargetLineButton(),
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

  Widget _buildTargetLineButton() {
    final hasLine = _targetLineStart != null && _targetLineEnd != null;
    final isActive = _targetLineMode;
    final color = isActive
        ? Colors.green
        : hasLine
            ? Colors.green.shade800
            : Colors.grey.shade800;
    final label = isActive
        ? (_targetLineStart == null ? 'Set Start' : 'Set End')
        : hasLine
            ? 'Target ✓'
            : 'Target Line';

    return GestureDetector(
      onTap: () {
        setState(() {
          if (isActive) {
            // Cancel target line mode
            _targetLineMode = false;
            if (_targetLineEnd == null) _targetLineStart = null;
          } else if (hasLine) {
            // Clear existing line
            _targetLineStart = null;
            _targetLineEnd = null;
          } else {
            // Enter target line mode
            _targetLineMode = true;
            _targetLineStart = null;
            _targetLineEnd = null;
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: (isActive || hasLine)
              ? Border.all(color: Colors.greenAccent, width: 1.5)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.straighten, size: 18,
                color: (isActive || hasLine) ? Colors.white : Colors.grey),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: (isActive || hasLine) ? Colors.white : Colors.grey,
                fontWeight: (isActive || hasLine)
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraLockButton() {
    final hasRefs = _cameraRefPoints.length >= 2;
    final isActive = _cameraLockMode;
    final color = isActive
        ? Colors.purple.shade700
        : hasRefs
            ? Colors.purple.shade900
            : Colors.grey.shade800;

    return GestureDetector(
      onTap: () => setState(() => _cameraLockMode = !_cameraLockMode),
      onLongPress: _cameraRefPoints.isNotEmpty
          ? () => setState(() {
                _cameraRefPoints.clear();
                _cameraLockMode = false;
                _trackingResult = null;
              })
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: (isActive || hasRefs)
              ? Border.all(color: Colors.purpleAccent, width: 1.5)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasRefs ? Icons.lock : Icons.lock_open,
              size: 14,
              color:
                  (isActive || hasRefs) ? Colors.purpleAccent : Colors.grey,
            ),
            const SizedBox(width: 4),
            Text(
              isActive ? 'Tap Landmark' : (hasRefs ? 'Scene Locked' : 'Lock Scene'),
              style: TextStyle(
                fontSize: 11,
                color:
                    (isActive || hasRefs) ? Colors.purpleAccent : Colors.grey,
                fontWeight:
                    (isActive || hasRefs) ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            if (_cameraRefPoints.isNotEmpty) ...[
              const SizedBox(width: 4),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.purple,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${_cameraRefPoints.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCameraRefMarker(_CameraRefPoint ref, Size videoSize) {
    final x = ref.x * videoSize.width - 10;
    final y = ref.y * videoSize.height - 10;
    final isCurrentFrame = ref.frameIndex == _currentFrame;
    return Positioned(
      left: x,
      top: y,
      child: IgnorePointer(
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.purple.withAlpha(isCurrentFrame ? 200 : 120),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.purpleAccent, width: 1.5),
          ),
          child: const Center(
            child: Icon(Icons.lock, color: Colors.white, size: 10),
          ),
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

/// Draws a directional arrowhead on the rim of the magnifier circle,
/// pointing from the current touch point toward the most recently placed
/// keyframe so the user can find the previous disc position while zooming.
class _DirectionArrowPainter extends CustomPainter {
  final double angle;

  _DirectionArrowPainter({required this.angle});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const radius = 75.0;
    // Tip protrudes 10px beyond the rim; base sits 12px inside it.
    const tipDist = radius + 10.0;
    const baseDist = radius - 12.0;
    const halfBase = 8.0;

    final tipX = center.dx + tipDist * math.cos(angle);
    final tipY = center.dy + tipDist * math.sin(angle);

    final perpAngle = angle + math.pi / 2;
    final b1x = center.dx + baseDist * math.cos(angle) + halfBase * math.cos(perpAngle);
    final b1y = center.dy + baseDist * math.sin(angle) + halfBase * math.sin(perpAngle);
    final b2x = center.dx + baseDist * math.cos(angle) - halfBase * math.cos(perpAngle);
    final b2y = center.dy + baseDist * math.sin(angle) - halfBase * math.sin(perpAngle);

    final path = Path()
      ..moveTo(tipX, tipY)
      ..lineTo(b1x, b1y)
      ..lineTo(b2x, b2y)
      ..close();

    canvas.drawPath(path, Paint()..color = Colors.cyan);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_DirectionArrowPainter old) => old.angle != angle;
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

/// Draws the user-defined reference target line on the video overlay.
/// While [pendingMode] is true (only start set), draws a dot at start.
/// Once [end] is also set, draws start dot → dashed line → end dot with an
/// arrowhead, in green so it is visually distinct from the flight trail.
class _TargetLinePainter extends CustomPainter {
  final Offset start;   // Normalized 0-1
  final Offset? end;    // Normalized 0-1, null while waiting for second tap
  final Size videoSize;
  final bool pendingMode;

  const _TargetLinePainter({
    required this.start,
    required this.end,
    required this.videoSize,
    this.pendingMode = false,
  });

  Offset _toCanvas(Offset norm) =>
      Offset(norm.dx * videoSize.width, norm.dy * videoSize.height);

  @override
  void paint(Canvas canvas, Size size) {
    final startPx = _toCanvas(start);
    final dotPaint = Paint()
      ..color = Colors.greenAccent.withAlpha(230)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = Colors.white.withAlpha(200)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // Start dot
    canvas.drawCircle(startPx, 8, dotPaint);
    canvas.drawCircle(startPx, 8, borderPaint);

    if (end == null) return;
    final endPx = _toCanvas(end!);

    // Dashed line from start to end
    final linePaint = Paint()
      ..color = Colors.greenAccent.withAlpha(180)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    const dashLen = 12.0;
    const gapLen = 6.0;
    final dx = endPx.dx - startPx.dx;
    final dy = endPx.dy - startPx.dy;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist < 1) return;
    final ux = dx / dist;
    final uy = dy / dist;
    double drawn = 0;
    bool drawing = true;
    Offset cursor = startPx;
    while (drawn < dist) {
      final segLen = drawing
          ? dashLen.clamp(0, dist - drawn)
          : gapLen.clamp(0, dist - drawn);
      final next = Offset(cursor.dx + ux * segLen, cursor.dy + uy * segLen);
      if (drawing) canvas.drawLine(cursor, next, linePaint);
      cursor = next;
      drawn += segLen;
      drawing = !drawing;
    }

    // Arrowhead at end
    const arrowLen = 12.0;
    const arrowAngle = 0.45;
    final x1 = endPx.dx - arrowLen * (ux * math.cos(arrowAngle) - uy * math.sin(arrowAngle));
    final y1 = endPx.dy - arrowLen * (uy * math.cos(arrowAngle) + ux * math.sin(arrowAngle));
    final x2 = endPx.dx - arrowLen * (ux * math.cos(arrowAngle) + uy * math.sin(arrowAngle));
    final y2 = endPx.dy - arrowLen * (uy * math.cos(arrowAngle) - ux * math.sin(arrowAngle));
    canvas.drawPath(
      Path()
        ..moveTo(endPx.dx, endPx.dy)
        ..lineTo(x1, y1)
        ..lineTo(x2, y2)
        ..close(),
      Paint()
        ..color = Colors.greenAccent.withAlpha(220)
        ..style = PaintingStyle.fill,
    );

    // End dot
    canvas.drawCircle(endPx, 8, dotPaint);
    canvas.drawCircle(endPx, 8, borderPaint);
  }

  @override
  bool shouldRepaint(_TargetLinePainter old) =>
      start != old.start || end != old.end || pendingMode != old.pendingMode;
}

/// Draws a ghost dot at [prevPos] and a cyan arrow toward [currentPos] so the
/// user can see the previous disc position and direction during zoom placement.
class _PrevPositionPainter extends CustomPainter {
  final Offset prevPos;
  final Offset currentPos;

  const _PrevPositionPainter({required this.prevPos, required this.currentPos});

  @override
  void paint(Canvas canvas, Size size) {
    final dx = currentPos.dx - prevPos.dx;
    final dy = currentPos.dy - prevPos.dy;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist < 10) return; // Too close — don't draw

    // Arrow line from previous position to current touch
    canvas.drawLine(
      prevPos,
      currentPos,
      Paint()
        ..color = Colors.cyanAccent.withAlpha(180)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke,
    );

    // Arrowhead at currentPos
    final ux = dx / dist;
    final uy = dy / dist;
    const arrowLen = 10.0;
    const arrowAngle = 0.45; // radians (~26°)
    final x1 = currentPos.dx - arrowLen * (ux * math.cos(arrowAngle) - uy * math.sin(arrowAngle));
    final y1 = currentPos.dy - arrowLen * (uy * math.cos(arrowAngle) + ux * math.sin(arrowAngle));
    final x2 = currentPos.dx - arrowLen * (ux * math.cos(arrowAngle) + uy * math.sin(arrowAngle));
    final y2 = currentPos.dy - arrowLen * (uy * math.cos(arrowAngle) - ux * math.sin(arrowAngle));
    canvas.drawPath(
      Path()
        ..moveTo(currentPos.dx, currentPos.dy)
        ..lineTo(x1, y1)
        ..lineTo(x2, y2)
        ..close(),
      Paint()
        ..color = Colors.cyanAccent.withAlpha(200)
        ..style = PaintingStyle.fill,
    );

    // Ghost dot at previous position
    canvas.drawCircle(
      prevPos,
      9,
      Paint()
        ..color = Colors.cyanAccent.withAlpha(120)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      prevPos,
      9,
      Paint()
        ..color = Colors.white.withAlpha(200)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_PrevPositionPainter old) =>
      prevPos != old.prevPos || currentPos != old.currentPos;
}
