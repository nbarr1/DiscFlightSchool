import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/video_service.dart';
import '../../services/posture_analysis_service.dart';
import '../../utils/pro_data_parser.dart';
import 'form_history_screen.dart';
import 'posture_analysis_screen.dart';
import 'video_trim_screen.dart';

class FormCoachScreen extends StatefulWidget {
  const FormCoachScreen({Key? key}) : super(key: key);

  @override
  State<FormCoachScreen> createState() => _FormCoachScreenState();
}

class _FormCoachScreenState extends State<FormCoachScreen> {
  String? _selectedPro;
  String _throwType    = 'BH';
  bool _isLeftHanded   = false;

  // Player list loaded from pro_baseline_db.json
  List<String> _availablePlayers   = [];
  Map<String, bool> _playerHasFH   = {};
  bool _playersLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadPlayers();
  }

  Future<void> _loadPlayers() async {
    final names = await ProBaselineParser.getPlayerNames();
    // Check which players have FH data (not all do for both types)
    final hasFH = <String, bool>{};
    for (final name in names) {
      hasFH[name] = await ProBaselineParser.hasThrowType(name, 'FH');
    }
    if (mounted) {
      setState(() {
        _availablePlayers = names;
        _playerHasFH      = hasFH;
        _playersLoaded    = true;
      });
    }
  }

  /// Players available for the current throw type selection.
  List<String> get _filteredPlayers {
    if (_throwType == 'BH') return _availablePlayers;
    // FH: only show players with FH data
    return _availablePlayers.where((p) => _playerHasFH[p] == true).toList();
  }

  @override
  Widget build(BuildContext context) {
    final videoService   = Provider.of<VideoService>(context);
    final postureService = Provider.of<PostureAnalysisService>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Form Coach'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Session History',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FormHistoryScreen()),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Compare With Pro',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 12),

                    // Throw type selector — placed before player dropdown
                    // so the player list filters by throw type availability.
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'BH', label: Text('Backhand')),
                        ButtonSegment(value: 'FH', label: Text('Forehand')),
                      ],
                      selected: {_throwType},
                      onSelectionChanged: (selection) {
                        setState(() {
                          _throwType = selection.first;
                          // Clear pro selection if they don't have this throw type
                          if (_selectedPro != null &&
                              _throwType == 'FH' &&
                              _playerHasFH[_selectedPro] != true) {
                            _selectedPro = null;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 12),

                    // Player dropdown — populated from JSON, not AppConstants
                    if (!_playersLoaded)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      )
                    else
                      DropdownButtonFormField<String>(
                        value: _selectedPro,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: 'Select a pro player (optional)',
                        ),
                        items: [
                          const DropdownMenuItem<String>(
                              value: null,
                              child: Text('— None —')),
                          ..._filteredPlayers.map((pro) =>
                              DropdownMenuItem(value: pro, child: Text(pro))),
                        ],
                        onChanged: (pro) => setState(() => _selectedPro = pro),
                      ),

                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Left-handed thrower'),
                      subtitle: const Text(
                        'Mirrors angle analysis — throwing arm is always scored as dominant',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: _isLeftHanded,
                      onChanged: (v) => setState(() => _isLeftHanded = v),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            ElevatedButton.icon(
              onPressed: () async {
                final videoPath = await videoService.selectVideo();
                if (videoPath != null && context.mounted) {
                  _navigateToAnalysis(videoPath);
                } else if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(videoService.lastError ??
                        'Could not open gallery. Check storage permission in Settings.'),
                    duration: const Duration(seconds: 6),
                  ));
                }
              },
              icon: const Icon(Icons.video_library),
              label: const Text('Upload Form Video'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
            ),

            const SizedBox(height: 12),

            ElevatedButton.icon(
              onPressed: () async {
                final videoPath = await videoService.captureVideo();
                if (videoPath != null && context.mounted) {
                  _navigateToAnalysis(videoPath);
                } else if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(videoService.lastError ??
                        'Could not open camera. Check camera permission in Settings.'),
                    duration: const Duration(seconds: 6),
                  ));
                }
              },
              icon: const Icon(Icons.videocam),
              label: const Text('Record Form Video'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
            ),

            const SizedBox(height: 20),

            // Last analysis card
            if (postureService.currentAnalysis != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Last Analysis',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      if (postureService.currentAnalysis!.isMock)
                        const Text(
                          'Pose detection failed on last video.',
                          style: TextStyle(color: Colors.amber, fontSize: 12),
                        )
                      else ...[
                        Text('Frames: ${postureService.currentAnalysis!.frames.length}'),
                      ],
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PostureAnalysisScreen(
                              analysis:  postureService.currentAnalysis!,
                              proPlayer: _selectedPro,
                              throwType: _throwType,
                              isLeftHanded: _isLeftHanded,
                            ),
                          ),
                        ),
                        child: const Text('View Analysis'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _navigateToAnalysis(String path) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoTrimScreen(
          videoPath:    path,
          proPlayer:    _selectedPro,
          throwType:    _throwType,
          isLeftHanded: _isLeftHanded,
        ),
      ),
    );
  }
}
