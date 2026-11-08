import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/error_messages.dart';

/// 摄像头采集页：拍照或录像，完成后把文件路径交回编辑器。
///
/// 桌面端（Windows）与移动端共用同一份实现；
/// 移动端另外还会优先走系统相机（见编辑器里的分支）。
class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({super.key, required this.videoMode});

  /// true = 录像，false = 拍照
  final bool videoMode;

  static Future<File?> open(BuildContext context, {required bool video}) {
    return Navigator.of(context).push<File>(
      MaterialPageRoute(builder: (_) => CameraCapturePage(videoMode: video)),
    );
  }

  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends State<CameraCapturePage> {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  String? _error;
  bool _initializing = false;
  bool _capturing = false;
  bool _recording = false;
  int _cameraIndex = 0;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _recording = false;
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (!mounted) return;
        setState(() => _error = '没有检测到摄像头。可以改用工具栏里的「图片」「视频」选择已有文件。');
        return;
      }
      await _startAt(0);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '无法打开摄像头：${describeError(e)}');
    }
  }

  Future<void> _startAt(int index) async {
    if (_initializing) return;
    _initializing = true;
    final previous = _controller;
    _controller = null;
    await previous?.dispose();

    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.high,
      enableAudio: widget.videoMode,
    );
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _cameraIndex = index;
        _error = null;
      });
    } on CameraException catch (e) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _error = e.code == 'CameraAccessDenied'
            ? 'Windows 拒绝了摄像头访问。请打开「设置 → 隐私和安全性 → 相机」，'
                '把「让桌面应用访问你的相机」和下方本应用的开关都打开；'
                '也可以返回后用工具栏的「图片」「视频」选择已有文件。'
            : '摄像头初始化失败：${describeError(e)}';
      });
    } catch (e) {
      await controller.dispose();
      if (!mounted) return;
      setState(() => _error = '摄像头初始化失败：${describeError(e)}');
    } finally {
      _initializing = false;
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _recording) return;
    await _startAt((_cameraIndex + 1) % _cameras.length);
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null || _capturing || _recording) return;
    setState(() => _capturing = true);
    try {
      final file = await controller.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(File(file.path));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '拍照失败：${describeError(e)}');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// 开始录像：只负责启动，不阻塞按钮
  Future<void> _startRecording() async {
    final controller = _controller;
    if (controller == null || _recording) return;
    try {
      await controller.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _elapsed = Duration.zero;
      });
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || !_recording) {
          timer.cancel();
          return;
        }
        setState(() => _elapsed += const Duration(seconds: 1));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '开始录制失败：${describeError(e)}');
    }
  }

  /// 停止录像：先把状态切走，确保按钮立刻可再点
  Future<void> _stopRecording() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _recording = false);
    _ticker?.cancel();
    try {
      final file = await controller.stopVideoRecording();
      if (!mounted) return;
      Navigator.of(context).pop(File(file.path));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '停止录制失败：${describeError(e)}');
    }
  }

  void _onShutter() {
    if (widget.videoMode) {
      if (_recording) {
        unawaited(_stopRecording());
      } else {
        unawaited(_startRecording());
      }
    } else {
      unawaited(_takePicture());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.videoMode ? '录像' : '拍照'),
        actions: [
          if (_cameras.length > 1)
            IconButton(
              icon: const Icon(Icons.cameraswitch_outlined),
              tooltip: '切换摄像头',
              onPressed: _recording ? null : _switchCamera,
            ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.videocam_off_outlined, color: Colors.white54, size: 44),
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, height: 1.6),
                    ),
                    const SizedBox(height: 20),
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                      child: const Text('返回'),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: Center(
                    child: controller == null
                        ? const CircularProgressIndicator()
                        : AspectRatio(
                            aspectRatio: controller.value.aspectRatio,
                            child: CameraPreview(controller),
                          ),
                  ),
                ),
                SizedBox(
                  height: 32,
                  child: Center(
                    child: _recording
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.fiber_manual_record,
                                  color: Colors.redAccent, size: 14),
                              const SizedBox(width: 6),
                              Text(
                                '录制中 ${_elapsed.inSeconds} 秒',
                                style: const TextStyle(color: Colors.redAccent),
                              ),
                            ],
                          )
                        : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: GestureDetector(
                    onTap: _capturing ? null : _onShutter,
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _recording ? Colors.red : Colors.white,
                        border: Border.all(color: Colors.white24, width: 4),
                      ),
                      child: Icon(
                        widget.videoMode
                            ? (_recording ? Icons.stop : Icons.videocam)
                            : Icons.camera_alt,
                        color: _recording ? Colors.white : Colors.black87,
                        size: 30,
                      ),
                    ),
                  ),
                ),
                Text(
                  widget.videoMode
                      ? (_recording ? '点击停止并保存' : '点击开始录制')
                      : '点击拍照',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
