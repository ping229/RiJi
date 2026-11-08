/// 恢复短语端到端探针：在一个一次性账号上跑完整流程。
///
///   set RJJ_USER=recovery-test RJJ_PASS=初始密码
///   dart run tool/recovery_probe.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:riji_client/core/api_client.dart';
import 'package:riji_client/core/crypto_service.dart';
import 'package:riji_client/core/models.dart';
import 'package:riji_client/core/recovery_service.dart';
import 'package:uuid/uuid.dart';

Future<void> main() async {
  final base = Platform.environment['RJJ_SERVER'] ?? 'http://127.0.0.1:8080';
  final username = Platform.environment['RJJ_USER'] ?? 'recovery-test';
  final oldPassword = Platform.environment['RJJ_PASS'] ?? '';
  if (oldPassword.isEmpty) {
    stderr.writeln('缺少 RJJ_PASS');
    exit(2);
  }

  final api = ApiClient(baseUrl: base);
  final login = await api.login(
    username: username,
    password: oldPassword,
    deviceName: '恢复探针',
    platform: 'windows',
  );
  stdout.writeln('1. 登录成功：${login.username}');

  // 首次登录：设置盐
  var salt = login.kdfSalt;
  if (salt == null || salt.isEmpty) {
    salt = CryptoService.generateSalt();
    await api.setKdfSalt(salt: salt, iterations: login.kdfIterations);
  }
  final kek = await CryptoService.derive(
    password: oldPassword,
    saltBase64: salt,
    iterations: login.kdfIterations,
  );

  // 包裹主密钥（首次即用密码派生密钥作为主密钥）
  final masterBytes = await kek.exportKeyBytes();
  final master = CryptoService.fromBytes(masterBytes);
  final wrap = await kek.wrapMasterKey(masterBytes);
  await api.putKeyWrap(wrap: wrap.cipherBase64, nonce: wrap.nonceBase64);
  stdout.writeln('2. 主密钥已包裹并上传');

  // 生成恢复短语
  final setup = await RecoveryService(api: api).generate(master: master);
  stdout.writeln('3. 恢复短语：${setup.words.join(' ')}');

  // 写一条加密日记，作为"历史数据"
  final calendar = await api.calendar();
  final blockId = const Uuid().v4();
  final hlc = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(12, '0') + '-0000-probe';
  final sealed = await master.seal(
    Uint8List.fromList(utf8.encode(jsonEncode({'text': '恢复前的日记内容'}))),
    aad: blockAad(blockId: blockId, hlc: hlc),
  );
  await api.writeBatch(date: calendar.today, tzId: calendar.tzId, operations: [
    Block(
      blockId: blockId,
      blockType: BlockType.text,
      orderKey: '777777',
      vv: {login.deviceId ?? 'probe': 1},
      hlc: hlc,
      data: const {},
      enc: 'aes-256-gcm',
      nonce: sealed.nonceBase64,
      rawPayload: sealed.cipherBase64,
    ),
  ]);
  stdout.writeln('4. 已写入一条加密日记（模拟历史数据）');

  // 忘记密码：用短语恢复到新密码
  const newPassword = 'recovered-pass-2026';
  final recoveredMasterBytes = await RecoveryService(api: api).recover(
    username: username,
    words: setup.words,
    newPassword: newPassword,
  );
  stdout.writeln('5. 已用短语恢复，新密码设置完成');

  // 用新密码登录
  final api2 = ApiClient(baseUrl: base);
  await api2.login(
    username: username,
    password: newPassword,
    deviceName: '恢复后设备',
    platform: 'windows',
  );
  stdout.writeln('6. 新密码登录成功');

  // 拉回包裹体，验证解出的主密钥与恢复时一致
  final remote = await api2.getKeyWrap();
  final kek2 = await CryptoService.derive(
    password: newPassword,
    saltBase64: salt,
    iterations: login.kdfIterations,
  );
  final unwrapped = await kek2.unwrapMasterKey(
    cipher: base64Decode(remote['wrap'] as String),
    nonce: base64Decode(remote['nonce'] as String),
  );
  stdout.writeln('7. 新密码解出的主密钥与恢复时一致：${unwrapped.toString() == recoveredMasterBytes.toString() ? '✓' : '✗'}');

  // 用解出的主密钥解密历史日记
  final detail = await api2.getDiary(calendar.today);
  final block = detail?.blocks.firstWhere((b) => b.blockId == blockId);
  if (block == null) {
    stderr.writeln('找不到刚写的块');
    exit(3);
  }
  final plain = await CryptoService.fromBytes(unwrapped).open(
    cipher: base64Decode(block.rawPayload!),
    nonce: base64Decode(block.nonce!),
    aad: blockAad(blockId: blockId, hlc: hlc),
  );
  stdout.writeln('8. 解密历史日记：${utf8.decode(plain)}');

  // 旧密码应当已经失效
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
  stdout.writeln('9. 旧密码已失效：${oldRejected ? '✓' : '✗'}');

  stdout.writeln('');
  stdout.writeln('RECOVERY_OK');
  api.close();
  api2.close();
}
