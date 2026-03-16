import 'package:flutter/material.dart';

class GameSessionScreen extends StatelessWidget {
  const GameSessionScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Game Session'),
      ),
      body: const Center(child: Text('Multi-player session tracking coming soon!'),
      ),
    );
  }
}