import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';

class VideoService extends ChangeNotifier {
  final ImagePicker _picker = ImagePicker();
  String? _currentVideoPath;
  List<String> _recentVideos = [];
  String? _lastError;

  String? get currentVideoPath => _currentVideoPath;
  List<String> get recentVideos => List.unmodifiable(_recentVideos);

  /// The last error message from a failed capture/select call.
  String? get lastError => _lastError;

  /// Capture a new video using the device camera
  Future<String?> captureVideo() async {
    _lastError = null;
    try {
      // Note: maxDuration omitted — some Android camera apps return null when it is set
      final XFile? video = await _picker.pickVideo(
        source: ImageSource.camera,
      );

      if (video != null) {
        _currentVideoPath = video.path;
        _addToRecentVideos(video.path);
        notifyListeners();
        return video.path;
      }
      _lastError = 'No video returned from camera. Please record a video and confirm.';
      return null;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Error capturing video: $e');
      return null;
    }
  }

  /// Select an existing video from the gallery.
  /// Uses file_picker (Storage Access Framework) to avoid the image_picker_android
  /// Pigeon channel bug that prevents video selection on some Android devices.
  Future<String?> selectVideo() async {
    _lastError = null;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
      );

      final path = result?.files.single.path;
      if (path != null) {
        _currentVideoPath = path;
        _addToRecentVideos(path);
        notifyListeners();
        return path;
      }
      _lastError = 'No video selected from gallery.';
      return null;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Error selecting video: $e');
      return null;
    }
  }

  /// Set the current video path manually
  void setCurrentVideo(String path) {
    _currentVideoPath = path;
    _addToRecentVideos(path);
    notifyListeners();
  }

  /// Clear the current video
  void clearCurrentVideo() {
    _currentVideoPath = null;
    notifyListeners();
  }

  /// Add a video to recent videos list
  void _addToRecentVideos(String path) {
    // Remove if already exists
    _recentVideos.remove(path);
    
    // Add to beginning
    _recentVideos.insert(0, path);
    
    // Keep only last 10 videos
    if (_recentVideos.length > 10) {
      _recentVideos = _recentVideos.sublist(0, 10);
    }
  }

  /// Remove a video from recent videos
  void removeFromRecent(String path) {
    _recentVideos.remove(path);
    notifyListeners();
  }

  /// Clear all recent videos
  void clearRecentVideos() {
    _recentVideos.clear();
    notifyListeners();
  }

  /// Check if a video file exists
  bool videoExists(String path) {
    try {
      return File(path).existsSync();
    } catch (e) {
      debugPrint('Error checking video existence: $e');
      return false;
    }
  }

  /// Get video file size in MB
  Future<double?> getVideoSize(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        final bytes = await file.length();
        return bytes / (1024 * 1024); // Convert to MB
      }
      return null;
    } catch (e) {
      debugPrint('Error getting video size: $e');
      return null;
    }
  }

  /// Delete a video file
  Future<bool> deleteVideo(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        removeFromRecent(path);
        
        if (_currentVideoPath == path) {
          _currentVideoPath = null;
        }
        
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error deleting video: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Video stabilization
  // ---------------------------------------------------------------------------

  /// Stabilize a video using FFmpeg's two-pass vidstab pipeline.
  ///
  /// Pass 1 (`vidstabdetect`) analyses frame-to-frame motion and writes a
  /// transforms file.  Pass 2 (`vidstabtransform`) warps each frame to cancel
  /// that motion, producing a video whose background is locked to the first
  /// frame.  When disc detection is run on the stabilized output, all resulting
  /// coordinates are environment-relative rather than camera-relative.
  ///
  /// Both temp files are written to [getTemporaryDirectory()] and are
  /// automatically cleaned up by the OS on the next app restart.
  ///
  /// Returns the path of the stabilized output file, or throws on failure.
  Future<String> stabilizeVideo(
    String inputPath, {
    /// 1–10: sensitivity to camera shake. 8 covers handheld panning shots.
    int shakiness = 8,
    /// Smoothing window in frames. 20 ≈ 2 s at 10 fps.
    int smoothing = 20,
    /// Percentage zoom to crop stabilization black borders.
    int zoom = 3,
    void Function(String)? onStatus,
  }) async {
    final tmp = await getTemporaryDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final transformsPath = '${tmp.path}/vidstab_$ts.trf';
    final outputPath = '${tmp.path}/stabilized_$ts.mp4';

    // Pass 1 — detect motion and write transforms
    onStatus?.call('Analysing camera motion…');
    debugPrint('vidstab pass 1: $inputPath → $transformsPath');
    final pass1 = await FFmpegKit.execute(
      '-y -i "$inputPath"'
      ' -vf "vidstabdetect=shakiness=$shakiness:accuracy=9:result=$transformsPath"'
      ' -f null -',
    );
    final rc1 = await pass1.getReturnCode();
    if (!ReturnCode.isSuccess(rc1)) {
      final log = await pass1.getAllLogsAsString();
      throw Exception('vidstabdetect failed (rc=${rc1?.getValue()}): $log');
    }

    // Pass 2 — apply stabilization transforms
    onStatus?.call('Stabilizing video…');
    debugPrint('vidstab pass 2: → $outputPath');
    final pass2 = await FFmpegKit.execute(
      '-y -i "$inputPath"'
      ' -vf "vidstabtransform=input=$transformsPath:smoothing=$smoothing:crop=black:zoom=$zoom"'
      ' -c:v libx264 -preset fast -crf 23'
      ' -c:a copy'
      ' "$outputPath"',
    );
    final rc2 = await pass2.getReturnCode();

    // Clean up transforms file regardless of pass-2 outcome
    try {
      final trf = File(transformsPath);
      if (await trf.exists()) await trf.delete();
    } catch (_) {}

    if (!ReturnCode.isSuccess(rc2)) {
      final log = await pass2.getAllLogsAsString();
      throw Exception('vidstabtransform failed (rc=${rc2?.getValue()}): $log');
    }

    onStatus?.call('Stabilization complete');
    debugPrint('Stabilized video written to $outputPath');
    return outputPath;
  }

  /// Delete a previously stabilized temp file produced by [stabilizeVideo].
  Future<void> deleteStabilizedVideo(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('Could not delete stabilized video $path: $e');
    }
  }

  // ---------------------------------------------------------------------------

  /// Validate video file
  bool isValidVideoFile(String path) {
    final validExtensions = ['.mp4', '.mov', '.avi', '.mkv', '.m4v'];
    return validExtensions.any((ext) => path.toLowerCase().endsWith(ext));
  }
}