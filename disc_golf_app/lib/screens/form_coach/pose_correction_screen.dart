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
/// Three correction modes:
/// - **Individual mode** (default): tap a joint to select it, drag to
///   reposition it, or hold for precision zoom before placing.
/// - **Move All mode**: drag anywhere to shift the entire skeleton as a unit.
/// - **Re-place All mode**: guided sequential placement of all 12 landmarks
///   one at a time. Ideal when the skeleton is badly misaligned on a frame.
///   The user taps where each joint is; after all are placed the full skeleton
///   is shown for review before committing.
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

// ---------------------------------------------------------------------------
// Sequential placement data
// ---------------------------------------------------------------------------

/// One entry in the guided sequential placement sequence.
class _PlacementStep {
  final String key;        // PoseLandmarkType.xxx
  final String label;      // Human-readable name shown in banner
  final String side;       // 'R' or 'L' for the side badge

  const _PlacementStep(this.key, this.label, this.side);
}

/// The 12 landmarks in the order we guide the user through them.
/// Top-to-bottom, right-then-left to match natural visual scanning.
const List<_PlacementStep> _kPlacementSequence = [
  _PlacementStep('PoseLandmarkType.rightShoulder', 'Right Shoulder', 'R'),
  _PlacementStep('PoseLandmarkType.leftShoulder',  'Left Shoulder',  'L'),
  _PlacementStep('PoseLandmarkType.rightElbow',    'Right Elbow',    'R'),
  _PlacementStep('PoseLandmarkType.leftElbow',     'Left Elbow',     'L'),
  _PlacementStep('PoseLandmarkType.rightWrist',    'Right Wrist',    'R'),
  _PlacementStep('PoseLandmarkType.leftWrist',     'Left Wrist',     'L'),
  _PlacementStep('PoseLandmarkType.rightHip',      'Right Hip',      'R'),
  _PlacementStep('PoseLandmarkType.leftHip',       'Left Hip',       'L'),
  _PlacementStep('PoseLandmarkType.rightKnee',     'Right Knee',     'R'),
  _PlacementStep('PoseLandmarkType.leftKnee',      'Left Knee',      'L'),
  _PlacementStep('PoseLandmarkType.rightAnkle',    'Right Ankle',    'R'),
  _PlacementStep('PoseLandmarkType.leftAnkle',     'Left Ankle',     'L'),
];

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

  // Mode toggle: move-all vs individual joint vs sequential re-place
  bool _moveAllMode = false;

  // Sequential re-place mode state
  bool _sequentialMode = false;
  int _sequentialStep = 0; // index into _kPlacementSequence
  /// Positions placed so far in the current sequential session (image coords).
  final Map<String, Offset> _sequentialPlacements = {};
  bool _sequentialReviewMode = false; // true after all 12 are placed

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
  // Gesture handling — routes to active mode
  // ---------------------------------------------------------------------------

  void _onTapDown(TapDownDetails details) {
    if (_analysis.frames.isEmpty) return;

    if (_sequentialMode && !_sequentialReviewMode) {
      _onSequentialTap(details.localPosition);
      return;
    }

    if (_sequentialMode && _sequentialReviewMode) {
      // In review mode tapping a placed dot re-selects it for adjustment via
      // the existing individual mechanism — re-use nearestLandmark.
      final frame = _analysis.frames[_currentFrame];
      final nearest = SkeletonOverlay.nearestLandmark(
        details.localPosition,
        _videoWidgetSize,
        frame,
      );
      setState(() => _selectedLandmark = nearest);
      return;
    }

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
  // Sequential re-place mode
  // ---------------------------------------------------------------------------

  /// Enter sequential placement mode. Pauses video, hides existing skeleton
  /// until the user has placed all landmarks.
  void _enterSequentialMode() {
    _controller.pause();
    setState(() {
      _sequentialMode = true;
      _sequentialStep = 0;
      _sequentialReviewMode = false;
      _sequentialPlacements.clear();
      _moveAllMode = false;
      _selectedLandmark = null;
    });
  }

  /// Called when the user taps the frame during sequential placement.
  void _onSequentialTap(Offset canvasPos) {
    if (_sequentialStep >= _kPlacementSequence.length) return;

    final step = _kPlacementSequence[_sequentialStep];
    final frame = _analysis.frames[_currentFrame];
    final imagePos = SkeletonOverlay.canvasToImage(canvasPos, _videoWidgetSize, frame);

    setState(() {
      _sequentialPlacements[step.key] = imagePos;

      if (_sequentialStep < _kPlacementSequence.length - 1) {
        _sequentialStep++;
      } else {
        // All landmarks placed — enter review mode
        _sequentialReviewMode = true;
        _applySequentialToFrame();
      }
    });
  }

  /// Jump back to a specific step (user taps "Redo" chip on a placed joint).
  void _redoSequentialStep(int stepIndex) {
    setState(() {
      _sequentialStep = stepIndex;
      _sequentialReviewMode = false;
      // Remove placements from this step onward
      for (int i = stepIndex; i < _kPlacementSequence.length; i++) {
        _sequentialPlacements.remove(_kPlacementSequence[i].key);
      }
      _revertFrameToSequentialPlacements();
    });
  }

  /// Write _sequentialPlacements into the current frame's keyPoints and
  /// record them as corrections so Catmull-Rom propagation picks them up.
  void _applySequentialToFrame() {
    final frame = _analysis.frames[_currentFrame];
    final postureService =
        Provider.of<PostureAnalysisService>(context, listen: false);

    for (final entry in _sequentialPlacements.entries) {
      frame.keyPoints[entry.key] = entry.value;
      _corrections
          .putIfAbsent(entry.key, () => {})[_currentFrame] = entry.value;
    }
    _correctedFrames.add(_currentFrame);
    postureService.recalculateFrameAngles(frame);
  }

  /// Revert the current frame's keypoints to only the placements confirmed so
  /// far (used when the user re-does a step mid-sequence).
  void _revertFrameToSequentialPlacements() {
    // Re-apply only the placed landmarks
    final frame = _analysis.frames[_currentFrame];
    final postureService =
        Provider.of<PostureAnalysisService>(context, listen: false);
    for (final entry in _sequentialPlacements.entries) {
      frame.keyPoints[entry.key] = entry.value;
    }
    postureService.recalculateFrameAngles(frame);
  }

  /// Commit the sequential placements and leave sequential mode.
  void _commitSequential() {
    _applySequentialToFrame();
    setState(() {
      _sequentialMode = false;
      _sequentialReviewMode = false;
      _sequentialPlacements.clear();
    });
  }

  /// Discard sequential mode without saving changes.
  void _cancelSequential() {
    // Restore original keypoints for this frame from widget.analysis
    final original = FormAnalysis.fromJson(widget.analysis.toJson());
    if (_currentFrame < original.frames.length) {
      final origFrame = original.frames[_currentFrame];
      final frame = _analysis.frames[_currentFrame];
      frame.keyPoints
        ..clear()
        ..addAll(origFrame.keyPoints);
    }
    setState(() {
      _sequentialMode = false;
      _sequentialReviewMode = false;
      _sequentialPlacements.clear();
    });
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
          if (!_sequentialMode)
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
                if (_sequentialMode)
                  _buildSequentialBanner()
                else ...[
                  _buildFrameScrubber(),
                  _buildControls(),
                  _buildInstructions(),
                ],
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
                onTapDown: _onTapDown,
                onPanUpdate: (_sequentialMode && !_sequentialReviewMode)
                    ? null
                    : _onPanUpdate,
                onLongPressStart: (_moveAllMode || _sequentialMode)
                    ? null
                    : _onLongPressStart,
                onLongPressMoveUpdate: (_moveAllMode || _sequentialMode)
                    ? null
                    : _onLongPressMoveUpdate,
                onLongPressEnd: (_moveAllMode || _sequentialMode)
                    ? null
                    : _onLongPressEnd,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Video
                    RepaintBoundary(
                      key: _videoBoundaryKey,
                      child: VideoPlayer(_controller),
                    ),

                    // Skeleton overlay — hidden during active sequential
                    // placement; shown once in review mode or normal mode.
                    if (_analysis.frames.isNotEmpty &&
                        (!_sequentialMode || _sequentialReviewMode))
                      CustomPaint(
                        key: _overlayKey,
                        painter: SkeletonOverlay(
                          analysis: _analysis,
                          currentFrame: _currentFrame,
                          interactive: true,
                          selectedLandmark:
                              (_moveAllMode || _sequentialMode)
                                  ? null
                                  : _selectedLandmark,
                          correctedFrames: _correctedFrames,
                        ),
                        size: Size.infinite,
                      ),

                    // Sequential placement dots — shown while user is placing
                    if (_sequentialMode && !_sequentialReviewMode)
                      CustomPaint(
                        painter: _SequentialPlacementPainter(
                          placements: _sequentialPlacements,
                          currentStepKey: _sequentialStep <
                                  _kPlacementSequence.length
                              ? _kPlacementSequence[_sequentialStep].key
                              : null,
                          frame: _analysis.frames.isNotEmpty
                              ? _analysis.frames[_currentFrame]
                              : null,
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

  // ---------------------------------------------------------------------------
  // Sequential mode UI
  // ---------------------------------------------------------------------------

  Widget _buildSequentialBanner() {
    if (_sequentialReviewMode) {
      return _buildSequentialReviewBanner();
    }

    final step = _kPlacementSequence[_sequentialStep];
    final remaining = _kPlacementSequence.length - _sequentialStep;

    return Container(
      color: Colors.indigo.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: _sequentialStep / _kPlacementSequence.length,
              backgroundColor: Colors.white24,
              color: Colors.indigoAccent,
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // Side badge
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: step.side == 'R'
                      ? Colors.blue.shade700
                      : Colors.teal.shade700,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  step.side,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tap to place: ${step.label}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${_sequentialStep + 1} of ${_kPlacementSequence.length}  •  $remaining remaining',
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 12),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: _cancelSequential,
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ),
            ],
          ),
          // Previously placed chips — tap to redo
          if (_sequentialPlacements.isNotEmpty) ...[
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (int i = 0; i < _sequentialStep; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GestureDetector(
                        onTap: () => _redoSequentialStep(i),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white12,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: Colors.white24, width: 1),
                          ),
                          child: Text(
                            _kPlacementSequence[i].label,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSequentialReviewBanner() {
    return Container(
      color: Colors.green.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Review skeleton — tap a joint to re-place it',
            style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'All 12 landmarks placed. Drag any joint to fine-tune, then confirm.',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    // Restart from step 0
                    _redoSequentialStep(0);
                  },
                  icon: const Icon(Icons.refresh,
                      size: 16, color: Colors.white70),
                  label: const Text('Re-do All',
                      style:
                          TextStyle(color: Colors.white70, fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white30),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _commitSequential,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Confirm',
                      style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ],
          ),
        ],
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

          // Re-place All button
          GestureDetector(
            onTap: _enterSequentialMode,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.indigo.shade900,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Colors.indigoAccent.withAlpha(180),
                    width: 1.5),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.place, size: 16, color: Colors.indigoAccent),
                  SizedBox(width: 4),
                  Text(
                    'Re-place All',
                    style: TextStyle(
                        fontSize: 12,
                        color: Colors.indigoAccent,
                        fontWeight: FontWeight.bold),
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
        '2. Tap a joint (cyan/orange/red circles) to select, then drag to move\n'
        '3. Hold on a joint for zoom precision placement\n'
        '4. Use "Move All" if the whole skeleton is shifted\n'
        '5. Use "Re-place All" to place all joints from scratch, one by one\n'
        '6. Repeat for other bad frames, then tap Apply',
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

// ---------------------------------------------------------------------------
// Sequential placement painter
// ---------------------------------------------------------------------------

/// Draws confirmed placement dots during guided sequential mode.
/// Each placed joint is shown as a labeled dot. The slot for the current
/// step pulses with a dashed ring to indicate where the user should tap.
class _SequentialPlacementPainter extends CustomPainter {
  final Map<String, Offset> placements; // image-coord positions
  final String? currentStepKey;
  final FormFrame? frame;

  const _SequentialPlacementPainter({
    required this.placements,
    required this.currentStepKey,
    required this.frame,
  });

  Offset _scale(Offset pt, Size size) {
    final f = frame;
    if (f == null) return pt;
    final w = f.imageWidth;
    final h = f.imageHeight;
    if (w != null && h != null && w > 0 && h > 0) {
      return Offset(pt.dx * size.width / w, pt.dy * size.height / h);
    }
    if (pt.dx <= 1.0 && pt.dy <= 1.0) {
      return Offset(pt.dx * size.width, pt.dy * size.height);
    }
    return Offset(pt.dx * size.width / 640, pt.dy * size.height / 640);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final dotPaint = Paint()..color = Colors.indigoAccent;
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    for (final step in _kPlacementSequence) {
      final pos = placements[step.key];
      if (pos == null) continue;
      final scaled = _scale(pos, size);

      canvas.drawCircle(scaled, 7, dotPaint);
      canvas.drawCircle(scaled, 7, borderPaint);

      // Label
      final tp = TextPainter(
        text: TextSpan(
          text: step.label.split(' ').first, // "Right"/"Left" → just joint name
          style: const TextStyle(
              color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, scaled + const Offset(9, -7));
    }
  }

  @override
  bool shouldRepaint(_SequentialPlacementPainter old) =>
      old.placements.length != placements.length ||
      old.currentStepKey != currentStepKey;
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
