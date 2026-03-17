import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/tracking_service.dart';
import 'services/video_service.dart';
import 'services/posture_analysis_service.dart';
import 'services/scoring_service.dart';
import 'services/disc_detection_service.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const DiscGolfApp());
}

class DiscGolfApp extends StatelessWidget {
  const DiscGolfApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TrackingService()),
        ChangeNotifierProvider(create: (_) => VideoService()),
        ChangeNotifierProvider(create: (_) => PostureAnalysisService()),
        ChangeNotifierProvider(create: (_) => ScoringService()),
        ChangeNotifierProvider(create: (_) => DiscDetectionService()),
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
        home: const HomeScreen(),
      ),
    );
  }
}
