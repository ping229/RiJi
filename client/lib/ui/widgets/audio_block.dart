/// 语音块：内联可播放的音频条（播放/暂停 + 进度 + 时长）。
///
/// 播放内核复用 video_player（Windows 上走 Media Foundation，Android 上走 ExoPlayer），
/// 这样音频和视频共用一套解码链路，不必再引入第二个原生播放器依赖。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/models.dart';
import '../../core/waveform.dart';

class AudioBlockView extends StatefulWidget {
  const AudioBlockView({
    super.key,
    required this.block,
    required this.fileLoader,
  });

  final Block block;
  final Future<String> Function(String mediaKey) fileLoader;

  @override
  State<AudioBlockView> createState() => _AudioBlockViewState();
}

class _AudioBlockViewState extends State<AudioBlockView> {
  VideoPlayerController? _controller;
  bool _preparing = false;
  String? _error;

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  Future<void> _ensureController() async {
    if (_controller != null) return;
    final key = widget.block.mediaRef;
    if (key == null) return;
    final path = await widget.fileLoader(key);
    final controller = VideoPlayerController.file(File(path));
    await controller.initialize();
    controller.addListener(_onTick);
    if (!mounted) {
      await controller.dispose();
      return;
    }
    _controller = controller;
  }

  Future<void> _toggle() async {
    if (_preparing) return;
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      await _ensureController();
      final controller = _controller;
      if (controller == null) return;
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        if (controller.value.position >= controller.value.duration) {
          await controller.seekTo(Duration.zero);
        }
        await controller.play();
      }
      if (mounted) setState(() => _preparing = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '语音无法播放';
        _preparing = false;
      });
    }
  }

  Future<void> _seekTo(double ratio) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final total = controller.value.duration.inMilliseconds;
    if (total <= 0) return;
    final target = (total * ratio.clamp(0.0, 1.0)).round();
    await controller.seekTo(Duration(milliseconds: target));
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;
    final declared = widget.block.durationMs;
    final total = controller != null && controller.value.isInitialized
        ? controller.value.duration
        : (declared != null ? Duration(milliseconds: declared) : Duration.zero);
    final position = controller?.value.position ?? Duration.zero;
    final ratio = total.inMilliseconds > 0
        ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final playing = controller?.value.isPlaying ?? false;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          IconButton.filledTonal(
            onPressed: _error == null ? _toggle : null,
            icon: _preparing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(playing ? Icons.pause : Icons.play_arrow),
            tooltip: playing ? '暂停' : '播放',
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.mic_none, size: 15, color: theme.colorScheme.outline),
                    const SizedBox(width: 6),
                    Text(
                      _error ?? '语音',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                    ),
                    const Spacer(),
                    Text(
                      '${_fmt(position)} / ${_fmt(total)}',
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _WaveformOrBar(
                  block: widget.block,
                  progress: ratio,
                  onSeek: _seekTo,
                ),
              ],
            ),
          ),
          if (_error != null)
            TextButton(
              onPressed: _preparing ? null : _toggle,
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }
}

/// 有波形数据就画柱子，没有就退回进度条；点/拖任意位置可以跳转
class _WaveformOrBar extends StatelessWidget {
  const _WaveformOrBar({required this.block, required this.progress, required this.onSeek});

  final Block block;
  final double progress;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final raw = block.data['waveform'];
    final bars = raw is List ? raw.map((e) => (e as num).toInt()).toList() : const <int>[];

    final barsEmpty = bars.isEmpty || Waveform.isSilent(bars);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void seekAt(Offset local) {
          if (width <= 0) return;
          onSeek((local.dx / width).clamp(0.0, 1.0));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => seekAt(details.localPosition),
          onHorizontalDragUpdate: (details) => seekAt(details.localPosition),
          child: SizedBox(
            height: 28,
            width: double.infinity,
            child: barsEmpty
                ? Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(value: progress, minHeight: 4),
                    ),
                  )
                : CustomPaint(
                    painter: _WaveformPainter(
                      bars: bars,
                      progress: progress,
                      played: theme.colorScheme.primary,
                      unplayed: theme.colorScheme.primary.withValues(alpha: 0.25),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.bars,
    required this.progress,
    required this.played,
    required this.unplayed,
  });

  final List<int> bars;
  final double progress;
  final Color played;
  final Color unplayed;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final slot = size.width / bars.length;
    final barWidth = (slot * 0.62).clamp(1.0, 6.0);
    final paint = Paint()..style = PaintingStyle.fill;
    final playedUntil = (size.width * progress).clamp(0.0, size.width);

    for (var i = 0; i < bars.length; i += 1) {
      final centerX = slot * i + slot / 2;
      // 最低给 3px，静音段不至于完全看不见
      final height = (bars[i] / 100 * size.height).clamp(3.0, size.height);
      final top = (size.height - height) / 2;
      paint.color = centerX <= playedUntil ? played : unplayed;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(centerX - barWidth / 2, top, barWidth, height),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.bars != bars;
}