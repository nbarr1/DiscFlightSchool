import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';

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

  /// Validate video file
  bool isValidVideoFile(String path) {
    final validExtensions = ['.mp4', '.mov', '.avi', '.mkv', '.m4v'];
    return validExtensions.any((ext) => path.toLowerCase().endsWith(ext));
  }
}