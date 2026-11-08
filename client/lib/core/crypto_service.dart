/// 端到端加密的核心（需求 6.1）。
///
/// 设计要点：
///   * 主密钥由「密码 + 服务端存的随机盐」经 PBKDF2-HMAC-SHA256 派生，**永不上传**
///   * 块内容用 AES-256-GCM 加密；AAD 绑定 blockId / deviceId / hlc，防止密文被挪到别的块
///   * 服务端只看到密文，管理员与节点运维方无法读取明文
///
/// 局限（已写入文档）：本地缓存仍是明文，便于离线与导出。
/// 得到强保护的场景是"服务端或备份被盗"，不是"本机磁盘被拆"。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class SealedPayload {
  SealedPayload({required this.cipher, required this.nonce});

  /// 密文 + 认证标签（标签在末尾 16 字节）
  final Uint8List cipher;
  final Uint8List nonce;

  String get cipherBase64 => base64Encode(cipher);
  String get nonceBase64 => base64Encode(nonce);
}

class CryptoService {
  CryptoService._(this.masterKey);

  final SecretKey masterKey;

  static const int keyLengthBytes = 32;
  static const int nonceLengthBytes = 12;
  static const int macLengthBytes = 16;
  static const int defaultIterations = 210000;

  static final _aes = AesGcm.with256bits();
  static final _random = Random.secure();

  static List<int> _randomBytes(int length) => List<int>.generate(length, (_) => _random.nextInt(256));

  /// 生成随机密钥字节（恢复密钥等）
  static List<int> randomKeyBytes(int length) => _randomBytes(length);

  /// 生成新的随机盐（首次启用加密时提交给服务端保存）
  static String generateSalt() => base64Encode(_randomBytes(16));

  /// 用密码 + 盐派生主密钥。迭代次数由服务端下发，保证各设备一致。
  static Future<CryptoService> derive({
    required String password,
    required String saltBase64,
    int iterations = defaultIterations,
  }) async {
    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: keyLengthBytes * 8,
    );
    final key = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: base64Decode(saltBase64),
    );
    return CryptoService._(key);
  }

  /// 从已保存的密钥字节恢复（重启后免二次输入密码）
  static CryptoService fromBytes(List<int> bytes) => CryptoService._(SecretKey(bytes));

  Future<List<int>> exportKeyBytes() => masterKey.extractBytes();

  /// 包裹主密钥用的固定 AAD：明确这是"密钥包裹体"，不能与日记内容混用
  static final List<int> _keyWrapAad = utf8.encode('riji-key-wrap-v1');

  /// 用当前密钥（KEK）包裹主密钥，得到可安全存到服务端的密文
  Future<SealedPayload> wrapMasterKey(List<int> masterBytes) =>
      seal(Uint8List.fromList(masterBytes), aad: _keyWrapAad);

  /// 解开主密钥包裹体
  Future<List<int>> unwrapMasterKey({required List<int> cipher, required List<int> nonce}) async {
    final plain = await open(cipher: cipher, nonce: nonce, aad: _keyWrapAad);
    return plain;
  }

  /// 加密一段内容。aad 把密文绑定到具体位置（块 ID、设备、时钟）。
  Future<SealedPayload> seal(Uint8List plain, {required List<int> aad}) async {
    final nonce = _randomBytes(nonceLengthBytes);
    final box = await _aes.encrypt(plain, secretKey: masterKey, nonce: nonce, aad: aad);
    final combined = Uint8List(box.cipherText.length + box.mac.bytes.length);
    combined.setRange(0, box.cipherText.length, box.cipherText);
    combined.setRange(box.cipherText.length, combined.length, box.mac.bytes);
    return SealedPayload(cipher: combined, nonce: Uint8List.fromList(box.nonce));
  }

  Future<Uint8List> open({
    required List<int> cipher,
    required List<int> nonce,
    required List<int> aad,
  }) async {
    if (cipher.length <= macLengthBytes) {
      throw const FormatException('密文长度异常');
    }
    final cipherText = cipher.sublist(0, cipher.length - macLengthBytes);
    final mac = cipher.sublist(cipher.length - macLengthBytes);
    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
    final plain = await _aes.decrypt(box, secretKey: masterKey, aad: aad);
    return Uint8List.fromList(plain);
  }
}

/// 用于构造块级 AAD：只用块自身的稳定标识，任何设备都能复算出来
List<int> blockAad({required String blockId, required String hlc}) =>
    utf8.encode('$blockId|$hlc');

/// 媒体加密用的 AAD：绑定内容哈希，避免密文被换到别的媒体上
List<int> mediaAad({required String mediaKey}) => utf8.encode('media|$mediaKey');
