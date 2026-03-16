import 'package:flutter/material.dart';

class TrackingService extends ChangeNotifier {
  List<Offset> _trackingPoints = [];
  List<Offset> _flightPoints = [];
  String? _currentVideoPath;
  Map<String, dynamic>? _flightAnalysis;
  bool _isManualMode = true;
  bool _isTracking = false;

  List<Offset> get trackingPoints => List.unmodifiable(_trackingPoints);
  List<Offset> get flightPoints => List.unmodifiable(_flightPoints);
  String? get currentVideoPath => _currentVideoPath;
  Map<String, dynamic>? get flightAnalysis => _flightAnalysis;
  bool get isManualMode => _isManualMode;
  bool get isTracking => _isTracking;

  void toggleManualMode() {
    _isManualMode = !_isManualMode;
    notifyListeners();
  }

  void addPoint(Offset point) {
    _trackingPoints.add(point);
    notifyListeners();
  }

  void addManualPoint(Offset point) {
    _flightPoints.add(point);
    notifyListeners();
  }

  void removeLastPoint() {
    if (_trackingPoints.isNotEmpty) {
      _trackingPoints.removeLast();
      notifyListeners();
    }
  }

  void clearPoints() {
    _trackingPoints.clear();
    _flightPoints.clear();
    _flightAnalysis = null;
    notifyListeners();
  }

  void setPoints(List<Offset> points) {
    _trackingPoints = List.from(points);
    notifyListeners();
  }

  void setVideoPath(String? path) {
    _currentVideoPath = path;
    notifyListeners();
  }

  // Auto-track video (placeholder for future AI implementation)
  Future<void> autoTrackVideo(String videoPath, String discId) async {
    _isTracking = true;
    notifyListeners();

    // Simulate processing delay
    await Future.delayed(const Duration(seconds: 2));

    // TODO: Implement actual video tracking with ML/CV
    // For now, generate sample points
    _flightPoints = _generateSampleFlightPath();

    _isTracking = false;
    notifyListeners();
  }

  // Generate sample flight path for testing
  List<Offset> _generateSampleFlightPath() {
    final points = <Offset>[];
    for (int i = 0; i < 20; i++) {
      final x = 50.0 + (i * 15.0);
      final y = 200.0 - (i * 5.0) + (i > 10 ? (i - 10) * 3.0 : 0);
      points.add(Offset(x, y));
    }
    return points;
  }

  // Interpolate points for smooth curve
  List<Offset> interpolatePoints(List<Offset> points, int targetCount) {
    if (points.length < 2) return points;
    if (points.length >= targetCount) return points;

    final interpolated = <Offset>[];
    final segmentCount = targetCount - 1;
    final step = (points.length - 1) / segmentCount;

    for (int i = 0; i < targetCount; i++) {
      final index = i * step;
      final lowerIndex = index.floor();
      final upperIndex = (lowerIndex + 1).clamp(0, points.length - 1);
      final t = index - lowerIndex;

      if (lowerIndex == upperIndex) {
        interpolated.add(points[lowerIndex]);
      } else {
        final p1 = points[lowerIndex];
        final p2 = points[upperIndex];
        final x = p1.dx + (p2.dx - p1.dx) * t;
        final y = p1.dy + (p2.dy - p1.dy) * t;
        interpolated.add(Offset(x, y));
      }
    }

    return interpolated;
  }

  void analyzeFlightPath() {
    final points = _flightPoints.isNotEmpty ? _flightPoints : _trackingPoints;
    
    if (points.length < 2) {
      _flightAnalysis = null;
      notifyListeners();
      return;
    }

    // Calculate flight metrics
    final startPoint = points.first;
    final endPoint = points.last;
    
    // Calculate total distance
    double totalDistance = 0;
    for (int i = 0; i < points.length - 1; i++) {
      final dx = points[i + 1].dx - points[i].dx;
      final dy = points[i + 1].dy - points[i].dy;
      totalDistance += (dx * dx + dy * dy).abs();
    }

    // Calculate straight-line distance
    final straightDistance = ((endPoint.dx - startPoint.dx) * (endPoint.dx - startPoint.dx) + 
                             (endPoint.dy - startPoint.dy) * (endPoint.dy - startPoint.dy)).abs();

    // Calculate turn/fade
    final horizontalMovement = endPoint.dx - startPoint.dx;
    final verticalMovement = endPoint.dy - startPoint.dy;

    // Find apex (highest point)
    double highestY = points.first.dy;
    int apexIndex = 0;
    for (int i = 0; i < points.length; i++) {
      if (points[i].dy < highestY) {
        highestY = points[i].dy;
        apexIndex = i;
      }
    }

    // Determine flight shape
    String flightShape;
    if (horizontalMovement.abs() < 50) {
      flightShape = 'Straight';
    } else if (horizontalMovement < 0) {
      flightShape = 'Fade Left';
    } else {
      flightShape = 'Fade Right';
    }

    // Calculate flight stability (ratio of actual path to straight line)
    final stability = straightDistance / (totalDistance + 1);

    _flightAnalysis = {
      'totalDistance': totalDistance.toStringAsFixed(1),
      'straightDistance': straightDistance.toStringAsFixed(1),
      'horizontalMovement': horizontalMovement.toStringAsFixed(1),
      'verticalMovement': verticalMovement.toStringAsFixed(1),
      'apexIndex': apexIndex,
      'apexPercentage': ((apexIndex / points.length) * 100).toStringAsFixed(0),
      'flightShape': flightShape,
      'stability': (stability * 100).toStringAsFixed(0),
      'pointCount': points.length,
    };

    notifyListeners();
  }

  // Get flight path as a list of points for drawing
  List<Offset> getFlightPath() {
    return _flightPoints.isNotEmpty ? List.from(_flightPoints) : List.from(_trackingPoints);
  }

  // Check if we have enough points for analysis
  bool get hasEnoughPoints => (_flightPoints.isNotEmpty ? _flightPoints.length : _trackingPoints.length) >= 2;

  // Get a simplified version of the path (for performance)
  List<Offset> getSimplifiedPath({int maxPoints = 50}) {
    final points = _flightPoints.isNotEmpty ? _flightPoints : _trackingPoints;
    
    if (points.length <= maxPoints) {
      return List.from(points);
    }

    final step = points.length / maxPoints;
    final simplified = <Offset>[];
    
    for (int i = 0; i < maxPoints; i++) {
      final index = (i * step).floor();
      if (index < points.length) {
        simplified.add(points[index]);
      }
    }

    // Always include the last point
    if (simplified.last != points.last) {
      simplified.add(points.last);
    }

    return simplified;
  }
}