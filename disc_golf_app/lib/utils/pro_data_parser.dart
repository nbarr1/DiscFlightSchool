import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/form_analysis.dart';

/// Parses pro_baseline_db.json and generates interpolated per-frame
/// angle curves from 4-phase snapshot data for use as reference in waveforms.
class ProBaselineParser {
  static Map<String, dynamic>? _cachedData;

  static Future<Map<String, dynamic>> _loadRawData() async {
    if (_cachedData != null) return _cachedData!;
    final jsonStr =
        await rootBundle.loadString('assets/data/pro_baseline_db.json');
    _cachedData = json.decode(jsonStr) as Map<String, dynamic>;
    return _cachedData!;
  }

  /// Get the list of available pro player names.
  static Future<List<String>> getPlayerNames() async {
    final data = await _loadRawData();
    final players = data['players'] as Map<String, dynamic>;
    return players.keys.toList();
  }

  /// Check if a player has data for a given throw type ('BH' or 'FH').
  static Future<bool> hasThrowType(String playerName, String throwType) async {
    final data = await _loadRawData();
    final players = data['players'] as Map<String, dynamic>;
    final player = players[playerName] as Map<String, dynamic>?;
    if (player == null) return false;
    final throws = player['throws'] as Map<String, dynamic>;
    return throws.containsKey(throwType);
  }

  /// Mapping from pro JSON angle names to app angle names.
  /// BH assumes right-hand backhand (RHBH).
  static Map<String, String> _getAngleMapping(String throwType) {
    if (throwType == 'BH') {
      return {
        'elbow_flexion_deg': 'rightElbowAngle',
        'shoulder_abduction_deg': 'rightShoulderAngle',
        'lead_knee_flexion_deg': 'rightKneeAngle', // RHBH lead = R side
        'trail_knee_flexion_deg': 'leftKneeAngle',  // RHBH trail = L side
        'trunk_lateral_tilt_deg': 'spineAngle',
        // x_factor_deg and hip_rotation_deg skipped — no app equivalent
      };
    } else {
      // FH
      return {
        'elbow_flexion_deg': 'leftElbowAngle',
        'shoulder_abduction_deg': 'leftShoulderAngle',
        'lead_knee_flexion_deg': 'rightKneeAngle',
        'trail_knee_flexion_deg': 'leftKneeAngle',
        'trunk_lateral_tilt_deg': 'spineAngle',
      };
    }
  }

  /// Phase names in order for each throw type.
  static List<String> _getPhaseOrder(String throwType) {
    if (throwType == 'BH') {
      return ['reach_back', 'power_pocket', 'release', 'follow_through'];
    } else {
      return ['wind_up', 'power_pocket', 'release', 'follow_through'];
    }
  }

  /// Generate a FormAnalysis with interpolated per-frame angle data
  /// from pro phase snapshots.
  static Future<FormAnalysis> generateProAnalysis(
    String playerName,
    String throwType, {
    int frameCount = 30,
  }) async {
    final data = await _loadRawData();
    final players = data['players'] as Map<String, dynamic>;
    final player = players[playerName] as Map<String, dynamic>;
    final throws = player['throws'] as Map<String, dynamic>;
    final throwData = throws[throwType] as Map<String, dynamic>;
    final phases = throwData['phases'] as Map<String, dynamic>;

    final phaseOrder = _getPhaseOrder(throwType);
    final angleMapping = _getAngleMapping(throwType);

    // Phase frame positions (evenly spaced across frameCount)
    final phaseFrames = [
      0,
      (frameCount * 0.33).round(),
      (frameCount * 0.67).round(),
      frameCount - 1,
    ];

    // Also fill in non-throwing side with reasonable defaults
    final defaultAngles = <String, double>{
      'rightElbowAngle': 140.0,
      'leftElbowAngle': 140.0,
      'rightShoulderAngle': 100.0,
      'leftShoulderAngle': 100.0,
      'rightKneeAngle': 160.0,
      'leftKneeAngle': 160.0,
      'spineAngle': 85.0,
    };

    // Collect phase values per app angle
    final phaseValues = <String, List<double>>{};
    for (final entry in angleMapping.entries) {
      final proAngle = entry.key;
      final appAngle = entry.value;
      final values = <double>[];
      for (final phaseName in phaseOrder) {
        final phaseData = phases[phaseName] as Map<String, dynamic>;
        final raw = phaseData[proAngle];
        double value = raw != null
            ? (raw as num).toDouble()
            : defaultAngles[appAngle] ?? 90.0;
        // Convert trunk tilt (degrees from vertical) to app spine angle (degrees from horizontal)
        if (proAngle == 'trunk_lateral_tilt_deg') {
          value = 90.0 - value;
        }
        values.add(value);
      }
      phaseValues[appAngle] = values;
    }

    // Interpolate each angle across all frames using Catmull-Rom
    final interpolated = <String, List<double>>{};
    for (final entry in phaseValues.entries) {
      interpolated[entry.key] =
          _catmullRomInterpolate(entry.value, phaseFrames, frameCount);
    }

    // Build FormFrames
    final frames = <FormFrame>[];
    for (int i = 0; i < frameCount; i++) {
      final angles = <String, double>{};
      for (final angleName in defaultAngles.keys) {
        if (interpolated.containsKey(angleName)) {
          angles[angleName] = interpolated[angleName]![i];
        } else {
          angles[angleName] = defaultAngles[angleName]!;
        }
      }
      frames.add(FormFrame(
        timestamp: Duration(milliseconds: i * 200),
        angles: angles,
        keyPoints: {},
      ));
    }

    return FormAnalysis(
      id: 'pro_${playerName}_$throwType',
      date: DateTime.now(),
      videoPath: '',
      frames: frames,
      score: 95.0,
    );
  }

  /// Get raw 4-phase angle snapshots for a player and throw type.
  /// Returns a map of phase name → {appAngleName → degrees}.
  static Future<Map<String, Map<String, double>>> getPhaseAngles(
    String playerName,
    String throwType,
  ) async {
    final data = await _loadRawData();
    final players = data['players'] as Map<String, dynamic>;
    final player = players[playerName] as Map<String, dynamic>;
    final throws = player['throws'] as Map<String, dynamic>;
    final throwData = throws[throwType] as Map<String, dynamic>;
    final phases = throwData['phases'] as Map<String, dynamic>;

    final phaseOrder = _getPhaseOrder(throwType);
    final angleMapping = _getAngleMapping(throwType);
    final defaultAngles = <String, double>{
      'rightElbowAngle': 140.0,
      'leftElbowAngle': 140.0,
      'rightShoulderAngle': 100.0,
      'leftShoulderAngle': 100.0,
      'rightKneeAngle': 160.0,
      'leftKneeAngle': 160.0,
      'spineAngle': 85.0,
    };

    final result = <String, Map<String, double>>{};
    for (final phaseName in phaseOrder) {
      final phaseData = phases[phaseName] as Map<String, dynamic>;
      final angles = <String, double>{};
      for (final entry in angleMapping.entries) {
        final raw = phaseData[entry.key];
        double value = raw != null
            ? (raw as num).toDouble()
            : defaultAngles[entry.value] ?? 90.0;
        // Convert trunk tilt (degrees from vertical) to app spine angle (degrees from horizontal)
        if (entry.key == 'trunk_lateral_tilt_deg') {
          value = 90.0 - value;
        }
        angles[entry.value] = value;
      }
      result[phaseName] = angles;
    }
    return result;
  }

  /// Get the display-friendly phase names for a throw type.
  static List<String> getPhaseNames(String throwType) => _getPhaseOrder(throwType);

  /// Catmull-Rom spline interpolation from phase snapshot values to per-frame.
  static List<double> _catmullRomInterpolate(
    List<double> values,
    List<int> frames,
    int totalFrames,
  ) {
    assert(values.length == frames.length);
    final result = List<double>.filled(totalFrames, 0.0);

    // Extend with virtual control points for Catmull-Rom at boundaries
    final extValues = [
      values[0] - (values[1] - values[0]), // P-1
      ...values,
      values.last + (values.last - values[values.length - 2]), // P_n+1
    ];
    final extFrames = [
      frames[0] - (frames[1] - frames[0]),
      ...frames,
      frames.last + (frames.last - frames[frames.length - 2]),
    ];

    for (int f = 0; f < totalFrames; f++) {
      // Find which segment this frame falls in
      int seg = 0;
      for (int s = 0; s < frames.length - 1; s++) {
        if (f >= frames[s] && f <= frames[s + 1]) {
          seg = s;
          break;
        }
      }

      // Catmull-Rom with 4 control points: P0, P1, P2, P3
      // seg+0 in extValues = P-1, seg+1 = P_seg, seg+2 = P_seg+1, seg+3 = P_seg+2
      final p0 = extValues[seg];
      final p1 = extValues[seg + 1];
      final p2 = extValues[seg + 2];
      final p3 = extValues[seg + 3];

      final f1 = extFrames[seg + 1];
      final f2 = extFrames[seg + 2];
      final range = f2 - f1;
      final t = range > 0 ? (f - f1) / range : 0.0;

      // Standard Catmull-Rom formula
      result[f] = 0.5 *
          ((2 * p1) +
              (-p0 + p2) * t +
              (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t +
              (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t);
    }

    return result;
  }
}
