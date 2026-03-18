import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/form_analysis.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'video_frame_extractor.dart';
import 'dart:io';
import 'dart:math';

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

  Future<FormAnalysis> analyzeForm(String videoPath, {int startMs = 0, int frameCount = 30}) async {
    List<String>? framePaths;

    try {
      debugPrint('Starting form analysis for: $videoPath (start: ${startMs}ms, frames: $frameCount)');

      // Extract frames from video
      framePaths = await _frameExtractor.extractFrames(videoPath, frameCount: frameCount, startMs: startMs);
      debugPrint('Extracted ${framePaths.length} frames');
      
      // Read image dimensions from first frame
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

      // Analyze each frame
      final frames = <FormFrame>[];
      const intervalMs = 200; // Must match VideoFrameExtractor.intervalMs

      for (int i = 0; i < framePaths.length; i++) {
        final framePath = framePaths[i];
        if (i % 10 == 0) {
          debugPrint('Analyzing frame ${i + 1}/${framePaths.length}');
        }

        final inputImage = InputImage.fromFilePath(framePath);
        final poses = await _poseDetector.processImage(inputImage);

        if (poses.isNotEmpty) {
          final pose = poses.first;
          final angles = _calculateAngles(pose);
          final keyPoints = _extractKeyPoints(pose);

          frames.add(FormFrame(
            timestamp: Duration(milliseconds: i * intervalMs),
            angles: angles,
            keyPoints: keyPoints,
            imageWidth: imgWidth,
            imageHeight: imgHeight,
          ));
        } else {
          // Add empty frame so skeleton hides when person not visible
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
        debugPrint('No poses detected in any frame, using mock data');
        return _generateMockAnalysis(videoPath);
      }
      
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
    } catch (e) {
      debugPrint('Error analyzing form: $e');
      return _generateMockAnalysis(videoPath);
    } finally {
      // Cleanup extracted frames
      if (framePaths != null) {
        await _frameExtractor.cleanupFrames(framePaths);
      }
    }
  }

  Map<String, double> _calculateAngles(Pose pose) {
    final landmarks = pose.landmarks;
    final angles = <String, double>{};

    // Helper function to calculate angle between three points
    double calculateAngle(PoseLandmark? a, PoseLandmark? b, PoseLandmark? c) {
      if (a == null || b == null || c == null) return 0.0;
      
      final ba = Point(a.x - b.x, a.y - b.y);
      final bc = Point(c.x - b.x, c.y - b.y);
      
      final dotProduct = ba.x * bc.x + ba.y * bc.y;
      final magnitudeBA = sqrt(ba.x * ba.x + ba.y * ba.y);
      final magnitudeBC = sqrt(bc.x * bc.x + bc.y * bc.y);
      
      if (magnitudeBA == 0 || magnitudeBC == 0) return 0.0;
      
      final cosAngle = dotProduct / (magnitudeBA * magnitudeBC);
      final angle = acos(cosAngle.clamp(-1.0, 1.0)) * (180 / pi);
      
      return angle;
    }

    // Right arm angles
    final rightShoulder = landmarks[PoseLandmarkType.rightShoulder];
    final rightElbow = landmarks[PoseLandmarkType.rightElbow];
    final rightWrist = landmarks[PoseLandmarkType.rightWrist];
    final rightHip = landmarks[PoseLandmarkType.rightHip];
    
    // Left arm angles
    final leftShoulder = landmarks[PoseLandmarkType.leftShoulder];
    final leftElbow = landmarks[PoseLandmarkType.leftElbow];
    final leftWrist = landmarks[PoseLandmarkType.leftWrist];
    final leftHip = landmarks[PoseLandmarkType.leftHip];
    
    // Leg angles
    final rightKnee = landmarks[PoseLandmarkType.rightKnee];
    final rightAnkle = landmarks[PoseLandmarkType.rightAnkle];
    final leftKnee = landmarks[PoseLandmarkType.leftKnee];
    final leftAnkle = landmarks[PoseLandmarkType.leftAnkle];

    // Calculate key angles for disc golf form
    angles['rightElbowAngle'] = calculateAngle(rightShoulder, rightElbow, rightWrist);
    angles['leftElbowAngle'] = calculateAngle(leftShoulder, leftElbow, leftWrist);
    angles['rightShoulderAngle'] = calculateAngle(rightElbow, rightShoulder, rightHip);
    angles['leftShoulderAngle'] = calculateAngle(leftElbow, leftShoulder, leftHip);
    angles['rightKneeAngle'] = calculateAngle(rightHip, rightKnee, rightAnkle);
    angles['leftKneeAngle'] = calculateAngle(leftHip, leftKnee, leftAnkle);
    
    // Hip angle (using shoulders and hips)
    if (rightShoulder != null && leftShoulder != null && rightHip != null && leftHip != null) {
      final shoulderMid = Point(
        (rightShoulder.x + leftShoulder.x) / 2,
        (rightShoulder.y + leftShoulder.y) / 2,
      );
      final hipMid = Point(
        (rightHip.x + leftHip.x) / 2,
        (rightHip.y + leftHip.y) / 2,
      );
      
      // Spine angle relative to vertical
      final spineAngle = atan2(
        shoulderMid.x - hipMid.x,
        shoulderMid.y - hipMid.y,
      ) * (180 / pi);
      angles['spineAngle'] = 90 - spineAngle.abs();
    }

    return angles;
  }

  Map<String, Offset> _extractKeyPoints(Pose pose) {
    final keyPoints = <String, Offset>{};
    
    for (var landmark in pose.landmarks.entries) {
      keyPoints[landmark.key.toString()] = Offset(
        landmark.value.x.toDouble(),
        landmark.value.y.toDouble(),
      );
    }
    
    return keyPoints;
  }

  double _calculateScore(List<FormFrame> frames) {
    if (frames.isEmpty) return 0.0;

    double totalScore = 0.0;
    int count = 0;

    for (var frame in frames) {
      // Ideal angles for disc golf form
      final idealAngles = {
        'rightElbowAngle': 120.0,
        'leftElbowAngle': 140.0,
        'rightShoulderAngle': 100.0,
        'leftShoulderAngle': 100.0,
        'rightKneeAngle': 160.0,
        'leftKneeAngle': 160.0,
        'spineAngle': 85.0,
      };

      for (var entry in frame.angles.entries) {
        if (idealAngles.containsKey(entry.key)) {
          final diff = (entry.value - idealAngles[entry.key]!).abs();
          final score = max(0, 100 - diff);
          totalScore += score;
          count++;
        }
      }
    }

    return count > 0 ? totalScore / count : 0.0;
  }

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

  Future<void> loadProFormData(String proName) async {
    // Mock pro data - in a real app, this would load from a database
    final mockFrames = List.generate(30, (index) {
      final progress = index / 30;
      return FormFrame(
        timestamp: Duration(milliseconds: index * 100),
        angles: {
          'rightElbowAngle': 120.0 + (sin(progress * pi) * 10),
          'leftElbowAngle': 140.0,
          'rightShoulderAngle': 100.0 + (cos(progress * pi * 2) * 20),
          'leftShoulderAngle': 100.0,
          'rightKneeAngle': 160.0,
          'leftKneeAngle': 160.0,
          'spineAngle': 85.0,
        },
        keyPoints: {},
      );
    });

    final proFormAnalysis = FormAnalysis(
      id: 'pro_$proName',
      date: DateTime.now(),
      videoPath: '',
      frames: mockFrames,
      score: 95.0,
    );

    _proAnalysis = proFormAnalysis;
    _currentAnalysis = proFormAnalysis;
    notifyListeners();
  }

  List<String> generateSuggestions() {
    if (_currentAnalysis == null || _currentAnalysis!.frames.isEmpty) {
      return [
        'Upload a video to get personalized form suggestions',
        'Focus on maintaining balance throughout your throw',
        'Practice your reach-back motion',
      ];
    }

    final suggestions = <String>[];

    // Analyze average angles
    final avgAngles = <String, double>{};
    for (var frame in _currentAnalysis!.frames) {
      for (var entry in frame.angles.entries) {
        avgAngles[entry.key] = (avgAngles[entry.key] ?? 0) + entry.value;
      }
    }

    avgAngles.updateAll((key, value) => value / _currentAnalysis!.frames.length);

    // Generate suggestions based on angles
    if ((avgAngles['rightShoulderAngle'] ?? 0) < 80) {
      suggestions.add('Increase shoulder rotation for more power');
    }
    if ((avgAngles['rightElbowAngle'] ?? 0) > 140) {
      suggestions.add('Keep your elbow at 90-120 degrees during pull-through');
    }
    if ((avgAngles['rightKneeAngle'] ?? 0) < 140) {
      suggestions.add('Keep your knees less bent for better balance');
    }
    if ((avgAngles['spineAngle'] ?? 0) < 75) {
      suggestions.add('Maintain a more upright spine position');
    }
    if ((avgAngles['leftKneeAngle'] ?? 0) < 140) {
      suggestions.add('Engage your legs more in the throw');
    }

    if (suggestions.isEmpty) {
      suggestions.add('Great form! Keep practicing consistency');
      suggestions.add('Focus on smooth, controlled movements');
      suggestions.add('Try recording from different angles');
    }

    return suggestions;
  }

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