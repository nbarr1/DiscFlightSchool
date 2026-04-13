import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/form_analysis.dart';
import '../utils/angle_calculator.dart';
import '../utils/pro_data_parser.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'video_frame_extractor.dart';
import 'dart:io';
import 'dart:math';

const double _kConfidenceThreshold = 0.5;

class FormSuggestion {
  final String text;
  final String? kbArticleId;
  const FormSuggestion(this.text, {this.kbArticleId});
}

class PostureAnalysisService extends ChangeNotifier {
  final List<FormAnalysis> _analyses = [];
  FormAnalysis? _currentAnalysis;

  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(
      mode: PoseDetectionMode.single,
      model: PoseDetectionModel.accurate,
    ),
  );
  final VideoFrameExtractor _frameExtractor = VideoFrameExtractor();

  List<FormAnalysis> get analyses => _analyses;
  FormAnalysis? get currentAnalysis => _currentAnalysis;

  static Map<String, double> _mirrorAngles(Map<String, double> angles) {
    final result = <String, double>{};
    for (final e in angles.entries) {
      String key = e.key;
      if (key.startsWith('right')) {
        key = 'left${key.substring(5)}';
      } else if (key.startsWith('left')) {
        key = 'right${key.substring(4)}';
      }
      result[key] = e.value;
    }
    return result;
  }

  Future<FormAnalysis> analyzeForm(
    String videoPath, {
    int startMs = 0,
    int frameCount = 30,
    bool isLeftHanded = false,
    String throwType = 'BH',
  }) async {
    List<String>? framePaths;
    try {
      debugPrint('Starting form analysis for: $videoPath (start: ${startMs}ms, frames: $frameCount)');
      framePaths = await _frameExtractor.extractFrames(
          videoPath, frameCount: frameCount, startMs: startMs);
      debugPrint('Extracted ${framePaths.length} frames');

      double? imgWidth;
      double? imgHeight;
      if (framePaths.isNotEmpty) {
        final firstFile = File(framePaths.first);
        final bytes = await firstFile.readAsBytes();
        final decoded = await decodeImageFromList(bytes);
        imgWidth = decoded.width.toDouble();
        imgHeight = decoded.height.toDouble();
      }

      final frames = <FormFrame>[];
      const intervalMs = VideoFrameExtractor.defaultIntervalMs;

      for (int i = 0; i < framePaths.length; i++) {
        final framePath = framePaths[i];
        if (i % 10 == 0) {
          debugPrint('Analyzing frame ${i + 1}/${framePaths.length}');
        }
        final inputImage = InputImage.fromFilePath(framePath);
        final poses = await _poseDetector.processImage(inputImage);

        if (poses.isNotEmpty) {
          final pose = poses.first;
          final landmarkConf = _extractConfidence(pose);
          final landmarkZ    = _extractDepth(pose);
          final keyPoints    = _extractKeyPoints(pose);
          final rawAngles =
              _calculateAngles3D(pose, landmarkConf) ??
              _calculateAngles2D(pose, landmarkConf);
          final mirrored =
              isLeftHanded ? _mirrorAngles(rawAngles) : rawAngles;
          final angles = _clampToPhysiologicalLimits(mirrored);
          frames.add(FormFrame(
            timestamp: Duration(milliseconds: i * intervalMs),
            angles: angles,
            keyPoints: keyPoints,
            landmarkZ: landmarkZ,
            landmarkConf: landmarkConf,
            imageWidth: imgWidth,
            imageHeight: imgHeight,
          ));
        } else {
          frames.add(FormFrame(
            timestamp: Duration(milliseconds: i * intervalMs),
            angles: {},
            keyPoints: {},
            imageWidth: imgWidth,
            imageHeight: imgHeight,
          ));
        }
      }

      if (frames.isEmpty) {
        final mock = _generateMockAnalysis(videoPath);
        mock.isMock = true;
        return mock;
      }

      _smoothFrameAngles(frames);
      _smoothKeyPoints(frames);

      final analysis = FormAnalysis(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        date: DateTime.now(),
        videoPath: videoPath,
        frames: frames,
        score: 0.0,
      );
      _analyses.add(analysis);
      _currentAnalysis = analysis;
      notifyListeners();
      return analysis;
    } catch (e) {
      debugPrint('Error analyzing form: $e');
      final mock = _generateMockAnalysis(videoPath);
      mock.isMock = true;
      return mock;
    } finally {
      if (framePaths != null) {
        await _frameExtractor.cleanupFrames(framePaths);
      }
    }
  }

  // ── Landmark extraction ────────────────────────────────────────────────────

  Map<String, Offset> _extractKeyPoints(Pose pose) {
    final keyPoints = <String, Offset>{};
    for (var entry in pose.landmarks.entries) {
      keyPoints[entry.key.toString()] =
          Offset(entry.value.x.toDouble(), entry.value.y.toDouble());
    }
    return keyPoints;
  }

  Map<String, double> _extractConfidence(Pose pose) {
    final conf = <String, double>{};
    for (var entry in pose.landmarks.entries) {
      conf[entry.key.toString()] = entry.value.likelihood.toDouble();
    }
    return conf;
  }

  Map<String, double> _extractDepth(Pose pose) {
    final depth = <String, double>{};
    for (var entry in pose.landmarks.entries) {
      depth[entry.key.toString()] = entry.value.z.toDouble();
    }
    return depth;
  }

  // ── Angle calculation ──────────────────────────────────────────────────────

  Map<String, double> _calculateAngles2D(
      Pose pose, Map<String, double> conf) {
    final lm = pose.landmarks;
    final angles = <String, double>{};

    PoseLandmark? trusted(PoseLandmarkType type) {
      final l = lm[type];
      if (l == null) return null;
      final c = conf[type.toString()] ?? 0.0;
      return c >= _kConfidenceThreshold ? l : null;
    }

    double calcAngle(PoseLandmark? a, PoseLandmark? b, PoseLandmark? c) {
      if (a == null || b == null || c == null) return double.nan;
      final ba = Point(a.x - b.x, a.y - b.y);
      final bc = Point(c.x - b.x, c.y - b.y);
      final dot = ba.x * bc.x + ba.y * bc.y;
      final magBA = sqrt(ba.x * ba.x + ba.y * ba.y);
      final magBC = sqrt(bc.x * bc.x + bc.y * bc.y);
      if (magBA == 0 || magBC == 0) return double.nan;
      return acos((dot / (magBA * magBC)).clamp(-1.0, 1.0)) * (180 / pi);
    }

    final rShoulder = trusted(PoseLandmarkType.rightShoulder);
    final rElbow    = trusted(PoseLandmarkType.rightElbow);
    final rWrist    = trusted(PoseLandmarkType.rightWrist);
    final rHip      = trusted(PoseLandmarkType.rightHip);
    final lShoulder = trusted(PoseLandmarkType.leftShoulder);
    final lElbow    = trusted(PoseLandmarkType.leftElbow);
    final lWrist    = trusted(PoseLandmarkType.leftWrist);
    final lHip      = trusted(PoseLandmarkType.leftHip);
    final rKnee     = trusted(PoseLandmarkType.rightKnee);
    final rAnkle    = trusted(PoseLandmarkType.rightAnkle);
    final lKnee     = trusted(PoseLandmarkType.leftKnee);
    final lAnkle    = trusted(PoseLandmarkType.leftAnkle);

    void set(String key, double val) {
      if (!val.isNaN) angles[key] = val;
    }

    set('rightElbowAngle',    calcAngle(rShoulder, rElbow, rWrist));
    set('leftElbowAngle',     calcAngle(lShoulder, lElbow, lWrist));
    set('rightShoulderAngle', calcAngle(rElbow, rShoulder, rHip));
    set('leftShoulderAngle',  calcAngle(lElbow, lShoulder, lHip));
    set('rightKneeAngle',     calcAngle(rHip, rKnee, rAnkle));
    set('leftKneeAngle',      calcAngle(lHip, lKnee, lAnkle));

    if (rShoulder != null && lShoulder != null &&
        rHip != null && lHip != null) {
      final smX = (rShoulder.x + lShoulder.x) / 2;
      final smY = (rShoulder.y + lShoulder.y) / 2;
      final hmX = (rHip.x + lHip.x) / 2;
      final hmY = (rHip.y + lHip.y) / 2;
      final spine = atan2(smX - hmX, hmY - smY) * (180 / pi);
      angles['spineAngle'] = 90 - spine.abs();
    }

    return angles;
  }

  Map<String, double>? _calculateAngles3D(
      Pose pose, Map<String, double> conf) {
    final lm = pose.landmarks;
    double maxAbsZ = 0;
    for (final l in lm.values) {
      final az = l.z.abs();
      if (az > maxAbsZ) maxAbsZ = az;
    }
    if (maxAbsZ < 0.01) return null;

    ({double x, double y, double z})? trusted(PoseLandmarkType type) {
      final l = lm[type];
      if (l == null) return null;
      final c = conf[type.toString()] ?? 0.0;
      if (c < _kConfidenceThreshold) return null;
      return (x: l.x.toDouble(), y: l.y.toDouble(), z: l.z.toDouble());
    }

    final rShoulder = trusted(PoseLandmarkType.rightShoulder);
    final rElbow    = trusted(PoseLandmarkType.rightElbow);
    final rWrist    = trusted(PoseLandmarkType.rightWrist);
    final rHip      = trusted(PoseLandmarkType.rightHip);
    final lShoulder = trusted(PoseLandmarkType.leftShoulder);
    final lElbow    = trusted(PoseLandmarkType.leftElbow);
    final lWrist    = trusted(PoseLandmarkType.leftWrist);
    final lHip      = trusted(PoseLandmarkType.leftHip);
    final rKnee     = trusted(PoseLandmarkType.rightKnee);
    final rAnkle    = trusted(PoseLandmarkType.rightAnkle);
    final lKnee     = trusted(PoseLandmarkType.leftKnee);
    final lAnkle    = trusted(PoseLandmarkType.leftAnkle);

    final angles = <String, double>{};

    void set3D(
      String key,
      ({double x, double y, double z})? a,
      ({double x, double y, double z})? b,
      ({double x, double y, double z})? c,
    ) {
      if (a == null || b == null || c == null) return;
      final val = AngleCalculator.angleBetween3D(a, b, c);
      if (!val.isNaN) angles[key] = val;
    }

    set3D('rightElbowAngle',    rShoulder, rElbow, rWrist);
    set3D('leftElbowAngle',     lShoulder, lElbow, lWrist);
    set3D('rightShoulderAngle', rElbow, rShoulder, rHip);
    set3D('leftShoulderAngle',  lElbow, lShoulder, lHip);
    set3D('rightKneeAngle',     rHip, rKnee, rAnkle);
    set3D('leftKneeAngle',      lHip, lKnee, lAnkle);

    if (rShoulder != null && lShoulder != null &&
        rHip != null && lHip != null) {
      final xFactor = AngleCalculator.xFactor3D(
          rShoulder, lShoulder, rHip, lHip);
      if (!xFactor.isNaN) angles['xFactor'] = xFactor;

      final smX = (rShoulder.x + lShoulder.x) / 2;
      final smY = (rShoulder.y + lShoulder.y) / 2;
      final hmX = (rHip.x + lHip.x) / 2;
      final hmY = (rHip.y + lHip.y) / 2;
      final spine = atan2(smX - hmX, hmY - smY) * (180 / pi);
      angles['spineAngle'] = 90 - spine.abs();
    }

    return angles.isEmpty ? null : angles;
  }

  // ── Physiological limits ───────────────────────────────────────────────────

  static const Map<String, ({double min, double max})> _romLimits = {
    'rightElbowAngle':    (min: 40.0,  max: 180.0),
    'leftElbowAngle':     (min: 40.0,  max: 180.0),
    'rightShoulderAngle': (min: 0.0,   max: 180.0),
    'leftShoulderAngle':  (min: 0.0,   max: 180.0),
    'rightKneeAngle':     (min: 30.0,  max: 180.0),
    'leftKneeAngle':      (min: 30.0,  max: 180.0),
    'spineAngle':         (min: 40.0,  max: 90.0),
  };

  static const double _kRomTolerance = 10.0;

  static Map<String, double> _clampToPhysiologicalLimits(
      Map<String, double> angles) {
    final result = <String, double>{};
    for (final e in angles.entries) {
      final limits = _romLimits[e.key];
      if (limits == null) {
        result[e.key] = e.value;
        continue;
      }
      final clamped = e.value.clamp(limits.min, limits.max);
      if ((e.value - clamped).abs() <= _kRomTolerance) {
        result[e.key] = clamped;
      }
    }
    return result;
  }

  // ── Smoothing ──────────────────────────────────────────────────────────────

  void _smoothFrameAngles(List<FormFrame> frames) {
    if (frames.length < 3) return;
    final angleNames = <String>{};
    for (final f in frames) angleNames.addAll(f.angles.keys);
    for (final name in angleNames) {
      var data = frames.map((f) => f.angles[name] ?? double.nan).toList();
      data = _sparseMedianFilter(data, 3);
      data = _sparseMovingAverage(data, 9);
      data = _sparseMovingAverage(data, 7);
      for (int i = 0; i < frames.length; i++) {
        if (!data[i].isNaN) frames[i].angles[name] = data[i];
      }
    }
  }

  void _smoothKeyPoints(List<FormFrame> frames) {
    if (frames.length < 3) return;
    final pointNames = <String>{};
    for (final f in frames) pointNames.addAll(f.keyPoints.keys);
    for (final name in pointNames) {
      final xData = frames.map((f) => f.keyPoints[name]?.dx ?? double.nan).toList();
      final yData = frames.map((f) => f.keyPoints[name]?.dy ?? double.nan).toList();
      final smoothedX = _sparseMovingAverage(xData, 5);
      final smoothedY = _sparseMovingAverage(yData, 5);
      for (int i = 0; i < frames.length; i++) {
        if (frames[i].keyPoints.containsKey(name) && !smoothedX[i].isNaN) {
          frames[i].keyPoints[name] = Offset(smoothedX[i], smoothedY[i]);
        }
      }
    }
  }

  List<double> _sparseMedianFilter(List<double> data, int window) {
    final half = window ~/ 2;
    return List.generate(data.length, (i) {
      final start = (i - half).clamp(0, data.length - 1);
      final end   = (i + half).clamp(0, data.length - 1);
      final seg   = data.sublist(start, end + 1)
          .where((v) => !v.isNaN)
          .toList()
        ..sort();
      if (seg.isEmpty) return double.nan;
      return seg[seg.length ~/ 2];
    });
  }

  List<double> _sparseMovingAverage(List<double> data, int window) {
    final half = window ~/ 2;
    return List.generate(data.length, (i) {
      final start = (i - half).clamp(0, data.length - 1);
      final end   = (i + half).clamp(0, data.length - 1);
      double sum  = 0;
      int count   = 0;
      for (int j = start; j <= end; j++) {
        if (!data[j].isNaN) { sum += data[j]; count++; }
      }
      return count > 0 ? sum / count : double.nan;
    });
  }

  // ── Pro deviation scoring ──────────────────────────────────────────────────

  /// Compute a 0–100 deviation score against measured pro phase snapshots.
  ///
  /// [phaseAngles]: phase name → {appAngleName → degrees}
  /// [phaseFrameIndices]: maps phase name → frame index in [frames] where that
  ///   phase occurs. When provided, each frame snaps to its nearest *measured*
  ///   phase rather than the hardcoded 0/0.33/0.67/1.0 fractions.
  ///   Pass null to fall back to the fractional approximation (less accurate).
  static double computeProDeviationScore(
    List<FormFrame> frames,
    Map<String, Map<String, double>> phaseAngles,
    String throwType, {
    Map<String, int>? phaseFrameIndices,
  }) {
    if (frames.isEmpty || phaseAngles.isEmpty) return 0.0;

    final phaseOrder = throwType == 'FH'
        ? ['wind_up', 'power_pocket', 'release', 'follow_through']
        : ['reach_back', 'power_pocket', 'release', 'follow_through'];

    final total = frames.length;

    // Build sorted list of (frameIndex, phaseName) anchors.
    // If phaseFrameIndices provided, use those; otherwise space evenly.
    final List<({int frameIdx, String phaseName})> anchors;
    if (phaseFrameIndices != null && phaseFrameIndices.isNotEmpty) {
      final entries = phaseOrder
          .where((p) => phaseFrameIndices.containsKey(p))
          .map((p) => (frameIdx: phaseFrameIndices[p]!, phaseName: p))
          .toList()
        ..sort((a, b) => a.frameIdx.compareTo(b.frameIdx));
      anchors = entries;
    } else {
      // Fallback: evenly-spaced fractions
      final phaseT = [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0];
      anchors = List.generate(phaseOrder.length, (i) => (
        frameIdx: ((phaseT[i]) * (total - 1)).round().clamp(0, total - 1),
        phaseName: phaseOrder[i],
      ));
    }

    double totalScore = 0.0;
    int count = 0;

    for (int i = 0; i < total; i++) {
      // Snap to nearest anchor
      var nearest = anchors.first;
      var minDist = (i - nearest.frameIdx).abs();
      for (final anchor in anchors.skip(1)) {
        final d = (i - anchor.frameIdx).abs();
        if (d < minDist) { minDist = d; nearest = anchor; }
      }

      final proAngles = phaseAngles[nearest.phaseName];
      if (proAngles == null) continue;

      for (final entry in frames[i].angles.entries) {
        final proAngle = proAngles[entry.key];
        if (proAngle == null) continue;
        final diff  = (entry.value - proAngle).abs();
        final score = (100 - diff * 2.0).clamp(0.0, 100.0);
        totalScore += score;
        count++;
      }
    }

    return count > 0 ? totalScore / count : 0.0;
  }

  // ── Suggestion generation (data-driven) ───────────────────────────────────

  /// Generate coaching suggestions using measured pro baseline data.
  ///
  /// When [proPhaseAngles] and [phaseFrameIndices] are provided, suggestions
  /// are specific: "Your elbow at power pocket (94°) is above the pro mean
  /// of 71.6° ± 21.6° — try tucking tighter through the pull."
  ///
  /// When only [throwType] is given (no pro selected), suggestions use the
  /// cross-player baseline summary ranges from [ProBaselineParser].
  ///
  /// Falls back to generic cues when no analysis is available.
  Future<List<FormSuggestion>> generateSuggestionsAsync({
    String throwType = 'BH',
    Map<String, Map<String, double>>? proPhaseAngles,
    Map<String, int>? phaseFrameIndices,
    String? proName,
  }) async {
    if (_currentAnalysis == null || _currentAnalysis!.frames.isEmpty) {
      return _genericSuggestions(throwType);
    }

    // Get cross-player baseline for range checking
    final baseline = await ProBaselineParser.getBaselineSummary(throwType);

    // Extract per-phase average angles from user's analysis
    final userPhaseAngles = _extractUserPhaseAngles(
        _currentAnalysis!.frames, throwType, phaseFrameIndices);

    final suggestions = <FormSuggestion>[];
    final phaseOrder = ProBaselineParser.getPhaseNames(throwType);

    for (final phaseName in phaseOrder) {
      final userAngles = userPhaseAngles[phaseName];
      final proAngles  = proPhaseAngles?[phaseName];
      final phaseStats = baseline[phaseName];
      if (userAngles == null || phaseStats == null) continue;

      for (final angleEntry in userAngles.entries) {
        final appKey    = angleEntry.key;
        final userAngle = angleEntry.value;

        // Determine reference: pro-specific if available, else baseline mean
        double? refAngle;
        double? refSD;
        String? refLabel;

        if (proAngles != null && proAngles[appKey] != null) {
          refAngle = proAngles[appKey]!;
          refLabel = proName ?? 'pro';
          // Get SD from baseline even when comparing vs specific pro
          final jsonKey = _reverseAngleKey(appKey, throwType);
          final stats   = phaseStats[jsonKey] as Map<String, dynamic>?;
          refSD = (stats?['sd'] as num?)?.toDouble();
        } else {
          final jsonKey = _reverseAngleKey(appKey, throwType);
          final stats   = phaseStats[jsonKey] as Map<String, dynamic>?;
          if (stats == null) continue;
          refAngle = (stats['mean'] as num?)?.toDouble();
          refSD    = (stats['sd'] as num?)?.toDouble();
          refLabel = 'pro average';
          // Convert from JSON convention to app convention if needed
          if (jsonKey == 'trunk_lateral_tilt_deg' && refAngle != null) {
            refAngle = 90.0 - refAngle;
          }
        }

        if (refAngle == null || refSD == null || refSD == 0) continue;
        final deviation  = userAngle - refAngle;
        final deviationSD = deviation / refSD;

        // Only flag deviations > 1 SD
        if (deviationSD.abs() <= 1.0) continue;

        final suggestion = _suggestionForAngle(
          appKey:      appKey,
          phaseName:   phaseName,
          throwType:   throwType,
          userAngle:   userAngle,
          refAngle:    refAngle,
          refSD:       refSD,
          refLabel:    refLabel!,
          deviationSD: deviationSD,
        );
        if (suggestion != null) suggestions.add(suggestion);
      }
    }

    if (suggestions.isEmpty) {
      suggestions.addAll(_positiveSuggestions());
    }
    return suggestions;
  }

  /// Synchronous fallback for compatibility with existing call sites.
  /// Returns generic suggestions only — call [generateSuggestionsAsync] for
  /// data-driven feedback.
  List<FormSuggestion> generateSuggestions({String throwType = 'BH'}) {
    if (_currentAnalysis == null || _currentAnalysis!.frames.isEmpty) {
      return _genericSuggestions(throwType);
    }
    // Compute avg angles for threshold-based fallback
    final avgAngles = <String, double>{};
    for (var frame in _currentAnalysis!.frames) {
      for (var entry in frame.angles.entries) {
        avgAngles[entry.key] = (avgAngles[entry.key] ?? 0) + entry.value;
      }
    }
    avgAngles.updateAll((k, v) => v / _currentAnalysis!.frames.length);
    return _thresholdSuggestions(avgAngles, throwType);
  }

  // ── Suggestion helpers ─────────────────────────────────────────────────────

  /// Extract average user angles at each throw phase.
  Map<String, Map<String, double>> _extractUserPhaseAngles(
    List<FormFrame> frames,
    String throwType,
    Map<String, int>? phaseFrameIndices,
  ) {
    final phaseOrder = ProBaselineParser.getPhaseNames(throwType);
    final total      = frames.length;
    final result     = <String, Map<String, double>>{};

    if (phaseFrameIndices != null && phaseFrameIndices.isNotEmpty) {
      // Use measured phase frames — average a ±2 frame window around each
      for (final phaseName in phaseOrder) {
        final centerFrame = phaseFrameIndices[phaseName];
        if (centerFrame == null) continue;
        final startF = (centerFrame - 2).clamp(0, total - 1);
        final endF   = (centerFrame + 2).clamp(0, total - 1);
        final window = frames.sublist(startF, endF + 1);
        result[phaseName] = _averageAngles(window);
      }
    } else {
      // Fallback: evenly-spaced fractions
      final phaseT = [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0];
      for (int i = 0; i < phaseOrder.length; i++) {
        final frameIdx = ((phaseT[i]) * (total - 1)).round().clamp(0, total - 1);
        final startF   = (frameIdx - 2).clamp(0, total - 1);
        final endF     = (frameIdx + 2).clamp(0, total - 1);
        result[phaseOrder[i]] = _averageAngles(frames.sublist(startF, endF + 1));
      }
    }
    return result;
  }

  Map<String, double> _averageAngles(List<FormFrame> frames) {
    if (frames.isEmpty) return {};
    final sums   = <String, double>{};
    final counts = <String, int>{};
    for (final f in frames) {
      for (final e in f.angles.entries) {
        sums[e.key]   = (sums[e.key]   ?? 0) + e.value;
        counts[e.key] = (counts[e.key] ?? 0) + 1;
      }
    }
    return sums.map((k, v) => MapEntry(k, v / counts[k]!));
  }

  /// Reverse-look up the JSON angle key from an app angle key.
  String? _reverseAngleKey(String appKey, String throwType) {
    const bh = {
      'rightElbowAngle':    'elbow_angle_deg',
      'rightShoulderAngle': 'shoulder_flexion_deg',
      'rightKneeAngle':     'lead_knee_flexion_deg',
      'leftKneeAngle':      'trail_knee_flexion_deg',
      'spineAngle':         'trunk_lateral_tilt_deg',
      'leftElbowAngle':     'off_arm_elbow_angle_deg',
      'leftShoulderAngle':  'off_arm_shoulder_angle_deg',
      'xFactor':            'x_factor_deg',
    };
    const fh = {
      'rightElbowAngle':    'elbow_angle_deg',
      'rightShoulderAngle': 'shoulder_flexion_deg',
      'leftKneeAngle':      'lead_knee_flexion_deg',
      'rightKneeAngle':     'trail_knee_flexion_deg',
      'spineAngle':         'trunk_lateral_tilt_deg',
      'leftElbowAngle':     'off_arm_elbow_angle_deg',
      'leftShoulderAngle':  'off_arm_shoulder_angle_deg',
      'xFactor':            'x_factor_deg',
    };
    return throwType == 'BH' ? bh[appKey] : fh[appKey];
  }

  /// Build a specific coaching suggestion for one angle deviation.
  FormSuggestion? _suggestionForAngle({
    required String appKey,
    required String phaseName,
    required String throwType,
    required double userAngle,
    required double refAngle,
    required double refSD,
    required String refLabel,
    required double deviationSD,
  }) {
    final phaseLabel = phaseName.replaceAll('_', ' ');
    final user       = userAngle.toStringAsFixed(1);
    final ref        = refAngle.toStringAsFixed(1);
    final direction  = deviationSD > 0 ? 'above' : 'below';

    switch (appKey) {
      case 'rightElbowAngle':
        if (throwType == 'FH') {
          if (deviationSD > 1) {
            return FormSuggestion(
              'Your throwing elbow at $phaseLabel ($user°) is straighter than $refLabel ($ref°) — '
              'keep more bend to maximise forehand snap',
              kbArticleId: 'bio_tip_1',
            );
          } else {
            return FormSuggestion(
              'Your elbow at $phaseLabel ($user°) is more bent than $refLabel ($ref°) — '
              'extend slightly to increase leverage at release',
              kbArticleId: 'bio_tip_1',
            );
          }
        } else {
          // BH
          if (deviationSD > 1) {
            return FormSuggestion(
              'Your elbow at $phaseLabel ($user°) is straighter than $refLabel ($ref°) — '
              'tuck the disc tighter during the pull for more power',
              kbArticleId: 'bio_tip_1',
            );
          } else {
            return FormSuggestion(
              'Your elbow at $phaseLabel ($user°) is more bent than $refLabel ($ref°) — '
              'extend fully toward the target at release',
              kbArticleId: 'bio_tip_1',
            );
          }
        }

      case 'rightShoulderAngle':
        if (deviationSD < -1) {
          return FormSuggestion(
            'Your throwing shoulder at $phaseLabel ($user°) is $direction the $refLabel range ($ref°) — '
            'increase shoulder rotation for more disc speed',
            kbArticleId: 'bio_tip_3',
          );
        } else {
          return FormSuggestion(
            'Your throwing shoulder at $phaseLabel ($user°) is $direction the $refLabel range ($ref°) — '
            'keep the shoulder more closed until the power pocket',
            kbArticleId: 'bio_tip_3',
          );
        }

      case 'rightKneeAngle':
      case 'leftKneeAngle':
        final side = appKey == 'rightKneeAngle' ? 'lead' : 'trail';
        return FormSuggestion(
          'Your $side knee at $phaseLabel ($user°) is $direction the $refLabel range ($ref°) — '
          '${deviationSD < -1 ? "bend more to load the legs for power" : "straighten to drive through the throw"}',
          kbArticleId: 'bio_faq_4',
        );

      case 'spineAngle':
        return FormSuggestion(
          'Your trunk lean at $phaseLabel ($user°) is $direction the $refLabel range ($ref°) — '
          '${deviationSD < -1 ? "stay taller through the throw to keep accuracy" : "lean slightly into the throw for power"}',
          kbArticleId: 'bio_tip_4',
        );

      case 'xFactor':
        if (deviationSD < -1) {
          return FormSuggestion(
            'Your hip-shoulder separation at $phaseLabel ($user°) is below $refLabel ($ref°) — '
            'rotate the hips further ahead of the shoulders in the backswing',
            kbArticleId: 'bio_tip_5',
          );
        }
        return null;

      case 'leftElbowAngle':
        if (throwType == 'BH' && deviationSD < -1) {
          return FormSuggestion(
            'Your off-arm at $phaseLabel ($user°) is more bent than $refLabel ($ref°) — '
            'extend the off-arm to help maintain shoulder plane',
          );
        }
        return null;

      default:
        return null;
    }
  }

  // ── Threshold fallback suggestions (no pro data) ──────────────────────────

  List<FormSuggestion> _thresholdSuggestions(
      Map<String, double> avgAngles, String throwType) {
    final suggestions = <FormSuggestion>[];
    if (throwType == 'FH') {
      if ((avgAngles['rightElbowAngle'] ?? 180) > 120) {
        suggestions.add(const FormSuggestion(
          'Keep your throwing elbow bent (~90°) — a straight arm loses snap on forehand',
          kbArticleId: 'bio_tip_1',
        ));
      }
      if ((avgAngles['rightShoulderAngle'] ?? 0) < 70) {
        suggestions.add(const FormSuggestion(
          'Open your throwing shoulder toward the target through release',
          kbArticleId: 'bio_tip_3',
        ));
      }
      if ((avgAngles['rightKneeAngle'] ?? 0) < 140) {
        suggestions.add(const FormSuggestion(
          'Drive off your back foot to add power to your forehand',
          kbArticleId: 'bio_faq_4',
        ));
      }
      if ((avgAngles['spineAngle'] ?? 0) < 78) {
        suggestions.add(const FormSuggestion(
          'Stay tall — excessive forward lean reduces forehand accuracy',
          kbArticleId: 'bio_tip_4',
        ));
      }
      if ((avgAngles['leftShoulderAngle'] ?? 0) < 85) {
        suggestions.add(const FormSuggestion(
          'Keep your off-arm close to prevent premature shoulder opening',
          kbArticleId: 'bio_faq_2',
        ));
      }
    } else {
      if ((avgAngles['rightShoulderAngle'] ?? 0) < 80) {
        suggestions.add(const FormSuggestion(
          'Increase shoulder rotation for more power',
          kbArticleId: 'bio_tip_5',
        ));
      }
      if ((avgAngles['rightElbowAngle'] ?? 0) > 140) {
        suggestions.add(const FormSuggestion(
          'Keep your elbow at 90-120° during pull-through',
          kbArticleId: 'bio_tip_1',
        ));
      }
      if ((avgAngles['rightKneeAngle'] ?? 0) < 140) {
        suggestions.add(const FormSuggestion(
          'Keep your knees less bent for better balance',
          kbArticleId: 'bio_faq_4',
        ));
      }
      if ((avgAngles['spineAngle'] ?? 0) < 75) {
        suggestions.add(const FormSuggestion(
          'Maintain a more upright spine position',
          kbArticleId: 'bio_tip_4',
        ));
      }
      if ((avgAngles['xFactor'] ?? 0) < 30) {
        suggestions.add(const FormSuggestion(
          'Increase hip-shoulder separation (X-factor) in your backswing',
          kbArticleId: 'bio_tip_5',
        ));
      }
    }
    return suggestions.isEmpty ? _positiveSuggestions() : suggestions;
  }

  List<FormSuggestion> _genericSuggestions(String throwType) {
    return [
      const FormSuggestion('Upload a video to get personalized form suggestions'),
      const FormSuggestion('Focus on maintaining balance throughout your throw'),
      FormSuggestion(
        throwType == 'FH'
            ? 'Practice your forehand sidearm snap'
            : 'Practice your reach-back motion',
        kbArticleId: 'bio_faq_2',
      ),
    ];
  }

  List<FormSuggestion> _positiveSuggestions() {
    return [
      const FormSuggestion('Your angles are within the pro range — great form!'),
      const FormSuggestion('Focus on smooth, controlled movements'),
      const FormSuggestion('Try recording from different angles for a fuller picture'),
    ];
  }

  // ── Mock fallback ──────────────────────────────────────────────────────────

  FormAnalysis _generateMockAnalysis(String videoPath) {
    final frames = List.generate(30, (index) {
      final progress = index / 30;
      return FormFrame(
        timestamp: Duration(milliseconds: index * 100),
        angles: _generateRealisticAngles(progress),
        keyPoints: {},
      );
    });
    final analysis = FormAnalysis(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      date: DateTime.now(),
      videoPath: videoPath,
      frames: frames,
      score: 0.0,
    );
    _analyses.add(analysis);
    _currentAnalysis = analysis;
    notifyListeners();
    return analysis;
  }

  Map<String, double> _generateRealisticAngles(double progress) {
    return {
      'rightElbowAngle':    140 - (sin(progress * pi) * 50),
      'leftElbowAngle':     140 + (sin(progress * pi) * 20),
      'rightShoulderAngle': 90  + (cos(progress * pi * 2) * 60),
      'leftShoulderAngle':  100 + (sin(progress * pi) * 30),
      'rightKneeAngle':     160 + (sin(progress * pi * 2) * 20),
      'leftKneeAngle':      160 - (sin(progress * pi * 2) * 15),
      'spineAngle':         85  + (sin(progress * pi) * 10),
    };
  }

  // ── Public helpers for PoseCorrectionScreen ────────────────────────────────

  void recalculateFrameAngles(FormFrame frame) {
    final newAngles = AngleCalculator.calculateFromKeyPoints(frame.keyPoints);
    frame.angles
      ..clear()
      ..addAll(newAngles);
  }

  void clearAnalyses() {
    _analyses.clear();
    _currentAnalysis = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _poseDetector.close();
    super.dispose();
  }
}
