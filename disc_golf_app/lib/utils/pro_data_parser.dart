import 'dart:convert';
import 'package:flutter/services.dart';

/// Parses `assets/data/pro_baseline_db.json` (v4.0) and exposes pro phase
/// angle data for use in form comparison and suggestion generation.
///
/// All methods are async and cache the parsed JSON on first load.
///
/// Key design decisions vs the previous version:
/// - Null angles (occluded landmarks) are returned as null, NOT silently
///   replaced with defaults. Callers should check for null and surface the
///   data quality context to the user.
/// - `xFactor` mapping added (app key → `x_factor_deg` in JSON).
/// - `getPhaseAnglesNullable` is the primary method for scoring/comparison.
///   The old `getPhaseAngles` (with silent defaults) is kept with a deprecation
///   note for backward compatibility until all call sites are updated.
/// - `getBaselineSummary` exposes cross-player mean ± SD for range-based
///   feedback that works even without a specific pro selected.
/// - `getDataQualityFlags` exposes known issues so the UI can warn users.
class ProBaselineParser {
  static Map<String, dynamic>? _cachedData;

  static Future<Map<String, dynamic>> _loadRawData() async {
    if (_cachedData != null) return _cachedData!;
    final jsonStr =
        await rootBundle.loadString('assets/data/pro_baseline_db.json');
    _cachedData = json.decode(jsonStr) as Map<String, dynamic>;
    return _cachedData!;
  }

  // ── Player / throw type queries ───────────────────────────────────────────

  /// All player names present in the database.
  static Future<List<String>> getPlayerNames() async {
    final data = await _loadRawData();
    return (data['players'] as Map<String, dynamic>).keys.toList();
  }

  /// Whether a player has data for the given throw type ('BH' or 'FH').
  static Future<bool> hasThrowType(
      String playerName, String throwType) async {
    final data = await _loadRawData();
    final players = data['players'] as Map<String, dynamic>;
    final player = players[playerName] as Map<String, dynamic>?;
    if (player == null) return false;
    final throws = player['throws'] as Map<String, dynamic>;
    return throws.containsKey(throwType);
  }

  // ── Angle name mappings ───────────────────────────────────────────────────

  /// Maps JSON angle keys → app `FormFrame.angles` keys.
  ///
  /// BH (RHBH): lead knee = right, trail knee = left.
  /// FH (RHFH): lead knee = left,  trail knee = right.
  /// All pros in the DB are right-handed; throwing arm = right throughout.
  static Map<String, String> _getAngleMapping(String throwType) {
    if (throwType == 'BH') {
      return {
        'elbow_angle_deg':          'rightElbowAngle',
        'shoulder_flexion_deg':     'rightShoulderAngle',
        'lead_knee_flexion_deg':    'rightKneeAngle',   // RHBH lead = R
        'trail_knee_flexion_deg':   'leftKneeAngle',    // RHBH trail = L
        'trunk_lateral_tilt_deg':   'spineAngle',
        'off_arm_elbow_angle_deg':  'leftElbowAngle',
        'off_arm_shoulder_angle_deg': 'leftShoulderAngle',
        'x_factor_deg':             'xFactor',
      };
    } else {
      // FH (RHFH)
      return {
        'elbow_angle_deg':          'rightElbowAngle',
        'shoulder_flexion_deg':     'rightShoulderAngle',
        'lead_knee_flexion_deg':    'leftKneeAngle',    // RHFH lead = L
        'trail_knee_flexion_deg':   'rightKneeAngle',   // RHFH trail = R
        'trunk_lateral_tilt_deg':   'spineAngle',
        'off_arm_elbow_angle_deg':  'leftElbowAngle',
        'off_arm_shoulder_angle_deg': 'leftShoulderAngle',
        'x_factor_deg':             'xFactor',
      };
    }
  }

  /// Reverse mapping: app key → JSON key (for baseline summary lookup).
  static Map<String, String> _getReverseMapping(String throwType) {
    return _getAngleMapping(throwType)
        .map((jsonKey, appKey) => MapEntry(appKey, jsonKey));
  }

  static double _convertAngle(String jsonKey, double raw) {
    // trunk_lateral_tilt_deg (0=upright) → spineAngle (90=upright)
    if (jsonKey == 'trunk_lateral_tilt_deg') return 90.0 - raw;
    return raw;
  }

  // ── Phase queries ─────────────────────────────────────────────────────────

  /// Ordered phase names for a throw type.
  static List<String> getPhaseNames(String throwType) {
    return throwType == 'BH'
        ? ['reach_back', 'power_pocket', 'release', 'follow_through']
        : ['wind_up', 'power_pocket', 'release', 'follow_through'];
  }

  // ── Primary data access ───────────────────────────────────────────────────

  /// Phase angle snapshots for one player, allowing null values.
  ///
  /// Returns: `phase name → {app angle key → degrees?}`
  /// Null means the landmark was occluded or below confidence — do not
  /// replace with a default; surface a warning or skip that angle in scoring.
  ///
  /// `xFactor` is included when available (3D-computed by the app; also in
  /// the JSON as `x_factor_deg`).
  static Future<Map<String, Map<String, double?>>> getPhaseAnglesNullable(
    String playerName,
    String throwType,
  ) async {
    final data    = await _loadRawData();
    final players = data['players'] as Map<String, dynamic>;
    final player  = players[playerName] as Map<String, dynamic>?;
    if (player == null) return {};

    final throwData = (player['throws'] as Map<String, dynamic>)[throwType]
        as Map<String, dynamic>?;
    if (throwData == null) return {};

    final phases       = throwData['phases'] as Map<String, dynamic>;
    final phaseOrder   = getPhaseNames(throwType);
    final angleMapping = _getAngleMapping(throwType);
    final result       = <String, Map<String, double?>>{};

    for (final phaseName in phaseOrder) {
      final phaseData = phases[phaseName] as Map<String, dynamic>?;
      if (phaseData == null) {
        result[phaseName] = {};
        continue;
      }
      final angles = <String, double?>{};
      for (final entry in angleMapping.entries) {
        final raw = phaseData[entry.key];
        if (raw == null) {
          angles[entry.value] = null; // occluded — caller must handle
        } else {
          angles[entry.value] = _convertAngle(entry.key, (raw as num).toDouble());
        }
      }
      result[phaseName] = angles;
    }
    return result;
  }

  /// Phase angles with null values replaced by the cross-player baseline mean.
  ///
  /// Use for scoring and waveform markers where a missing value would cause
  /// a gap. The substitution is noted in [qualityWarnings] so the UI can
  /// tell the user "Wysocki FH power pocket — lead leg occluded, using
  /// group average".
  static Future<({
    Map<String, Map<String, double>> angles,
    List<String> qualityWarnings,
  })> getPhaseAnglesWithFallback(
    String playerName,
    String throwType,
  ) async {
    final nullable = await getPhaseAnglesNullable(playerName, throwType);
    final summary  = await getBaselineSummary(throwType);
    final flags    = await getDataQualityFlags(
        playerName: playerName, throwType: throwType);
    final warnings = <String>[];

    // Surface any pre-flagged issues
    for (final flag in flags) {
      final issue = flag['issue'] as String? ?? '';
      if (issue.isNotEmpty) warnings.add(issue);
    }

    final result = <String, Map<String, double>>{};

    for (final phaseEntry in nullable.entries) {
      final phaseName   = phaseEntry.key;
      final phaseAngles = phaseEntry.value;
      final resolved    = <String, double>{};
      final reverseMap  = _getReverseMapping(throwType);

      for (final angleEntry in phaseAngles.entries) {
        final appKey  = angleEntry.key;
        final jsonKey = reverseMap[appKey];
        if (angleEntry.value != null) {
          resolved[appKey] = angleEntry.value!;
        } else if (jsonKey != null) {
          // Fall back to cross-player mean
          final phaseStats = summary[phaseName];
          final stats = phaseStats?[jsonKey] as Map<String, dynamic>?;
          final mean  = stats?['mean'];
          if (mean != null) {
            final fallback = _convertAngle(jsonKey, (mean as num).toDouble());
            resolved[appKey] = fallback;
            warnings.add(
              '$playerName $throwType $phaseName: $appKey occluded — '
              'using group mean (${fallback.toStringAsFixed(1)}°)',
            );
          }
        }
      }
      result[phaseName] = resolved;
    }

    return (angles: result, qualityWarnings: warnings);
  }

  /// [Deprecated — use getPhaseAnglesNullable or getPhaseAnglesWithFallback]
  ///
  /// Legacy method that silently fills nulls with hardcoded defaults.
  /// Kept for backward compatibility while call sites are migrated.
  static Future<Map<String, Map<String, double>>> getPhaseAngles(
    String playerName,
    String throwType,
  ) async {
    final result = await getPhaseAnglesWithFallback(playerName, throwType);
    return result.angles;
  }

  // ── Baseline summary (cross-player stats) ─────────────────────────────────

  /// Cross-player mean ± SD statistics per phase.
  ///
  /// Returns: `phase name → {json angle key → {mean, sd, min, max, n}}`
  ///
  /// Use for range-based feedback when no specific pro is selected:
  /// "Your elbow at power pocket (94°) is above the pro mean of 71.6° ± 21.6°."
  static Future<Map<String, Map<String, Map<String, dynamic>>>>
      getBaselineSummary(String throwType) async {
    final data    = await _loadRawData();
    final summary = data['baseline_summary'] as Map<String, dynamic>;
    final typeData = summary[throwType] as Map<String, dynamic>?;
    if (typeData == null) return {};

    final result =
        <String, Map<String, Map<String, dynamic>>>{};
    for (final phaseEntry in typeData.entries) {
      final angles = phaseEntry.value as Map<String, dynamic>;
      result[phaseEntry.key] = angles.map(
        (angleKey, stats) => MapEntry(
          angleKey,
          Map<String, dynamic>.from(stats as Map),
        ),
      );
    }
    return result;
  }

  /// Returns a human-readable summary for one angle at one phase.
  /// e.g. "Pro mean: 71.6° (SD ±21.6°, range 46–96°, n=5)"
  static Future<String?> getBaselineDescription(
    String throwType,
    String phaseName,
    String appAngleKey,
  ) async {
    final summary    = await getBaselineSummary(throwType);
    final reverseMap = _getReverseMapping(throwType);
    final jsonKey    = reverseMap[appAngleKey];
    if (jsonKey == null) return null;

    final phaseStats  = summary[phaseName];
    final stats = phaseStats?[jsonKey] as Map<String, dynamic>?;
    if (stats == null) return null;

    final mean = (stats['mean'] as num?)?.toDouble();
    final sd   = (stats['sd'] as num?)?.toDouble();
    final min  = (stats['min'] as num?)?.toDouble();
    final max  = (stats['max'] as num?)?.toDouble();
    final n    = stats['n'] as int?;
    if (mean == null) return null;

    final meanDisplay = _convertAngle(jsonKey, mean).toStringAsFixed(1);
    final sdDisplay   = sd?.toStringAsFixed(1);
    final minDisplay  = min != null ? _convertAngle(jsonKey, min).toStringAsFixed(1) : '?';
    final maxDisplay  = max != null ? _convertAngle(jsonKey, max).toStringAsFixed(1) : '?';

    return 'Pro mean: $meanDisplay°'
        '${sdDisplay != null ? ' (SD ±$sdDisplay°' : ''}'
        '${n != null ? ', n=$n' : ''}'
        '${sdDisplay != null ? ')' : ''}'
        ' · range $minDisplay–$maxDisplay°';
  }

  // ── Deviation scoring against baseline range ──────────────────────────────

  /// Returns how many SDs a user angle deviates from the cross-player mean
  /// at a given phase. Positive = above mean, negative = below.
  ///
  /// Returns null if baseline data is unavailable for this combination.
  static Future<double?> deviationInSD(
    String throwType,
    String phaseName,
    String appAngleKey,
    double userAngle,
  ) async {
    final summary    = await getBaselineSummary(throwType);
    final reverseMap = _getReverseMapping(throwType);
    final jsonKey    = reverseMap[appAngleKey];
    if (jsonKey == null) return null;

    final stats = summary[phaseName]?[jsonKey] as Map<String, dynamic>?;
    if (stats == null) return null;

    final mean = (stats['mean'] as num?)?.toDouble();
    final sd   = (stats['sd'] as num?)?.toDouble();
    if (mean == null || sd == null || sd == 0) return null;

    final meanConverted = _convertAngle(jsonKey, mean);
    return (userAngle - meanConverted) / sd;
  }

  // ── Data quality flags ─────────────────────────────────────────────────────

  /// Known data quality issues from the JSON metadata.
  ///
  /// Filter by [playerName] and/or [throwType] to get relevant flags.
  /// Each flag is a raw Map matching the JSON structure — keys vary:
  ///   `player`, `throw_type`, `phases`, `issue`, `cause`, `recommendation`,
  ///   `general` (true for dataset-wide issues).
  static Future<List<Map<String, dynamic>>> getDataQualityFlags({
    String? playerName,
    String? throwType,
  }) async {
    final data  = await _loadRawData();
    final meta  = data['metadata'] as Map<String, dynamic>;
    final flags = (meta['data_quality_flags'] as List<dynamic>)
        .cast<Map<String, dynamic>>();

    return flags.where((flag) {
      // Always include general flags
      if (flag['general'] == true) return true;
      // Filter by player if specified
      if (playerName != null) {
        final fp = flag['player'] as String?;
        if (fp != null && fp != playerName) return false;
      }
      // Filter by throw type if specified
      if (throwType != null) {
        final ft = flag['throw_type'] as String?;
        if (ft != null && ft != throwType) return false;
      }
      return true;
    }).toList();
  }

  /// True if a specific player+throwType+phase combination has known
  /// occlusion or reliability issues.
  static Future<bool> hasQualityWarning(
    String playerName,
    String throwType,
    String phaseName,
  ) async {
    final flags = await getDataQualityFlags(
        playerName: playerName, throwType: throwType);
    for (final flag in flags) {
      final phases = flag['phases'] as List<dynamic>?;
      final phase  = flag['phase'] as String?;
      if (phase == phaseName) return true;
      if (phases != null && phases.contains(phaseName)) return true;
    }
    return false;
  }
}
