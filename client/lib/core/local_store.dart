/// 本地存储：日记缓存、待推送队列、媒体缓存。
///
/// 产品第一原则是"写入即持久"——保存必须先落本地，网络同步是后台行为。
/// 所以编辑器永远先写这里，再尝试推服务器。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';
import 'vv.dart';

/// 日记存储接口。
/// 生产环境用文件实现（[LocalStore]），测试用内存实现（[MemoryStore]），
/// 这样 UI 逻辑可以在不碰磁盘的情况下被完整验证。
abstract class DiaryStore {
  Future<void> cacheBlocks(String date, List<Block> blocks, {String? tzId});
  Future<List<Block>?> readBlocks(String date);
  Future<List<DiarySummary>> cachedSummaries();
  Future<void> enqueue(String date, List<Block> ops);
  Future<void> removeFromOutbox(String date, Iterable<String> blockIds);
  Future<Map<String, List<Block>>> pending();
  Future<int> pendingCount();
  Future<void> cacheMedia(String key, Uint8List bytes);
  Future<Uint8List?> readMedia(String key);
  Future<void> applyServerBlocks(String date, List<Block> blocks);

  /// 把媒体落到一个可播放的本地文件，返回路径。
  /// 不能用系统临时目录 —— 受限环境下那里可能不可写。
  Future<String> writePlaybackFile(String fileName, Uint8List bytes);
}

/// 纯内存实现：给自动化测试和"不落盘"的临时会话使用。
class MemoryStore implements DiaryStore {
  final Map<String, List<Block>> _blocks = {};
  final Map<String, Map<String, Block>> _outbox = {};
  final Map<String, Uint8List> _media = {};

  @override
  Future<void> cacheBlocks(String date, List<Block> blocks, {String? tzId}) async {
    _blocks[date] = blocks.where((b) => !b.tombstone).map((b) => b.copy()).toList();
  }

  @override
  Future<List<Block>?> readBlocks(String date) async {
    final list = _blocks[date];
    if (list == null || list.isEmpty) return null;
    return list.map((b) => b.copy()).toList();
  }

  @override
  Future<List<DiarySummary>> cachedSummaries() async {
    final out = _blocks.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => DiarySummary(
              diaryId: e.key,
              diaryDate: e.key,
              blockCount: e.value.length,
              updatedAt: '',
            ))
        .toList();
    out.sort((a, b) => b.diaryDate.compareTo(a.diaryDate));
    return out;
  }

  @override
  Future<void> enqueue(String date, List<Block> ops) async {
    final slot = _outbox.putIfAbsent(date, () => {});
    for (final op in ops) {
      slot[op.blockId] = op.copy();
    }
  }

  @override
  Future<void> removeFromOutbox(String date, Iterable<String> blockIds) async {
    final slot = _outbox[date];
    if (slot == null) return;
    for (final id in blockIds) {
      slot.remove(id);
    }
    if (slot.isEmpty) _outbox.remove(date);
  }

  @override
  Future<Map<String, List<Block>>> pending() async {
    return _outbox.map((date, map) => MapEntry(date, map.values.map((b) => b.copy()).toList()));
  }

  @override
  Future<int> pendingCount() async {
    return _outbox.values.fold<int>(0, (sum, map) => sum + map.length);
  }

  @override
  Future<void> cacheMedia(String key, Uint8List bytes) async => _media[key] = bytes;

  @override
  Future<Uint8List?> readMedia(String key) async => _media[key];

  @override
  Future<void> applyServerBlocks(String date, List<Block> blocks) async {
    _blocks[date] = blocks.where((b) => !b.tombstone).map((b) => b.copy()).toList();
  }

  @override
  Future<String> writePlaybackFile(String fileName, Uint8List bytes) async {
    final dir = await Directory.systemTemp.createTemp('riji_playback_');
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}

class LocalStore implements DiaryStore {
  LocalStore._(this.root);

  /// 数据根目录（<应用数据目录>/diary）
  final Directory root;

  /// 打开本地库。**每个账号一个独立目录**，否则换账号登录会看到上一个账号的日记。
  ///
  /// 升级前的老缓存放在 `diary/` 下且没有归属标记：
  /// 第一次用某个账号登录时把它判给这个账号（写 owner.txt），
  /// 之后的账号各自使用 `diary_<账号>/`，不会再互相看到。
  static Future<LocalStore> open(Directory baseDir, {String? account}) async {
    final legacy = Directory(_join(baseDir.path, 'diary'));
    Directory dir;

    if (account == null || account.trim().isEmpty) {
      dir = legacy;
    } else {
      final safe = account.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.@\-\u4e00-\u9fa5]'), '_');
      final ownerFile = File(_join(legacy.path, 'owner.txt'));

      if (await ownerFile.exists()) {
        final owner = (await ownerFile.readAsString()).trim();
        dir = owner == account.trim() ? legacy : Directory(_join(baseDir.path, 'diary_$safe'));
      } else if (await _hasLocalData(legacy)) {
        // 老版本留下的缓存：归第一个登录的账号所有
        await ownerFile.writeAsString(account.trim(), flush: true);
        dir = legacy;
      } else {
        dir = Directory(_join(baseDir.path, 'diary_$safe'));
        await dir.create(recursive: true);
        await File(_join(dir.path, 'owner.txt')).writeAsString(account.trim(), flush: true);
      }
    }

    await Directory(_join(dir.path, 'diaries')).create(recursive: true);
    await Directory(_join(dir.path, 'media')).create(recursive: true);
    return LocalStore._(dir);
  }

  static Future<bool> _hasLocalData(Directory dir) async {
    final diaries = Directory(_join(dir.path, 'diaries'));
    if (!await diaries.exists()) return false;
    return (await diaries.list().toList()).isNotEmpty;
  }

  static String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

  File _diaryFile(String date) => File(_join(_join(root.path, 'diaries'), '$date.json'));
  File get _outboxFile => File(_join(root.path, 'outbox.json'));
  File _mediaFile(String key) => File(_join(_join(root.path, 'media'), '$key.bin'));

  // ---------------------------------------------------------------- 日记缓存

  Future<void> cacheBlocks(String date, List<Block> blocks, {String? tzId}) async {
    final payload = {
      'diaryDate': date,
      'tzId': tzId,
      'cachedAt': DateTime.now().toUtc().toIso8601String(),
      'blocks': blocks.map((b) => {...b.toWire(), 'tombstone': b.tombstone}).toList(),
    };
    final file = _diaryFile(date);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(payload), flush: true);
    await tmp.rename(file.path);
  }

  Future<List<Block>?> readBlocks(String date) async {
    final file = _diaryFile(date);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final raw = decoded['blocks'] as List<dynamic>? ?? const [];
      final blocks = raw
          .map((e) => Block.fromJson(e as Map<String, dynamic>))
          .where((b) => !b.tombstone)
          .toList();
      return blocks.isEmpty ? null : blocks;
    } catch (_) {
      return null;
    }
  }

  /// 扫描本地缓存，生成日记摘要列表（由新到旧）
  Future<List<DiarySummary>> cachedSummaries() async {
    final dir = Directory(_join(root.path, 'diaries'));
    if (!await dir.exists()) return const [];
    final out = <DiarySummary>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final date = decoded['diaryDate'] as String?;
        final blocks = (decoded['blocks'] as List<dynamic>? ?? const []);
        if (date == null || blocks.isEmpty) continue;
        out.add(DiarySummary(
          diaryId: date,
          diaryDate: date,
          blockCount: blocks.length,
          updatedAt: decoded['cachedAt'] as String? ?? '',
        ));
      } catch (_) {
        // 单个文件损坏不影响整体
      }
    }
    out.sort((a, b) => b.diaryDate.compareTo(a.diaryDate));
    return out;
  }

  // ------------------------------------------------------------ 待推送队列

  Future<Map<String, List<Block>>> _readOutbox() async {
    if (!await _outboxFile.exists()) return {};
    try {
      final decoded = jsonDecode(await _outboxFile.readAsString()) as Map<String, dynamic>;
      return decoded.map((date, value) => MapEntry(
            date,
            (value as List<dynamic>).map((e) => Block.fromJson(e as Map<String, dynamic>)).toList(),
          ));
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeOutbox(Map<String, List<Block>> outbox) async {
    final cleaned = <String, dynamic>{};
    outbox.forEach((date, blocks) {
      if (blocks.isNotEmpty) {
        cleaned[date] = blocks.map((b) => {...b.toWire(), 'tombstone': b.tombstone}).toList();
      }
    });
    final tmp = File('${_outboxFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(cleaned), flush: true);
    await tmp.rename(_outboxFile.path);
  }

  /// 入队：同一块以最后一次为准
  Future<void> enqueue(String date, List<Block> ops) async {
    final outbox = await _readOutbox();
    final existing = {for (final b in outbox[date] ?? const <Block>[]) b.blockId: b};
    for (final op in ops) {
      existing[op.blockId] = op;
    }
    outbox[date] = existing.values.toList();
    await _writeOutbox(outbox);
  }

  Future<void> removeFromOutbox(String date, Iterable<String> blockIds) async {
    final outbox = await _readOutbox();
    final remaining = (outbox[date] ?? const <Block>[])
        .where((b) => !blockIds.contains(b.blockId))
        .toList();
    outbox[date] = remaining;
    await _writeOutbox(outbox);
  }

  /// 取出全部待推送内容（按日期）
  Future<Map<String, List<Block>>> pending() async {
    final outbox = await _readOutbox();
    return outbox;
  }

  Future<int> pendingCount() async {
    final outbox = await _readOutbox();
    return outbox.values.fold<int>(0, (sum, list) => sum + list.length);
  }

  // -------------------------------------------------------------- 媒体缓存

  Future<void> cacheMedia(String key, Uint8List bytes) async {
    final file = _mediaFile(key);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  Future<Uint8List?> readMedia(String key) async {
    final file = _mediaFile(key);
    if (!await file.exists()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 把引擎返回的块写回缓存（用于服务端合并后的规范版本）
  Future<void> applyServerBlocks(String date, List<Block> blocks) async {
    final merged = <String, Block>{};
    for (final b in blocks) {
      if (!b.tombstone) merged[b.blockId] = b;
    }
    await cacheBlocks(date, merged.values.toList());
  }

  @override
  Future<String> writePlaybackFile(String fileName, Uint8List bytes) async {
    final dir = Directory(_join(root.path, 'playback'));
    await dir.create(recursive: true);
    final file = File(_join(dir.path, fileName));
    if (!await file.exists()) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return file.path;
  }

  /// 本地块列表 → 版本向量合并结果，供调试与测试
  static VersionVector mergeAll(Iterable<Block> blocks) {
    var vv = <String, int>{};
    for (final b in blocks) {
      vv = mergeVv(vv, b.vv);
    }
    return vv;
  }
}
