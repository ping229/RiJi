/// 媒体服务：哈希去重、上传、把密文缓存落到本地文件供播放器使用。
///
/// 启用端到端加密时：
///   * 上传前用媒体子密钥加密，服务端只存密文
///   * 下载后解密再交给播放器
///   * 本地缓存仍保存解密后的明文，便于离线播放与导出
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'api_client.dart';
import 'crypto_service.dart';
import 'local_store.dart';
import 'models.dart';

class MediaService {
  MediaService({required this.api, required this.store, this.crypto});

  final ApiClient api;
  final DiaryStore store;

  /// 为空表示不加密
  final CryptoService? crypto;

  final Map<String, File> _materialized = {};

  /// 计算内容哈希并上传；已存在则跳过重复上传（同一用户内去重）
  Future<MediaUploadResult> upload({
    required Uint8List bytes,
    required String mime,
    int? width,
    int? height,
    int? durationMs,
  }) async {
    final key = sha256.convert(bytes).toString();
    // 本地缓存明文，供离线播放与导出使用
    await store.cacheMedia(key, bytes);

    try {
      if (await api.mediaExists(key)) {
        return MediaUploadResult(mediaKey: key, bytes: bytes.length, deduped: true);
      }
    } catch (_) {
      // 检查失败不影响上传
    }

    final key2 = crypto;
    if (key2 == null) {
      return api.uploadMedia(
        bytes: bytes,
        mediaKey: key,
        mime: mime,
        width: width,
        height: height,
        durationMs: durationMs,
      );
    }

    final sealed = await key2.seal(bytes, aad: mediaAad(mediaKey: key));
    return api.uploadMedia(
      bytes: sealed.cipher,
      mediaKey: key,
      mime: mime,
      width: width,
      height: height,
      durationMs: durationMs,
      enc: 'aes-256-gcm',
      nonce: sealed.nonceBase64,
    );
  }

  /// 取媒体字节：优先本地缓存，其次服务器（服务器返回的是密文）
  Future<Uint8List> bytesFor(String key) async {
    final cached = await store.readMedia(key);
    if (cached != null) return cached;

    final blob = await api.downloadMediaBlob(key);
    if (blob.bytes.isEmpty) {
      // 空文件通常意味着上传没完成，不能当正常内容缓存，否则播放器会一直黑屏
      throw StateError('媒体内容为空，可能上传未完成');
    }
    final plain = await _decryptBlob(key, blob);
    await store.cacheMedia(key, plain);
    return plain;
  }

  Future<Uint8List> _decryptBlob(String key, MediaBlob blob) async {
    final cryptoKey = crypto;
    if (!blob.isEncrypted || cryptoKey == null || blob.nonce == null) {
      return blob.bytes;
    }
    return cryptoKey.open(
      cipher: blob.bytes,
      nonce: base64Decode(blob.nonce!),
      aad: mediaAad(mediaKey: key),
    );
  }

  /// 播放器需要文件路径：把字节写到应用自己的数据目录，同一媒体只写一次
  Future<File> fileFor(String key, {String extension = 'mp4'}) async {
    final existing = _materialized[key];
    if (existing != null && await existing.exists()) return existing;
    final bytes = await bytesFor(key);
    final path = await store.writePlaybackFile('$key.$extension', bytes);
    final file = File(path);
    _materialized[key] = file;
    return file;
  }
}
