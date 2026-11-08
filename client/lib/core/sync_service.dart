/// 同步服务：本地优先写入 + 后台推送 + 回落后再拉取。
///
/// 端到端加密的边界就在这一层：
///   * 推送前把块内容加密（本地缓存仍是明文，便于离线与导出）
///   * 拉取后把密文解密成明文再交给界面
///   * 服务端与节点自始至终只见密文
library;

import 'dart:convert';
import 'dart:typed_data';

import 'api_client.dart';
import 'crypto_service.dart';
import 'local_store.dart';
import 'models.dart';

class SyncOutcome {
  SyncOutcome({
    required this.pushedBlocks,
    required this.serverBlocks,
    required this.conflicts,
    required this.online,
    this.error,
    this.conflictBlockIds = const [],
  });

  final int pushedBlocks;
  final List<Block> serverBlocks;
  final int conflicts;
  final bool online;
  final String? error;

  /// 发生并发冲突的块，界面据此提供"查看版本历史"
  final List<String> conflictBlockIds;
}

class SyncService {
  SyncService({required this.api, required this.store, this.crypto});

  final ApiClient api;
  final DiaryStore store;

  /// 为空表示未启用加密（例如老账号还没设置盐）
  final CryptoService? crypto;

  bool get encryptionEnabled => crypto != null;

  /// 读取某天：优先网络，失败回落本地缓存
  Future<List<Block>?> loadDiary(String date) async {
    try {
      final detail = await api.getDiary(date);
      if (detail != null) {
        final plain = await _decryptBlocks(detail.blocks);
        await store.applyServerBlocks(date, plain);
        return plain;
      }
      return await store.readBlocks(date);
    } catch (_) {
      return await store.readBlocks(date);
    }
  }

  /// 把某一天的待推送内容推上去（含删除墓碑）
  Future<SyncOutcome> pushDate(String date, {required String tzId}) async {
    final pending = await store.pending();
    final ops = pending[date] ?? const <Block>[];
    if (ops.isEmpty) {
      return SyncOutcome(pushedBlocks: 0, serverBlocks: const [], conflicts: 0, online: true);
    }

    final alive = ops.where((b) => !b.tombstone).toList();
    final dead = ops.where((b) => b.tombstone).toList();

    try {
      WriteResult? result;
      if (alive.isNotEmpty) {
        final wire = await _encryptBlocks(alive);
        result = await api.writeBatch(date: date, tzId: tzId, operations: wire);
      }
      for (final tombstone in dead) {
        await api.deleteBlock(
          date: date,
          blockId: tombstone.blockId,
          vv: tombstone.vv,
          hlc: tombstone.hlc,
        );
      }
      await store.removeFromOutbox(date, ops.map((b) => b.blockId));

      var serverBlocks = result?.blocks ?? const <Block>[];
      if (serverBlocks.isEmpty) {
        final detail = await api.getDiary(date);
        serverBlocks = detail?.blocks ?? const <Block>[];
      }
      final plain = await _decryptBlocks(serverBlocks);
      await store.applyServerBlocks(date, plain);
      return SyncOutcome(
        pushedBlocks: ops.length,
        serverBlocks: plain,
        conflicts: result?.conflicts.length ?? 0,
        conflictBlockIds: result?.conflicts.map((c) => c.blockId).toList() ?? const [],
        online: true,
      );
    } catch (e) {
      return SyncOutcome(
        pushedBlocks: 0,
        serverBlocks: const [],
        conflicts: 0,
        online: false,
        error: e.toString(),
      );
    }
  }

  /// 推送所有日期的待同步内容
  Future<SyncOutcome> pushAll({required String tzId}) async {
    final pending = await store.pending();
    var pushed = 0;
    var conflicts = 0;
    var lastBlocks = const <Block>[];
    for (final date in pending.keys.toList()) {
      final outcome = await pushDate(date, tzId: tzId);
      if (!outcome.online) return outcome;
      pushed += outcome.pushedBlocks;
      conflicts += outcome.conflicts;
      if (outcome.serverBlocks.isNotEmpty) lastBlocks = outcome.serverBlocks;
    }
    return SyncOutcome(
      pushedBlocks: pushed,
      serverBlocks: lastBlocks,
      conflicts: conflicts,
      online: true,
    );
  }

  /// 拉取某个块的历史版本并解密（供"版本历史"面板使用）
  Future<List<BlockVersion>> loadVersions(String blockId) async {
    final raw = await api.blockVersions(blockId);
    final out = <BlockVersion>[];
    for (final item in raw) {
      final payloadB64 = item['payload'] as String? ?? '';
      final enc = item['enc'] as String? ?? 'none';
      final nonce = item['nonce'] as String?;
      Map<String, dynamic> data = const {};
      if (enc != 'none' && crypto != null && nonce != null) {
        try {
          final plain = await crypto!.open(
            cipher: base64Decode(payloadB64),
            nonce: base64Decode(nonce),
            aad: blockAad(blockId: blockId, hlc: item['hlc'] as String? ?? ''),
          );
          final decoded = jsonDecode(utf8.decode(plain));
          if (decoded is Map<String, dynamic>) data = decoded;
        } catch (_) {
          data = const {};
        }
      } else {
        try {
          final decoded = jsonDecode(utf8.decode(base64Decode(payloadB64)));
          if (decoded is Map<String, dynamic>) data = decoded;
        } catch (_) {
          data = const {};
        }
      }
      out.add(BlockVersion(
        versionId: item['versionId'] as String? ?? '',
        hlc: item['hlc'] as String? ?? '',
        createdAt: item['createdAt'] as String? ?? '',
        data: data,
        enc: enc,
      ));
    }
    return out;
  }

  // ------------------------------------------------------------ 加密与解密

  Future<List<Block>> _encryptBlocks(List<Block> blocks) async {
    final key = crypto;
    if (key == null) return blocks;
    final out = <Block>[];
    for (final block in blocks) {
      final plain = Uint8List.fromList(utf8.encode(jsonEncode(block.data)));
      final sealed = await key.seal(plain, aad: blockAad(blockId: block.blockId, hlc: block.hlc));
      out.add(block.copy()
        ..enc = 'aes-256-gcm'
        ..nonce = sealed.nonceBase64
        ..rawPayload = sealed.cipherBase64);
    }
    return out;
  }

  Future<List<Block>> _decryptBlocks(List<Block> blocks) async {
    final key = crypto;
    if (key == null) return blocks;
    final out = <Block>[];
    for (final block in blocks) {
      if (!block.isEncrypted || block.nonce == null || block.rawPayload == null) {
        out.add(block);
        continue;
      }
      try {
        final plain = await key.open(
          cipher: base64Decode(block.rawPayload!),
          nonce: base64Decode(block.nonce!),
          aad: blockAad(blockId: block.blockId, hlc: block.hlc),
        );
        final data = jsonDecode(utf8.decode(plain));
        out.add(block.copy()
          ..data = data is Map<String, dynamic> ? data : <String, dynamic>{}
          ..enc = 'none'
          ..nonce = null
          ..rawPayload = base64Encode(utf8.encode(jsonEncode(data))));
      } catch (_) {
        // 解密失败（例如换了设备但没同步密钥）：保留原样，界面会显示为不可读
        out.add(block);
      }
    }
    return out;
  }
}
