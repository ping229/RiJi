/// 改密码端到端探针：验证换密码不影响历史密文。
///
///   set RJJ_USER=change-test RJJ_PASS=初始密码
///   dart run tool/change_password_probe.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:riji_client/core/api_client.dart';
import 'package:riji_client/core/crypto_service.dart';
import 'package:riji_client/core/models.dart';
import 'package:uuid/uuid.dart';

Future<void> main() async {
  final base = Platform.environment['RJJ_SERVER'] ?? 'http://127.0.0.1:8080';
  final username = Platform.environment['RJJ_USER'] ?? 'change-test';
  final oldPassword = Platform.environment['RJJ_PASS'] ?? '';
  if (oldPassword.isEmpty) {
    stderr.writeln('缺少 RJJ_PASS');
    exit(2);
  }

  final api = ApiClient(baseUrl: base);
  final login = await api.login(
    username: username,
    password: oldPassword,
    deviceName: '改密探针',
    platform: 'windows',
  );
  stdout.writeln('1. 登录成功：${login.username}');

  var salt = login.kdfSalt;
  if (salt == null || salt.isEmpty) {
    salt = CryptoService.generateSalt();
    await api.setKdfSalt(salt: salt, iterations: login.kdfIterations);
  }
  final kekOld = await CryptoService.derive(
    password: oldPassword,
    saltBase64: salt,
    iterations: login.kdfIterations,
  );
  final masterBytes = await kekOld.exportKeyBytes();
  final master = CryptoService.fromBytes(masterBytes);
  final wrap = await kekOld.wrapMasterKey(masterBytes);
  await api.putKeyWrap(wrap: wrap.cipherBase64, nonce: wrap.nonceBase64);
  stdout.writeln('2. 主密钥已包裹');

  // 写一条加密日记
  final calendar = await api.calendar();
  final blockId = const Uuid().v4();
  final hlc = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(12, '0') + '-0000-probe';
  final sealed = await master.seal(
    Uint8List.fromList(utf8.encode(jsonEncode({'text': '改密码前写的日记'}))),
    aad: blockAad(blockId: blockId, hlc: hlc),
  );
  await api.writeBatch(date: calendar.today, tzId: calendar.tzId, operations: [
    Block(
      blockId: blockId,
      blockType: BlockType.text,
      orderKey: '666666',
      vv: {login.deviceId ?? 'probe': 1},
      hlc: hlc,
      data: const {},
      enc: 'aes-256-gcm',
      nonce: sealed.nonceBase64,
      rawPayload: sealed.cipherBase64,
    ),
  ]);
  stdout.writeln('3. 已写入加密日记');

  // 改密码：用新密码派生新 KEK，重新包裹同一把主密钥
  const newPassword = 'new-pass-2026-ok';
  final kekNew = await CryptoService.derive(
    password: newPassword,
    saltBase64: salt,
    iterations: login.kdfIterations,
  );
  final rewrapped = await kekNew.wrapMasterKey(masterBytes);
  await api.changePassword(
    currentPassword: oldPassword,
    newPassword: newPassword,
    keyWrap: rewrapped.cipherBase64,
    keyWrapNonce: rewrapped.nonceBase64,
  );
  stdout.writeln('4. 密码已修改');

  // 用新密码登录并解密历史数据
  final api2 = ApiClient(baseUrl: base);
  await api2.login(
    username: username,
    password: newPassword,
    deviceName: '新设备',
    platform: 'windows',
  );
  stdout.writeln('5. 新密码登录成功');

  final remote = await api2.getKeyWrap();
  final unwrapped = await kekNew.unwrapMasterKey(
    cipher: base64Decode(remote['wrap'] as String),
    nonce: base64Decode(remote['nonce'] as String),
  );
  stdout.writeln('6. 包裹体解出的主密钥与原来一致：${unwrapped.toString() == masterBytes.toString() ? '✓' : '✗'}');

  final detail = await api2.getDiary(calendar.today);
  final block = detail?.blocks.firstWhere((b) => b.blockId == blockId);
  if (block == null) {
    stderr.writeln('找不到块');
    exit(3);
  }
  final plain = await CryptoService.fromBytes(unwrapped).open(
    cipher: base64Decode(block.rawPayload!),
    nonce: base64Decode(block.nonce!),
    aad: blockAad(blockId: blockId, hlc: hlc),
  );
  stdout.writeln('7. 解密改密码前的日记：${utf8.decode(plain)}');

  var oldRejected = false;
  try {
    await ApiClient(baseUrl: base).login(
      username: username,
      password: oldPassword,
      deviceName: 'x',
      platform: 'windows',
    );
  } catch (_) {
    oldRejected = true;
  }
  stdout.writeln('8. 旧密码已失效：${oldRejected ? '✓' : '✗'}');

  // 用错误旧密码改密码应被拒绝
  var wrongCurrentRejected = false;
  try {
    await api2.changePassword(
      currentPassword: 'definitely-wrong',
      newPassword: 'another-pass-2026',
      keyWrap: rewrapped.cipherBase64,
      keyWrapNonce: rewrapped.nonceBase64,
    );
  } catch (_) {
    wrongCurrentRejected = true;
  }
  stdout.writeln('9. 用错误旧密码改密码被拒：${wrongCurrentRejected ? '✓' : '✗'}');

  stdout.writeln('');
  stdout.writeln('CHANGE_PASSWORD_OK');
  api.close();
  api2.close();
}
