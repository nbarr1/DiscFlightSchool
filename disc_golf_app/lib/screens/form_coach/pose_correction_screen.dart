import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../models/form_analysis.dart';
import '../../services/posture_analysis_service.dart';
import '../../services/video_frame_extractor.dart';
import '../../utils/angle_calculator.dart';
import '../../widgets/skeleton_overlay.dart';

/// Screen for manually correcting auto-detected pose landmarks.
///
/// The user scrubs to frames where the skeleton is off, then either:
/// - **Individual mode**: tap a joint to select it, drag to reposition it, or
///   hold for precision zoom before placing.
/// - **Move All mode**: drag anywhere to shift the entire skeleton as a unit.
///
/// On "Apply", Catmull-Rom spline interpolation fills gaps between corrected
/// frames, angles are recalculated, and the corrected [FormAnalysis] is
/// returned via Navigator.pop.
class PoseCorrectionScreen extends StatefulWidget {
  final FormAnalysis analysis;
  final String videoPath;
  final int? analysisStartMs;
  final int? analysisEndMs;
  /// If provided, the screen opens at this frame index (used when launched
  /// from per-phase verification to start on the relevant phase frame).
  final int? initialFrame;

  const PoseCorrectionScreen({
    super.key,
    required this.analysis,
    required this.videoPath,
    this.analysisStartMs,
    this.analysisEndMs,
    this.initialFrame,
  });

  @override
  State<PoseCorrectionScreen> createState() => _PoseCorrectionScreenState();
}

class _PoseCorrectionScreenState extends State<PoseCorrectionScreen> {
  static const _frameIntervalMs = VideoFrameExtractor.defaultIntervalMs;

  late VideoPlayerController _controller;
  late FormAnalysis _analysis;
  bool _isInitialized = false;
  int _currentFrame = 0;
  Size _videoWidgetSize = Size.zero;

  // Individual landmark correction state
  String? _selectedLandmark;
  final Set<int> _correctedFrames = {};
  final Map<String, Map<int, Offset>> _corrections = {};

  // Mode toggle: move-all vs individual joint
  bool _moveAllMode = false;

  // Zoom / magnifier state (individual mode only)
  bool _isZooming = false;
  Offset? _zoomPosition;
  ui.Image? _capturedFrame;
  bool _wasPlayingBeforeZoom = false;

  // Keys
  final GlobalKey _overlayKey = GlobalKey();
  final GlobalKey _videoBoundaryKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _analysis = FormAnalysis.fromJson(widget.analysis.toJson());
    _initVideo();
  }

  Future<void> _initVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath));
    await _controller.initialize();
    _controller.addListener(_onVideoTick);
    if (widget.initialFrame != null) {
      _seekToFrame(widget.initialFrame!);
    }
    setState(() => _isInitialized = true);
  }

  void _onVideoTick() {
    if (_analysis.frames.isEmpty) return;
    final posMs = _controller.value.position.inMilliseconds;
    final startMs = widget.analysisStartMs ?? 0;
    final frame = ((posMs - startMs) / _frameIntervalMs)
        .floor()
        .clamp(0, _analysis.frames.length - 1);
    if (frame != _currentFrame) {
      setState(() => _currentFrame = frame);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onVideoTick);
    _controller.dispose();
    _capturedFrame?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Gesture handling — Individual mode
  // ---------------------------------------------------------------------------

  void _onTapDown(TapDownDetails details) {
    if (_analysis.frames.isEmpty) return;
    final frame = _analysis.frames[_currentFrame];
    final nearest = SkeletonOverlay.nearestLandmark(
      details.localPosition,
      _videoWidgetSize,
      frame,
    );
    setState(() => _selectedLandmark = nearest);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_analysis.frames.isEmpty) return;

    if (_moveAllMode) {
      _applyMoveAllDelta(details.delta);
    } else {
      _applyLandmarkDelta(details.localPosition);
    }
  }

  void _applyLandmarkDelta(Offset canvasPos) {
    if (_selectedLandmark == null) return;
    final frame = _analysis.frames[_currentFrame];
    final imagePos =
        SkeletonOverlay.canvasToImage(canvasPos, _videoWidgetSize, frame);

    frame.keyPoints[_selectedLandmark!] = imagePos;
    _corrections
        .putIfAbsent(_selectedLandmark!, () => {})[_currentFrame] = imagePos;
    _correctedFrames.add(_currentFrame);

    final postureService =
        Provider.of<PostureAnalysisService>(context, listen: false);
    postureService.recalculateFrameAngles(frame);
    setState(() {});
  }

  void _applyMoveAllDelta(Offset canvasDelta) {
    final frame = _analysis.frames[_currentFrame];
    if (frame.keyPoints.isEmpty || _videoWidgetSize == Size.zero) return;

    // Convert canvas delta to image-space delta
    final origin = SkeletonOverlay.canvasToImage(
        Offset.zero, _videoWidgetSize, frame);
    final target = SkeletonOverlay.canvasToImage(
        canvasDelta, _videoWidgetSize, frame);
    final imageDelta = target - origin;

    // Shift every landmark
    for (final key in frame.keyPoints.keys.toList()) {
      final newPos = frame.keyPoints[key]! + imageDelta;
      frame.keyPoints[key] = newPos;
      _corrections.putIfAbsent(key, () => {})[_currentFrame] = newPos;
    }
    _correctedFrames.add(_currentFrame);

    final postureService =
        Provider.of<PostureAnalysisService>(context, listen: false);
    postureService.recalculateFrameAngles(frame);
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Zoom / magnifier (individual mode only)
  // ---------------------------------------------------------------------------

  Future<void> _onLongPressStart(LongPressStartDetails details) async {
    if (_analysis.frames.isEmpty) return;

    _wasPlayingBeforeZoom = _controller.value.isPlaying;
    if (_wasPlayingBeforeZoom) _controller.pause();

    // Select nearest landmark immediately
    final frame = _analysis.frames[_currentFrame];
    final nearest = SkeletonOverlay.nearestLandmark(
      details.localPosition,
      _videoWidgetSize,
      frame,
    );

    setState(() {
      _selectedLandmark = nearest;
      _isZooming = true;
      _zoomPosition = details.localPosition;
    });

    // Capture video frame for magnifier
    final boundary = _videoBoundaryKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary != null) {
      try {
        final image = await boundary.toImage(pixelRatio: 2.0);
        if (mounted) setState(() => _capturedFrame = image);
      } catch (_) {}
    }
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!_isZooming) return;
    setState(() => _zoomPosition = details.localPosition);

    if (_selectedLandmark != null) {
      _applyLandmarkDelta(details.localPosition);
    }
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (_isZooming && _selectedLandmark != null) {
      final pos = _zoomPosition ?? details.localPosition;
      _applyLandmarkDelta(pos);
    }

    if (_wasPlayingBeforeZoom) _controller.play();

    setState(() {
      _isZooming = false;
      _zoomPosition = null;
    });
    _capturedFrame?.dispose();
    _capturedFrame = null;
  }

  // ---------------------------------------------------------------------------
  // Apply corrections (interpolation + angle recalculation)
  // ---------------------------------------------------------------------------

  void _applyCorrections() {
    if (_corrections.isEmpty) {
      Navigator.pop(context);
      return;
    }

    final postureService =
        Provider.of<PostureAnalysisService>(context, listen: false);
    final totalFrames = _analysis.frames.length;

    for (final entry in _corrections.entries) {
      final landmark = entry.key;
      final anchors = entry.value;
      if (anchors.isEmpty) continue;

      final interpolated = AngleCalculator.interpolateAnchors(
        anchors,
        0,
        totalFrames - 1,
      );

      final sortedAnchorKeys = anchors.keys.toList()..sort();
      final firstAnchor = sortedAnchorKeys.first;
      final lastAnchor = sortedAnchorKeys.last;

      for (int i = firstAnchor; i <= lastAnchor; i++) {
        final pos = interpolated[i];
        if (pos != null) {
          _analysis.frames[i].keyPoints[landmark] = pos;
        }
      }
    }

    for (final frame in _analysis.frames) {
      postureService.recalculateFrameAngles(frame);
    }

    final newScore = postureService.recalculateScore(_analysis.frames);
    final corrected = FormAnalysis(
      id: _analysis.id,
      date: _analysis.date,
      videoPath: _analysis.videoPath,
      frames: _analysis.frames,
      score: newScore,
    );

    Navigator.pop(context, corrected);
  }

  // ---------------------------------------------------------------------------
  // Frame navigation
  // ---------------------------------------------------------------------------

  void _seekToFrame(int frame) {
    final clamped = frame.clamp(0, _analysis.frames.length - 1);
    final startMs = widget.analysisStartMs ?? 0;
    _controller.seekTo(
        Duration(milliseconds: startMs + clamped * _frameIntervalMs));
    setState(() => _currentFrame = clamped);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Correct Pose'),
        actions: [
          TextButton.icon(
            onPressed: _applyCorrections,
            icon: const Icon(Icons.check, color: Colors.green),
            label: Text(
              _corrections.isEmpty
                  ? 'Done'
                  : 'Apply (${_correctedFrames.length})',
              style: const TextStyle(color: Colors.green),
            ),
          ),
        ],
      ),
      body: !_isInitialized
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildVideoWithOverlay(),
                _buildFrameScrubber(),
                _buildControls(),
                _buildInstructions(),
              ],
            ),
    );
  }

  Widget _buildVideoWithOverlay() {
    return Expanded(
      child: Center(
        child: AspectRatio(
          aspectRatio: _controller.value.aspectRatio,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _videoWidgetSize = constraints.biggest;

              return GestureDetector(
                onTapDown: _moveAllMode ? null : _onTapDown,
                onPanUpdate: _onPanUpdate,
                onLongPressStart:
                    _moveAllMode ? null : _onLongPressStart,
                onLongPressMoveUpdate:
                    _moveAllMode ? null : _onLongPressMoveUpdate,
                onLongPressEnd:
                    _moveAllMode ? null : _onLongPressEnd,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Video
                    RepaintBoundary(
                      key: _videoBoundaryKey,
                      child: VideoPlayer(_controller),
                    ),

                    // Skeleton overlay
                    if (_analysis.frames.isNotEmpty)
                      CustomPaint(
                        key: _overlayKey,
                        painter: SkeletonOverlay(
                          analysis: _analysis,
                          currentFrame: _currentFrame,
                          interactive: true,
                          selectedLandmark: _moveAllMode
                              ? null
                              : _selectedLandmark,
                          correctedFrames: _correctedFrames,
                        ),
                        size: Size.infinite,
                      ),

                    // Magnifier (individual mode only)
                    if (_isZooming && _zoomPosition != null)
                      _buildMagnifier(constraints.biggest),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildMagnifier(Size videoSize) {
    const magnifierDiameter = 150.0;
    const magnifierRadius = magnifierDiameter / 2;
    const offsetAbove = 110.0;

    final touchX = _zoomPosition!.dx;
    final touchY = _zoomPosition!.dy;

    final magnifierTop = touchY - magnifierDiameter - offsetAbove;
    final flipBelow = magnifierTop < -magnifierRadius;
    final top = flipBelow
        ? touchY + offsetAbove * 0.4
        : touchY - magnifierDiameter - offsetAbove;
    final left = (touchX - magnifierRadius)
        .clamp(-magnifierRadius, videoSize.width - magnifierRadius);

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Container(
          width: magnifierDiameter,
          height: magnifierDiameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.cyanAccent, width: 2.5),
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
                    painter: _PoseMagnifierPainter(
                      image: _capturedFrame!,
                      focusPoint: _zoomPosition!,
                      sourceSize: videoSize,
                      magnifierRadius: magnifierRadius,
                      zoomFactor: 3.0,
                    ),
                  )
                : const ColoredBox(color: Colors.black54),
          ),
        ),
      ),
    );
  }

  Widget _buildFrameScrubber() {
    if (_analysis.frames.isEmpty) return const SizedBox.shrink();

    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous,
                color: Colors.white, size: 20),
            onPressed: () => _seekToFrame(_currentFrame - 1),
          ),
          IconButton(
            icon: Icon(
              _controller.value.isPlaying
                  ? Icons.pause
                  : Icons.play_arrow,
              color: Colors.white,
              size: 20,
            ),
            onPressed: () {
              setState(() {
                _controller.value.isPlaying
                    ? _controller.pause()
                    : _controller.play();
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.skip_next,
                color: Colors.white, size: 20),
            onPressed: () => _seekToFrame(_currentFrame + 1),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: _currentFrame.toDouble(),
                min: 0,
                max: (_analysis.frames.length - 1).toDouble(),
                onChanged: (v) => _seekToFrame(v.round()),
              ),
            ),
          ),
          Text(
            'F${_currentFrame + 1}/${_analysis.frames.length}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          if (_correctedFrames.contains(_currentFrame))
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.edit, color: Colors.yellow, size: 14),
            ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          // Mode toggle: Move All
          GestureDetector(
            onTap: () => setState(() {
              _moveAllMode = !_moveAllMode;
              _selectedLandmark = null;
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _moveAllMode
                    ? Colors.orange.shade800
                    : Colors.grey.shade800,
                borderRadius: BorderRadius.circular(8),
                border: _moveAllMode
                    ? Border.all(color: Colors.orangeAccent, width: 1.5)
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.open_with,
                      size: 16,
                      color: _moveAllMode
                          ? Colors.white
                          : Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    'Move All',
                    style: TextStyle(
                      fontSize: 12,
                      color: _moveAllMode
                          ? Colors.white
                          : Colors.grey,
                      fontWeight: _moveAllMode
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Selected landmark label (individual mode only)
          if (!_moveAllMode)
            Expanded(
              child: Text(
                _selectedLandmark != null
                    ? _formatLandmark(_selectedLandmark!)
                    : 'Tap a joint to select',
                style: TextStyle(
                  color: _selectedLandmark != null
                      ? Colors.cyanAccent
                      : Colors.grey,
                  fontSize: 13,
                ),
              ),
            )
          else
            const Expanded(
              child: Text(
                'Drag to shift skeleton',
                style: TextStyle(
                    color: Colors.orangeAccent, fontSize: 13),
              ),
            ),

          if (!_moveAllMode && _selectedLandmark != null)
            TextButton(
              onPressed: () =>
                  setState(() => _selectedLandmark = null),
              child:
                  const Text('Deselect', style: TextStyle(fontSize: 12)),
            ),
          TextButton(
            onPressed: _corrections.isEmpty
                ? null
                : () {
                    setState(() {
                      _corrections.clear();
                      _correctedFrames.clear();
                      _analysis = FormAnalysis.fromJson(
                          widget.analysis.toJson());
                    });
                  },
            child: const Text('Reset All',
                style:
                    TextStyle(fontSize: 12, color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructions() {
    if (_moveAllMode) {
      return Container(
        width: double.infinity,
        color: Colors.grey[900],
        padding: const EdgeInsets.all(12),
        child: const Text(
          'Move All: drag anywhere to shift the entire skeleton\n'
          'Tap "Move All" again to return to individual joint mode',
          style:
              TextStyle(color: Colors.white60, fontSize: 12, height: 1.4),
        ),
      );
    }
    return Container(
      width: double.infinity,
      color: Colors.grey[900],
      padding: const EdgeInsets.all(12),
      child: const Text(
        '1. Scrub to a frame where the skeleton is off\n'
        '2. Tap a joint (cyan circles) to select it, then drag to reposition\n'
        '3. Hold on a joint for zoom precision placement\n'
        '4. Use "Move All" if the whole skeleton is shifted\n'
        '5. Repeat for other bad frames, then tap Apply',
        style:
            TextStyle(color: Colors.white60, fontSize: 12, height: 1.4),
      ),
    );
  }

  String _formatLandmark(String key) {
    final name = key.split('.').last;
    return name
        .replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(0)}')
        .trim()
        .split(' ')
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }
}

/// Paints a zoomed portion of a captured video frame inside the magnifier circle.
class _PoseMagnifierPainter extends CustomPainter {
  final ui.Image image;
  final Offset focusPoint;
  final Size sourceSize;
  final double magnifierRadius;
  final double zoomFactor;

  const _PoseMagnifierPainter({
    required this.image,
    required this.focusPoint,
    required this.sourceSize,
    required this.magnifierRadius,
    required this.zoomFactor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(magnifierRadius, magnifierRadius);

    canvas.save();
    canvas.clipPath(Path()
      ..addOval(
          Rect.fromCircle(center: center, radius: magnifierRadius)));

    const pixelRatio = 2.0;
    final imgX = (focusPoint.dx / sourceSize.width) * image.width;
    final imgY = (focusPoint.dy / sourceSize.height) * image.height;

    final srcHalfW = (magnifierRadius / zoomFactor) * pixelRatio;
    final srcHalfH = (magnifierRadius / zoomFactor) * pixelRatio;

    final srcRect = Rect.fromCenter(
      center: Offset(imgX, imgY),
      width: srcHalfW * 2,
      height: srcHalfH * 2,
    );

    final dstRect = Rect.fromCircle(
        center: center, radius: magnifierRadius);

    canvas.drawImageRect(image, srcRect, dstRect, Paint());
    canvas.restore();

    // Crosshair
    final crossPaint = Paint()
      ..color = Colors.cyanAccent.withAlpha(200)
      ..strokeWidth = 1.0;
    canvas.drawLine(
        Offset(center.dx - 10, center.dy),
        Offset(center.dx + 10, center.dy),
        crossPaint);
    canvas.drawLine(
        Offset(center.dx, center.dy - 10),
        Offset(center.dx, center.dy + 10),
        crossPaint);
  }

  @override
  bool shouldRepaint(_PoseMagnifierPainter old) =>
      old.focusPoint != focusPoint || old.image != image;
}
