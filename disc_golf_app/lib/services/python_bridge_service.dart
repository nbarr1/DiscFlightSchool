import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class PythonBridgeService {
  static const String baseUrl = 'http://localhost:5000/api';

  static Future<bool> checkConnection() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/health'));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> trackDisc(String videoPath) {
    return _postVideo('$baseUrl/track-flight', videoPath);
  }

  static Future<Map<String, dynamic>?> analyzePose(String videoPath) {
    return _postVideo('$baseUrl/analyze-form', videoPath);
  }

  static Future<Map<String, dynamic>?> _postVideo(
    String url,
    String videoPath,
  ) async {
    try {
      final file = File(videoPath);
      if (!await file.exists()) return null;

      final request = http.MultipartRequest('POST', Uri.parse(url));
      request.files.add(await http.MultipartFile.fromPath('video', videoPath));
      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      debugPrint('Python bridge error ${response.statusCode}: ${response.body}');
    } catch (e) {
      debugPrint('Python bridge request failed: $e');
    }
    return null;
  }
}
