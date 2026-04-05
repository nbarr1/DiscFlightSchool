import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/tracking_service.dart';
import 'services/video_service.dart';
import 'services/posture_analysis_service.dart';
// import 'services/scoring_service.dart'; // ARCHIVED
import 'services/disc_detection_service.dart';
import 'services/form_history_service.dart';
import 'services/roulette_history_service.dart';
import 'services/knowledge_base_service.dart';
import 'services/training_data_service.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding/onboarding_screen.dart';

void main() {
  runApp(const DiscGolfApp());
}

class DiscGolfApp extends StatefulWidget {
  const DiscGolfApp({super.key});

  @override
  State<DiscGolfApp> createState() => _DiscGolfAppState();
}

class _DiscGolfAppState extends State<DiscGolfApp> {
  final _postureAnalysisService = PostureAnalysisService();
  final _discDetectionService = DiscDetectionService();

  @override
  void dispose() {
    _postureAnalysisService.dispose();
    _discDetectionService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TrackingService()),
        ChangeNotifierProvider(create: (_) => VideoService()),
        ChangeNotifierProvider.value(value: _postureAnalysisService),
        // ChangeNotifierProvider(create: (_) => ScoringService()), // ARCHIVED
        ChangeNotifierProvider.value(value: _discDetectionService),
        ChangeNotifierProvider(create: (_) => TrainingDataService()..init()),
        ChangeNotifierProvider(create: (_) => KnowledgeBaseService()),
        ChangeNotifierProvider(create: (_) => FormHistoryService()),
        ChangeNotifierProvider(create: (_) => RouletteHistoryService()),
      ],
      child: MaterialApp(
        title: 'Disc Flight School',
        theme: ThemeData(
          primarySwatch: Colors.blue,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF1a1a2e),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF0f3460),
          ),
          cardTheme: const CardThemeData(
            color: Color(0xFF16213e),
            elevation: 4,
          ),
        ),
        builder: (context, child) {
          return SafeArea(
            top: false, // AppBar handles top inset
            child: child!,
          );
        },
        home: const _StartupRouter(),
      ),
    );
  }
}

/// Shows [OnboardingScreen] on first launch, [HomeScreen] on every subsequent
/// launch. Decision is made by reading 'onboarding_complete' from SharedPrefs.
class _StartupRouter extends StatelessWidget {
  const _StartupRouter();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SharedPreferences>(
      future: SharedPreferences.getInstance(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final complete = snap.data!.getBool('onboarding_complete') ?? false;
        return complete ? const HomeScreen() : const OnboardingScreen();
      },
    );
  }
}
