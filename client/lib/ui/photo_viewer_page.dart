/// 全屏看图。
///
/// 设计目标（对应"查看原图没反应 / 横屏照片太小"这两个反馈）：
///   * **立刻有反应**：点下去马上打开页面并显示已有的压缩图，原图在后台加载
///   * **原图真的占满屏幕**：黑色背景 + BoxFit.contain + 可缩放，不再被对话框限制大小
///   * **加载失败看得见**：给出原因、重试按钮，并说明当前看到的是压缩图
///   * **方向正确**：加载后按 EXIF 把照片转正（横屏照片不会歪、也不会显得小）
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/error_messages.dart';
import '../core/image_utils.dart';

class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.loader,
    this.preview,
    this.title = '图片',
    this.caption,
  });

  /// 加载原图字节。可以抛异常，页面会显示失败原因并允许重试。
  final Future<Uint8List> Function() loader;

  /// 已经有的压缩图：先显示它，避免白屏等待
  final Uint8List? preview;

  final String title;

  /// 底部说明（例如"原图 · 2.4 MB"）
  final String? caption;

  static Future<void> open(
    BuildContext context, {
    required Future<Uint8List> Function() loader,
    Uint8List? preview,
    String title = '图片',
    String? caption,
  }) {
    return Navigator.of(context).push<void>(
      PageRouteBuilder(
        opaque: true,
        barrierColor: Colors.black,
        pageBuilder: (_, animation, _) => FadeTransition(
          opacity: animation,
          child: PhotoViewerPage(loader: loader, preview: preview, title: title, caption: caption),
        ),
      ),
    );
  }

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  Uint8List? _bytes;
  String? _error;
  bool _loading = true;
  int? _width;
  int? _height;
  final TransformationController _transform = TransformationController();
  TapDownDetails? _doubleTapDetails;

  @override
  void initState() {
    super.initState();
    _bytes = widget.preview;
    _load();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await widget.loader();
      // 解码 + 转正 + 缩小放到 isolate 里，避免大图卡住界面
      final normalized = await compute(_normalize, raw);
      if (!mounted) return;
      setState(() {
        _bytes = normalized;
        _loading = false;
      });
      _readSize(normalized);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is Exception ? describeError(e) : '$e';
        _loading = false;
      });
    }
  }

  Future<void> _readSize(Uint8List bytes) async {
    try {
      final info = await decodeImageFromList(bytes);
      if (!mounted) return;
      setState(() {
        _width = info.width;
        _height = info.height;
      });
      info.dispose();
    } catch (_) {
      // 尺寸只是锦上添花
    }
  }

  void _handleDoubleTap() {
    final position = _doubleTapDetails?.localPosition;
    if (position == null) return;
    final current = _transform.value.getMaxScaleOnAxis();
    if (current > 1.01) {
      _transform.value = Matrix4.identity();
    } else {
      _transform.value = Matrix4.identity()
        ..translateByDouble(-position.dx * 1.5, -position.dy * 1.5, 0, 1)
        ..scaleByDouble(2.5, 2.5, 1, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bytes = _bytes;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)),
              ),
            ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Material(
              color: Colors.red.shade900,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _bytes == null ? '原图加载失败：$_error' : '原图加载失败，下面显示的是压缩图：$_error',
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                    TextButton(
                      onPressed: _loading ? null : _load,
                      child: const Text('重试', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: GestureDetector(
              onDoubleTapDown: (details) => _doubleTapDetails = details,
              onDoubleTap: _handleDoubleTap,
              child: bytes == null
                  ? const Center(child: CircularProgressIndicator(color: Colors.white70))
                  : InteractiveViewer(
                      transformationController: _transform,
                      minScale: 1,
                      maxScale: 6,
                      child: SizedBox.expand(
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                          gaplessPlayback: true,
                          errorBuilder: (_, error, _) => Center(
                            child: Text('图片无法显示：$error', style: const TextStyle(color: Colors.white70)),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      [
                        widget.caption,
                        if (_width != null && _height != null) '$_width × $_height',
                        if (_width == null && _loading) '正在加载原图…',
                      ].whereType<String>().join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
                    ),
                  ),
                  const Text('双击缩放', style: TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// compute 要求顶层/静态函数：这里把可选的命名参数收掉
Uint8List _normalize(Uint8List bytes) => ImageUtils.normalizeForViewing(bytes);
