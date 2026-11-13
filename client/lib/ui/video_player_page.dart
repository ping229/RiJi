/// 全屏视频播放。
///
/// 内联播放器适合"扫一眼"，但横屏视频在日记卡片里最大只有 420px 高。
/// 点全屏后进这个页面：黑色背景、自适应方向、可拖动进度、点按暂停。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/error_messages.dart';

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.loader,
    this.title = '视频',
  });

  /// 返回本地可播放文件路径
  final Future<String> Function() loader;
  final String title;

  static Future<void> open(
    BuildContext context, {
    required Future<String> Function() loader,
    String title = '视频',
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(loader: loader, title: title),
      ),
    );
  }

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _controller;
  String? _error;
  bool _loading = true;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  void _onTick() {
    final c = _controller;
    if (c == null || !mounted) return;
    // 播放结束后自动把控制条放出来
    if (c.value.isInitialized && c.value.position >= c.value.duration && !c.value.isPlaying && !_showControls) {
      setState(() => _showControls = true);
      return;
    }
    setState(() {});
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final path = await widget.loader();
      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      controller.addListener(_onTick);
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '视频无法播放：${describeError(e)}';
        _loading = false;
      });
    }
  }

  Future<void> _togglePlay() async {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (c.value.position >= c.value.duration) await c.seekTo(Duration.zero);
      await c.play();
    }
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) {
    final total = d.inSeconds;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final ready = c != null && c.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white70, size: 40),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: _loading ? null : _init,
                      child: const Text('重试', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              )
            : !ready
                ? const CircularProgressIndicator(color: Colors.white70)
                : GestureDetector(
                    onTap: () => setState(() => _showControls = !_showControls),
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        Center(
                          child: AspectRatio(
                            aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
                            child: VideoPlayer(c),
                          ),
                        ),
                        if (_showControls)
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.black54, Colors.transparent, Colors.black87],
                                  stops: [0, 0.4, 1],
                                ),
                              ),
                              child: Column(
                                children: [
                                  const Spacer(),
                                  IconButton(
                                    iconSize: 56,
                                    color: Colors.white,
                                    icon: Icon(c.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill),
                                    onPressed: _togglePlay,
                                  ),
                                  const Spacer(),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                                    child: Row(
                                      children: [
                                        Text(_fmt(c.value.position), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                        Expanded(
                                          child: Slider(
                                            value: c.value.duration.inMilliseconds == 0
                                                ? 0
                                                : c.value.position.inMilliseconds
                                                    .clamp(0, c.value.duration.inMilliseconds)
                                                    .toDouble(),
                                            max: c.value.duration.inMilliseconds.toDouble().clamp(1, double.infinity),
                                            onChanged: (v) => c.seekTo(Duration(milliseconds: v.round())),
                                          ),
                                        ),
                                        Text(_fmt(c.value.duration), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
      ),
    );
  }
}
