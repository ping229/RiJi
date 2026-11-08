/// 与服务端接口对齐的数据模型。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'vv.dart';

enum BlockType {
  text,
  image,
  audio,
  video,
  divider;

  static BlockType parse(String raw) =>
      BlockType.values.firstWhere((t) => t.name == raw, orElse: () => BlockType.text);
}

/// 一个块 = 正文里的一段内容。类型 + 载荷 + 版本元数据。
class Block {
  Block({
    required this.blockId,
    required this.blockType,
    required this.orderKey,
    required this.vv,
    required this.hlc,
    required this.data,
    this.mediaRef,
    this.tombstone = false,
    this.updatedAt,
    this.enc = 'none',
    this.nonce,
    this.rawPayload,
  });

  final String blockId;
  BlockType blockType;
  String orderKey;
  VersionVector vv;
  String hlc;
  Map<String, dynamic> data;
  String? mediaRef;
  bool tombstone;
  String? updatedAt;

  /// 'none' 或 'aes-256-gcm'。服务端只认这个标记，不关心内容。
  String enc;

  /// 加密时使用的 nonce（base64）
  String? nonce;

  /// 加密块的原始密文（base64）。明文块为 null，由 data 现算。
  String? rawPayload;

  bool get isEncrypted => enc != 'none';

  /// 文本块正文
  String get text => (data['text'] as String?) ?? '';

  set text(String value) => data['text'] = value;

  String get mime => (data['mime'] as String?) ?? 'application/octet-stream';
  int? get width => data['width'] as int?;
  int? get height => data['height'] as int?;
  int? get durationMs => data['durationMs'] as int?;
  String? get fileName => data['name'] as String?;

  static Block fromJson(Map<String, dynamic> json) {
    final rawPayload = base64Decode(json['payload'] as String? ?? '');
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(utf8.decode(rawPayload));
      data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      data = <String, dynamic>{};
    }
    return Block(
      blockId: json['blockId'] as String,
      blockType: BlockType.parse(json['blockType'] as String? ?? 'text'),
      orderKey: json['orderKey'] as String? ?? 'a0',
      vv: normalizeVv((json['vv'] as Map?)?.cast<String, dynamic>()),
      hlc: json['hlc'] as String? ?? '',
      data: data,
      mediaRef: json['mediaRef'] as String?,
      tombstone: json['tombstone'] as bool? ?? false,
      updatedAt: json['updatedAt'] as String?,
      enc: json['enc'] as String? ?? 'none',
      nonce: json['nonce'] as String?,
      rawPayload: json['payload'] as String?,
    );
  }

  Map<String, dynamic> toWire() => {
        'blockId': blockId,
        'blockType': blockType.name,
        'orderKey': orderKey,
        'vv': vv,
        'hlc': hlc,
        // 只有加密块才复用原始密文；明文块必须按当前 data 重新序列化，
        // 否则编辑后会把旧内容发出去。
        'payload': (isEncrypted && rawPayload != null)
            ? rawPayload!
            : base64Encode(utf8.encode(jsonEncode(data))),
        'mediaRef': mediaRef,
        'enc': enc,
        if (nonce != null) 'nonce': nonce,
      };

  Block copy() => Block(
        blockId: blockId,
        blockType: blockType,
        orderKey: orderKey,
        vv: Map<String, int>.from(vv),
        hlc: hlc,
        data: Map<String, dynamic>.from(data),
        mediaRef: mediaRef,
        tombstone: tombstone,
        updatedAt: updatedAt,
        enc: enc,
        nonce: nonce,
        rawPayload: rawPayload,
      );
}

/// 块的历史版本（冲突中被覆盖的那一版，或直接因果覆盖的旧版）
class BlockVersion {
  BlockVersion({
    required this.versionId,
    required this.hlc,
    required this.createdAt,
    required this.data,
    this.enc = 'none',
  });

  final String versionId;
  final String hlc;
  final String createdAt;
  final Map<String, dynamic> data;
  final String enc;

  String get text => (data['text'] as String?) ?? '';
  String get mime => (data['mime'] as String?) ?? '';
  int? get durationMs => data['durationMs'] as int?;
  String? get fileName => data['name'] as String?;
}

class DiarySummary {
  DiarySummary({
    required this.diaryId,
    required this.diaryDate,
    required this.blockCount,
    required this.updatedAt,
    this.timeSuspect = false,
  });

  final String diaryId;
  final String diaryDate;
  final int blockCount;
  final String updatedAt;
  final bool timeSuspect;

  static DiarySummary fromJson(Map<String, dynamic> json) => DiarySummary(
        diaryId: json['diaryId'] as String,
        diaryDate: json['diaryDate'] as String,
        blockCount: (json['blockCount'] as num?)?.toInt() ?? 0,
        updatedAt: json['updatedAt'] as String? ?? '',
        timeSuspect: json['timeSuspect'] as bool? ?? false,
      );
}

class DiaryDetail {
  DiaryDetail({required this.diary, required this.blocks});

  final DiarySummary diary;
  final List<Block> blocks;
}

class ConflictNotice {
  ConflictNotice({required this.blockId, required this.winnerHlc, required this.loserHlc, required this.archivedVersionId});

  final String blockId;
  final String winnerHlc;
  final String loserHlc;
  final String archivedVersionId;

  static ConflictNotice fromJson(Map<String, dynamic> json) => ConflictNotice(
        blockId: json['blockId'] as String,
        winnerHlc: json['winnerHlc'] as String? ?? '',
        loserHlc: json['loserHlc'] as String? ?? '',
        archivedVersionId: json['archivedVersionId'] as String? ?? '',
      );
}

class WriteResult {
  WriteResult({
    required this.blocks,
    required this.conflicts,
    required this.today,
    required this.serverNow,
    required this.timeSuspect,
  });

  final List<Block> blocks;
  final List<ConflictNotice> conflicts;
  final String today;
  final String serverNow;
  final bool timeSuspect;

  static WriteResult fromJson(Map<String, dynamic> json) => WriteResult(
        blocks: (json['blocks'] as List<dynamic>? ?? const [])
            .map((e) => Block.fromJson(e as Map<String, dynamic>))
            .toList(),
        conflicts: (json['conflicts'] as List<dynamic>? ?? const [])
            .map((e) => ConflictNotice.fromJson(e as Map<String, dynamic>))
            .toList(),
        today: json['today'] as String? ?? '',
        serverNow: json['serverNow'] as String? ?? '',
        timeSuspect: json['timeSuspect'] as bool? ?? false,
      );
}

class CalendarWindow {
  CalendarWindow({
    required this.tzId,
    required this.dayCutHour,
    required this.today,
    required this.writableDates,
    required this.serverNow,
  });

  final String tzId;
  final int dayCutHour;
  final String today;
  final List<String> writableDates;
  final String serverNow;

  static CalendarWindow fromJson(Map<String, dynamic> json) => CalendarWindow(
        tzId: json['tzId'] as String? ?? 'Asia/Shanghai',
        dayCutHour: (json['dayCutHour'] as num?)?.toInt() ?? 4,
        today: json['today'] as String? ?? '',
        writableDates: (json['writableDates'] as List<dynamic>? ?? const [])
            .map((e) => e as String)
            .toList(),
        serverNow: json['serverNow'] as String? ?? '',
      );
}

class LoginResult {
  LoginResult({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.username,
    required this.role,
    required this.tzId,
    this.deviceId,
    this.kdfSalt,
    this.kdfIterations = 210000,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
  final String username;
  final String role;
  final String tzId;
  final String? deviceId;
  final String? kdfSalt;
  final int kdfIterations;

  static LoginResult fromJson(Map<String, dynamic> json) {
    final user = (json['user'] as Map<String, dynamic>?) ?? const {};
    return LoginResult(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String,
      userId: user['id'] as String? ?? '',
      username: user['username'] as String? ?? '',
      role: user['role'] as String? ?? 'user',
      tzId: user['tzId'] as String? ?? 'Asia/Shanghai',
      deviceId: json['deviceId'] as String?,
      kdfSalt: user['kdfSalt'] as String?,
      kdfIterations: (user['kdfIterations'] as num?)?.toInt() ?? 210000,
    );
  }
}

class MediaUploadResult {
  MediaUploadResult({required this.mediaKey, required this.bytes, required this.deduped});

  final String mediaKey;
  final int bytes;
  final bool deduped;

  static MediaUploadResult fromJson(Map<String, dynamic> json) => MediaUploadResult(
        mediaKey: json['mediaKey'] as String,
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        deduped: json['deduped'] as bool? ?? false,
      );
}

class MediaBlob {
  MediaBlob({required this.bytes, required this.mime, required this.enc, this.nonce});

  final Uint8List bytes;
  final String mime;
  final String enc;
  final String? nonce;

  bool get isEncrypted => enc != 'none';
}
