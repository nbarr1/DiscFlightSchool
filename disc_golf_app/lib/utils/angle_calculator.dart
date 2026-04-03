import 'dart:math';
import 'dart:ui';

/// Shared utility for angle calculations and Catmull-Rom spline interpolation.
/// Extracted from PostureAnalysisService and VideoPlayerScreen to allow reuse
/// across pose correction and hybrid disc detection features.
class AngleCalculator {
  // ---------------------------------------------------------------------------
  // 2-D helpers
  // ---------------------------------------------------------------------------

  /// Calculate the angle in degrees at vertex B, formed by points A-B-C.
  static double angleBetween(Offset a, Offset b, Offset c) {
    final ba = Offset(a.dx - b.dx, a.dy - b.dy);
    final bc = Offset(c.dx - b.dx, c.dy - b.dy);

    final dot = ba.dx * bc.dx + ba.dy * bc.dy;
    final magBA = sqrt(ba.dx * ba.dx + ba.dy * ba.dy);
    final magBC = sqrt(bc.dx * bc.dx + bc.dy * bc.dy);

    if (magBA == 0 || magBC == 0) return 0.0;

    final cosAngle = dot / (magBA * magBC);
    return acos(cosAngle.clamp(-1.0, 1.0)) * (180 / pi);
  }

  /// Calculate all 7 app angles from a keyPoints map.
  /// Keys must be in the format 'PoseLandmarkType.rightShoulder', etc.
  static Map<String, double> calculateFromKeyPoints(
      Map<String, Offset> keyPoints) {
    final angles = <String, double>{};

    Offset? kp(String name) => keyPoints['PoseLandmarkType.$name'];

    final rightShoulder = kp('rightShoulder');
    final rightElbow = kp('rightElbow');
    final rightWrist = kp('rightWrist');
    final rightHip = kp('rightHip');
    final leftShoulder = kp('leftShoulder');
    final leftElbow = kp('leftElbow');
    final leftWrist = kp('leftWrist');
    final leftHip = kp('leftHip');
    final rightKnee = kp('rightKnee');
    final rightAnkle = kp('rightAnkle');
    final leftKnee = kp('leftKnee');
    final leftAnkle = kp('leftAnkle');

    if (rightShoulder != null && rightElbow != null && rightWrist != null) {
      angles['rightElbowAngle'] =
          angleBetween(rightShoulder, rightElbow, rightWrist);
    }
    if (leftShoulder != null && leftElbow != null && leftWrist != null) {
      angles['leftElbowAngle'] =
          angleBetween(leftShoulder, leftElbow, leftWrist);
    }
    if (rightElbow != null && rightShoulder != null && rightHip != null) {
      angles['rightShoulderAngle'] =
          angleBetween(rightElbow, rightShoulder, rightHip);
    }
    if (leftElbow != null && leftShoulder != null && leftHip != null) {
      angles['leftShoulderAngle'] =
          angleBetween(leftElbow, leftShoulder, leftHip);
    }
    if (rightHip != null && rightKnee != null && rightAnkle != null) {
      angles['rightKneeAngle'] =
          angleBetween(rightHip, rightKnee, rightAnkle);
    }
    if (leftHip != null && leftKnee != null && leftAnkle != null) {
      angles['leftKneeAngle'] = angleBetween(leftHip, leftKnee, leftAnkle);
    }

    // Spine angle — uses midpoints of shoulders and hips
    if (rightShoulder != null &&
        leftShoulder != null &&
        rightHip != null &&
        leftHip != null) {
      final shoulderMidX = (rightShoulder.dx + leftShoulder.dx) / 2;
      final shoulderMidY = (rightShoulder.dy + leftShoulder.dy) / 2;
      final hipMidX = (rightHip.dx + leftHip.dx) / 2;
      final hipMidY = (rightHip.dy + leftHip.dy) / 2;

      final spineAngle = atan2(
            shoulderMidX - hipMidX,
            hipMidY - shoulderMidY, // y-down in image coords
          ) *
          (180 / pi);
      angles['spineAngle'] = 90 - spineAngle.abs();
    }

    return angles;
  }

  // ---------------------------------------------------------------------------
  // 3-D helpers
  // ---------------------------------------------------------------------------

  /// Typedef for a 3-D point record used by the 3D API.
  /// Using Dart records avoids adding a vector3 dependency.
  // ignore: library_private_types_in_public_api
  static ({double x, double y, double z}) _vec(double x, double y, double z) =>
      (x: x, y: y, z: z);

  static ({double x, double y, double z}) _sub(
    ({double x, double y, double z}) a,
    ({double x, double y, double z}) b,
  ) =>
      _vec(a.x - b.x, a.y - b.y, a.z - b.z);

  static double _dot(
    ({double x, double y, double z}) a,
    ({double x, double y, double z}) b,
  ) =>
      a.x * b.x + a.y * b.y + a.z * b.z;

  static double _mag(({double x, double y, double z}) v) =>
      sqrt(v.x * v.x + v.y * v.y + v.z * v.z);

  static ({double x, double y, double z}) _cross(
    ({double x, double y, double z}) a,
    ({double x, double y, double z}) b,
  ) =>
      _vec(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
      );

  /// Calculate the angle in degrees at vertex B using 3-D coordinates.
  /// Returns [double.nan] if any vector has zero magnitude.
  static double angleBetween3D(
    ({double x, double y, double z}) a,
    ({double x, double y, double z}) b,
    ({double x, double y, double z}) c,
  ) {
    final ba = _sub(a, b);
    final bc = _sub(c, b);
    final magBA = _mag(ba);
    final magBC = _mag(bc);
    if (magBA == 0 || magBC == 0) return double.nan;
    final cosAngle = _dot(ba, bc) / (magBA * magBC);
    return acos(cosAngle.clamp(-1.0, 1.0)) * (180 / pi);
  }

  /// Compute the X-factor: the signed angle between the shoulder plane and the
  /// hip plane, projected onto the vertical axis (Y-axis in image space).
  ///
  /// A positive value means the shoulders have rotated further than the hips —
  /// the key mechanical advantage in disc golf and golf.
  ///
  /// Returns [double.nan] if depth data is degenerate.
  static double xFactor3D(
    ({double x, double y, double z}) rightShoulder,
    ({double x, double y, double z}) leftShoulder,
    ({double x, double y, double z}) rightHip,
    ({double x, double y, double z}) leftHip,
  ) {
    // Shoulder axis vector (left→right)
    final shoulderAxis = _sub(rightShoulder, leftShoulder);
    // Hip axis vector (left→right)
    final hipAxis = _sub(rightHip, leftHip);

    final magS = _mag(shoulderAxis);
    final magH = _mag(hipAxis);
    if (magS == 0 || magH == 0) return double.nan;

    // Project both axes onto the horizontal plane (ignore y component)
    final sFlat = _vec(shoulderAxis.x, 0, shoulderAxis.z);
    final hFlat = _vec(hipAxis.x, 0, hipAxis.z);
    final magSF = _mag(sFlat);
    final magHF = _mag(hFlat);
    if (magSF == 0 || magHF == 0) return double.nan;

    final cosAngle = _dot(sFlat, hFlat) / (magSF * magHF);
    final angle = acos(cosAngle.clamp(-1.0, 1.0)) * (180 / pi);

    // Determine sign via cross product Y component
    final cross = _cross(sFlat, hFlat);
    return cross.y >= 0 ? angle : -angle;
  }

  // ---------------------------------------------------------------------------
  // Catmull-Rom spline interpolation
  // ---------------------------------------------------------------------------

  /// Catmull-Rom spline interpolation for a single scalar value.
  static double catmullRom(
      double p0, double p1, double p2, double p3, double t) {
    final t2 = t * t;
    final t3 = t2 * t;
    return 0.5 *
        ((2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
  }

  /// Catmull-Rom spline interpolation for 2D points.
  static Offset catmullRomOffset(
      Offset p0, Offset p1, Offset p2, Offset p3, double t) {
    return Offset(
      catmullRom(p0.dx, p1.dx, p2.dx, p3.dx, t),
      catmullRom(p0.dy, p1.dy, p2.dy, p3.dy, t),
    );
  }

  /// Interpolate positions between anchor frames using Catmull-Rom splines.
  /// [anchorFrames] maps frame index → position. Returns interpolated
  /// positions for every frame in [startFrame..endFrame].
  static Map<int, Offset> interpolateAnchors(
    Map<int, Offset> anchorFrames,
    int startFrame,
    int endFrame,
  ) {
    if (anchorFrames.isEmpty) return {};

    final sortedKeys = anchorFrames.keys.toList()..sort();
    final result = <int, Offset>{};

    for (final key in sortedKeys) {
      result[key] = anchorFrames[key]!;
    }

    for (int i = 0; i < sortedKeys.length - 1; i++) {
      final f1 = sortedKeys[i];
      final f2 = sortedKeys[i + 1];
      final span = f2 - f1;
      if (span <= 1) continue;

      final p0 = i > 0
          ? anchorFrames[sortedKeys[i - 1]]!
          : anchorFrames[f1]!;
      final p1 = anchorFrames[f1]!;
      final p2 = anchorFrames[f2]!;
      final p3 = i < sortedKeys.length - 2
          ? anchorFrames[sortedKeys[i + 2]]!
          : anchorFrames[f2]!;

      for (int f = 1; f < span; f++) {
        final t = f / span;
        result[f1 + f] = catmullRomOffset(p0, p1, p2, p3, t);
      }
    }

    return result;
  }
}
