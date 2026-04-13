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
  bool _isAnalyzing   = false;
  FormAnalysis? _analysis;
  int _currentFrame   = 0;
  bool _inAnalysisRange = false;
  bool _showSkeleton    = true;
  bool _showThresholds  = true;

  // Phase verification
  bool _isVerifying          = false;
  int _verificationPhaseIndex = 0;

  // Pro selector
  String? _selectedPro;
  String _selectedThrowType = 'BH';

  // Pro data — loaded asynchronously
  Map<String, Map<String, double>>? _proPhaseAngles;
  List<String> _proQualityWarnings = [];
  double? _proDeviationScore;

  // Suggestions
  List<FormSuggestion> _suggestions = [];

  // Manual phase selection fallback
  bool _phaseSelectionMode = false;
  final Map<String, int> _phaseFrames = {};

  // Player list loaded from JSON
  List<String> _availablePlayers = [];
  bool _playersLoaded = false;

  // ── Phase frame indices derived from phaseTimestamps ──────────────────────
  /// Maps phase name → frame index in [_analysis.frames].
  Map<String, int> get _phaseFrameIndices {
    if (_analysis == null || widget.phaseTimestamps == null) return {};
    return widget.phaseTimestamps!.map(
      (phase, absMs) => MapEntry(phase, _frameForPhase(absMs)),
    );
  }

  List<MapEntry<String, int>> get _sortedPhases {
    if (widget.phaseTimestamps == null) return [];
    final entries = widget.phaseTimestamps!.entries.toList();
    entries.sort((a, b) => a.value.compareTo(b.value));
    return entries;
  }

  @override
  void initState() {
    super.initState();
    _analysis         = widget.analysis;
    _selectedPro      = widget.proPlayer;
    _selectedThrowType = widget.throwType;
    _loadPlayerNames();
    if (widget.videoPath != null) {
      _initializeVideo();
      _startAnalysis();
    }
  }

  Future<void> _loadPlayerNames() async {
    final names = await ProBaselineParser.getPlayerNames();
    if (mounted) setState(() { _availablePlayers = names; _playersLoaded = true; });
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.file(File(widget.videoPath!));
    await _controller!.initialize();
    setState(() => _isInitialized = true);
    _controller!.addListener(() {
      if (_analysis != null) {
        final pos    = _controller!.value.position.inMilliseconds;
        final start  = widget.analysisStartMs ?? 0;
        final end    = widget.analysisEndMs ??
            (start + _analysis!.frames.length * _frameIntervalMs);
        final inRange = pos >= start && pos <= end;
        final frame   = ((pos - start) / _frameIntervalMs)
            .floor()
            .clamp(0, _analysis!.frames.length - 1);
        if (frame != _currentFrame || inRange != _inAnalysisRange) {
          setState(() { _currentFrame = frame; _inAnalysisRange = inRange; });
        }
      }
    });
  }

  Future<void> _startAnalysis() async {
    setState(() => _isAnalyzing = true);
    final postureService =
        Provider.of<PostureAnalysisService>(context, listen: false);
    final analysis = await postureService.analyzeForm(
      widget.videoPath!,
      startMs:     widget.analysisStartMs ?? 0,
      frameCount:  widget.analysisFrameCount ?? 30,
      isLeftHanded: widget.isLeftHanded,
      throwType:   widget.throwType,
    );
    setState(() { _analysis = analysis; _isAnalyzing = false; });

    // Persist session
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
      Provider.of<FormHistoryService>(context, listen: false).saveSession(
        FormSessionRecord(
          id: analysis.id,
          date: analysis.date,
          score: analysis.score,
          throwType: widget.throwType,
          proPlayer: widget.proPlayer,
          frameCount: analysis.frames.length,
          avgAngles: avgAngles,
        ),
      );
    }

    // Load pro data if pre-selected
    if (_selectedPro != null) {
      await _loadProData(_selectedPro!, _selectedThrowType);
    } else {
      // Still generate baseline-only suggestions
      await _refreshSuggestions();
    }

    // Phase verification
    if (widget.phaseTimestamps != null && widget.phaseTimestamps!.isNotEmpty) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && _analysis != null) _startPhaseVerification();
      });
    } else {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _analysis != null) _showFormVerificationBanner();
      });
    }
  }

  // ── Pro data loading ───────────────────────────────────────────────────────

  Future<void> _loadProData(String proName, String throwType) async {
    if (_analysis == null) return;
    final result = await ProBaselineParser.getPhaseAnglesWithFallback(
        proName, throwType);
    final score = PostureAnalysisService.computeProDeviationScore(
      _analysis!.frames,
      result.angles,
      throwType,
      phaseFrameIndices: _phaseFrameIndices.isNotEmpty ? _phaseFrameIndices : null,
    );
    if (mounted) {
      setState(() {
        _proPhaseAngles      = result.angles;
        _proQualityWarnings  = result.qualityWarnings;
        _proDeviationScore   = score;
      });
    }
    await _refreshSuggestions();
  }

  Future<void> _refreshSuggestions() async {
    if (_analysis == null) return;
    final postureService =
        Provider.of<PostureAnalysisService>(context, listen: false);
    final sug = await postureService.generateSuggestionsAsync(
      throwType:         _selectedThrowType,
      proPhaseAngles:    _proPhaseAngles,
      phaseFrameIndices: _phaseFrameIndices.isNotEmpty ? _phaseFrameIndices : null,
      proName:           _selectedPro,
    );
    if (mounted) setState(() => _suggestions = sug);
  }

  // ── Phase verification ─────────────────────────────────────────────────────

  int _frameForPhase(int absoluteMs) {
    if (_analysis == null) return 0;
    final start = widget.analysisStartMs ?? 0;
    return ((absoluteMs - start) / _frameIntervalMs)
        .floor()
        .clamp(0, _analysis!.frames.length - 1);
  }

  void _seekToPhase(int absoluteMs) {
    _controller?.seekTo(Duration(milliseconds: absoluteMs));
    setState(() => _currentFrame = _frameForPhase(absoluteMs));
  }

  void _startPhaseVerification() {
    final sorted = _sortedPhases;
    if (sorted.isEmpty) return;
    setState(() { _isVerifying = true; _verificationPhaseIndex = 0; });
    _controller?.pause();
    _seekToPhase(sorted[0].value);
  }

  void _approveCurrentPhase() {
    final sorted    = _sortedPhases;
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
    final sorted      = _sortedPhases;
    final phaseMs     = sorted[_verificationPhaseIndex].value;
    final initialFrame = _frameForPhase(phaseMs);
    final corrected   = await Navigator.push<FormAnalysis>(
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
      // Recompute score and suggestions with corrected frames
      if (_proPhaseAngles != null) {
        final score = PostureAnalysisService.computeProDeviationScore(
          corrected.frames,
          _proPhaseAngles!,
          _selectedThrowType,
          phaseFrameIndices: _phaseFrameIndices.isNotEmpty ? _phaseFrameIndices : null,
        );
        setState(() => _proDeviationScore = score);
      }
      await _refreshSuggestions();
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
              FeedbackService.log({'verified': false, 'type': 'form_analysis'});
              _showCorrectionOptions();
            },
            child: const Text("It's Off"),
          ),
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              FeedbackService.log({'verified': true, 'type': 'form_analysis'});
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
              child: Text('How would you like to fix it?',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: Colors.blue),
              title: const Text('Retake Tips'),
              subtitle: const Text('Get advice on camera angle and lighting'),
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Tip: Use a side-view camera with good lighting.'),
                  duration: Duration(seconds: 5),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.orange),
              title: const Text('Correct Manually'),
              subtitle: const Text('Drag joints to the right positions'),
              onTap: () { Navigator.pop(ctx); _navigateToCorrection(); },
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
      setState(() => _analysis = corrected);
      if (_proPhaseAngles != null) {
        final score = PostureAnalysisService.computeProDeviationScore(
          corrected.frames,
          _proPhaseAngles!,
          _selectedThrowType,
          phaseFrameIndices: _phaseFrameIndices.isNotEmpty ? _phaseFrameIndices : null,
        );
        setState(() => _proDeviationScore = score);
      }
      await _refreshSuggestions();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Form Analysis'),
        actions: [
          if (_analysis != null)
            IconButton(
              icon: Icon(_showSkeleton ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _showSkeleton = !_showSkeleton),
              tooltip: _showSkeleton ? 'Hide Skeleton' : 'Show Skeleton',
            ),
          if (_analysis != null)
            IconButton(
              icon: Icon(_showThresholds
                  ? Icons.straighten
                  : Icons.straighten_outlined),
              onPressed: () => setState(() => _showThresholds = !_showThresholds),
              tooltip: _showThresholds
                  ? 'Hide Ideal Angles'
                  : 'Show Ideal Angles',
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
                  Text('Detecting pose and calculating joint angles',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            )
          : _analysis == null
              ? const Center(child: Text('No analysis available'))
              : SingleChildScrollView(
                  child: Column(
                    children: [
                      if (_analysis!.isMock) _buildMockWarning(),
                      if (_isInitialized && _controller != null)
                        _buildVideoWithOverlay(),
                      if (_isVerifying) _buildPhaseVerificationCard(),
                      if (_isInitialized && _controller != null)
                        _buildVideoControls(),
                      _buildScoreCard(),
                      _buildProSelector(),
                      if (_proQualityWarnings.isNotEmpty)
                        _buildQualityWarnings(),
                      if (_selectedPro != null && _analysis != null)
                        _buildPhaseComparisonSection(),
                      _buildAngleCharts(),
                      _buildSuggestions(),
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
          const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Pose detection failed',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
                const SizedBox(height: 4),
                Text(
                  'No person was detected. Scores and angles are simulated. '
                  'Try recording from the side with good lighting.',
                  style: TextStyle(color: Colors.red.shade100, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Data quality warning banner — shown when the selected pro+throw type
  /// has known occlusion or reliability issues in the reference database.
  Widget _buildQualityWarnings() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.amber.shade900.withAlpha(120),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.shade600),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.info_outline, color: Colors.amber, size: 16),
            const SizedBox(width: 6),
            const Text('Reference data notes',
                style: TextStyle(
                    color: Colors.amber,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
          ]),
          const SizedBox(height: 6),
          ..._proQualityWarnings.take(3).map((w) => Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('• $w',
                    style: TextStyle(
                        color: Colors.amber.shade200, fontSize: 11)),
              )),
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
        if (_showSkeleton &&
            _inAnalysisRange &&
            _analysis != null &&
            _analysis!.frames.isNotEmpty)
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
                  setState(() => _currentFrame =
                      (_currentFrame - 1).clamp(0, (_analysis?.frames.length ?? 1) - 1));
                },
              ),
              IconButton(
                icon: Icon(
                  _controller!.value.isPlaying
                      ? Icons.pause
                      : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: () => setState(() {
                  _controller!.value.isPlaying
                      ? _controller!.pause()
                      : _controller!.play();
                }),
              ),
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white),
                onPressed: () {
                  final pos = _controller!.value.position +
                      Duration(milliseconds: _frameIntervalMs);
                  _controller!.seekTo(pos);
                  setState(() => _currentFrame =
                      (_currentFrame + 1).clamp(0, (_analysis?.frames.length ?? 1) - 1));
                },
              ),
              Expanded(
                child: Slider(
                  value: _controller!.value.position.inMilliseconds
                      .toDouble()
                      .clamp(0,
                          _controller!.value.duration.inMilliseconds.toDouble()),
                  min: 0,
                  max: _controller!.value.duration.inMilliseconds.toDouble(),
                  onChanged: (value) {
                    _controller!
                        .seekTo(Duration(milliseconds: value.toInt()));
                    if (_analysis != null) {
                      setState(() => _currentFrame =
                          (value / _frameIntervalMs).floor().clamp(
                              0, _analysis!.frames.length - 1));
                    }
                  },
                ),
              ),
              Text(
                '${_formatDuration(_controller!.value.position)} / '
                '${_formatDuration(_controller!.value.duration)}',
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
            Text('Compare With Pro',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            if (!_playersLoaded)
              const Center(
                  child: SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(strokeWidth: 2)))
            else
              DropdownButtonFormField<String>(
                value: _selectedPro,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Select a pro player',
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<String>(
                      value: null, child: Text('None')),
                  ..._availablePlayers.map((pro) =>
                      DropdownMenuItem(value: pro, child: Text(pro))),
                ],
                onChanged: (pro) async {
                  setState(() {
                    _selectedPro         = pro;
                    _proPhaseAngles      = null;
                    _proQualityWarnings  = [];
                    _proDeviationScore   = null;
                    _phaseSelectionMode  = false;
                    _phaseFrames.clear();
                  });
                  if (pro != null && _analysis != null) {
                    await _loadProData(pro, _selectedThrowType);
                  } else {
                    await _refreshSuggestions();
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
                  _selectedThrowType   = selection.first;
                  _proPhaseAngles      = null;
                  _proQualityWarnings  = [];
                  _proDeviationScore   = null;
                  _phaseSelectionMode  = false;
                  _phaseFrames.clear();
                });
                if (_selectedPro != null && _analysis != null) {
                  await _loadProData(_selectedPro!, selection.first);
                } else {
                  await _refreshSuggestions();
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
            Text('Pro Deviation Score',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
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
                        style: Theme.of(context)
                            .textTheme
                            .displaySmall
                            ?.copyWith(
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
              const Text('Select a pro above to score your form',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                  textAlign: TextAlign.center),
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

  Widget _buildPhaseVerificationCard() {
    final sorted = _sortedPhases;
    if (_verificationPhaseIndex >= sorted.length) return const SizedBox.shrink();
    final phaseName  = sorted[_verificationPhaseIndex].key;
    final phaseLabel = _formatPhaseName(phaseName);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.blue.shade900,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Icon(Icons.verified_user, color: Colors.lightBlue, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Verify Phase: $phaseLabel',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Colors.white)),
              ),
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
                    width: 8, height: 8,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, color: color),
                  );
                }),
              ),
            ]),
            const SizedBox(height: 6),
            Text('Is the pose overlay correct for this frame?',
                style: TextStyle(color: Colors.blue.shade100, fontSize: 13)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _fixCurrentPhase,
                  icon: const Icon(Icons.edit, size: 16, color: Colors.orange),
                  label: const Text('Fix It',
                      style: TextStyle(color: Colors.orange)),
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.orange)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _approveCurrentPhase,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Looks Good'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade700),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildPhaseComparisonSection() {
    final throwType = _selectedThrowType;
    final phases    = ProBaselineParser.getPhaseNames(throwType);

    if (widget.phaseTimestamps != null && _analysis != null) {
      final phaseFrames = _phaseFrameIndices;
      final allPresent  = phases.every((p) => phaseFrames.containsKey(p));
      if (!allPresent) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: ElevatedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PhaseComparisonScreen(
                userAnalysis: _analysis!,
                phaseFrames:  phaseFrames,
                proName:      _selectedPro!,
                throwType:    throwType,
              ),
            ),
          ),
          icon: const Icon(Icons.compare_arrows),
          label: const Text('Compare Phases vs Pro'),
          style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(14)),
        ),
      );
    }

    // Manual selection fallback
    if (!_phaseSelectionMode) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: ElevatedButton.icon(
          onPressed: () => setState(() {
            _phaseSelectionMode = true;
            _phaseFrames.clear();
          }),
          icon: const Icon(Icons.compare_arrows),
          label: const Text('Compare Phases vs Pro'),
          style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(14)),
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
            Row(children: [
              const Icon(Icons.compare_arrows, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                  child: Text('Select Phase Frames',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15))),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => setState(() {
                  _phaseSelectionMode = false;
                  _phaseFrames.clear();
                }),
              ),
            ]),
            const Text(
              'Navigate to the correct frame, then tap the phase button to assign it.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: phases.map((phase) {
                final isSet  = _phaseFrames.containsKey(phase);
                final label  = _formatPhaseName(phase);
                return ChoiceChip(
                  label: Text(
                    isSet ? '$label (F${_phaseFrames[phase]! + 1})' : label,
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: isSet,
                  selectedColor: Colors.green.withAlpha(60),
                  onSelected: (_) =>
                      setState(() => _phaseFrames[phase] = _currentFrame),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: allPhasesSet
                  ? () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PhaseComparisonScreen(
                            userAnalysis: _analysis!,
                            phaseFrames:  Map.from(_phaseFrames),
                            proName:      _selectedPro!,
                            throwType:    throwType,
                          ),
                        ),
                      )
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

  String _formatPhaseName(String name) =>
      name.split('_').map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');

  // ── Angle charts ───────────────────────────────────────────────────────────

  Widget _buildAngleCharts() {
    if (_analysis == null || _analysis!.frames.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: Text('No frame data available')),
      );
    }
    final angles     = _analysis!.frames.first.angles.keys.toList();
    final phaseOrder = ProBaselineParser.getPhaseNames(_selectedThrowType);

    return Column(
      children: angles.map((angleName) {
        // Build phase markers from actual phase frame indices, not fractions.
        // The marker x-position is the frame index / (totalFrames - 1),
        // which correctly places the dot at the measured phase frame.
        List<({double t, double angle, String label})>? phaseMarkers;
        if (_proPhaseAngles != null) {
          final phaseIndices = _phaseFrameIndices.isNotEmpty
              ? _phaseFrameIndices
              : _evenlySpacedPhaseIndices(_analysis!.frames.length, phaseOrder);

          final total = _analysis!.frames.length;
          phaseMarkers = [];
          for (final phase in phaseOrder) {
            final proAngle = _proPhaseAngles![phase]?[angleName];
            if (proAngle == null) continue;
            final frameIdx = phaseIndices[phase];
            if (frameIdx == null) continue;
            final t = total > 1 ? frameIdx / (total - 1) : 0.0;
            final shortLabel = _phaseShortLabel(phase);
            phaseMarkers.add((t: t, angle: proAngle, label: shortLabel));
          }
          if (phaseMarkers.isEmpty) phaseMarkers = null;
        }
        return _buildAngleChart(angleName, phaseMarkers: phaseMarkers);
      }).toList(),
    );
  }

  /// Returns evenly-spaced frame indices as a fallback when no
  /// phaseTimestamps are available.
  Map<String, int> _evenlySpacedPhaseIndices(
      int totalFrames, List<String> phases) {
    final phaseT = [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0];
    final result = <String, int>{};
    for (int i = 0; i < phases.length && i < phaseT.length; i++) {
      result[phases[i]] =
          ((phaseT[i]) * (totalFrames - 1)).round().clamp(0, totalFrames - 1);
    }
    return result;
  }

  String _phaseShortLabel(String phase) {
    switch (phase) {
      case 'reach_back':  return 'RB';
      case 'wind_up':     return 'WU';
      case 'power_pocket': return 'PP';
      case 'release':     return 'Rel';
      case 'follow_through': return 'FT';
      default:            return phase.substring(0, 2).toUpperCase();
    }
  }

  Widget _buildAngleChart(
    String angleName, {
    List<({double t, double angle, String label})>? phaseMarkers,
  }) {
    final angleData = _analysis!.frames
        .map((f) => f.angles[angleName] ?? 0.0)
        .toList();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_formatAngleName(angleName),
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SizedBox(
              height: 80,
              child: LayoutBuilder(builder: (context, constraints) {
                return GestureDetector(
                  onTapDown: (d) {
                    final frac =
                        (d.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                    _seekToFrame(
                        (frac * (_analysis!.frames.length - 1)).round());
                  },
                  onHorizontalDragUpdate: (d) {
                    final frac =
                        (d.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                    _seekToFrame(
                        (frac * (_analysis!.frames.length - 1)).round());
                  },
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, 80),
                    painter: AngleWaveformPainter(
                      angleData:     angleData,
                      currentFrame:  _currentFrame,
                      phaseMarkers:  phaseMarkers,
                      showThreshold: _showThresholds,
                    ),
                  ),
                );
              }),
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
    final clamped = frame.clamp(0, _analysis!.frames.length - 1);
    final startMs = widget.analysisStartMs ?? 0;
    _controller!
        .seekTo(Duration(milliseconds: startMs + clamped * _frameIntervalMs));
    setState(() => _currentFrame = clamped);
  }

  String _formatAngleName(String name) {
    final result =
        name.replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(0)}');
    return result[0].toUpperCase() + result.substring(1);
  }

  String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
  }

  // ── Suggestions ────────────────────────────────────────────────────────────

  Widget _buildSuggestions() {
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
          Text('Suggestions',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (_suggestions.isEmpty)
            const Text('Analyzing…',
                style: TextStyle(color: Colors.grey, fontSize: 13))
          else
            ..._suggestions.map((suggestion) {
              final kbService =
                  Provider.of<KnowledgeBaseService>(context, listen: false);
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
                          child: Text(suggestion.text,
                              style: Theme.of(context).textTheme.bodySmall),
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
                                    ArticleDetailScreen(article: article)),
                          ),
                          child: const Text('Learn more →',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.lightBlueAccent,
                                  decoration: TextDecoration.underline)),
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

// ── AngleWaveformPainter (phase markers fixed) ─────────────────────────────

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

  List<double> _smooth(List<double> data) {
    if (data.length < 3) return data;
    var result = _medianFilter(data, 3);
    result = _movingAvg(result, 9);
    result = _movingAvg(result, 7);
    return result;
  }

  List<double> _medianFilter(List<double> data, int window) {
    final half = window ~/ 2;
    return List.generate(data.length, (i) {
      final start = (i - half).clamp(0, data.length - 1);
      final end   = (i + half).clamp(0, data.length - 1);
      final seg   = data.sublist(start, end + 1)..sort();
      return seg[seg.length ~/ 2];
    });
  }

  List<double> _movingAvg(List<double> data, int window) {
    if (data.length < window) return data;
    final half = window ~/ 2;
    return List.generate(data.length, (i) {
      final start = (i - half).clamp(0, data.length - 1);
      final end   = (i + half).clamp(0, data.length - 1);
      double sum  = 0;
      int count   = 0;
      for (int j = start; j <= end; j++) { sum += data[j]; count++; }
      return sum / count;
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (angleData.isEmpty) return;
    final smoothed = _smooth(angleData);

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

    final paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final fillPaint = Paint()
      ..color = Colors.blue.withAlpha(50)
      ..style = PaintingStyle.fill;
    final framePaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 2;

    final path     = Path();
    final fillPath = Path();
    for (int i = 0; i < smoothed.length; i++) {
      final x = (i / (smoothed.length - 1)) * size.width;
      final n = (smoothed[i] - minAngle) / range;
      final y = size.height - n * size.height;
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

    // Current frame indicator
    final clampedFrame = currentFrame.clamp(0, smoothed.length - 1);
    final x = (clampedFrame / (smoothed.length - 1)) * size.width;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), framePaint);

    // Grid lines
    final gridPaint = Paint()
      ..color = Colors.grey.withAlpha(76)
      ..strokeWidth = 1;
    for (int i = 0; i <= 4; i++) {
      final y = (i / 4) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Phase marker dots — positioned at actual phase frame fractions.
    // `t` is already computed as frameIdx / (totalFrames - 1) by the screen,
    // so these dots land at the measured phase frames, not hardcoded quarters.
    if (phaseMarkers != null) {
      final dotPaint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.fill;
      final dotBorder = Paint()
        ..color = Colors.greenAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      for (final marker in phaseMarkers!) {
        final mx = marker.t * size.width;
        final n  = (marker.angle - minAngle) / range;
        final my = size.height - n * size.height;

        canvas.drawCircle(Offset(mx, my), 5.0, dotPaint);
        canvas.drawCircle(Offset(mx, my), 5.0, dotBorder);

        final tp = TextPainter(
          text: TextSpan(
            text: marker.label,
            style: const TextStyle(
                color: Colors.greenAccent,
                fontSize: 9,
                fontWeight: FontWeight.bold),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final lx = (mx - tp.width / 2).clamp(0.0, size.width - tp.width);
        final ly = (my + 7).clamp(0.0, size.height - tp.height);
        tp.paint(canvas, Offset(lx, ly));
      }
    }
  }

  @override
  bool shouldRepaint(covariant AngleWaveformPainter old) =>
      old.currentFrame != currentFrame ||
      old.angleData != angleData ||
      old.phaseMarkers != phaseMarkers ||
      old.showThreshold != showThreshold;
}
