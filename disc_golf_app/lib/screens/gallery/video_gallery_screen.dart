import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// Metadata for a saved flight path video.
class _SavedVideo {
  final String path;
  final DateTime savedAt;
  final String? thumbnailPath;

  _SavedVideo({
    required this.path,
    required this.savedAt,
    this.thumbnailPath,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'savedAt': savedAt.toIso8601String(),
        'thumbnailPath': thumbnailPath,
      };

  factory _SavedVideo.fromJson(Map<String, dynamic> json) => _SavedVideo(
        path: json['path'] as String,
        savedAt: DateTime.parse(json['savedAt'] as String),
        thumbnailPath: json['thumbnailPath'] as String?,
      );
}

class VideoGalleryScreen extends StatefulWidget {
  const VideoGalleryScreen({super.key});

  static const prefsKey = 'saved_flight_videos';

  /// Register a newly exported video. Called from the export flow.
  static Future<String> saveToGallery(String tempVideoPath) async {
    // Copy to persistent app directory
    final appDir = await getApplicationDocumentsDirectory();
    final galleryDir = Directory('${appDir.path}/flight_gallery');
    if (!await galleryDir.exists()) {
      await galleryDir.create(recursive: true);
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final destPath = '${galleryDir.path}/flight_$timestamp.mp4';
    await File(tempVideoPath).copy(destPath);

    // Generate thumbnail
    String? thumbPath;
    try {
      thumbPath = await VideoThumbnail.thumbnailFile(
        video: destPath,
        thumbnailPath: galleryDir.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 320,
        quality: 75,
      );
    } catch (_) {}

    // Save to registry
    final video = _SavedVideo(
      path: destPath,
      savedAt: DateTime.now(),
      thumbnailPath: thumbPath,
    );

    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(prefsKey) ?? [];
    jsonList.insert(0, jsonEncode(video.toJson()));
    await prefs.setStringList(prefsKey, jsonList);

    return destPath;
  }

  @override
  State<VideoGalleryScreen> createState() => _VideoGalleryScreenState();
}

class _VideoGalleryScreenState extends State<VideoGalleryScreen> {
  List<_SavedVideo> _videos = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(VideoGalleryScreen.prefsKey) ?? [];
    final videos = <_SavedVideo>[];

    for (final jsonStr in jsonList) {
      try {
        final video =
            _SavedVideo.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
        // Only keep videos that still exist on disk
        if (await File(video.path).exists()) {
          videos.add(video);
        }
      } catch (_) {}
    }

    setState(() {
      _videos = videos;
      _isLoading = false;
    });
  }

  Future<void> _deleteVideo(int index) async {
    final video = _videos[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Video'),
        content:
            const Text('Remove this video from the gallery? The copy saved '
                'to your device gallery will not be affected.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Delete file
    try {
      await File(video.path).delete();
    } catch (_) {}
    if (video.thumbnailPath != null) {
      try {
        await File(video.thumbnailPath!).delete();
      } catch (_) {}
    }

    // Update prefs
    setState(() {
      _videos.removeAt(index);
    });
    await _saveRegistry();
  }

  Future<void> _saveRegistry() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList =
        _videos.map((v) => jsonEncode(v.toJson())).toList();
    await prefs.setStringList(VideoGalleryScreen.prefsKey, jsonList);
  }

  void _playVideo(_SavedVideo video) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _VideoPlaybackScreen(videoPath: video.path),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flight Path Gallery'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _videos.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.video_library,
                          size: 64, color: Colors.grey[600]),
                      const SizedBox(height: 16),
                      Text(
                        'No saved flight path videos',
                        style: TextStyle(
                            fontSize: 18, color: Colors.grey[500]),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Export a video from Flight Tracker to see it here',
                        style: TextStyle(
                            fontSize: 14, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _videos.length,
                  itemBuilder: (context, index) {
                    final video = _videos[index];
                    return _VideoCard(
                      video: video,
                      formatDate: _formatDate,
                      formatSize: _formatSize,
                      onPlay: () => _playVideo(video),
                      onDelete: () => _deleteVideo(index),
                    );
                  },
                ),
    );
  }

}

class _VideoCard extends StatelessWidget {
  final _SavedVideo video;
  final String Function(DateTime) formatDate;
  final String Function(int) formatSize;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  const _VideoCard({
    required this.video,
    required this.formatDate,
    required this.formatSize,
    required this.onPlay,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPlay,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail
            SizedBox(
              height: 180,
              child: video.thumbnailPath != null &&
                      File(video.thumbnailPath!).existsSync()
                  ? Image.file(
                      File(video.thumbnailPath!),
                      fit: BoxFit.cover,
                    )
                  : Container(
                      color: Colors.grey[800],
                      child: const Center(
                        child: Icon(Icons.flight_takeoff,
                            size: 48, color: Colors.white38),
                      ),
                    ),
            ),
            // Info row
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          formatDate(video.savedAt),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const SizedBox(height: 2),
                        FutureBuilder<int>(
                          future: File(video.path).length(),
                          builder: (_, snap) => Text(
                            snap.hasData
                                ? formatSize(snap.data!)
                                : '',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[500]),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.play_circle_fill,
                        color: Colors.blue, size: 36),
                    onPressed: onPlay,
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        color: Colors.red[300]),
                    onPressed: onDelete,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Simple full-screen video playback.
class _VideoPlaybackScreen extends StatefulWidget {
  final String videoPath;
  const _VideoPlaybackScreen({required this.videoPath});

  @override
  State<_VideoPlaybackScreen> createState() => _VideoPlaybackScreenState();
}

class _VideoPlaybackScreenState extends State<_VideoPlaybackScreen> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        setState(() => _initialized = true);
        _controller.play();
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Center(
        child: !_initialized
            ? const CircularProgressIndicator()
            : GestureDetector(
                onTap: () {
                  setState(() {
                    _controller.value.isPlaying
                        ? _controller.pause()
                        : _controller.play();
                  });
                },
                child: AspectRatio(
                  aspectRatio: _controller.value.aspectRatio,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      VideoPlayer(_controller),
                      if (!_controller.value.isPlaying)
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(12),
                          child: const Icon(Icons.play_arrow,
                              color: Colors.white, size: 48),
                        ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
