import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:video_player/video_player.dart';
import 'manual_tracking.dart';

void main() {
  runApp(const DiscGolfApp());
}

class DiscGolfApp extends StatelessWidget {
  const DiscGolfApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Disc Golf Analyzer',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1a1a2e),
        cardTheme: CardTheme(
          color: const Color(0xFF16213e),
          elevation: 4,
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ============================================================================
// HOME PAGE - Module Selection
// ============================================================================

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Disc Golf Analyzer'),
        centerTitle: true,
        backgroundColor: const Color(0xFF0f3460),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          children: [
            _buildModuleCard(
              context,
              'Flight Tracker',
              Icons.flight,
              Colors.blue,
              () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const FlightTrackerPage()),
              ),
            ),
            _buildModuleCard(
              context,
              'Form Analysis',
              Icons.accessibility_new,
              Colors.green,
              () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const FormAnalysisPage()),
              ),
            ),
            _buildModuleCard(
              context,
              'Disc Golf Roulette',
              Icons.casino,
              Colors.orange,
              () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const RouletteePage()),
              ),
            ),
            _buildModuleCard(
              context,
              'Score Tracker',
              Icons.scoreboard,
              Colors.purple,
              () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ScoreTrackerPage()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModuleCard(
    BuildContext context,
    String title,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: color),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// FLIGHT TRACKER MODULE
// ============================================================================

class FlightTrackerPage extends StatefulWidget {
  const FlightTrackerPage({super.key});

  @override
  State<FlightTrackerPage> createState() => _FlightTrackerPageState();
}

class _FlightTrackerPageState extends State<FlightTrackerPage> {
  Map<String, dynamic>? flightData;
  VideoPlayerController? _videoController;
  bool isLoading = true;
  bool isManualMode = false;
  List<Offset> manualPoints = [];
  int currentFrame = 0;

  @override
  void initState() {
    super.initState();
    _loadFlightData();
  }

  Future<void> _loadFlightData() async {
    try {
      final String jsonString = await rootBundle.loadString('assets/data/output_coordinates.json');
      setState(() {
        flightData = json.decode(jsonString);
        isLoading = false;
      });
    } catch (e) {
      print('Error loading flight $e');
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flight Tracker'),
        backgroundColor: const Color(0xFF0f3460),
        actions: [
          IconButton(
            icon: const Icon(Icons.video_library),
            onPressed: () async {
              // Open manual tracking
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ManualTrackingPage(
                    videoPath: '/c/ClaudeDiscGolfApp/test_videos/throw.mp4',
                  ),
                ),
              );
              
              if (result != null) {
                // Handle saved tracking points
                print('Saved ${(result as List).length} points');
              }
            },
            tooltip: 'Manual Tracking',
          ),
          IconButton(
            icon: Icon(isManualMode ? Icons.auto_awesome : Icons.edit),
            onPressed: () {
              setState(() {
                isManualMode = !isManualMode;
              });
            },
            tooltip: isManualMode ? 'Auto Mode' : 'Manual Mode',
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Video Player with Overlay
                  _buildVideoPlayer(),
                  const SizedBox(height: 24),

                  // Flight Statistics
                  _buildFlightStats(),
                  const SizedBox(height: 24),

                  // Flight Path Graph
                  _buildFlightPathGraph(),
                  const SizedBox(height: 24),

                  // Manual Tracking Controls
                  if (isManualMode) _buildManualControls(),
                ],
              ),
            ),
    );
  }

  // ... rest of the methods stay the same (_buildVideoPlayer, _buildFlightStats, etc.)

// ============================================================================
// Flight Path Overlay Painter
// ============================================================================

class FlightPathOverlayPainter extends CustomPainter {
  final Map<String, dynamic>? flightData;
  final int currentFrame;

  FlightPathOverlayPainter({this.flightData, required this.currentFrame});

  @override
  void paint(Canvas canvas, Size size) {
    if (flightData == null) return;

    final coords = flightData!['coordinates'] as List? ?? [];
    if (coords.isEmpty) return;

    // Draw flight path
    final pathPaint = Paint()
      ..color = Colors.blue.withOpacity(0.5)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final path = Path();
    bool firstPoint = true;

    for (var coord in coords) {
      final x = (coord['x'] as num).toDouble() * size.width / 1920; // Scale to video size
      final y = (coord['y'] as num).toDouble() * size.height / 1080;

      if (firstPoint) {
        path.moveTo(x, y);
        firstPoint = false;
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, pathPaint);

    // Draw current position
    if (currentFrame < coords.length) {
      final currentCoord = coords[currentFrame];
      final x = (currentCoord['x'] as num).toDouble() * size.width / 1920;
      final y = (currentCoord['y'] as num).toDouble() * size.height / 1080;

      final dotPaint = Paint()
        ..color = Colors.red
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(x, y), 8, dotPaint);
    }
  }

  @override
  bool shouldRepaint(FlightPathOverlayPainter oldDelegate) => true;
}

// ============================================================================
// FORM ANALYSIS MODULE
// ============================================================================

class FormAnalysisPage extends StatefulWidget {
  const FormAnalysisPage({super.key});

  @override
  State<FormAnalysisPage> createState() => _FormAnalysisPageState();
}

class _FormAnalysisPageState extends State<FormAnalysisPage> {
  Map<String, dynamic>? analysisData;
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAnalysisData();
  }

  Future<void> _loadAnalysisData() async {
    try {
      final String jsonString = await rootBundle.loadString('assets/data/analysis_results.json');
      setState(() {
        analysisData = json.decode(jsonString);
        isLoading = false;
      });
    } catch (e) {
      print('Error loading analysis $e');
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Form Analysis'),
        backgroundColor: const Color(0xFF0f3460),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Overall Score
                  _buildOverallScore(),
                  const SizedBox(height: 24),

                  // Side-by-Side Comparison
                  _buildSideBySideComparison(),
                  const SizedBox(height: 24),

                  // Joint Angle Details
                  _buildJointAngleDetails(),
                  const SizedBox(height: 24),

                  // Recommendations
                  _buildRecommendations(),
                ],
              ),
            ),
    );
  }

  Widget _buildOverallScore() {
    if (analysisData == null) return const SizedBox.shrink();

    final match = analysisData!['percentage_match'] ?? 0.0;
    final color = match > 70 ? Colors.green : match > 50 ? Colors.orange : Colors.red;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Text(
              'Form Match Score',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 150,
                  height: 150,
                  child: CircularProgressIndicator(
                    value: match / 100,
                    strokeWidth: 12,
                    backgroundColor: Colors.grey[800],
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
                Text(
                  '${match.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSideBySideComparison() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Form Comparison',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      const Text(
                        'Your Form',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 250,
                        decoration: BoxDecoration(
                          color: Colors.grey[900],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: CustomPaint(
                          painter: SkeletonPainter(
                            keypoints: analysisData?['user_keypoints'],
                            color: Colors.blue,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    children: [
                      const Text(
                        'Pro Form',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 250,
                        decoration: BoxDecoration(
                          color: Colors.grey[900],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: CustomPaint(
                          painter: SkeletonPainter(
                            keypoints: analysisData?['pro_keypoints'],
                            color: Colors.green,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildJointAngleDetails() {
    if (analysisData == null) return const SizedBox.shrink();

    final spineDiff = analysisData!['spine_difference'] ?? 0.0;
    final elbowDiff = analysisData!['elbow_difference'] ?? 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Joint Angle Analysis',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            _buildAngleRow('Spine Angle', spineDiff),
            const Divider(height: 24),
            _buildAngleRow('Elbow Angle', elbowDiff),
          ],
        ),
      ),
    );
  }

  Widget _buildAngleRow(String label, double difference) {
    final isGood = difference.abs() < 10;
    final color = isGood ? Colors.green : difference.abs() < 20 ? Colors.orange : Colors.red;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 16)),
        Row(
          children: [
            Text(
              '${difference.abs().toStringAsFixed(1)}° off',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              isGood ? Icons.check_circle : Icons.warning,
              color: color,
              size: 20,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRecommendations() {
    if (analysisData == null) return const SizedBox.shrink();

    final spineDiff = analysisData!['spine_difference'] ?? 0.0;
    final elbowDiff = analysisData!['elbow_difference'] ?? 0.0;

    List<String> recommendations = [];

    if (spineDiff.abs() > 10) {
      if (spineDiff > 0) {
        recommendations.add('• Lean forward more during your reach-back');
      } else {
        recommendations.add('• Stand more upright during your reach-back');
      }
    }

    if (elbowDiff.abs() > 10) {
      if (elbowDiff > 0) {
        recommendations.add('• Keep your elbow more tucked in');
      } else {
        recommendations.add('• Extend your elbow more during the throw');
      }
    }

    if (recommendations.isEmpty) {
      recommendations.add('• Great form! Keep practicing to maintain consistency');
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Recommendations',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ...recommendations.map((rec) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(rec, style: const TextStyle(fontSize: 14)),
                )),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Skeleton Overlay Painter
// ============================================================================

class SkeletonPainter extends CustomPainter {
  final Map<String, dynamic>? keypoints;
  final Color color;

  SkeletonPainter({this.keypoints, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (keypoints == null) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // Define skeleton connections
    final connections = [
      ['nose', 'left_shoulder'],
      ['nose', 'right_shoulder'],
      ['left_shoulder', 'right_shoulder'],
      ['left_shoulder', 'left_elbow'],
      ['left_elbow', 'left_wrist'],
      ['right_shoulder', 'right_elbow'],
      ['right_elbow', 'right_wrist'],
      ['left_shoulder', 'left_hip'],
      ['right_shoulder', 'right_hip'],
      ['left_hip', 'right_hip'],
      ['left_hip', 'left_knee'],
      ['left_knee', 'left_ankle'],
      ['right_hip', 'right_knee'],
      ['right_knee', 'right_ankle'],
    ];

    // Draw connections
    for (var connection in connections) {
      final start = keypoints![connection[0]];
      final end = keypoints![connection[1]];

      if (start != null && end != null) {
        final x1 = (start['x'] as num).toDouble() * size.width;
        final y1 = (start['y'] as num).toDouble() * size.height;
        final x2 = (end['x'] as num).toDouble() * size.width;
        final y2 = (end['y'] as num).toDouble() * size.height;

        canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);
      }
    }

    // Draw keypoints
    keypoints!.forEach((key, value) {
      if (value != null) {
        final x = (value['x'] as num).toDouble() * size.width;
        final y = (value['y'] as num).toDouble() * size.height;
        canvas.drawCircle(Offset(x, y), 5, dotPaint);
      }
    });

    // Draw angle arcs for spine and elbow
    _drawAngleArc(canvas, size, 'left_shoulder', 'left_hip', 'left_knee', paint);
    _drawAngleArc(canvas, size, 'left_shoulder', 'left_elbow', 'left_wrist', paint);
  }

  void _drawAngleArc(Canvas canvas, Size size, String p1Key, String p2Key, String p3Key, Paint paint) {
    final p1 = keypoints![p1Key];
    final p2 = keypoints![p2Key];
    final p3 = keypoints![p3Key];

    if (p1 == null || p2 == null || p3 == null) return;

    final x1 = (p1['x'] as num).toDouble() * size.width;
    final y1 = (p1['y'] as num).toDouble() * size.height;
    final x2 = (p2['x'] as num).toDouble() * size.width;
    final y2 = (p2['y'] as num).toDouble() * size.height;
    final x3 = (p3['x'] as num).toDouble() * size.width;
    final y3 = (p3['y'] as num).toDouble() * size.height;

    // Draw arc overlay (simplified)
    final arcPaint = Paint()
      ..color = color.withOpacity(0.3)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    canvas.drawCircle(Offset(x2, y2), 20, arcPaint);
  }

  @override
  bool shouldRepaint(SkeletonPainter oldDelegate) => true;
}

// ============================================================================
// DISC GOLF ROULETTE MODULE
// ============================================================================

class RouletteePage extends StatefulWidget {
  const RouletteePage({super.key});

  @override
  State<RouletteePage> createState() => _RouletteePageState();
}

class _RouletteePageState extends State<RouletteePage> {
  String? currentChallenge;
  final List<String> challenges = [
    'Throw with your off-hand',
    'Roller shot only',
    'Forehand approach',
    'Backhand only this hole',
    'Putt from your knees',
    'Tomahawk or thumber drive',
    'No run-up allowed',
    'Grenade shot',
    'Hyzer flip required',
    'Anhyzer line only',
    'Straddle putt mandatory',
    'Jump putt from circle 2',
    'Overhand shot off the tee',
    'Standstill drive only',
    'Opposite stance (RHBH → LHBH)',
  ];

  void _spinRoulette() {
    setState(() {
      challenges.shuffle();
      currentChallenge = challenges.first;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Disc Golf Roulette'),
        backgroundColor: const Color(0xFF0f3460),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.casino, size: 100, color: Colors.orange),
              const SizedBox(height: 32),
              const Text(
                'Tap to get a random challenge!',
                style: TextStyle(fontSize: 20),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              if (currentChallenge != null)
                Card(
                  color: Colors.orange.withOpacity(0.2),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      currentChallenge!,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: _spinRoulette,
                icon: const Icon(Icons.refresh, size: 32),
                label: const Text(
                  'SPIN',
                  style: TextStyle(fontSize: 20),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// SCORE TRACKER MODULE
// ============================================================================

class ScoreTrackerPage extends StatefulWidget {
  const ScoreTrackerPage({super.key});

  @override
  State<ScoreTrackerPage> createState() => _ScoreTrackerPageState();
}

class _ScoreTrackerPageState extends State<ScoreTrackerPage> {
  List<HoleScore> scores = [];
  int currentHole = 1;
  final int totalHoles = 18;

  @override
  void initState() {
    super.initState();
    // Initialize with default pars
    for (int i = 1; i <= totalHoles; i++) {
      scores.add(HoleScore(holeNumber: i, par: 3, score: 0));
    }
  }

  void _updateScore(int hole, int score) {
    setState(() {
      scores[hole - 1].score = score;
    });
  }

  int get totalScore => scores.fold(0, (sum, hole) => sum + hole.score);
  int get totalPar => scores.fold(0, (sum, hole) => sum + hole.par);
  int get scoreToPar => totalScore - totalPar;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Score Tracker'),
        backgroundColor: const Color(0xFF0f3460),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                for (var hole in scores) {
                  hole.score = 0;
                }
                currentHole = 1;
              });
            },
            tooltip: 'Reset Round',
          ),
        ],
      ),
      body: Column(
        children: [
          // Score Summary
          _buildScoreSummary(),

          // Hole List
          Expanded(
            child: ListView.builder(
              itemCount: totalHoles,
              itemBuilder: (context, index) {
                return _buildHoleCard(scores[index]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreSummary() {
    final scoreColor = scoreToPar < 0
        ? Colors.green
        : scoreToPar > 0
            ? Colors.red
            : Colors.grey;

    final scoreText = scoreToPar == 0
        ? 'E'
        : scoreToPar > 0
            ? '+$scoreToPar'
            : '$scoreToPar';

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            Column(
              children: [
                const Text(
                  'Total Score',
                  style: TextStyle(color: Colors.grey),
                ),
                Text(
                  '$totalScore',
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            Column(
              children: [
                const Text(
                  'To Par',
                  style: TextStyle(color: Colors.grey),
                ),
                Text(
                  scoreText,
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: scoreColor,
                  ),
                ),
              ],
            ),
            Column(
              children: [
                const Text(
                  'Holes',
                  style: TextStyle(color: Colors.grey),
                ),
                Text(
                  '${scores.where((h) => h.score > 0).length}/$totalHoles',
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHoleCard(HoleScore hole) {
    final isCompleted = hole.score > 0;
    final scoreDiff = hole.score - hole.par;

    String scoreLabel = '';
    Color scoreColor = Colors.grey;

    if (isCompleted) {
      if (scoreDiff == -2) {
        scoreLabel = 'Eagle';
        scoreColor = Colors.amber;
      } else if (scoreDiff == -1) {
        scoreLabel = 'Birdie';
        scoreColor = Colors.green;
      } else if (scoreDiff == 0) {
        scoreLabel = 'Par';
        scoreColor = Colors.blue;
      } else if (scoreDiff == 1) {
        scoreLabel = 'Bogey';
        scoreColor = Colors.orange;
      } else if (scoreDiff >= 2) {
        scoreLabel = 'Double+';
        scoreColor = Colors.red;
      }
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: isCompleted ? const Color(0xFF16213e) : const Color(0xFF0f3460),
      child: ExpansionTile(
        title: Row(
          children: [
            SizedBox(
              width: 60,
              child: Text(
                'Hole ${hole.holeNumber}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Text('Par ${hole.par}', style: const TextStyle(color: Colors.grey)),
            const Spacer(),
            if (isCompleted)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: scoreColor.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  scoreLabel,
                  style: TextStyle(
                    color: scoreColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            const SizedBox(width: 16),
            Text(
              isCompleted ? '${hole.score}' : '-',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const Text('Enter Score:'),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (int i = 1; i <= 7; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ElevatedButton(
                          onPressed: () => _updateScore(hole.holeNumber, i),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: hole.score == i
                                ? Colors.blue
                                : Colors.grey[800],
                            shape: const CircleBorder(),
                            padding: const EdgeInsets.all(16),
                          ),
                          child: Text(
                            '$i',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Data Models
// ============================================================================

class HoleScore {
  final int holeNumber;
  final int par;
  int score;

  HoleScore({
    required this.holeNumber,
    required this.par,
    this.score = 0,
  });
}