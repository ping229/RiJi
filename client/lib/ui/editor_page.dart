import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';

import '../core/error_messages.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../core/api_client.dart';
import '../core/hlc.dart';
import '../core/image_utils.dart';
import '../core/local_store.dart';
import '../core/media_service.dart';
import '../core/models.dart';
import '../core/paste_utils.dart';
import '../core/rich_text.dart';
import '../core/session_store.dart';
import '../core/sync_service.dart';
import '../core/vv.dart';
import 'camera_page.dart';
import 'widgets/audio_block.dart';
import 'widgets/rich_text_view.dart';
import 'widgets/audio_record_dialog.dart';
import 'widgets/video_block.dart';

/// 编辑器：块序列 + 自动保存。
///
/// 每个块独立持有版本向量和 HLC，保存时只提交发生变化的块，
/// 这样两台设备各改不同位置时不会互相覆盖。
class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.api,
    required this.session,
    required this.store,
    required this.sync,
    required this.date,
    required this.tzId,
    required this.dayCutHour,
    required this.today,
    required this.writable,
    required this.onHlcChanged,
  });

  final ApiClient api;
  final Session session;
  final DiaryStore store;
  final SyncService sync;
  final String date;
  final String tzId;
  final int dayCutHour;
  final String today;
  final bool writable;
  final Future<void> Function(String hlc) onHlcChanged;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> with WidgetsBindingObserver {
  static const _uuid = Uuid();

  /// 输入后多久写本地（内容先落盘，不能丢）
  static const _localSaveDelay = Duration(milliseconds: 600);

  /// 停止输入多久之后才推服务器。用户要求的"退出时同步"为主，
  /// 这个定时器只是兜底：一直开着窗口也不会让内容永远只在本机。
  static const _idleSyncDelay = Duration(seconds: 25);

  final List<Block> _blocks = [];
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, FocusNode> _focusNodes = {};
  final Set<String> _dirty = {};
  final Map<String, Uint8List> _mediaCache = {};

  /// 每个块一次 Future，避免每次重建都重新发下载请求（长日记会一卡一卡的）
  final Map<String, Future<Uint8List>> _mediaFutures = {};

  /// 文字块的 GlobalKey：用来算光标位置，保证输入时视图跟着光标走
  final Map<String, GlobalKey> _fieldKeys = {};

  /// 后台上传任务：键是媒体键（sha256），块通过 mediaRef 找到自己的状态
  final Map<String, _MediaUploadTask> _uploadTasks = {};

  final ScrollController _scroll = ScrollController();

  late HlcClock _clock;
  Timer? _localSaveTimer;
  Timer? _idleSyncTimer;
  bool _loading = true;
  bool _persisting = false;
  bool _syncing = false;

  /// 本地有改动但还没推服务器
  bool _unsynced = false;

  /// 每次输入自增；落盘期间又输入了就不会把新内容当成已保存
  int _editRevision = 0;

  String? _loadError;
  String _status = '已保存';
  bool _changedSinceOpen = false;
  String? _conflictNotice;

  /// 发生过并发冲突的块，供查看看版本历史定位
  final Set<String> _conflictBlockIds = {};

  /// 当前获得焦点的文字块（格式按钮的作用对象）
  String? _focusedBlockId;

  /// 预览模式：把标记渲染成真正的排版
  bool _preview = false;

  /// 正在转码的媒体数量（需求 5.2 的"处理中"提示）
  int _processingMedia = 0;

  String get _deviceId => widget.session.deviceId ?? 'local-device';

  late final MediaService _media = MediaService(api: widget.api, store: widget.store, crypto: widget.sync.crypto);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock = _buildClock();
    _load();
  }

  /// 切到后台/退出窗口前把内容落本地并尽量同步一次（移动端很常见）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      unawaited(_flush());
    }
  }

  HlcClock _buildClock() {
    Hlc? last;
    final encoded = widget.session.lastHlc;
    if (encoded != null) {
      try {
        last = Hlc.decode(encoded);
      } catch (_) {
        last = null;
      }
    }
    return HlcClock(_deviceId, last: last);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _localSaveTimer?.cancel();
    _idleSyncTimer?.cancel();
    _scroll.dispose();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final loaded = await widget.sync.loadDiary(widget.date);
      if (!mounted) return;
      _blocks.clear();
      if (loaded == null || loaded.isEmpty) {
        _blocks.add(_newTextBlock());
      } else {
        _blocks.addAll(loaded.where((b) => !b.tombstone));
      }
      _syncControllers();
      setState(() {
        _loading = false;
        _status = '已保存';
      });
      // 后台查一下有没有媒体还在转码（不阻塞界面）
      unawaited(_refreshMediaStatus());
      // 上次没传完的媒体（比如传一半关掉了程序）也在这里认领回来
      unawaited(_verifyMediaPresence());
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '读取失败：$e';
        _loading = false;
      });
    }
  }

  void _syncControllers() {
    final alive = _blocks.map((b) => b.blockId).toSet();
    for (final id in _controllers.keys.toList()) {
      if (!alive.contains(id)) {
        _controllers.remove(id)?.dispose();
        _focusNodes.remove(id)?.dispose();
        _fieldKeys.remove(id);
      }
    }
    for (final block in _blocks) {
      if (block.blockType != BlockType.text) continue;
      final existing = _controllers[block.blockId];
      if (existing == null) {
        _controllers[block.blockId] = TextEditingController(text: block.text);
        final node = FocusNode();
        node.addListener(() {
          if (!mounted) return;
          if (node.hasFocus) {
            setState(() => _focusedBlockId = block.blockId);
            // 点进一个长段落时，光标可能在屏幕外，先把它带进来
            WidgetsBinding.instance.addPostFrameCallback((_) => _scrollCaretIntoView(block.blockId));
          } else if (_dirty.contains(block.blockId)) {
            // 离开段落时立刻落本地：不用等自动保存计时器
            unawaited(_persistLocal());
          }
        });
        _focusNodes[block.blockId] = node;
        _fieldKeys[block.blockId] ??= GlobalKey();
      } else if (existing.text != block.text) {
        existing.text = block.text;
      }
    }
  }

  Block _newTextBlock() => Block(
        blockId: _uuid.v4(),
        blockType: BlockType.text,
        orderKey: _orderKeyFor(_blocks.length),
        vv: <String, int>{},
        hlc: _clock.next().encode(),
        data: <String, dynamic>{'text': ''},
      );

  String _orderKeyFor(int index) => index.toString().padLeft(6, '0');

  void _onTextChanged(String blockId) {
    _dirty.add(blockId);
    _changedSinceOpen = true;
    _editRevision += 1;
    _scheduleLocalSave();
    // 输入时光标可能在可视区外（长日记最常见的问题）：下一帧把它带回来
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollCaretIntoView(blockId));
  }

  void _scheduleLocalSave() {
    _localSaveTimer?.cancel();
    _localSaveTimer = Timer(_localSaveDelay, () => unawaited(_persistLocal()));
  }

  /// 停止输入一段时间后兜底同步一次（不是每次按键都推）
  void _scheduleIdleSync() {
    _idleSyncTimer?.cancel();
    _idleSyncTimer = Timer(_idleSyncDelay, () => unawaited(_syncNow()));
  }

  /// 把改动写进本地缓存与待推送队列。这一步永远成功（除非磁盘坏了），
  /// 所以状态可以立刻显示"已保存到本机"。
  Future<void> _persistLocal({bool showStatus = true}) async {
    if (!widget.writable) return;
    if (_persisting) return;
    _persisting = true;
    final revisionAtStart = _editRevision;
    try {
      final ops = <Block>[];
      for (var i = 0; i < _blocks.length; i++) {
        final block = _blocks[i];
        if (!_dirty.contains(block.blockId)) continue;
        if (block.blockType == BlockType.text) {
          block.text = _controllers[block.blockId]?.text ?? block.text;
        }
        block.orderKey = _orderKeyFor(i);
        block.vv = incrementVv(block.vv, _deviceId);
        block.hlc = _clock.next().encode();
        ops.add(block);
      }

      if (ops.isEmpty) {
        if (mounted && showStatus) setState(() => _status = '已保存');
        return;
      }

      // 第一步：先写本地。断网、崩溃都不会丢内容（写入即持久）。
      await widget.store.cacheBlocks(widget.date, _blocks, tzId: widget.tzId);
      await widget.store.enqueue(widget.date, ops);
      await widget.onHlcChanged(_clock.last.encode());

      // 落盘期间用户可能又敲了字：那就别把它们当成已保存
      if (_editRevision == revisionAtStart) {
        _dirty.removeAll(ops.map((b) => b.blockId));
      }
      _unsynced = true;

      if (!mounted) return;
      if (showStatus) {
        final at = TimeOfDay.now();
        setState(() => _status = '已保存到本机 ${at.format(context)}');
      } else {
        setState(() {});
      }
      _scheduleIdleSync();
    } finally {
      _persisting = false;
    }
  }

  /// 真正推送服务器。只由退出、手动点同步、失焦/空闲兜底触发。
  Future<void> _syncNow({bool force = false}) async {
    if (!widget.writable) return;
    if (_syncing) return;
    if (!_unsynced && !force) return;

    _idleSyncTimer?.cancel();
    // 确保推上去的是最新内容
    if (_dirty.isNotEmpty) await _persistLocal(showStatus: false);
    if (!mounted) return;
    if (!_unsynced) return;

    _syncing = true;
    setState(() => _status = '同步中…');
    try {
      final outcome = await widget.sync.pushDate(widget.date, tzId: widget.tzId);
      if (!mounted) return;
      setState(() {
        if (outcome.online) {
          _unsynced = false;
          final at = TimeOfDay.now();
          _status = '已同步 ${at.format(context)}';
          for (final serverBlock in outcome.serverBlocks) {
            final index = _blocks.indexWhere((b) => b.blockId == serverBlock.blockId);
            if (index >= 0) {
              _blocks[index].vv = serverBlock.vv;
              _blocks[index].hlc = serverBlock.hlc;
            }
          }
          if (outcome.conflicts > 0) {
            _conflictBlockIds.addAll(outcome.conflictBlockIds);
            _conflictNotice = '部分内容在另一台设备上也改过，已合并保留两个版本。';
          }
        } else {
          _status = '已保存到本机，联网后自动同步';
        }
      });
    } finally {
      _syncing = false;
    }
  }

  /// 保存并尽量同步：退出页面、切后台、手动保存按钮都走这里
  Future<void> _flush() async {
    await _persistLocal(showStatus: false);
    await _syncNow();
  }

  void _addTextBlock() {
    final block = _newTextBlock();
    setState(() {
      _blocks.add(block);
      _dirty.add(block.blockId);
      _changedSinceOpen = true;
      _syncControllers();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNodes[block.blockId]?.requestFocus();
    });
    unawaited(_persistLocal());
  }

  // ------------------------------------------------------ 光标跟随（长日记）

  /// 找到 TextField 内部真正负责排版的 RenderEditable
  RenderEditable? _findRenderEditable(RenderObject? node) {
    if (node == null) return null;
    if (node is RenderEditable) return node;
    RenderEditable? found;
    node.visitChildren((child) {
      found ??= _findRenderEditable(child);
    });
    return found;
  }

  /// 把光标带回可视区。
  ///
  /// TextField 用 maxLines: null 时高度会一直长，外层 ListView 不会自动跟着长，
  /// 结果就是在长日记里越写越"停在上面"。这里直接量光标矩形，再按视口高度微调。
  void _scrollCaretIntoView(String blockId) {
    if (!mounted || !_scroll.hasClients) return;
    final fieldContext = _fieldKeys[blockId]?.currentContext;
    final controller = _controllers[blockId];
    if (fieldContext == null || controller == null) return;
    if (!controller.selection.isValid) return;

    final editable = _findRenderEditable(fieldContext.findRenderObject());
    if (editable == null) return;

    final caret = editable.getLocalRectForCaret(
      TextPosition(offset: controller.selection.extentOffset),
    );
    final viewport = _scroll.position.context.storageContext.findRenderObject() as RenderBox?;
    if (viewport == null) return;

    final top = editable.localToGlobal(caret.topLeft, ancestor: viewport).dy;
    final bottom = editable.localToGlobal(caret.bottomLeft, ancestor: viewport).dy;

    const margin = 96.0;
    final viewportHeight = _scroll.position.viewportDimension;
    double? target;
    if (bottom > viewportHeight - margin) {
      target = _scroll.position.pixels + (bottom - (viewportHeight - margin));
    } else if (top < margin) {
      target = _scroll.position.pixels - (margin - top);
    }
    if (target == null) return;

    final clamped = target.clamp(0.0, _scroll.position.maxScrollExtent);
    if ((clamped - _scroll.position.pixels).abs() < 1) return;
    _scroll.jumpTo(clamped);
  }

  // ------------------------------------------------------ 媒体后台上传

  /// 立刻把媒体块插进正文，上传交给后台；失败时块上显示感叹号，点一下重试
  void _startMediaUpload({
    required String mediaKey,
    required Uint8List bytes,
    required String mime,
    int? width,
    int? height,
    int? durationMs,
  }) {
    final task = _MediaUploadTask(
      mediaKey: mediaKey,
      bytes: bytes,
      mime: mime,
      width: width,
      height: height,
      durationMs: durationMs,
    );
    _uploadTasks[mediaKey] = task;
    if (mounted) setState(() {});
    unawaited(_runMediaUpload(mediaKey));
  }

  Future<void> _runMediaUpload(String mediaKey) async {
    final task = _uploadTasks[mediaKey];
    if (task == null) return;
    task.attempts += 1;
    if (mounted) {
      setState(() {
        task.state = _UploadState.uploading;
        task.error = null;
      });
    }
    try {
      await _media.upload(
        bytes: task.bytes,
        mime: task.mime,
        width: task.width,
        height: task.height,
        durationMs: task.durationMs,
      );
      if (!mounted) return;
      // 上传成功后才把块标脏：服务端拿到的块一定指向真实存在的媒体
      final index = _blocks.indexWhere((b) => b.mediaRef == mediaKey);
      final block = index >= 0 ? _blocks[index] : null;
      setState(() {
        _uploadTasks.remove(mediaKey);
        if (block != null) _dirty.add(block.blockId);
        _changedSinceOpen = true;
      });
      await _persistLocal();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        task.state = _UploadState.failed;
        task.error = e is ApiException ? e.message : describeError(e);
      });
      // 前两次自动重试，之后交给用户点
      if (task.attempts < 3) {
        Timer(Duration(seconds: 3 * task.attempts), () {
          if (!mounted) return;
          if (_uploadTasks[mediaKey]?.state == _UploadState.failed) {
            unawaited(_runMediaUpload(mediaKey));
          }
        });
      }
    }
  }

  void _retryMediaUpload(String mediaKey) {
    final task = _uploadTasks[mediaKey];
    if (task == null || task.state == _UploadState.uploading) return;
    unawaited(_runMediaUpload(mediaKey));
  }

  /// 打开日记时核对一遍：本地有明文、服务器却没有 = 上次没传完
  Future<void> _verifyMediaPresence() async {
    for (final block in List<Block>.of(_blocks)) {
      if (block.blockType == BlockType.text || block.blockType == BlockType.divider) continue;
      final key = block.mediaRef;
      if (key == null || _uploadTasks.containsKey(key)) continue;
      final local = await widget.store.readMedia(key);
      if (local == null) continue; // 本地没有明文：可能是别的设备传的，等正常下载
      try {
        if (await widget.api.mediaExists(key)) continue;
      } catch (_) {
        continue; // 网络不好时不要误报
      }
      if (!mounted) return;
      _uploadTasks[key] = _MediaUploadTask(
        mediaKey: key,
        bytes: local,
        mime: block.mime,
        width: block.width,
        height: block.height,
        durationMs: block.durationMs,
      )..state = _UploadState.failed;
    }
    if (mounted) setState(() {});
  }

  /// 媒体块上方那条"上传中/上传失败"的提示
  Widget _uploadBanner(Block block) {
    final key = block.mediaRef;
    if (key == null) return const SizedBox.shrink();
    final task = _uploadTasks[key];
    if (task == null) return const SizedBox.shrink();
    final theme = Theme.of(context);

    if (task.state == _UploadState.uploading) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text('正在后台上传…', style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _retryMediaUpload(key),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 16, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '上传失败${task.error == null ? '' : '：${task.error}'}，点击重试',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 是否支持调用摄像头（桌面端没有 image_picker 实现，走文件选择）
  bool get _cameraSupported => true;

  /// 移动端用系统相机（体验更好），桌面端用内置预览页
  bool get _systemCamera => Platform.isAndroid || Platform.isIOS;

  /// 拍照：调用系统相机，拍完走与"选择图片"完全相同的压缩与上传流程
  Future<void> _takePhoto() async {
    if (!_systemCamera) {
      final file = await CameraCapturePage.open(context, video: false);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      await _insertImageBytes(bytes, _captureName(file.path, '照片'), _extensionOf(file.path), '拍照');
      return;
    }
    try {
      final shot = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 100);
      if (shot == null) return;
      final bytes = await shot.readAsBytes();
      await _insertImageBytes(bytes, shot.name, _extensionOf(shot.name), '拍照');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '无法打开相机：${describeError(e)}');
    }
  }

  /// 录像：调用系统相机录制，录完走与"选择视频"相同的上传流程
  Future<void> _recordVideo() async {
    if (!_systemCamera) {
      final file = await CameraCapturePage.open(context, video: true);
      if (file == null) return;
      await _insertVideoFromPath(file.path, _captureName(file.path, '录像'));
      return;
    }
    try {
      final shot = await ImagePicker().pickVideo(source: ImageSource.camera);
      if (shot == null) return;
      await _insertVideoFromPath(shot.path, shot.name);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '无法打开相机：${describeError(e)}');
    }
  }

  /// 相机生成的文件名往往是一串 UUID，日记里显示不友好；
  /// 这里换成「照片-20261105-133501.jpg」这种可读名字
  String _captureName(String path, String prefix) {
    final ext = path.contains('.') ? path.split('.').last : 'jpg';
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '$prefix-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}.$ext';
  }

  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot + 1).toLowerCase() : 'jpg';
  }

  Future<void> _insertImage() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    await _insertImageBytes(bytes, file.name, file.extension ?? '', '图片');
  }

  Future<void> _insertImageBytes(Uint8List bytes, String name, String extension, String label) async {
    if (bytes.isEmpty) return;

    try {
      // 长边超过 2048 的图片先压缩再插入，原图另存一份供"查看原图"（需求 3.4）
      final prepared = ImageUtils.prepare(bytes);
      final displayBytes = prepared.display;
      final mime = prepared.resized ? 'image/jpeg' : _mimeForExtension(extension);
      final width = prepared.width > 0 ? prepared.width : null;
      final height = prepared.height > 0 ? prepared.height : null;

      // 先算键、先落本地：块立刻出现，上传在后台跑
      final mediaKey = MediaService.keyOf(displayBytes);
      await widget.store.cacheMedia(mediaKey, displayBytes);

      String? originalRef;
      if (prepared.resized) {
        originalRef = MediaService.keyOf(prepared.original);
        await widget.store.cacheMedia(originalRef, prepared.original);
      }

      final block = Block(
        blockId: _uuid.v4(),
        blockType: BlockType.image,
        orderKey: _orderKeyFor(_blocks.length),
        vv: <String, int>{},
        hlc: _clock.next().encode(),
        mediaRef: mediaKey,
        data: <String, dynamic>{
          'mime': mime,
          'width': width,
          'height': height,
          'name': name,
          'size': displayBytes.length,
          'originalRef': originalRef,
          'originalSize': prepared.resized ? bytes.length : null,
        },
      );
      _mediaCache[mediaKey] = displayBytes;
      if (originalRef != null) _mediaCache[originalRef] = prepared.original;
      setState(() {
        _blocks.add(block);
        _changedSinceOpen = true;
        _status = '$label已插入，正在后台上传';
      });

      _startMediaUpload(
        mediaKey: mediaKey,
        bytes: displayBytes,
        mime: mime,
        width: width,
        height: height,
      );
      // 原图也后台传；失败只影响"查看原图"，正文那张不受影响
      if (originalRef != null) {
        _startMediaUpload(
          mediaKey: originalRef,
          bytes: prepared.original,
          mime: _mimeForExtension(extension),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '图片处理失败：${describeError(e)}');
    }
  }

  Future<void> _insertAudio() async {
    final recorded = await AudioRecordDialog.show(context);
    if (recorded == null) return;
    setState(() => _status = '正在保存语音…');
    try {
      final bytes = await File(recorded.path).readAsBytes();
      final mediaKey = MediaService.keyOf(bytes);
      await widget.store.cacheMedia(mediaKey, bytes);

      final block = Block(
        blockId: _uuid.v4(),
        blockType: BlockType.audio,
        orderKey: _orderKeyFor(_blocks.length),
        vv: <String, int>{},
        hlc: _clock.next().encode(),
        mediaRef: mediaKey,
        data: <String, dynamic>{
          'mime': 'audio/mp4',
          'durationMs': recorded.duration.inMilliseconds,
          'waveform': recorded.waveform,
          'name': '语音',
          'size': bytes.length,
        },
      );
      setState(() {
        _blocks.add(block);
        _changedSinceOpen = true;
        _status = '语音已插入，正在后台上传';
      });
      _startMediaUpload(
        mediaKey: mediaKey,
        bytes: bytes,
        mime: 'audio/mp4',
        durationMs: recorded.duration.inMilliseconds,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '语音保存失败：${describeError(e)}');
    } finally {
      try {
        await File(recorded.path).delete();
      } catch (_) {
        // 临时文件清理失败不影响内容
      }
    }
  }

  Future<void> _insertVideo() async {
    final picked = await FilePicker.pickFile(type: FileType.video);
    if (picked == null || picked.path == null) return;
    await _insertVideoFromPath(picked.path!, picked.name);
  }

  Future<void> _insertVideoFromPath(String path, String name) async {
    setState(() => _status = '正在处理视频…');
    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      final mediaKey = MediaService.keyOf(bytes);
      await widget.store.cacheMedia(mediaKey, bytes);

      // 尺寸/时长在后台探测，界面不用等
      var width = 0;
      var height = 0;
      var durationMs = 0;
      try {
        final probe = VideoPlayerController.file(file);
        try {
          await probe.initialize();
          width = probe.value.size.width.round();
          height = probe.value.size.height.round();
          durationMs = probe.value.duration.inMilliseconds;
        } finally {
          await probe.dispose();
        }
      } catch (_) {
        // 探测失败不影响插入：播放器自己会处理
      }

      final block = Block(
        blockId: _uuid.v4(),
        blockType: BlockType.video,
        orderKey: _orderKeyFor(_blocks.length),
        vv: <String, int>{},
        hlc: _clock.next().encode(),
        mediaRef: mediaKey,
        data: <String, dynamic>{
          'mime': 'video/mp4',
          'width': width,
          'height': height,
          'durationMs': durationMs,
          'name': name,
          'size': bytes.length,
        },
      );
      setState(() {
        _blocks.add(block);
        _changedSinceOpen = true;
        _status = '视频已插入，正在后台上传';
      });
      _startMediaUpload(
        mediaKey: mediaKey,
        bytes: bytes,
        mime: 'video/mp4',
        width: width > 0 ? width : null,
        height: height > 0 ? height : null,
        durationMs: durationMs > 0 ? durationMs : null,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '视频处理失败：${describeError(e)}');
    }
  }

  Future<String> _fileFor(Block block) {
    final key = block.mediaRef!;
    final extension = block.mime == 'audio/mp4' ? 'm4a' : 'mp4';
    return _media.fileFor(key, extension: extension).then((f) => f.path);
  }

  String _mimeForExtension(String? extension) {
    switch ((extension ?? '').toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'heic':
        return 'image/heic';
      default:
        return 'image/jpeg';
    }
  }

  Future<void> _deleteBlock(Block block) async {
    if (block.blockType == BlockType.text && _controllers[block.blockId]?.text.isNotEmpty == true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除这一段？'),
          content: const Text('删除后可以在版本历史里找回。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() {
      _blocks.removeWhere((b) => b.blockId == block.blockId);
      _dirty.remove(block.blockId);
      _syncControllers();
      _changedSinceOpen = true;
    });

    // 已有服务端记录的块要用墓碑标记，不能直接消失（否则另一台设备会当成"没见过"）
    if (block.hlc.isNotEmpty && block.vv.isNotEmpty) {
      final tombstone = block.copy()
        ..tombstone = true
        ..vv = incrementVv(block.vv, _deviceId)
        ..hlc = _clock.next().encode();
      await widget.store.cacheBlocks(widget.date, _blocks, tzId: widget.tzId);
      await widget.store.enqueue(widget.date, [tombstone]);
      _unsynced = true;
      await _syncNow(force: true);
      if (!mounted) return;
      setState(() {
        _status = _unsynced ? '已删除（本地），联网后同步' : '已删除';
      });
    }
  }

  void _move(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _blocks.length) return;
    setState(() {
      final block = _blocks.removeAt(index);
      _blocks.insert(target, block);
      _dirty.addAll(_blocks.map((b) => b.blockId));
      _changedSinceOpen = true;
    });
    unawaited(_persistLocal());
  }


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // 退出即同步：用户不用记得点保存
        await _flush();
        if (mounted) Navigator.of(context).pop(_changedSinceOpen);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.date),
              if (widget.date == widget.today)
                Text('今天', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
          actions: [
            IconButton(
              icon: Icon(_preview ? Icons.edit_outlined : Icons.visibility_outlined),
              tooltip: _preview ? '回到编辑' : '预览排版',
              onPressed: () => setState(() => _preview = !_preview),
            ),
            // 手动同步：不想等"退出时同步"就点它
            IconButton(
              icon: Icon(_unsynced ? Icons.cloud_upload : Icons.cloud_done_outlined),
              tooltip: _unsynced ? '立即同步到服务器' : '已与服务器同步',
              onPressed: _syncing
                  ? null
                  : () => unawaited(_syncNow(force: true)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text(
                  _status,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            if (!widget.writable)
              MaterialBanner(
                content: const Text('这一天已超出 7 天补写窗口，只能阅读。'),
                leading: const Icon(Icons.lock_outline),
                actions: [TextButton(onPressed: () {}, child: const Text('知道了'))],
              ),
            if (_conflictNotice != null)
              MaterialBanner(
                content: Text(_conflictNotice!),
                leading: const Icon(Icons.merge_type),
                backgroundColor: theme.colorScheme.secondaryContainer,
                actions: [
                  TextButton(
                    onPressed: () {
                      final id = _conflictBlockIds.isEmpty ? null : _conflictBlockIds.first;
                      setState(() => _conflictNotice = null);
                      if (id != null) _showVersions(id);
                    },
                    child: const Text('查看改动'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _conflictNotice = null),
                    child: const Text('知道了'),
                  ),
                ],
              ),
            if (widget.writable) _toolbar(theme),
            Expanded(child: _body(theme)),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.2))),
      ),
      // 按钮较多，窄屏放不下：横向可滚动，保证每个入口都点得到
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
        children: [
          PopupMenuButton<String>(
            tooltip: '格式',
            onSelected: _applyFormat,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'bold', child: Text('加粗 **文字**')),
              PopupMenuItem(value: 'italic', child: Text('斜体 *文字*')),
              PopupMenuItem(value: 'underline', child: Text('下划线 __文字__')),
              PopupMenuItem(value: 'strike', child: Text('删除线 ~~文字~~')),
              PopupMenuItem(value: 'code', child: Text('行内代码 `文字`')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'h1', child: Text('# 大标题')),
              PopupMenuItem(value: 'h2', child: Text('## 小标题')),
              PopupMenuItem(value: 'bullet', child: Text('- 列表')),
              PopupMenuItem(value: 'quote', child: Text('> 引用')),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.text_format, size: 18),
                  SizedBox(width: 4),
                  Text('格式'),
                ],
              ),
            ),
          ),
          _toolButton(Icons.notes, '文字', _addTextBlock),
          if (_cameraSupported) _toolButton(Icons.photo_camera_outlined, '拍照', _takePhoto),
          if (_cameraSupported) _toolButton(Icons.videocam, '录像', _recordVideo),
          _toolButton(Icons.image_outlined, '图片', _insertImage),
          _toolButton(Icons.mic_none, '语音', _insertAudio),
          _toolButton(Icons.videocam_outlined, '视频', _insertVideo),
        ],
        ),
      ),
    );
  }

  Widget _toolButton(IconData icon, String label, VoidCallback? onPressed) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: onPressed == null ? Colors.grey : null,
      ),
    );
  }

  // ---------------------------------------------------------- 版本历史

  String _fmtTime(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return iso;
    final local = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  // ---------------------------------------------------------- 富文本格式

  /// 勾选/取消某个待办项：改文本、标脏、自动保存
  void _toggleTodo(String blockId, int lineIndex) {
    final controller = _controllers[blockId];
    if (controller == null) return;
    final updated = RichTextParser.toggleTodoAt(controller.text, lineIndex);
    if (updated == controller.text) return;
    final selection = controller.selection;
    controller.value = TextEditingValue(
      text: updated,
      selection: selection.isValid && selection.end <= updated.length
          ? selection
          : TextSelection.collapsed(offset: updated.length),
    );
    _onTextChanged(blockId);
  }

  void _applyFormat(String kind) {
    final id = _focusedBlockId ??
        _blocks.firstWhere((b) => b.blockType == BlockType.text, orElse: () => _blocks.first).blockId;
    final controller = _controllers[id];
    if (controller == null) {
      setState(() => _status = '请先点进一个文字块再套用格式');
      return;
    }
    final selection = controller.selection;
    final start = selection.isValid ? selection.start : controller.text.length;
    final end = selection.isValid ? selection.end : controller.text.length;

    final result = switch (kind) {
      'bold' => RichTextParser.wrapSelection(controller.text, start, end, '**'),
      'italic' => RichTextParser.wrapSelection(controller.text, start, end, '*'),
      'underline' => RichTextParser.wrapSelection(controller.text, start, end, '__'),
      'strike' => RichTextParser.wrapSelection(controller.text, start, end, '~~'),
      'code' => RichTextParser.wrapSelection(controller.text, start, end, '`'),
      'h1' => RichTextParser.prefixLine(controller.text, start, '# '),
      'h2' => RichTextParser.prefixLine(controller.text, start, '## '),
      'bullet' => RichTextParser.prefixLine(controller.text, start, '- '),
      'quote' => RichTextParser.prefixLine(controller.text, start, '> '),
      _ => controller.text,
    };

    controller.value = TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: result.length),
    );
    _onTextChanged(id);
  }

  Future<void> _showVersions(String blockId) async {
    List<BlockVersion> versions;
    try {
      versions = await widget.sync.loadVersions(blockId);
    } catch (e) {
      if (mounted) setState(() => _status = '版本历史读取失败');
      return;
    }
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('版本历史'),
        content: SizedBox(
          width: 520,
          child: versions.isEmpty
              ? const Text('这个块还没有历史版本。')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: versions.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final version = versions[index];
                    final preview = version.text.trim().isEmpty
                        ? '（媒体或空白版本）'
                        : version.text.trim();
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(preview, maxLines: 3, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_fmtTime(version.createdAt)),
                      trailing: TextButton(
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                          _restoreVersion(blockId, version);
                        },
                        child: const Text('恢复'),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _restoreVersion(String blockId, BlockVersion version) async {
    final index = _blocks.indexWhere((b) => b.blockId == blockId);
    if (index < 0) return;
    setState(() {
      _blocks[index].data = Map<String, dynamic>.from(version.data);
      _controllers[blockId]?.text = _blocks[index].text;
      _dirty.add(blockId);
      _changedSinceOpen = true;
      _status = '已恢复历史版本，正在保存';
    });
    await _persistLocal();
    _unsynced = true;
    await _syncNow(force: true);
  }

  /// 需要跨平台归一的格式：与服务器 media-jobs.ts 的列表保持一致
  static const Set<String> _needsNormalizeMime = {
    'video/quicktime',
    'video/x-msvideo',
    'video/x-matroska',
    'video/webm',
    'video/mpeg',
    'audio/wav',
    'audio/x-wav',
    'audio/wave',
    'audio/webm',
    'audio/ogg',
  };

  /// 查一下有没有还在转码的媒体，用于显示提示条
  Future<void> _refreshMediaStatus() async {
    final keys = <String>[];
    for (final block in _blocks) {
      final mime = block.data['mime'] as String?;
      final ref = block.mediaRef;
      if (mime != null && ref != null && _needsNormalizeMime.contains(mime)) {
        keys.add(ref);
      }
    }
    var processing = 0;
    for (final key in keys) {
      try {
        final status = await widget.api.mediaStatus(key);
        final value = status['status'] as String? ?? 'none';
        if (value == 'pending' || value == 'processing') processing += 1;
      } catch (_) {
        // 查询失败不打扰用户
      }
    }
    if (!mounted) return;
    if (processing != _processingMedia) {
      setState(() => _processingMedia = processing);
    }
  }

  Widget _mediaProcessingBanner(ThemeData theme) {
    if (_processingMedia <= 0) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '有 $_processingMedia 个媒体正在转码，完成前在部分设备上可能无法播放',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadError!),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (_processingMedia > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: _mediaProcessingBanner(theme),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 120),
            // 块内文字自己会增高，不让 ListView 猜高度，减少输入时的跳动
            itemCount: _blocks.length,
            itemBuilder: (context, index) {
              final block = _blocks[index];
              return _BlockCard(
                key: ValueKey(block.blockId),
                index: index,
                total: _blocks.length,
                readOnly: !widget.writable,
                onMoveUp: index == 0 ? null : () => _move(index, -1),
                onMoveDown: index == _blocks.length - 1 ? null : () => _move(index, 1),
                onDelete: () => _deleteBlock(block),
                child: _blockContent(block, theme),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _showOriginal(Block block, String originalRef) async {
    Uint8List bytes;
    try {
      bytes = await _mediaBytes(originalRef);
    } catch (e) {
      if (mounted) setState(() => _status = '原图加载失败');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InteractiveViewer(
                maxScale: 4,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '原图 · ${(bytes.length / 1024).toStringAsFixed(0)} KB',
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _blockContent(Block block, ThemeData theme) {
    switch (block.blockType) {
      case BlockType.text:
        final controller = _controllers[block.blockId];
        if (controller == null) return const SizedBox.shrink();
        if (_preview) {
          return RichTextView(
            text: controller.text,
            onToggleTodo: widget.writable
                ? (lineIndex) => _toggleTodo(block.blockId, lineIndex)
                : null,
          );
        }
        return TextField(
          key: _fieldKeys[block.blockId],
          controller: controller,
          contextMenuBuilder: (menuContext, editableTextState) {
            final items = editableTextState.contextMenuButtonItems;
            return AdaptiveTextSelectionToolbar.buttonItems(
              anchors: editableTextState.contextMenuAnchors,
              buttonItems: [
                ...items,
                ContextMenuButtonItem(
                  label: '粘贴并清理格式',
                  onPressed: () async {
                    final data = await Clipboard.getData('text/plain');
                    if (data?.text == null) return;
                    final selection = controller.selection;
                    final result = PasteUtils.insert(
                      controller.text,
                      selection.isValid ? selection.start : controller.text.length,
                      selection.isValid ? selection.end : controller.text.length,
                      data!.text!,
                    );
                    controller.value = TextEditingValue(
                      text: result.text,
                      selection: TextSelection.collapsed(offset: result.caret),
                    );
                    _onTextChanged(block.blockId);
                    editableTextState.hideToolbar();
                  },
                ),
              ],
            );
          },
          focusNode: _focusNodes[block.blockId],
          maxLines: null,
          readOnly: !widget.writable,
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.7, fontSize: 16),
          decoration: const InputDecoration(
            hintText: '写点什么…',
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
          onChanged: (_) => _onTextChanged(block.blockId),
        );
      case BlockType.image:
        return _withUploadStatus(block, _bounded(_mediaImage(block, theme)));
      case BlockType.audio:
        if (block.mediaRef == null) return const SizedBox.shrink();
        return _withUploadStatus(
          block,
          AudioBlockView(block: block, fileLoader: (_) => _fileFor(block)),
        );
      case BlockType.video:
        if (block.mediaRef == null) return const SizedBox.shrink();
        return _withUploadStatus(
          block,
          _bounded(VideoBlockView(block: block, fileLoader: (_) => _fileFor(block))),
        );
      case BlockType.divider:
        return const Divider(height: 32);
    }
  }

  /// 媒体块 + 上传状态条（上传中 / 失败可重试）
  Widget _withUploadStatus(Block block, Widget child) {
    final key = block.mediaRef;
    if (key == null || !_uploadTasks.containsKey(key)) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_uploadBanner(block), child],
    );
  }

  /// 媒体块不该占满整个窗口，限制最大高度并左对齐
  Widget _bounded(Widget child) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420, maxWidth: 720),
        child: child,
      ),
    );
  }

  Widget _mediaImage(Block block, ThemeData theme) {
    final key = block.mediaRef;
    if (key == null) return const SizedBox.shrink();
    // 同一个键只发一次请求：否则每次 setState（保存状态、上传进度）都会闪一下
    final future = _mediaFutures.putIfAbsent(key, () => _mediaBytes(key));
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            height: 180,
            child: Center(
              child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        }
        if (!snapshot.hasData) {
          return ListTile(
            leading: const Icon(Icons.broken_image_outlined),
            title: Text(block.fileName ?? '图片'),
            subtitle: const Text('图片暂时无法加载'),
          );
        }
        final width = block.width;
        final height = block.height;
        final aspect = (width != null && height != null && height > 0) ? width / height : null;
        final originalRef = block.data['originalRef'] as String?;
        return Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: aspect ?? 16 / 9,
                child: Image.memory(snapshot.data!, fit: BoxFit.cover),
              ),
            ),
            if (originalRef != null && originalRef.isNotEmpty)
              Positioned(
                right: 8,
                bottom: 8,
                child: FilledButton.tonalIcon(
                  onPressed: () => _showOriginal(block, originalRef),
                  icon: const Icon(Icons.zoom_out_map, size: 15),
                  label: const Text('查看原图'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<Uint8List> _mediaBytes(String key) async {
    final cached = _mediaCache[key];
    if (cached != null) return cached;
    // 必须走 MediaService：它会解密服务端返回的密文，并把明文缓存到本地。
    // 直接调 api.downloadMedia 拿到的是密文，重启后会显示成空白。
    final bytes = await _media.bytesFor(key);
    _mediaCache[key] = bytes;
    return bytes;
  }
}

class _BlockCard extends StatelessWidget {
  const _BlockCard({
    super.key,
    required this.index,
    required this.total,
    required this.child,
    required this.readOnly,
    this.onMoveUp,
    this.onMoveDown,
    required this.onDelete,
  });

  final int index;
  final int total;
  final Widget child;
  final bool readOnly;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onDelete;


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onHover: (_) {},
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: child),
            if (!readOnly)
              _BlockHandle(
                onMoveUp: onMoveUp,
                onMoveDown: onMoveDown,
                onDelete: onDelete,
                color: theme.colorScheme.outline,
              ),
          ],
        ),
      ),
    );
  }
}

class _BlockHandle extends StatelessWidget {
  const _BlockHandle({
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDelete,
    required this.color,
  });

  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onDelete;
  final Color color;


  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '块操作',
      icon: Icon(Icons.more_vert, size: 18, color: color),
      onSelected: (value) {
        switch (value) {
          case 'up':
            onMoveUp?.call();
          case 'down':
            onMoveDown?.call();
          case 'delete':
            onDelete();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'up', enabled: onMoveUp != null, child: const Text('上移')),
        PopupMenuItem(value: 'down', enabled: onMoveDown != null, child: const Text('下移')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'delete', child: Text('删除这一段')),
      ],
    );
  }
}

enum _UploadState { uploading, failed }

/// 一次后台上传任务。块插入后立刻存在，上传在它后面默默跑。
class _MediaUploadTask {
  _MediaUploadTask({
    required this.mediaKey,
    required this.bytes,
    required this.mime,
    this.width,
    this.height,
    this.durationMs,
  });

  final String mediaKey;
  final Uint8List bytes;
  final String mime;
  final int? width;
  final int? height;
  final int? durationMs;

  _UploadState state = _UploadState.uploading;
  String? error;
  int attempts = 0;
}
