/// 视频块：内联播放器卡片（封面 + 播放按钮 + 时长），点击后原地播放。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/error_messages.dart';
import 'package:video_player/video_player.dart';

import '../../core/models.dart';

class VideoBlockView extends StatefulWidget {
  const VideoBlockView({
    super.key,
    required this.block,
    required this.fileLoader,
  });

  final Block block;
  final Future<String> Function(String mediaKey) fileLoader;

  @override
  State<VideoBlockView> createState() => _VideoBlockViewState();
}

class _VideoBlockViewState extends State<VideoBlockView> {
  VideoPlayerController? _controller;
  bool _initializing = false;
  String? _error;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final key = widget.block.mediaRef;
    if (key == null || _initializing) return;
    setState(() {
      _initializing = true;
      _error = null;
    });
    try {
      final path = await widget.fileLoader(key);
      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '视频无法播放：${describeError(e)}';
        _initializing = false;
      });
    }
  }

  String _fmtDuration(int? ms) {
    if (ms == null || ms <= 0) return '';
    final total = (ms / 1000).round();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;
    final width = widget.block.width;
    final height = widget.block.height;
    final aspect = (width != null && height != null && height > 0) ? width / height : 16 / 9;

    if (controller != null && controller.value.isInitialized) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio == 0 ? aspect : controller.value.aspectRatio,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              VideoPlayer(controller),
              VideoProgressIndicator(controller, allowScrubbing: true, padding: const EdgeInsets.all(6)),
            ],
          ),
        ),
      );
    }

    return AspectRatio(
      aspectRatio: aspect,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _error == null ? _start : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: _initializing
                    ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.play_circle_fill, size: 56, color: theme.colorScheme.primary),
              ),
              Positioned(
                left: 12,
                bottom: 10,
                right: 12,
                child: Row(
                  children: [
                    Icon(Icons.videocam_outlined, size: 16, color: theme.colorScheme.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _error ?? (widget.block.fileName ?? '视频') + ' ${_fmtDuration(widget.block.durationMs)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
