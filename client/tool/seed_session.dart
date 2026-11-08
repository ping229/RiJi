/// 验收用：先登录并写好本机会话，让发布版程序启动即进入主页。
///
///   set RJJ_PASS=密码 && dart run tool/seed_session.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:riji_client/core/api_client.dart';
import 'package:riji_client/core/crypto_service.dart';
import 'package:riji_client/core/session_store.dart';

Future<void> main() async {
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
    deviceName: '验收设备',
    platform: 'windows',
  );

  var salt = login.kdfSalt;
  if (salt == null || salt.isEmpty) {
    salt = CryptoService.generateSalt();
    await api.setKdfSalt(salt: salt, iterations: login.kdfIterations);
  }
  final kek = await CryptoService.derive(
    password: password,
    saltBase64: salt,
    iterations: login.kdfIterations,
  );

  // 与登录页一致的逻辑：有包裹体就解开，没有就用派生密钥当主密钥并上传
  List<int> masterBytes;
  String? wrapB64;
  String? wrapNonce;
  try {
    final remote = await api.getKeyWrap();
    wrapB64 = remote['wrap'] as String?;
    wrapNonce = remote['nonce'] as String?;
  } catch (_) {
    // 忽略
  }
  if (wrapB64 != null && wrapB64.isNotEmpty && wrapNonce != null && wrapNonce.isNotEmpty) {
    masterBytes = await kek.unwrapMasterKey(
      cipher: base64Decode(wrapB64),
      nonce: base64Decode(wrapNonce),
    );
  } else {
    masterBytes = await kek.exportKeyBytes();
    final sealed = await kek.wrapMasterKey(masterBytes);
    await api.putKeyWrap(wrap: sealed.cipherBase64, nonce: sealed.nonceBase64);
  }

  final store = await SessionStore.open();
  await store.save(Session(
    baseUrl: base,
    accessToken: login.accessToken,
    refreshToken: login.refreshToken,
    deviceId: login.deviceId,
    username: login.username,
    keyB64: base64Encode(masterBytes),
    kdfSalt: salt,
    kdfIterations: login.kdfIterations,
  ));
  stdout.writeln('会话已写入：${(await SessionStore.open()).debugPath}');
  stdout.writeln('SEED_OK');
  api.close();
}
