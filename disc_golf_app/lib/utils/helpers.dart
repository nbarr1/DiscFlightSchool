import 'dart:math';

class Helpers {
  // Calculate distance between two points
  static double calculateDistance(double x1, double y1, double x2, double y2) {
    return sqrt(pow(x2 - x1, 2) + pow(y2 - y1, 2));
  }

  // Calculate angle between three points
  static double calculateAngle(
    double x1, double y1,
    double x2, double y2,
    double x3, double y3,
  ) {
    final angle1 = atan2(y1 - y2, x1 - x2);
    final angle2 = atan2(y3 - y2, x3 - x2);
    var angle = (angle2 - angle1) * 180 / pi;
    
    if (angle < 0) angle += 360;
    if (angle > 180) angle = 360 - angle;
    
    return angle;
  }

  // Format duration to readable string
  static String formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  // Calculate flight statistics
  static Map<String, double> calculateFlightStats(List<Map<String, double>> points) {
    if (points.isEmpty) return {};

    double maxHeight = 0;
    double totalDistance = 0;

    for (var point in points) {
      if (point['y']! < maxHeight) maxHeight = point['y']!;
    }

    if (points.length > 1) {
      final firstPoint = points.first;
      final lastPoint = points.last;
      totalDistance = calculateDistance(
        firstPoint['x']!,
        firstPoint['y']!,
        lastPoint['x']!,
        lastPoint['y']!,
      );
    }

    return {
      'maxHeight': maxHeight.abs(),
      'distance': totalDistance,
    };
  }

  // Interpolate between two values
  static double interpolate(double start, double end, double t) {
    return start + (end - start) * t;
  }
}