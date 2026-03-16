import 'package:flutter/material.dart';

class ComparisonScreen extends StatelessWidget {
  const ComparisonScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Form Comparison'),
      ),
      body: const Center(
        child: Text('Side-by-side comparison coming soon!'),
      ),
    );
  }
}