import 'dart:convert';
import 'package:flutter/services.dart';

class FlightDataService {
  /// Load flight path coordinates from JSON file
  static Future<String> loadFlightPath() async {
    try {
      return await rootBundle.loadString('assets/data/output_coordinates.json');
    } catch (e) {
      print('Error loading flight path: $e');
      rethrow;
    }
  }
  
  /// Load form analysis results from JSON file
  static Future<Map<String, dynamic>> loadAnalysisResults() async {
    try {
      final String jsonString = await rootBundle.loadString('assets/data/analysis_results.json');
      return json.decode(jsonString) as Map<String, dynamic>;
    } catch (e) {
      print('Error loading analysis results: $e');
      rethrow;
    }
  }
  
  /// Check if flight data exists
  static Future<bool> hasFlightData() async {
    try {
      await loadFlightPath();
      return true;
    } catch (e) {
      return false;
    }
  }
  
  /// Check if analysis results exist
  static Future<bool> hasAnalysisResults() async {
    try {
      await loadAnalysisResults();
      return true;
    } catch (e) {
      return false;
    }
  }
}