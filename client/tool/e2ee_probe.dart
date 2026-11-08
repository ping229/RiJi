/// 端到端加密验证探针。
///
/// 用法：set RJJ_PASS=密码 && dart run tool/e2ee_probe.dart [日期]
///
/// 它会：
///   1. 登录并派生主密钥
///   2. 用加密后的块写入一篇日记
///   3. 立刻读回来并解密，打印明文
///   4. 打印该块的密文摘要，便于对照数据库里的存储形态
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:riji_client/core/api_client.dart';
import 'package:riji_client/core/crypto_service.dart';
import 'package:riji_client/core/models.dart';
import 'package:uuid/uuid.dart';

Future<void> main(List<String> args) async {
  final base = Platform.environment['RJJ_SERVER'] ?? 'http://127.0.0.1:8080';
  final username = Platform.environment['RJJ_USER'] ?? 'admin';
  final password = Platform.environment['RJJ_PASS'] ?? '';
  if (password.isEmpty) {
    stderr.writeln('缺少 RJJ_PASS');
    exit(2);
  }

  final api = ApiClient(baseUrl: base);
  final login = await api.login(
    username: username,
    password: password,
    deviceName: '加密探针',
    platform: 'windows',
  );
  stdout.writeln('登录成功：${login.username}');

  final salt = login.kdfSalt;
  if (salt == null || salt.isEmpty) {
    stderr.writeln('该账号还没有启用加密盐，先用客户端登录一次');
    exit(3);
  }
  final crypto = await CryptoService.derive(
    password: password,
    saltBase64: salt,
    iterations: login.kdfIterations,
  );
  stdout.writeln('主密钥已派生（${(await crypto.exportKeyBytes()).length} 字节）');

  final calendar = await api.calendar();
  final date = args.isNotEmpty ? args[0] : calendar.today;
  final plainText = '这段话在服务端应该是乱码：${DateTime.now().toIso8601String()}';

  final blockId = const Uuid().v4();
  final hlc = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(12, '0') + '-0000-probe';
  final plainBytes = Uint8List.fromList(utf8.encode(jsonEncode({'text': plainText})));
  final sealed = await crypto.seal(plainBytes, aad: blockAad(blockId: blockId, hlc: hlc));

  stdout.writeln('');
  stdout.writeln('块 ID：$blockId');
  stdout.writeln('明文长度：${plainBytes.length} 字节');
  stdout.writeln('密文长度：${sealed.cipher.length} 字节');
  stdout.writeln('密文前 24 字符（base64）：${sealed.cipherBase64.substring(0, 24)}…');

  await api.writeBatch(date: date, tzId: calendar.tzId, operations: [
    Block(
      blockId: blockId,
      blockType: BlockType.text,
      orderKey: '999999',
      vv: {login.deviceId ?? 'probe': 1},
      hlc: hlc,
      data: const {},
      enc: 'aes-256-gcm',
      nonce: sealed.nonceBase64,
      rawPayload: sealed.cipherBase64,
    ),
  ]);
  stdout.writeln('已写入日期 $date');

  final detail = await api.getDiary(date);
  final fetched = detail?.blocks.where((b) => b.blockId == blockId).toList() ?? [];
  if (fetched.isEmpty) {
    stderr.writeln('写入了但没读回来');
    exit(4);
  }
  final stored = fetched.first;
  stdout.writeln('');
  stdout.writeln('服务端返回的块：enc=${stored.enc}');
  final decrypted = await crypto.open(
    cipher: base64Decode(stored.rawPayload!),
    nonce: base64Decode(stored.nonce!),
    aad: blockAad(blockId: blockId, hlc: hlc),
  );
  stdout.writeln('解密结果：${utf8.decode(decrypted)}');

  // 校验：拿错误的 AAD 解密必须失败
  var tamperRejected = false;
  try {
    await crypto.open(
      cipher: base64Decode(stored.rawPayload!),
      nonce: base64Decode(stored.nonce!),
      aad: blockAad(blockId: 'wrong-block', hlc: hlc),
    );
  } catch (_) {
    tamperRejected = true;
  }
  stdout.writeln('篡改块 ID 后解密被拒：${tamperRejected ? '✓ 是' : '✗ 否'}');
  stdout.writeln('');
  stdout.writeln('E2EE_OK $blockId');
  api.close();
}
