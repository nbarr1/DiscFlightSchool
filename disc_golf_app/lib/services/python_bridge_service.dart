import 'dart:convert';
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

  static Future<Map<String, dynamic>?> trackDisc(String videoPath) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/track'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'video_path': videoPath}),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      print('Error tracking disc: $e');
    }
    return null;
  }

  static Future<Map<String, dynamic>?> analyzePose(String videoPath) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/analyze_form'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'video_path': videoPath}),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      print('Error analyzing pose: $e');
    }
    return null;
  }
}