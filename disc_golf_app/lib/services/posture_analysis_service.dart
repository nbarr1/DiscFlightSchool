import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/form_analysis.dart';
import '../utils/angle_calculator.dart';
import '../utils/pro_data_parser.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'video_frame_extractor.dart';
import 'dart:io';
import 'dart:math';

/// Minimum ML Kit likelihood a landmark must have before its position is
/// trusted for angle calculation. Landmarks below this are excluded and the
/// angle that depends on them is omitted for that frame; the smoothing pass
/// then interpolates from neighbouring confident frames.
const double _kConfidenceThreshold = 0.5;

/// A form coaching suggestion paired with an optional Knowledge Base article
/// ID that the user can tap to learn more.
class FormSuggestion {
  final String text;
  /// Knowledge Base article ID (see `assets/data/knowledge_base.json`).
  /// Null when no directly-relevant article is mapped.
  final String? kbArticleId;

  const FormSuggestion(this.text, {this.kbArticleId});
}

class PostureAnalysisService extends ChangeNotifier {
  final List<FormAnalysis> _analyses = [];
  FormAnalysis? _currentAnalysis;
  FormAnalysis? _proAnalysis;

  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(
      mode: PoseDetectionMode.single,
      model: PoseDetectionModel.accurate,
    ),
  );
  final VideoFrameExtractor _frameExtractor = VideoFrameExtractor();

  List<FormAnalysis> get analyses => _analyses;
  FormAnalysis? get currentAnalysis => _currentAnalysis;
  FormAnalysis? get proAnalysis => _proAnalysis;

  /// Swap right↔left angle keys so the throwing arm is always "right*".
  /// Applied when [isLeftHanded] is true so all downstream scoring and
  /// comparison logic can treat "right" as the throwing arm.
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

  Future<FormAnalysis> analyzeForm(String videoPath, {int startMs = 0, int frameCount = 30, bool isLeftHanded = false, String throwType = 'BH'}) async {
    List<String>? framePaths;

    try {
      debugPrint('Starting form analysis for: $videoPath (start: ${startMs}ms, frames: $frameCount)');

      framePaths = await _frameExtractor.extractFrames(videoPath, frameCount: frameCount, startMs: startMs);
      debugPrint('Extracted ${framePaths.length} frames');

      double? imgWidth;
      double? imgHeight;
      if (framePaths.isNotEmpty) {
        final firstFile = File(framePaths.first);
        final bytes = await firstFile.readAsBytes();
        final decoded = await decodeImageFromList(bytes);
        imgWidth = decoded.width.toDouble();
        imgHeight = decoded.height.toDouble();
        debugPrint('Frame dimensions: ${imgWidth}x$imgHeight');
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
          final landmarkZ = _extractDepth(pose);
          final keyPoints = _extractKeyPoints(pose);
          // Use 3D angles when depth data is meaningful; fall back to 2D if not.
          // Mirror right↔left for left-handed throwers so the throwing arm is
          // always represented as "right*" throughout the pipeline.
          final rawAngles = _calculateAngles3D(pose, landmarkConf) ??
              _calculateAngles2D(pose, landmarkConf);
          final angles =
              isLeftHanded ? _mirrorAngles(rawAngles) : rawAngles;

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
        debugPrint('WARNING: No poses detected in any frame — returning mock data');
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
        score: _calculateScore(frames, throwType: throwType),
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

  // ---------------------------------------------------------------------------
  // Landmark extraction
  // ---------------------------------------------------------------------------

  /// Extract 2D keypoints (x, y in image-pixel space).
  Map<String, Offset> _extractKeyPoints(Pose pose) {
    final keyPoints = <String, Offset>{};
    for (var entry in pose.landmarks.entries) {
      keyPoints[entry.key.toString()] = Offset(
        entry.value.x.toDouble(),
        entry.value.y.toDouble(),
      );
    }
    return keyPoints;
  }

  /// Extract per-landmark ML Kit likelihood (0–1).
  Map<String, double> _extractConfidence(Pose pose) {
    final conf = <String, double>{};
    for (var entry in pose.landmarks.entries) {
      conf[entry.key.toString()] = entry.value.likelihood.toDouble();
    }
    return conf;
  }

  /// Extract per-landmark z-depth from ML Kit.
  /// Values are in the same scale as the x-coordinate; positive = closer to camera.
  Map<String, double> _extractDepth(Pose pose) {
    final depth = <String, double>{};
    for (var entry in pose.landmarks.entries) {
      depth[entry.key.toString()] = entry.value.z.toDouble();
    }
    return depth;
  }

  // ---------------------------------------------------------------------------
  // Angle calculation — 2D fallback
  // ---------------------------------------------------------------------------

  /// Calculate angles using only 2D (x, y) coordinates.
  /// Landmarks below [_kConfidenceThreshold] are skipped; their angles are
  /// omitted so the smoothing pass can interpolate from confident neighbours.
  Map<String, double> _calculateAngles2D(
      Pose pose, Map<String, double> conf) {
    final lm = pose.landmarks;
    final angles = <String, double>{};

    // Returns null if the landmark is missing OR below confidence threshold.
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

  // ---------------------------------------------------------------------------
  // Angle calculation — 3D (uses ML Kit z-depth)
  // ---------------------------------------------------------------------------

  /// Calculate angles using 3D (x, y, z) coordinates from ML Kit.
  ///
  /// Returns null if z-depth values are degenerate (all near zero, which can
  /// happen when the model is uncertain about depth), so the caller can fall
  /// back to 2D angles.
  Map<String, double>? _calculateAngles3D(
      Pose pose, Map<String, double> conf) {
    final lm = pose.landmarks;

    // Check whether depth data looks meaningful: at least some z values should
    // differ. If all z-values are ~0 the model didn't produce useful depth.
    double maxAbsZ = 0;
    for (final l in lm.values) {
      final az = l.z.abs();
      if (az > maxAbsZ) maxAbsZ = az;
    }
    if (maxAbsZ < 0.01) return null; // depth not reliable this frame

    // Returns null if missing or low-confidence.
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

    void set3D(String key,
        ({double x, double y, double z})? a,
        ({double x, double y, double z})? b,
        ({double x, double y, double z})? c) {
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

    // X-factor: rotation between shoulder plane normal and hip plane normal.
    // A positive value means the shoulders are rotated further than the hips
    // (desirable in the pull phase).
    if (rShoulder != null && lShoulder != null &&
        rHip != null && lHip != null) {
      final xFactor = AngleCalculator.xFactor3D(
          rShoulder, lShoulder, rHip, lHip);
      if (!xFactor.isNaN) angles['xFactor'] = xFactor;

      // Spine angle — use midpoints in 3D then project onto the vertical plane
      final smX = (rShoulder.x + lShoulder.x) / 2;
      final smY = (rShoulder.y + lShoulder.y) / 2;
      final hmX = (rHip.x + lHip.x) / 2;
      final hmY = (rHip.y + lHip.y) / 2;
      final spine = atan2(smX - hmX, hmY - smY) * (180 / pi);
      angles['spineAngle'] = 90 - spine.abs();
    }

    // Return null if we got no angles at all (all landmarks low-confidence)
    return angles.isEmpty ? null : angles;
  }

  // ---------------------------------------------------------------------------
  // Smoothing
  // ---------------------------------------------------------------------------

  /// Multi-pass smoothing to reduce pose estimation noise and spikes.
  /// Frames where an angle was omitted due to low confidence are represented as
  /// NaN so they are excluded from the average rather than pulling neighbours
  /// toward 0°.  After smoothing, frames that remain NaN keep no angle entry.
  void _smoothFrameAngles(List<FormFrame> frames) {
    if (frames.length < 3) return;

    final angleNames = <String>{};
    for (final f in frames) {
      angleNames.addAll(f.angles.keys);
    }

    for (final name in angleNames) {
      var data = frames.map((f) => f.angles[name] ?? double.nan).toList();

      data = _sparseMedianFilter(data, 3);
      data = _sparseMovingAverage(data, 9);
      data = _sparseMovingAverage(data, 7);

      for (int i = 0; i < frames.length; i++) {
        if (!data[i].isNaN) {
          frames[i].angles[name] = data[i];
        }
        // Frames that remain NaN keep no angle entry — omit rather than corrupt.
      }
    }
  }

  void _smoothKeyPoints(List<FormFrame> frames) {
    if (frames.length < 3) return;

    final pointNames = <String>{};
    for (final f in frames) {
      pointNames.addAll(f.keyPoints.keys);
    }

    for (final name in pointNames) {
      // Use NaN for frames that lack this landmark so they don't pull
      // neighbouring detected positions toward (0, 0).
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

  /// Median filter that ignores NaN entries.  Each output position is the
  /// median of the non-NaN values within the window; output is NaN when the
  /// window contains no valid values.
  List<double> _sparseMedianFilter(List<double> data, int window) {
    final half = window ~/ 2;
    return List.generate(data.length, (i) {
      final start = (i - half).clamp(0, data.length - 1);
      final end = (i + half).clamp(0, data.length - 1);
      final segment = data.sublist(start, end + 1)
          .where((v) => !v.isNaN)
          .toList()
        ..sort();
      if (segment.isEmpty) return double.nan;
      return segment[segment.length ~/ 2];
    });
  }

  /// Moving average that ignores NaN entries.  Output is NaN when no valid
  /// values exist in the window, preserving gaps rather than filling them
  /// with 0 or an incorrect interpolated value.
  List<double> _sparseMovingAverage(List<double> data, int window) {
    final half = window ~/ 2;
    return List.generate(data.length, (i) {
      final start = (i - half).clamp(0, data.length - 1);
      final end = (i + half).clamp(0, data.length - 1);
      double sum = 0;
      int count = 0;
      for (int j = start; j <= end; j++) {
        if (!data[j].isNaN) {
          sum += data[j];
          count++;
        }
      }
      return count > 0 ? sum / count : double.nan;
    });
  }

  // ---------------------------------------------------------------------------
  // Scoring & suggestions
  // ---------------------------------------------------------------------------

  /// Phase-aware ideal angles for a RHFH throw.
  /// Forehand uses a sidearm motion: throwing elbow stays lower and more bent,
  /// shoulder rotation is forward-facing rather than reaching back.
  static const _phaseIdealsFH = [
    // wind_up
    {
      'rightElbowAngle': 100.0,
      'leftElbowAngle': 150.0,
      'rightShoulderAngle': 60.0,
      'leftShoulderAngle': 95.0,
      'rightKneeAngle': 145.0,
      'leftKneeAngle': 155.0,
      'spineAngle': 82.0,
    },
    // power_pocket
    {
      'rightElbowAngle': 85.0,
      'leftElbowAngle': 135.0,
      'rightShoulderAngle': 90.0,
      'leftShoulderAngle': 100.0,
      'rightKneeAngle': 140.0,
      'leftKneeAngle': 155.0,
      'spineAngle': 83.0,
    },
    // release
    {
      'rightElbowAngle': 145.0,
      'leftElbowAngle': 140.0,
      'rightShoulderAngle': 120.0,
      'leftShoulderAngle': 95.0,
      'rightKneeAngle': 158.0,
      'leftKneeAngle': 163.0,
      'spineAngle': 86.0,
    },
    // follow_through
    {
      'rightElbowAngle': 130.0,
      'leftElbowAngle': 145.0,
      'rightShoulderAngle': 105.0,
      'leftShoulderAngle': 100.0,
      'rightKneeAngle': 168.0,
      'leftKneeAngle': 170.0,
      'spineAngle': 88.0,
    },
  ];

  /// Phase-aware ideal angles for a RHBH throw.
  /// Four rows correspond to: reach-back, power-pocket, release, follow-through.
  /// Values are interpolated across the frame range so each frame is scored
  /// against the ideal for its phase of the throw rather than a single
  /// fixed target, which was inaccurate (e.g. elbow must be extended at
  /// reach-back, tucked at power-pocket, extending again at release).
  static const _phaseIdeals = [
    // reach_back
    {
      'rightElbowAngle': 165.0,
      'leftElbowAngle': 155.0,
      'rightShoulderAngle': 70.0,
      'leftShoulderAngle': 90.0,
      'rightKneeAngle': 145.0,
      'leftKneeAngle': 155.0,
      'spineAngle': 80.0,
    },
    // power_pocket
    {
      'rightElbowAngle': 90.0,
      'leftElbowAngle': 130.0,
      'rightShoulderAngle': 110.0,
      'leftShoulderAngle': 100.0,
      'rightKneeAngle': 135.0,
      'leftKneeAngle': 150.0,
      'spineAngle': 82.0,
    },
    // release
    {
      'rightElbowAngle': 155.0,
      'leftElbowAngle': 145.0,
      'rightShoulderAngle': 130.0,
      'leftShoulderAngle': 95.0,
      'rightKneeAngle': 160.0,
      'leftKneeAngle': 165.0,
      'spineAngle': 87.0,
    },
    // follow_through
    {
      'rightElbowAngle': 140.0,
      'leftElbowAngle': 150.0,
      'rightShoulderAngle': 100.0,
      'leftShoulderAngle': 100.0,
      'rightKneeAngle': 170.0,
      'leftKneeAngle': 170.0,
      'spineAngle': 88.0,
    },
  ];

  /// Interpolate the ideal angle for [angleName] at fractional throw progress
  /// [t] (0 = first frame, 1 = last frame). Uses linear interpolation across
  /// the four phase snapshots, each occupying equal time.
  /// [throwType] selects between BH ('BH') and FH ('FH') phase tables.
  static double _phaseIdealAt(String angleName, double t,
      {String throwType = 'BH'}) {
    final table =
        throwType == 'FH' ? _phaseIdealsFH : _phaseIdeals;
    // t in [0,1] → phases each span equal width
    final scaled = t * (table.length - 1);
    final lo = scaled.floor().clamp(0, table.length - 1);
    final hi = (lo + 1).clamp(0, table.length - 1);
    final frac = scaled - lo;
    final loVal = table[lo][angleName];
    final hiVal = table[hi][angleName];
    if (loVal == null || hiVal == null) return double.nan;
    return loVal + (hiVal - loVal) * frac;
  }

  double _calculateScore(List<FormFrame> frames, {String throwType = 'BH'}) {
    if (frames.isEmpty) return 0.0;

    double totalScore = 0.0;
    int count = 0;
    final total = frames.length;

    for (int i = 0; i < total; i++) {
      final t = total > 1 ? i / (total - 1) : 0.0;
      final frame = frames[i];

      for (final entry in frame.angles.entries) {
        final ideal =
            _phaseIdealAt(entry.key, t, throwType: throwType);
        if (ideal.isNaN) continue;
        final diff = (entry.value - ideal).abs();
        // Score decays linearly: 100 at 0° diff, 0 at 50° diff
        final score = (100 - diff * 2.0).clamp(0.0, 100.0);
        totalScore += score;
        count++;
      }
    }

    return count > 0 ? totalScore / count : 0.0;
  }

  // ---------------------------------------------------------------------------
  // Mock fallback
  // ---------------------------------------------------------------------------

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
      score: _calculateScore(frames),
    );

    _analyses.add(analysis);
    _currentAnalysis = analysis;
    notifyListeners();

    return analysis;
  }

  Map<String, double> _generateRealisticAngles(double progress) {
    return {
      'rightElbowAngle': 140 - (sin(progress * pi) * 50),
      'leftElbowAngle': 140 + (sin(progress * pi) * 20),
      'rightShoulderAngle': 90 + (cos(progress * pi * 2) * 60),
      'leftShoulderAngle': 100 + (sin(progress * pi) * 30),
      'rightKneeAngle': 160 + (sin(progress * pi * 2) * 20),
      'leftKneeAngle': 160 - (sin(progress * pi * 2) * 15),
      'spineAngle': 85 + (sin(progress * pi) * 10),
    };
  }

  // ---------------------------------------------------------------------------
  // Pro data
  // ---------------------------------------------------------------------------

  Future<void> loadProFormData(String proName, {String throwType = 'BH'}) async {
    final proFormAnalysis = await ProBaselineParser.generateProAnalysis(
      proName,
      throwType,
      frameCount: 30,
    );

    _proAnalysis = proFormAnalysis;
    notifyListeners();
  }

  List<FormSuggestion> generateSuggestions({String throwType = 'BH'}) {
    if (_currentAnalysis == null || _currentAnalysis!.frames.isEmpty) {
      return [
        const FormSuggestion(
            'Upload a video to get personalized form suggestions'),
        const FormSuggestion(
            'Focus on maintaining balance throughout your throw'),
        FormSuggestion(
          throwType == 'FH'
              ? 'Practice your forehand sidearm snap'
              : 'Practice your reach-back motion',
          kbArticleId: 'bio_faq_2',
        ),
      ];
    }

    final suggestions = <FormSuggestion>[];
    final avgAngles = <String, double>{};
    for (var frame in _currentAnalysis!.frames) {
      for (var entry in frame.angles.entries) {
        avgAngles[entry.key] = (avgAngles[entry.key] ?? 0) + entry.value;
      }
    }
    avgAngles.updateAll(
        (key, value) => value / _currentAnalysis!.frames.length);

    if (throwType == 'FH') {
      // ---- Forehand-specific cues ----
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
          'Keep your off-arm close to your body to prevent premature shoulder opening',
          kbArticleId: 'bio_faq_2',
        ));
      }
    } else {
      // ---- Backhand-specific cues ----
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
      if ((avgAngles['leftKneeAngle'] ?? 0) < 140) {
        suggestions.add(const FormSuggestion(
          'Engage your legs more in the throw',
          kbArticleId: 'bio_faq_4',
        ));
      }
      if ((avgAngles['xFactor'] ?? 0) < 30) {
        suggestions.add(const FormSuggestion(
          'Increase hip-shoulder separation (X-factor) in your backswing',
          kbArticleId: 'bio_tip_5',
        ));
      }
    }

    if (suggestions.isEmpty) {
      suggestions.add(const FormSuggestion(
          'Great form! Keep practicing consistency'));
      suggestions.add(const FormSuggestion(
          'Focus on smooth, controlled movements'));
      suggestions.add(const FormSuggestion(
          'Try recording from different angles'));
    }

    return suggestions;
  }

  // ---------------------------------------------------------------------------
  // Public helpers used by PoseCorrectionScreen
  // ---------------------------------------------------------------------------

  /// Recalculate angles for a single frame from its current keyPoints.
  /// Falls back to 2D since manually-corrected frames have no z-depth.
  void recalculateFrameAngles(FormFrame frame) {
    final newAngles = AngleCalculator.calculateFromKeyPoints(frame.keyPoints);
    frame.angles
      ..clear()
      ..addAll(newAngles);
  }

  double recalculateScore(List<FormFrame> frames, {String throwType = 'BH'}) =>
      _calculateScore(frames, throwType: throwType);

  void clearAnalyses() {
    _analyses.clear();
    _currentAnalysis = null;
    _proAnalysis = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _poseDetector.close();
    super.dispose();
  }
}
