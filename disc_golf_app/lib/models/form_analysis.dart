import 'package:flutter/material.dart';

class FormFrame {
  final Duration timestamp;
  final Map<String, double> angles;
  final Map<String, Offset> keyPoints;
  /// Z-depth per landmark from ML Kit (relative, same scale as x).
  /// Positive = in front of camera. Empty for manually-corrected frames.
  final Map<String, double> landmarkZ;
  /// Per-landmark detection confidence (0–1) from ML Kit likelihood.
  /// Empty for manually-corrected frames (treat as fully trusted).
  final Map<String, double> landmarkConf;
  final double? imageWidth;
  final double? imageHeight;

  FormFrame({
    required this.timestamp,
    required this.angles,
    required this.keyPoints,
    Map<String, double>? landmarkZ,
    Map<String, double>? landmarkConf,
    this.imageWidth,
    this.imageHeight,
  })  : landmarkZ = landmarkZ ?? {},
        landmarkConf = landmarkConf ?? {};

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.inMilliseconds,
      'angles': angles,
      'keyPoints': keyPoints.map(
        (key, value) => MapEntry(key, {'dx': value.dx, 'dy': value.dy}),
      ),
      if (landmarkZ.isNotEmpty) 'landmarkZ': landmarkZ,
      if (landmarkConf.isNotEmpty) 'landmarkConf': landmarkConf,
      if (imageWidth != null) 'imageWidth': imageWidth,
      if (imageHeight != null) 'imageHeight': imageHeight,
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
      landmarkZ: json['landmarkZ'] != null
          ? Map<String, double>.from(json['landmarkZ'] as Map)
          : {},
      landmarkConf: json['landmarkConf'] != null
          ? Map<String, double>.from(json['landmarkConf'] as Map)
          : {},
      imageWidth: json['imageWidth'] as double?,
      imageHeight: json['imageHeight'] as double?,
    );
  }
}

class FormAnalysis {
  final String id;
  final DateTime date;
  final String videoPath;
  final List<FormFrame> frames;
  final double score;
  /// True when pose detection failed and mock data was substituted.
  bool isMock;

  FormAnalysis({
    required this.id,
    required this.date,
    required this.videoPath,
    required this.frames,
    required this.score,
    this.isMock = false,
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
