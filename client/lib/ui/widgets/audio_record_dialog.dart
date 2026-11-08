/// 录音对话框：调用麦克风，录完直接返回文件路径与时长。
/// 权限在点击"插入语音"时才请求（需求 5.3），而不是启动即弹窗。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/error_messages.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/waveform.dart';

class RecordedAudio {
  RecordedAudio({required this.path, required this.duration, this.waveform = const []});

  /// 录音时采集的波形（0..100 的柱子）
  final List<int> waveform;

  final String path;
  final Duration duration;
}

class AudioRecordDialog extends StatefulWidget {
  const AudioRecordDialog({super.key});

  static Future<RecordedAudio?> show(BuildContext context) {
    return showDialog<RecordedAudio>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AudioRecordDialog(),
    );
  }

  @override
  State<AudioRecordDialog> createState() => _AudioRecordDialogState();
}

class _AudioRecordDialogState extends State<AudioRecordDialog> {
  final AudioRecorder _recorder = AudioRecorder();
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  bool _recording = false;
  String? _error;
  String? _path;

  /// 录音过程中的振幅采样（0..100）
  final List<int> _levels = [];
  StreamSubscription<Amplitude>? _amplitudeSub;

  @override
  void initState() {
    super.initState();
    _start();
  }

  /// 把系统权限错误翻译成用户能照做的步骤
  String _micHint(Object e) {
    final text = e.toString().toLowerCase();
    if (text.contains('拒绝访问') || text.contains('denied') || text.contains('access')) {
      return '系统拒绝了麦克风权限。Windows：设置 → 隐私和安全性 → 麦克风 → 允许桌面应用访问；'
          '手机：在系统设置里给本应用麦克风权限';
    }
    return '无法开始录音：${describeError(e)}';
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _amplitudeSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final allowed = await _recorder.hasPermission();
      if (!allowed) {
        setState(() => _error = '没有麦克风权限。Windows：设置 → 隐私和安全性 → 麦克风 → 允许桌面应用访问；手机：在系统设置里给本应用麦克风权限。');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}${Platform.pathSeparator}rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          numChannels: 1,
          sampleRate: 44100,
        ),
        path: path,
      );
      _path = path;
      // 采集振幅用于画波形；失败不影响录音本身
      try {
        _amplitudeSub?.cancel();
        _amplitudeSub = _recorder
            .onAmplitudeChanged(const Duration(milliseconds: 150))
            .listen((amp) => _levels.add(Waveform.levelFromDb(amp.current)));
      } catch (_) {
        // 设备不支持振幅回调时跳过波形
      }
      setState(() => _recording = true);
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        setState(() => _elapsed += const Duration(milliseconds: 200));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _micHint(e));
    }
  }

  Future<void> _stop({required bool keep}) async {
    _ticker?.cancel();
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = _path;
    }
    if (!mounted) return;
    if (!keep || path == null) {
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {
          // 清理失败不影响流程
        }
      }
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(RecordedAudio(path: path, duration: _elapsed));
  }

  String _fmt(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('录制语音'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null)
            Text(_error!, style: TextStyle(color: theme.colorScheme.error))
          else ...[
            Icon(Icons.mic, size: 48, color: _recording ? theme.colorScheme.primary : theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(_fmt(_elapsed), style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              _recording ? '正在录音…' : '准备中…',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => _stop(keep: false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (_recording || _error != null) ? () => _stop(keep: _error == null) : null,
          child: const Text('停止并插入'),
        ),
      ],
    );
  }
}
