import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class FeedbackService {
  static Future<void> log(Map<String, dynamic> feedback) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/verification_feedback.json');
    final entries = file.existsSync()
        ? json.decode(await file.readAsString()) as List
        : [];
    entries.add({...feedback, 'timestamp': DateTime.now().toIso8601String()});
    await file.writeAsString(json.encode(entries));
  }
}
