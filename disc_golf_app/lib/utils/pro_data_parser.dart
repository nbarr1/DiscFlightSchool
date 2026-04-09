import 'dart:convert';
import 'package:flutter/services.dart';
// '../models/form_analysis.dart' removed — only needed by archived generateProAnalysis

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
  /// All players are right-handed. Throwing arm = right for both BH and FH.
  static Map<String, String> _getAngleMapping(String throwType) {
    if (throwType == 'BH') {
      return {
        'elbow_angle_deg': 'rightElbowAngle',            // throwing arm
        'shoulder_flexion_deg': 'rightShoulderAngle',     // throwing arm
        'lead_knee_flexion_deg': 'rightKneeAngle',        // RHBH lead = R side
        'trail_knee_flexion_deg': 'leftKneeAngle',        // RHBH trail = L side
        'trunk_lateral_tilt_deg': 'spineAngle',
        'off_arm_elbow_angle_deg': 'leftElbowAngle',      // off-arm = L side
        'off_arm_shoulder_angle_deg': 'leftShoulderAngle', // off-arm = L side
      };
    } else {
      // FH — throwing arm is still right for RHFH
      return {
        'elbow_angle_deg': 'rightElbowAngle',             // throwing arm
        'shoulder_flexion_deg': 'rightShoulderAngle',      // throwing arm
        'lead_knee_flexion_deg': 'leftKneeAngle',          // RHFH lead = L side
        'trail_knee_flexion_deg': 'rightKneeAngle',        // RHFH trail = R side
        'trunk_lateral_tilt_deg': 'spineAngle',
        'off_arm_elbow_angle_deg': 'leftElbowAngle',       // off-arm = L side
        'off_arm_shoulder_angle_deg': 'leftShoulderAngle',  // off-arm = L side
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

  // ARCHIVED — generateProAnalysis: produces 30 Catmull-Rom interpolated frames
  // from 4 measured phase snapshots. Intermediate frames are estimates, not
  // measured data. Kept for reference if per-frame pro video data is collected.
  //
  // static Future<FormAnalysis> generateProAnalysis(String playerName,
  //     String throwType, {int frameCount = 30}) async { ... }

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

  // ARCHIVED — _catmullRomInterpolate: only used by archived generateProAnalysis.
  // Kept for reference if per-frame interpolation is needed in future.
  //
  // static List<double> _catmullRomInterpolate(List<double> values,
  //     List<int> frames, int totalFrames) { ... }
}
