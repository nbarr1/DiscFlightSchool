import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoControls extends StatelessWidget {
  final VideoPlayerController controller;
  final VoidCallback? onPlayPause;

  const VideoControls({
    Key? key,
    required this.controller,
    this.onPlayPause,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          VideoProgressIndicator(
            controller,
            allowScrubbing: true,
            colors: const VideoProgressColors(
              playedColor: Colors.blue,
              bufferedColor: Colors.grey,
              backgroundColor: Colors.black,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: Icon(
                  controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  size: 32,
                ),
                onPressed: onPlayPause ??
                    () {
                      controller.value.isPlaying
                          ? controller.pause()
                          : controller.play();
                    },
              ),
              IconButton(
                icon: const Icon(Icons.replay_5, color: Colors.white),
                onPressed: () {
                  final newPosition =
                      controller.value.position - const Duration(seconds: 5);
                  controller.seekTo(newPosition);
                },
              ),
              IconButton(
                icon: const Icon(Icons.forward_5, color: Colors.white),
                onPressed: () {
                  final newPosition =
                      controller.value.position + const Duration(seconds: 5);
                  controller.seekTo(newPosition);
                },
              ),
              IconButton(
                icon: const Icon(Icons.replay, color: Colors.white),
                onPressed: () {
                  controller.seekTo(Duration.zero);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${_formatDuration(controller.value.position)} / ${_formatDuration(controller.value.duration)}',
            style: const TextStyle(color: Colors.white),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}