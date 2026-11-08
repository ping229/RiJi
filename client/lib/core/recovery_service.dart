/// 恢复短语业务逻辑（需求 6.1 的"恢复短语机制"）。
///
/// 两条路径：
///   * 生成：随机 16 字节种子 → 编码成 16 个词；种子再哈希扩展成 32 字节恢复密钥
///   * 恢复：用户输入 16 个词 → 还原种子 → 扩展出恢复密钥 → 解开主密钥 → 用新密码重新包裹
///
/// 为什么不是直接用 16 字节做密钥：AES-256 需要 32 字节，
/// 而 16 个词 × 8 bit = 128 bit 熵，用哈希扩展既保住熵又满足密钥长度要求。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'api_client.dart';
import 'crypto_service.dart';
import 'recovery_phrase.dart';

class RecoverySetup {
  RecoverySetup({required this.words});

  /// 16 个词，只在这里出现一次，用户必须抄下来
  final List<String> words;
}

class RecoveryService {
  RecoveryService({required this.api});

  final ApiClient api;

  static const _expandLabel = 'riji-recovery-v1';

  /// 由 16 字节种子扩展出 32 字节恢复密钥
  static List<int> recoveryKeyFromSeed(List<int> seed) =>
      sha256.convert([...seed, ...utf8.encode(_expandLabel)]).bytes;

  /// 持有证明：服务端只存这个散列，拿不到恢复密钥本身
  static String proofOfSeed(List<int> seed) =>
      sha256.convert(utf8.encode('proof|${base64Encode(seed)}')).toString();

  /// 为当前登录账号生成恢复短语（会覆盖已有短语）
  Future<RecoverySetup> generate({required CryptoService master}) async {
    final masterBytes = await master.exportKeyBytes();
    final seed = CryptoService.randomKeyBytes(16);
    final recoveryKey = recoveryKeyFromSeed(seed);
    final recoveryCrypto = CryptoService.fromBytes(Uint8List.fromList(recoveryKey));

    final wrapped = await recoveryCrypto.wrapMasterKey(masterBytes);
    await api.putRecoveryWrap(
      wrap: wrapped.cipherBase64,
      nonce: wrapped.nonceBase64,
      proof: proofOfSeed(seed),
    );
    return RecoverySetup(words: RecoveryPhrase.encode(Uint8List.fromList(seed)));
  }

  /// 用短语 + 新密码恢复账号。成功后返回主密钥字节（供调用方重建会话）。
  Future<List<int>> recover({
    required String username,
    required List<String> words,
    required String newPassword,
  }) async {
    final info = await api.recoverStart(username);
    final seed = RecoveryPhrase.decode(words).sublist(0, 16);
    final recoveryCrypto = CryptoService.fromBytes(Uint8List.fromList(recoveryKeyFromSeed(seed)));

    final masterBytes = await recoveryCrypto.unwrapMasterKey(
      cipher: base64Decode(info['recoveryWrap'] as String),
      nonce: base64Decode(info['recoveryNonce'] as String),
    );

    final salt = info['kdfSalt'] as String?;
    final iterations = (info['kdfIterations'] as num?)?.toInt() ?? CryptoService.defaultIterations;
    if (salt == null || salt.isEmpty) {
      throw StateError('账号缺少密钥派生盐，无法恢复');
    }

    final newKek = await CryptoService.derive(
      password: newPassword,
      saltBase64: salt,
      iterations: iterations,
    );
    final rewrapped = await newKek.wrapMasterKey(masterBytes);
    await api.recoverComplete(
      username: username,
      proof: proofOfSeed(seed),
      newPassword: newPassword,
      keyWrap: rewrapped.cipherBase64,
      keyWrapNonce: rewrapped.nonceBase64,
    );
    return masterBytes;
  }
}
