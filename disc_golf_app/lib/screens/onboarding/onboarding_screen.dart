import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../home_screen.dart';

/// Five-page first-launch onboarding walkthrough.
/// Shown once; completion is persisted in SharedPreferences.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pages = [
    _OnboardingPage(
      icon: Icons.sports,
      color: Color(0xFF0f3460),
      title: 'Welcome to\nDisc Flight School',
      body:
          'Your personal disc golf coach — analyze your form, track disc flight, '
          'and practice smarter with guided challenges.',
      isFirst: true,
    ),
    _OnboardingPage(
      icon: Icons.accessibility_new,
      color: Color(0xFF16213e),
      title: 'Form Coach',
      body:
          'Record a throw and let AI-powered pose detection score your technique. '
          'Compare against pro baselines phase by phase and get targeted cues to fix '
          'the angles that matter most.',
    ),
    _OnboardingPage(
      icon: Icons.track_changes,
      color: Color(0xFF0f3460),
      title: 'Flight Tracker',
      body:
          'Place disc markers on your video frame by frame to map the exact '
          'flight path. Zoom in for precise placement, draw a target line, '
          'and export the full trajectory data.',
    ),
    _OnboardingPage(
      icon: Icons.casino,
      color: Color(0xFF16213e),
      title: 'Disc Roulette',
      body:
          'Spin the wheel to get a random disc, distance, and difficulty '
          'combination. Add hindrances or power boosts for extra challenge — '
          'great for structured field work.',
    ),
    _OnboardingPage(
      icon: Icons.menu_book,
      color: Color(0xFF0f3460),
      title: 'Knowledge Base',
      body:
          'Browse tips, drills, and technique articles — or ask the AI assistant '
          'a specific question. Everything you need to understand the "why" behind '
          'the cues.',
      isLast: true,
    ),
  ];

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_complete', true);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  void _next() {
    if (_page < _pages.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _finish();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _pages.length - 1;

    return Scaffold(
      body: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: _pages.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => _pages[i],
          ),

          // Bottom nav
          Positioned(
            left: 0,
            right: 0,
            bottom: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Skip
                  TextButton(
                    onPressed: isLast ? null : _finish,
                    child: Text(
                      isLast ? '' : 'Skip',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),

                  // Dot indicators
                  Row(
                    children: List.generate(
                      _pages.length,
                      (i) => AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        margin:
                            const EdgeInsets.symmetric(horizontal: 4),
                        width: i == _page ? 18 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: i == _page
                              ? Colors.lightBlueAccent
                              : Colors.white24,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),

                  // Next / Get Started
                  ElevatedButton(
                    onPressed: _next,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.lightBlueAccent,
                      foregroundColor: Colors.black87,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
                    ),
                    child: Text(isLast ? 'Get Started' : 'Next'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final bool isFirst;
  final bool isLast;

  const _OnboardingPage({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.isFirst = false,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      padding: const EdgeInsets.fromLTRB(32, 80, 32, 100),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.white10,
              shape: BoxShape.circle,
              border:
                  Border.all(color: Colors.lightBlueAccent, width: 2),
            ),
            child: Icon(icon,
                size: 64, color: Colors.lightBlueAccent),
          ),
          const SizedBox(height: 40),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              color: Colors.white70,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
