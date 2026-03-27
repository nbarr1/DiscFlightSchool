import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class VideoFrameExtractor {
  /// Extract frames from video. [intervalMs] controls spacing between frames.
  /// Frame interval used across the analysis pipeline.
  static const int defaultIntervalMs = 50;

  Future<List<String>> extractFrames(String videoPath, {int frameCount = 60, int intervalMs = defaultIntervalMs, int startMs = 0}) async {
    final tempDir = await getTemporaryDirectory();
    final outputDir = Directory('${tempDir.path}/frames_${DateTime.now().millisecondsSinceEpoch}');
    
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    final frames = <String>[];
    
    debugPrint('Starting frame extraction from: $videoPath');
    
    // Extract frames at different time positions
    for (int i = 0; i < frameCount; i++) {
      final timeMs = startMs + (i * intervalMs);
      
      try {
        final thumbnailPath = await VideoThumbnail.thumbnailFile(
          video: videoPath,
          thumbnailPath: outputDir.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 640,
          timeMs: timeMs,
          quality: 75,
        );
        
        if (thumbnailPath != null) {
          // Rename to sequential format
          final newPath = '${outputDir.path}/frame_${i.toString().padLeft(3, '0')}.jpg';
          final file = File(thumbnailPath);
          if (await file.exists()) {
            await file.rename(newPath);
            frames.add(newPath);
            debugPrint('Extracted frame $i at ${timeMs}ms -> $newPath');
          }
        }
      } catch (e) {
        debugPrint('Error extracting frame $i: $e');
      }
      
      // Small delay to avoid overwhelming the system
      await Future.delayed(const Duration(milliseconds: 10));
    }
    
    debugPrint('Successfully extracted ${frames.length} frames');
    return frames;
  }

  Future<void> cleanupFrames(List<String> framePaths) async {
    for (var path in framePaths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('Error deleting frame: $e');
      }
    }
    
    // Also try to cleanup the parent directory
    if (framePaths.isNotEmpty) {
      try {
        final dir = Directory(File(framePaths.first).parent.path);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (e) {
        debugPrint('Error deleting frame directory: $e');
      }
    }
  }
}