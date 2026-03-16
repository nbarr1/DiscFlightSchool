import 'package:flutter/material.dart';

class FlightData {
  final String id;
  final double distance;
  final double maxHeight;
  final double flightTime;
  final double speed;
  final double launchAngle;
  final List<Offset> points;
  final String? videoPath;
  final String? discId;
  final DateTime recordedAt;

  FlightData({
    String? id,
    required this.distance,
    required this.maxHeight,
    required this.flightTime,
    required this.speed,
    required this.launchAngle,
    required this.points,
    this.videoPath,
    this.discId,
    DateTime? recordedAt,
  })  : id = id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        recordedAt = recordedAt ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'distance': distance,
      'maxHeight': maxHeight,
      'flightTime': flightTime,
      'speed': speed,
      'launchAngle': launchAngle,
      'points': points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
      'videoPath': videoPath,
      'discId': discId,
      'recordedAt': recordedAt.toIso8601String(),
    };
  }

  factory FlightData.fromJson(Map<String, dynamic> json) {
    return FlightData(
      id: json['id'],
      distance: json['distance'],
      maxHeight: json['maxHeight'],
      flightTime: json['flightTime'],
      speed: json['speed'],
      launchAngle: json['launchAngle'],
      points: (json['points'] as List)
          .map((p) => Offset(p['x'], p['y']))
          .toList(),
      videoPath: json['videoPath'],
      discId: json['discId'],
      recordedAt: DateTime.parse(json['recordedAt']),
    );
  }
}