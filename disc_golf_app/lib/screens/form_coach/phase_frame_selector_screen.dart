import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../utils/pro_data_parser.dart';
import 'posture_analysis_screen.dart';

/// Screen where the user marks which video frame corresponds to each throw phase
/// (reach back, power pocket, release, follow through) before analysis runs.
///
/// The resulting [phaseTimestamps] map (phase key → absolute ms) is passed to
/// [PostureAnalysisScreen], which uses them as checkpoints for guided
/// per-phase pose verification after the full analysis completes.
class PhaseFrameSelectorScreen extends StatefulWidget {
  final String videoPath;
  final String? proPlayer;
  final int analysisStartMs;
  final int analysisEndMs;
  final int analysisFrameCount;
  final String throwType;

  const PhaseFrameSelectorScreen({
    super.key,
    required this.videoPath,
    this.proPlayer,
    required this.analysisStartMs,
    required this.analysisEndMs,
    required this.analysisFrameCount,
    this.throwType = 'BH',
  });

  @override
  State<PhaseFrameSelectorScreen> createState() =>
      _PhaseFrameSelectorScreenState();
}

class _PhaseFrameSelectorScreenState extends State<PhaseFrameSelectorScreen> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  final Map<String, int> _phaseTimestamps = {};

  static const _phaseIcons = <String, IconData>{
    'reach_back': Icons.arrow_back,
    'power_pocket': Icons.sports_handball,
    'release': Icons.rocket_launch,
    'follow_through': Icons.redo,
    'wind_up': Icons.rotate_right,
  };

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath));
    await _controller!.initialize();
    await _controller!
        .seekTo(Duration(milliseconds: widget.analysisStartMs));
    _controller!.addListener(_onTick);
    setState(() => _isInitialized = true);
  }

  void _onTick() {
    if (_controller == null || !mounted) return;
    final pos = _controller!.value.position.inMilliseconds;
    if (pos >= widget.analysisEndMs) {
      _controller!.pause();
      _controller!
          .seekTo(Duration(milliseconds: widget.analysisEndMs));
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  List<String> get _phases =>
      ProBaselineParser.getPhaseNames(widget.throwType);

  bool get _allPhasesSet =>
      _phases.every((p) => _phaseTimestamps.containsKey(p));

  void _markPhase(String phase) {
    final pos =
        _controller?.value.position.inMilliseconds ?? widget.analysisStartMs;
    final clamped =
        pos.clamp(widget.analysisStartMs, widget.analysisEndMs);
    setState(() => _phaseTimestamps[phase] = clamped);
  }

  void _proceed() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => PostureAnalysisScreen(
          videoPath: widget.videoPath,
          proPlayer: widget.proPlayer,
          analysisStartMs: widget.analysisStartMs,
          analysisEndMs: widget.analysisEndMs,
          analysisFrameCount: widget.analysisFrameCount,
          phaseTimestamps: Map.from(_phaseTimestamps),
          throwType: widget.throwType,
        ),
      ),
    );
  }

  String _formatMs(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';

  String _formatPhase(String key) => key
      .split('_')
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Phase Frames'),
        actions: [
          TextButton(
            onPressed: _allPhasesSet ? _proceed : null,
            child: const Text('Analyze'),
          ),
        ],
      ),
      body: !_isInitialized
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Video preview
                Expanded(
                  flex: 5,
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

                // Video controls
                _buildVideoControls(),

                // Instructions
                Container(
                  width: double.infinity,
                  color: Colors.grey[900],
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 6),
                  child: const Text(
                    'Use ◀ ▶ to step frame-by-frame, then tap a phase card to mark it.',
                    style:
                        TextStyle(color: Colors.white60, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),

                // Phase cards
                Expanded(
                  flex: 4,
                  child: GridView.count(
                    crossAxisCount: 2,
                    padding: const EdgeInsets.all(8),
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 2.6,
                    children: _phases
                        .map((p) => _buildPhaseCard(p))
                        .toList(),
                  ),
                ),
              ],
            ),
    );
  }

  /// One video frame at 30 fps — the smallest useful step for frame picking.
  static const int _frameStepMs = 33;
  /// Coarse skip for jumping to the rough area quickly.
  static const int _coarseSkipMs = 500;

  void _stepVideo(int deltaMs) {
    if (_controller == null) return;
    final current = _controller!.value.position.inMilliseconds;
    final target = (current + deltaMs)
        .clamp(widget.analysisStartMs, widget.analysisEndMs);
    _controller!.seekTo(Duration(milliseconds: target));
  }

  Widget _buildVideoControls() {
    if (_controller == null) return const SizedBox.shrink();
    final total = widget.analysisEndMs - widget.analysisStartMs;
    final pos = _controller!.value.position.inMilliseconds;
    final relative =
        (pos - widget.analysisStartMs).clamp(0, total).toDouble();
    final isPlaying = _controller!.value.isPlaying;

    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: step buttons + time
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Coarse back
              IconButton(
                icon: const Icon(Icons.fast_rewind,
                    color: Colors.white70, size: 22),
                tooltip: '-0.5s',
                onPressed: () => _stepVideo(-_coarseSkipMs),
              ),
              // Single-frame back
              IconButton(
                icon: const Icon(Icons.skip_previous,
                    color: Colors.white, size: 26),
                tooltip: '-1 frame',
                onPressed: () => _stepVideo(-_frameStepMs),
              ),
              // Play / pause
              IconButton(
                icon: Icon(
                  isPlaying ? Icons.pause_circle : Icons.play_circle,
                  color: Colors.white,
                  size: 36,
                ),
                onPressed: () => setState(() {
                  isPlaying ? _controller!.pause() : _controller!.play();
                }),
              ),
              // Single-frame forward
              IconButton(
                icon: const Icon(Icons.skip_next,
                    color: Colors.white, size: 26),
                tooltip: '+1 frame',
                onPressed: () => _stepVideo(_frameStepMs),
              ),
              // Coarse forward
              IconButton(
                icon: const Icon(Icons.fast_forward,
                    color: Colors.white70, size: 22),
                tooltip: '+0.5s',
                onPressed: () => _stepVideo(_coarseSkipMs),
              ),
              const SizedBox(width: 8),
              Text(
                _formatMs(pos.clamp(
                    widget.analysisStartMs, widget.analysisEndMs)),
                style: const TextStyle(
                    color: Colors.white, fontSize: 13),
              ),
            ],
          ),
          // Row 2: position slider for coarse navigation
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: relative,
              min: 0,
              max: total.toDouble().clamp(1, double.infinity),
              onChanged: (v) => _controller!.seekTo(Duration(
                  milliseconds: widget.analysisStartMs + v.round())),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhaseCard(String phase) {
    final isSet = _phaseTimestamps.containsKey(phase);
    final label = _formatPhase(phase);
    final icon = _phaseIcons[phase] ?? Icons.flag;

    return GestureDetector(
      onTap: () => _markPhase(phase),
      child: Container(
        decoration: BoxDecoration(
          color: isSet ? Colors.green.shade900 : Colors.grey.shade800,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSet ? Colors.greenAccent : Colors.grey.shade600,
            width: isSet ? 1.5 : 1,
          ),
        ),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon,
                size: 20,
                color: isSet ? Colors.greenAccent : Colors.grey),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: isSet ? Colors.white : Colors.grey,
                    ),
                  ),
                  Text(
                    isSet
                        ? _formatMs(_phaseTimestamps[phase]!)
                        : 'Tap to mark',
                    style: TextStyle(
                      fontSize: 11,
                      color: isSet
                          ? Colors.greenAccent
                          : Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
            if (isSet)
              const Icon(Icons.check_circle,
                  color: Colors.greenAccent, size: 18),
          ],
        ),
      ),
    );
  }
}
