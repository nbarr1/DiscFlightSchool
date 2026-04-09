import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import '../../services/feedback_service.dart';
import '../../services/posture_analysis_service.dart';
import '../../services/knowledge_base_service.dart';
import '../knowledge_base/article_detail_screen.dart';
import '../../services/video_frame_extractor.dart';
import '../../models/form_analysis.dart';
import '../../utils/constants.dart';
import '../../utils/pro_data_parser.dart';
import '../../widgets/skeleton_overlay.dart';
import '../../services/form_history_service.dart';
// comparison_screen.dart is ARCHIVED (interpolated frames, not measured data)
import 'phase_comparison_screen.dart';
import 'pose_correction_screen.dart';
import 'dart:io';

class PostureAnalysisScreen extends StatefulWidget {
  final String? videoPath;
  final FormAnalysis? analysis;
  final String? proPlayer;
  final int? analysisStartMs;
  final int? analysisEndMs;
  final int? analysisFrameCount;
  /// Phase timestamps from [PhaseFrameSelectorScreen]: phase key → absolute ms.
  /// When provided, guided per-phase verification runs after full analysis.
  final Map<String, int>? phaseTimestamps;
  final String throwType;
  final bool isLeftHanded;

  const PostureAnalysisScreen({
    Key? key,
    this.videoPath,
    this.analysis,
    this.proPlayer,
    this.analysisStartMs,
    this.analysisEndMs,
    this.analysisFrameCount,
    this.phaseTimestamps,
    this.throwType = 'BH',
    this.isLeftHanded = false,
  }) : super(key: key);

  @override
  State<PostureAnalysisScreen> createState() => _PostureAnalysisScreenState();
}

class _PostureAnalysisScreenState extends State<PostureAnalysisScreen> {
  static const _frameIntervalMs = VideoFrameExtractor.defaultIntervalMs;

  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isAnalyzing = false;
  FormAnalysis? _analysis;
  int _currentFrame = 0;
  bool _inAnalysisRange = false;
  bool _showSkeleton = true;
  bool _showThresholds = true;

  // Phase verification state (used when phaseTimestamps != null)
  bool _isVerifying = false;
  int _verificationPhaseIndex = 0;

  // Pro selector state (allows switching pro after analysis)
  String? _selectedPro;
  String _selectedThrowType = 'BH';

  // Pro deviation score — computed from measured phase snapshots, null when no pro selected
  Map<String, Map<String, double>>? _proPhaseAngles;
  double? _proDeviationScore;

  // Manual phase selection fallback (used when phaseTimestamps == null)
  bool _phaseSelectionMode = false;
  final Map<String, int> _phaseFrames = {};

  List<MapEntry<String, int>> get _sortedPhases {
    if (widget.phaseTimestamps == null) return [];
    final entries = widget.phaseTimestamps!.entries.toList();
    entries.sort((a, b) => a.value.compareTo(b.value));
    return entries;
  }

  @override
  void initState() {
    super.initState();
    _analysis = widget.analysis;
    _selectedPro = widget.proPlayer;
    _selectedThrowType = widget.throwType;
    if (widget.videoPath != null) {
      _initializeVideo();
      _startAnalysis();
    }
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath!));
    await _controller!.initialize();
    setState(() {
      _isInitialized = true;
    });
    _controller!.addListener(() {
      if (_analysis != null) {
        final position = _controller!.value.position.inMilliseconds;
        final startMs = widget.analysisStartMs ?? 0;
        final endMs = widget.analysisEndMs ?? (startMs + _analysis!.frames.length * _frameIntervalMs);
        final inRange = position >= startMs && position <= endMs;
        // Frames extracted at _frameIntervalMs intervals from the trim start
        final frameNumber = ((position - startMs) / _frameIntervalMs).floor().clamp(0, _analysis!.frames.length - 1);
        if (frameNumber != _currentFrame || inRange != _inAnalysisRange) {
          setState(() {
            _currentFrame = frameNumber;
            _inAnalysisRange = inRange;
          });
        }
      }
    });
  }

  Future<void> _startAnalysis() async {
    setState(() {
      _isAnalyzing = true;
    });

    final postureService = Provider.of<PostureAnalysisService>(context, listen: false);
    final analysis = await postureService.analyzeForm(
      widget.videoPath!,
      startMs: widget.analysisStartMs ?? 0,
      frameCount: widget.analysisFrameCount ?? 30,
      isLeftHanded: widget.isLeftHanded,
      throwType: widget.throwType,
    );

    setState(() {
      _analysis = analysis;
      _isAnalyzing = false;
    });

    // Persist this session to history
    if (!analysis.isMock && mounted) {
      final avgAngles = <String, double>{};
      if (analysis.frames.isNotEmpty) {
        for (final f in analysis.frames) {
          for (final e in f.angles.entries) {
            avgAngles[e.key] = (avgAngles[e.key] ?? 0) + e.value;
          }
        }
        avgAngles.updateAll((k, v) => v / analysis.frames.length);
      }
      final record = FormSessionRecord(
        id: analysis.id,
        date: analysis.date,
        score: analysis.score,
        throwType: widget.throwType,
        proPlayer: widget.proPlayer,
        frameCount: analysis.frames.length,
        avgAngles: avgAngles,
      );
      Provider.of<FormHistoryService>(context, listen: false).saveSession(record);
    }

    if (widget.phaseTimestamps != null && widget.phaseTimestamps!.isNotEmpty) {
      // Guided per-phase verification after a short pause
      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted || _analysis == null) return;
        _startPhaseVerification();
      });
    } else {
      // Generic verification banner
      Future.delayed(const Duration(seconds: 3), () {
        if (!mounted || _analysis == null) return;
        _showFormVerificationBanner();
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Phase verification
  // ---------------------------------------------------------------------------

  int _frameForPhase(int absoluteMs) {
    if (_analysis == null) return 0;
    final startMs = widget.analysisStartMs ?? 0;
    return ((absoluteMs - startMs) / _frameIntervalMs)
        .floor()
        .clamp(0, _analysis!.frames.length - 1);
  }

  void _seekToPhase(int absoluteMs) {
    if (_controller == null || _analysis == null) return;
    _controller!.seekTo(Duration(milliseconds: absoluteMs));
    setState(() {
      _currentFrame = _frameForPhase(absoluteMs);
    });
  }

  void _startPhaseVerification() {
    final sorted = _sortedPhases;
    if (sorted.isEmpty) return;
    setState(() {
      _isVerifying = true;
      _verificationPhaseIndex = 0;
    });
    _controller?.pause();
    _seekToPhase(sorted[0].value);
  }

  void _approveCurrentPhase() {
    final sorted = _sortedPhases;
    final nextIndex = _verificationPhaseIndex + 1;
    if (nextIndex < sorted.length) {
      setState(() => _verificationPhaseIndex = nextIndex);
      _seekToPhase(sorted[nextIndex].value);
    } else {
      setState(() => _isVerifying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All phases verified!')),
      );
    }
  }

  Future<void> _fixCurrentPhase() async {
    if (_analysis == null || widget.videoPath == null) return;
    final sorted = _sortedPhases;
    final phaseMs = sorted[_verificationPhaseIndex].value;
    final initialFrame = _frameForPhase(phaseMs);

    final corrected = await Navigator.push<FormAnalysis>(
      context,
      MaterialPageRoute(
        builder: (_) => PoseCorrectionScreen(
          analysis: _analysis!,
          videoPath: widget.videoPath!,
          analysisStartMs: widget.analysisStartMs,
          analysisEndMs: widget.analysisEndMs,
          initialFrame: initialFrame,
        ),
      ),
    );

    if (corrected != null && mounted) {
      setState(() => _analysis = corrected);
    }

    if (mounted) _approveCurrentPhase();
  }

  void _showFormVerificationBanner() {
    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        content: const Text('Does the pose overlay match your body?'),
        leading: const Icon(Icons.help_outline),
        actions: [
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              FeedbackService.log({
                'verified': false,
                'type': 'form_analysis',
              });
              _showCorrectionOptions();
            },
            child: const Text("It's Off"),
          ),
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              FeedbackService.log({
                'verified': true,
                'type': 'form_analysis',
              });
            },
            child: const Text('Looks Good'),
          ),
        ],
      ),
    );
  }

  void _showCorrectionOptions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'How would you like to fix it?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: Colors.blue),
              title: const Text('Retake Tips'),
              subtitle: const Text(
                  'Get advice on camera angle and lighting'),
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        'Tip: Use a side-view camera angle with good lighting for best results.'),
                    duration: Duration(seconds: 5),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.orange),
              title: const Text('Correct Manually'),
              subtitle: const Text(
                  'Drag joints to the right positions frame by frame'),
              onTap: () {
                Navigator.pop(ctx);
                _navigateToCorrection();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _navigateToCorrection() async {
    if (_analysis == null || widget.videoPath == null) return;

    final corrected = await Navigator.push<FormAnalysis>(
      context,
      MaterialPageRoute(
        builder: (_) => PoseCorrectionScreen(
          analysis: _analysis!,
          videoPath: widget.videoPath!,
          analysisStartMs: widget.analysisStartMs,
          analysisEndMs: widget.analysisEndMs,
        ),
      ),
    );

    if (corrected != null && mounted) {
      setState(() {
        _analysis = corrected;
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Widget _buildPhaseVerificationCard() {
    final sorted = _sortedPhases;
    if (_verificationPhaseIndex >= sorted.length) return const SizedBox.shrink();

    final phaseKey = sorted[_verificationPhaseIndex].key;
    final phaseName = _formatPhaseName(phaseKey);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.blue.shade900,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.verified_user,
                    color: Colors.lightBlue, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Verify Phase: $phaseName',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Colors.white,
                    ),
                  ),
                ),
                // Progress dots
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(sorted.length, (i) {
                    final color = i < _verificationPhaseIndex
                        ? Colors.greenAccent
                        : i == _verificationPhaseIndex
                            ? Colors.white
                            : Colors.grey;
                    return Container(
                      margin: const EdgeInsets.only(left: 4),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color,
                      ),
                    );
                  }),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Is the pose overlay correct for this frame?',
              style: TextStyle(color: Colors.blue.shade100, fontSize: 13),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _fixCurrentPhase,
                    icon: const Icon(Icons.edit,
                        size: 16, color: Colors.orange),
                    label: const Text('Fix It',
                        style: TextStyle(color: Colors.orange)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.orange),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _approveCurrentPhase,
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Looks Good'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final postureService = Provider.of<PostureAnalysisService>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Form Analysis'),
        actions: [
          if (_analysis != null)
            IconButton(
              icon: Icon(
                _showSkeleton ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () {
                setState(() {
                  _showSkeleton = !_showSkeleton;
                });
              },
              tooltip: _showSkeleton ? 'Hide Skeleton' : 'Show Skeleton',
            ),
          if (_analysis != null)
            IconButton(
              icon: Icon(
                _showThresholds ? Icons.straighten : Icons.straighten_outlined,
              ),
              onPressed: () {
                setState(() {
                  _showThresholds = !_showThresholds;
                });
              },
              tooltip: _showThresholds ? 'Hide Ideal Angles' : 'Show Ideal Angles',
            ),
        ],
      ),
      body: _isAnalyzing
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Analyzing your form...'),
                  SizedBox(height: 8),
                  Text(
                    'Detecting pose and calculating joint angles',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            )
          : _analysis == null
              ? const Center(child: Text('No analysis available'))
              : SingleChildScrollView(
                  child: Column(
                    children: [
                      // Mock data warning — shown when pose detection failed
                      if (_analysis!.isMock) _buildMockWarning(),

                      // Video player with skeleton overlay
                      if (_isInitialized && _controller != null)
                        _buildVideoWithOverlay(),

                      // Phase verification card (shown between video and controls)
                      if (_isVerifying) _buildPhaseVerificationCard(),

                      // Video controls
                      if (_isInitialized && _controller != null)
                        _buildVideoControls(),

                      // Score card
                      _buildScoreCard(),

                      // Pro player selector (switch without re-analyzing)
                      _buildProSelector(),

                      // Phase selection / comparison
                      if (_selectedPro != null && _analysis != null)
                        _buildPhaseComparisonSection(),

                      // Angle charts
                      _buildAngleCharts(),

                      // Suggestions
                      _buildSuggestions(postureService),
                    ],
                  ),
                ),
    );
  }

  Widget _buildMockWarning() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withAlpha(180),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.shade400, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.amber, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pose detection failed',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  'No person was detected in this video. The scores and '
                  'angles shown are simulated and do not reflect your form. '
                  'Try recording from the side with good lighting.',
                  style: TextStyle(
                      color: Colors.red.shade100, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoWithOverlay() {
    return Stack(
      children: [
        AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: VideoPlayer(_controller!),
        ),
        if (_showSkeleton && _inAnalysisRange && _analysis != null && _analysis!.frames.isNotEmpty)
          Positioned.fill(
            child: AspectRatio(
              aspectRatio: _controller!.value.aspectRatio,
              child: CustomPaint(
                painter: SkeletonOverlay(
                  analysis: _analysis!,
                  currentFrame: _currentFrame,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildVideoControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.black87,
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white),
                onPressed: () {
                  final pos = _controller!.value.position -
                      Duration(milliseconds: _frameIntervalMs);
                  _controller!.seekTo(pos.isNegative ? Duration.zero : pos);
                  setState(() {
                    _currentFrame = (_currentFrame - 1).clamp(0, (_analysis?.frames.length ?? 1) - 1);
                  });
                },
                tooltip: 'Previous Frame',
              ),
              IconButton(
                icon: Icon(
                  _controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: () {
                  setState(() {
                    _controller!.value.isPlaying
                        ? _controller!.pause()
                        : _controller!.play();
                  });
                },
              ),
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white),
                onPressed: () {
                  final pos = _controller!.value.position +
                      Duration(milliseconds: _frameIntervalMs);
                  _controller!.seekTo(pos);
                  setState(() {
                    _currentFrame = (_currentFrame + 1).clamp(0, (_analysis?.frames.length ?? 1) - 1);
                  });
                },
                tooltip: 'Next Frame',
              ),
              Expanded(
                child: Slider(
                  value: _controller!.value.position.inMilliseconds
                      .toDouble()
                      .clamp(0, _controller!.value.duration.inMilliseconds.toDouble()),
                  min: 0,
                  max: _controller!.value.duration.inMilliseconds.toDouble(),
                  onChanged: (value) {
                    _controller!.seekTo(Duration(milliseconds: value.toInt()));
                    if (_analysis != null) {
                      final frame = (value / _frameIntervalMs).floor().clamp(0, _analysis!.frames.length - 1);
                      setState(() {
                        _currentFrame = frame;
                      });
                    }
                  },
                ),
              ),
              Text(
                '${_formatDuration(_controller!.value.position)} / ${_formatDuration(_controller!.value.duration)}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
          if (_analysis != null)
            Text(
              'Frame ${_currentFrame + 1} / ${_analysis!.frames.length}',
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
        ],
      ),
    );
  }

  Widget _buildProSelector() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Compare With Pro',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _selectedPro,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Select a pro player',
                isDense: true,
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('None'),
                ),
                ...AppConstants.proPlayers.map((pro) {
                  return DropdownMenuItem(
                    value: pro,
                    child: Text(pro),
                  );
                }),
              ],
              onChanged: (pro) async {
                setState(() {
                  _selectedPro = pro;
                  _proPhaseAngles = null;
                  _proDeviationScore = null;
                  _phaseSelectionMode = false;
                  _phaseFrames.clear();
                });
                if (pro != null && _analysis != null) {
                  final angles = await ProBaselineParser.getPhaseAngles(
                      pro, _selectedThrowType);
                  final score = PostureAnalysisService.computeProDeviationScore(
                      _analysis!.frames, angles, _selectedThrowType);
                  setState(() {
                    _proPhaseAngles = angles;
                    _proDeviationScore = score;
                  });
                }
              },
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'BH', label: Text('Backhand')),
                ButtonSegment(value: 'FH', label: Text('Forehand')),
              ],
              selected: {_selectedThrowType},
              onSelectionChanged: (selection) async {
                setState(() {
                  _selectedThrowType = selection.first;
                  _proPhaseAngles = null;
                  _proDeviationScore = null;
                  _phaseSelectionMode = false;
                  _phaseFrames.clear();
                });
                if (_selectedPro != null && _analysis != null) {
                  final angles = await ProBaselineParser.getPhaseAngles(
                      _selectedPro!, selection.first);
                  final score = PostureAnalysisService.computeProDeviationScore(
                      _analysis!.frames, angles, selection.first);
                  setState(() {
                    _proPhaseAngles = angles;
                    _proDeviationScore = score;
                  });
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreCard() {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              'Pro Deviation Score',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            if (_proDeviationScore != null) ...[
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 120,
                    height: 120,
                    child: CircularProgressIndicator(
                      value: _proDeviationScore! / 100,
                      strokeWidth: 10,
                      backgroundColor: Colors.grey[800],
                      valueColor: AlwaysStoppedAnimation<Color>(
                          _getScoreColor(_proDeviationScore!)),
                    ),
                  ),
                  Column(
                    children: [
                      Text(
                        _proDeviationScore!.toStringAsFixed(1),
                        style:
                            Theme.of(context).textTheme.displaySmall?.copyWith(
                                  color: _getScoreColor(_proDeviationScore!),
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                      Text(
                        _getScoreLabel(_proDeviationScore!),
                        style: TextStyle(
                            color: _getScoreColor(_proDeviationScore!),
                            fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'vs $_selectedPro · $_selectedThrowType',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ] else ...[
              const SizedBox(height: 16),
              const Icon(Icons.person_search, size: 48, color: Colors.white24),
              const SizedBox(height: 8),
              const Text(
                'Select a pro above to score your form',
                style: TextStyle(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }

  Color _getScoreColor(double score) {
    if (score >= 80) return Colors.green;
    if (score >= 60) return Colors.orange;
    return Colors.red;
  }

  String _getScoreLabel(double score) {
    if (score >= 90) return 'Excellent';
    if (score >= 80) return 'Good';
    if (score >= 70) return 'Fair';
    if (score >= 60) return 'Needs Work';
    return 'Poor';
  }

  Widget _buildPhaseComparisonSection() {
    final throwType = _selectedThrowType;
    final phases = ProBaselineParser.getPhaseNames(throwType);

    // When phase timestamps were provided (via PhaseFrameSelectorScreen),
    // we can go directly to comparison without manual frame selection.
    if (widget.phaseTimestamps != null && _analysis != null) {
      final phaseFrames = {
        for (final e in widget.phaseTimestamps!.entries)
          e.key: _frameForPhase(e.value)
      };
      final allPresent = phases.every((p) => phaseFrames.containsKey(p));
      if (!allPresent) return const SizedBox.shrink();

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: ElevatedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PhaseComparisonScreen(
                userAnalysis: _analysis!,
                phaseFrames: phaseFrames,
                proName: _selectedPro!,
                throwType: throwType,
              ),
            ),
          ),
          icon: const Icon(Icons.compare_arrows),
          label: const Text('Compare Phases vs Pro'),
          style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(14)),
        ),
      );
    }

    // Fallback: manual phase frame selection inline
    if (!_phaseSelectionMode) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: ElevatedButton.icon(
          onPressed: () {
            setState(() {
              _phaseSelectionMode = true;
              _phaseFrames.clear();
            });
          },
          icon: const Icon(Icons.compare_arrows),
          label: const Text('Compare Phases vs Pro'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.all(14),
          ),
        ),
      );
    }

    final allPhasesSet = phases.every((p) => _phaseFrames.containsKey(p));

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.compare_arrows, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Select Phase Frames',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    setState(() {
                      _phaseSelectionMode = false;
                      _phaseFrames.clear();
                    });
                  },
                ),
              ],
            ),
            const Text(
              'Navigate to the correct frame, then tap the phase button to assign it.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: phases.map((phase) {
                final isSet = _phaseFrames.containsKey(phase);
                final label = _formatPhaseName(phase);
                return ChoiceChip(
                  label: Text(
                    isSet
                        ? '$label (F${_phaseFrames[phase]! + 1})'
                        : label,
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: isSet,
                  selectedColor: Colors.green.withAlpha(60),
                  onSelected: (_) {
                    setState(() {
                      _phaseFrames[phase] = _currentFrame;
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: allPhasesSet
                  ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => PhaseComparisonScreen(
                            userAnalysis: _analysis!,
                            phaseFrames: Map.from(_phaseFrames),
                            proName: _selectedPro!,
                            throwType: throwType,
                          ),
                        ),
                      );
                    }
                  : null,
              icon: const Icon(Icons.analytics),
              label: Text(allPhasesSet
                  ? 'Compare'
                  : '${_phaseFrames.length}/${phases.length} phases set'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatPhaseName(String name) {
    return name
        .split('_')
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  Widget _buildAngleCharts() {
    if (_analysis == null || _analysis!.frames.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: Text('No frame data available')),
      );
    }

    final angles = _analysis!.frames.first.angles.keys.toList();
    final phaseOrder = _selectedThrowType == 'FH'
        ? ['wind_up', 'power_pocket', 'release', 'follow_through']
        : ['reach_back', 'power_pocket', 'release', 'follow_through'];
    const phaseT = [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0];
    const phaseLabels = ['R', 'P', 'Rel', 'F'];

    return Column(
      children: angles.map((angleName) {
        // Build 4 measured phase marker dots when a pro is selected
        List<({double t, double angle, String label})>? phaseMarkers;
        if (_proPhaseAngles != null) {
          phaseMarkers = [];
          for (int i = 0; i < phaseOrder.length; i++) {
            final a = _proPhaseAngles![phaseOrder[i]]?[angleName];
            if (a != null) {
              phaseMarkers.add((t: phaseT[i], angle: a, label: phaseLabels[i]));
            }
          }
          if (phaseMarkers.isEmpty) phaseMarkers = null;
        }
        return _buildAngleChart(angleName, phaseMarkers: phaseMarkers);
      }).toList(),
    );
  }

  Widget _buildAngleChart(String angleName,
      {List<({double t, double angle, String label})>? phaseMarkers}) {
    final angleData = _analysis!.frames.map((frame) {
      return frame.angles[angleName] ?? 0.0;
    }).toList();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _formatAngleName(angleName),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 80,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return GestureDetector(
                    onTapDown: (details) {
                      final fraction = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                      final frame = (fraction * (_analysis!.frames.length - 1)).round();
                      _seekToFrame(frame);
                    },
                    onHorizontalDragUpdate: (details) {
                      final fraction = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                      final frame = (fraction * (_analysis!.frames.length - 1)).round();
                      _seekToFrame(frame);
                    },
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, 80),
                      painter: AngleWaveformPainter(
                        angleData: angleData,
                        currentFrame: _currentFrame,
                        phaseMarkers: phaseMarkers,
                        showThreshold: _showThresholds,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Current: ${angleData[_currentFrame.clamp(0, angleData.length - 1)].toStringAsFixed(1)}°',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  void _seekToFrame(int frame) {
    if (_controller == null || _analysis == null) return;
    final clampedFrame = frame.clamp(0, _analysis!.frames.length - 1);
    final startMs = widget.analysisStartMs ?? 0;
    _controller!.seekTo(Duration(milliseconds: startMs + clampedFrame * _frameIntervalMs));
    setState(() {
      _currentFrame = clampedFrame;
    });
  }

  String _formatAngleName(String name) {
    final result = name.replaceAllMapped(
      RegExp(r'([A-Z])'),
      (match) => ' ${match.group(0)}',
    );
    return result[0].toUpperCase() + result.substring(1);
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  Widget _buildSuggestions(PostureAnalysisService postureService) {
    final suggestions =
        postureService.generateSuggestions(throwType: _selectedThrowType);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Suggestions',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          ...suggestions.map((suggestion) {
                final kbService = Provider.of<KnowledgeBaseService>(
                    context, listen: false);
                final article = suggestion.kbArticleId != null
                    ? kbService.articles
                        .where((a) => a.id == suggestion.kbArticleId)
                        .firstOrNull
                    : null;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.lightbulb_outline,
                              size: 16, color: Colors.amber),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              suggestion.text,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                      if (article != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 24, top: 2),
                          child: GestureDetector(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    ArticleDetailScreen(article: article),
                              ),
                            ),
                            child: const Text(
                              'Learn more →',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.lightBlueAccent,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }),
        ],
      ),
    );
  }
}

// Custom painter for angle waveform
class AngleWaveformPainter extends CustomPainter {
  final List<double> angleData;
  final int currentFrame;
  final List<({double t, double angle, String label})>? phaseMarkers;
  final bool showThreshold;

  AngleWaveformPainter({
    required this.angleData,
    required this.currentFrame,
    this.phaseMarkers,
    this.showThreshold = true,
  });

  /// Multi-pass smoothing: median filter to remove spikes, then moving average.
  List<double> _smooth(List<double> data) {
    if (data.length < 3) return data;
    // Pass 1: 3-point median filter to kill outlier spikes
    var result = _medianFilter(data, 3);
    // Pass 2-3: 9-point then 7-point moving average
    result = _movingAvg(result, 9);
    result = _movingAvg(result, 7);
    return result;
  }

  List<double> _medianFilter(List<double> data, int window) {
    final half = window ~/ 2;
    return List.generate(data.length, (i) {
      final start = (i - half).clamp(0, data.length - 1);
      final end = (i + half).clamp(0, data.length - 1);
      final seg = data.sublist(start, end + 1)..sort();
      return seg[seg.length ~/ 2];
    });
  }

  List<double> _movingAvg(List<double> data, int window) {
    if (data.length < window) return data;
    final half = window ~/ 2;
    return List.generate(data.length, (i) {
      final start = (i - half).clamp(0, data.length - 1);
      final end = (i + half).clamp(0, data.length - 1);
      double sum = 0;
      int count = 0;
      for (int j = start; j <= end; j++) {
        sum += data[j];
        count++;
      }
      return sum / count;
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (angleData.isEmpty) return;

    // Apply smoothing to reduce pose estimation noise
    final smoothed = _smooth(angleData);

    final paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..color = Colors.blue.withAlpha(50)
      ..style = PaintingStyle.fill;

    final currentFramePaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 2;

    // Find min and max for scaling (expand to include phase marker angles if shown)
    var minAngle = smoothed.reduce((a, b) => a < b ? a : b);
    var maxAngle = smoothed.reduce((a, b) => a > b ? a : b);
    if (phaseMarkers != null) {
      for (final m in phaseMarkers!) {
        if (m.angle < minAngle) minAngle = m.angle - 5;
        if (m.angle > maxAngle) maxAngle = m.angle + 5;
      }
    }
    final range = maxAngle - minAngle;

    if (range == 0) return;

    // Draw waveform
    final path = Path();
    final fillPath = Path();

    for (int i = 0; i < smoothed.length; i++) {
      final x = (i / (smoothed.length - 1)) * size.width;
      final normalizedValue = (smoothed[i] - minAngle) / range;
      final y = size.height - (normalizedValue * size.height);

      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);

    // Draw current frame indicator
    final clampedFrame = currentFrame.clamp(0, smoothed.length - 1);
    final x = (clampedFrame / (smoothed.length - 1)) * size.width;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      currentFramePaint,
    );

    // Draw grid lines
    final gridPaint = Paint()
      ..color = Colors.grey.withAlpha(76)
      ..strokeWidth = 1;

    for (int i = 0; i <= 4; i++) {
      final y = (i / 4) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Draw measured phase marker dots (one per pro phase snapshot)
    if (phaseMarkers != null) {
      final dotPaint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.fill;

      for (final marker in phaseMarkers!) {
        final x = marker.t * size.width;
        final normalizedAngle = (marker.angle - minAngle) / range;
        final y = size.height - normalizedAngle * size.height;

        // Draw dot
        canvas.drawCircle(Offset(x, y), 4.0, dotPaint);

        // Draw label below dot
        final labelPainter = TextPainter(
          text: TextSpan(
            text: marker.label,
            style: const TextStyle(
              color: Colors.green,
              fontSize: 8,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        labelPainter.layout();
        final labelX = (x - labelPainter.width / 2).clamp(0.0, size.width - labelPainter.width);
        final labelY = (y + 6).clamp(0.0, size.height - labelPainter.height);
        labelPainter.paint(canvas, Offset(labelX, labelY));
      }
    }
  }

  @override
  bool shouldRepaint(covariant AngleWaveformPainter oldDelegate) {
    return oldDelegate.currentFrame != currentFrame ||
        oldDelegate.angleData != angleData ||
        oldDelegate.phaseMarkers != phaseMarkers ||
        oldDelegate.showThreshold != showThreshold;
  }
}
