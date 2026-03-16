import 'package:flutter/material.dart';

class FormFrame {
  final Duration timestamp;
  final Map<String, double> angles;
  final Map<String, Offset> keyPoints;

  FormFrame({
    required this.timestamp,
    required this.angles,
    required this.keyPoints,
  });

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.inMilliseconds,
      'angles': angles,
      'keyPoints': keyPoints.map(
        (key, value) => MapEntry(key, {'dx': value.dx, 'dy': value.dy}),
      ),
    };
  }

  factory FormFrame.fromJson(Map<String, dynamic> json) {
    return FormFrame(
      timestamp: Duration(milliseconds: json['timestamp'] as int),
      angles: Map<String, double>.from(json['angles'] as Map),
      keyPoints: (json['keyPoints'] as Map).map(
        (key, value) => MapEntry(
          key.toString(),
          Offset(value['dx'] as double, value['dy'] as double),
        ),
      ),
    );
  }
}

class FormAnalysis {
  final String id;
  final DateTime date;
  final String videoPath;
  final List<FormFrame> frames;
  final double score;

  FormAnalysis({
    required this.id,
    required this.date,
    required this.videoPath,
    required this.frames,
    required this.score,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'videoPath': videoPath,
      'frames': frames.map((f) => f.toJson()).toList(),
      'score': score,
    };
  }

  factory FormAnalysis.fromJson(Map<String, dynamic> json) {
    return FormAnalysis(
      id: json['id'] as String,
      date: DateTime.parse(json['date'] as String),
      videoPath: json['videoPath'] as String,
      frames: (json['frames'] as List)
          .map((f) => FormFrame.fromJson(f as Map<String, dynamic>))
          .toList(),
      score: json['score'] as double,
    );
  }
}

class ProFormData {
  final String playerName;
  final FormAnalysis analysis;
  final String description;

  ProFormData({
    required this.playerName,
    required this.analysis,
    required this.description,
  });
}