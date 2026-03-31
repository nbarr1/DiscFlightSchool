import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/tracking_service.dart';
import 'services/video_service.dart';
import 'services/posture_analysis_service.dart';
import 'services/scoring_service.dart';
import 'services/disc_detection_service.dart';
import 'services/knowledge_base_service.dart';
import 'services/training_data_service.dart';
import 'screens/home_screen.dart';

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
        ChangeNotifierProvider(create: (_) => ScoringService()),
        ChangeNotifierProvider.value(value: _discDetectionService),
        ChangeNotifierProvider(create: (_) => TrainingDataService()..init()),
        ChangeNotifierProvider(create: (_) => KnowledgeBaseService()),
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
        home: const HomeScreen(),
      ),
    );
  }
}
