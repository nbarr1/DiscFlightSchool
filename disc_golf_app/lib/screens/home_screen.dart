import 'package:flutter/material.dart';
import 'flight_tracker/flight_tracker_screen.dart';
import 'form_coach/form_coach_screen.dart';
import 'roulette/roulette_screen.dart';
import 'roulette/start_round_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Disc Golf Training App'),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.sports_golf,
                  size: 80,
                  color: Colors.green,
                ),
                const SizedBox(height: 40),
                const Text(
                  'Welcome to Disc Golf Trainer',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                _buildFeatureButton(
                  context,
                  'Flight Tracker',
                  'Track and analyze disc flight paths',
                  Icons.track_changes,
                  Colors.blue,
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const FlightTrackerScreen(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildFeatureButton(
                  context,
                  'Form Coach',
                  'Analyze and improve your throwing form',
                  Icons.accessibility_new,
                  Colors.orange,
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const FormCoachScreen(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildFeatureButton(
                  context,
                  'Disc Roulette',
                  'Random disc selection game',
                  Icons.casino,
                  Colors.purple,
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const RouletteScreen(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildFeatureButton(
                  context,
                  'Start Scoring Round',
                  'Play a scored round with challenges',
                  Icons.score,
                  Colors.green,
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const StartRoundScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureButton(
    BuildContext context,
    String title,
    String description,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return Card(
      elevation: 4,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: 32,
                  color: color,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                color: Colors.grey[400],
              ),
            ],
          ),
        ),
      ),
    );
  }
}