import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riji_client/core/session_store.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('riji_session_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('会话：保存后能原样读回（含主密钥与盐）', () async {
    final store = SessionStore.at(dir);
    final session = Session(
      baseUrl: 'http://127.0.0.1:8080',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      deviceId: 'device-1',
      username: 'tester',
      keyB64: 'a2V5LWJ5dGVz',
      kdfSalt: 'c2FsdA==',
      kdfIterations: 210000,
    );
    await store.save(session);

    final loaded = await SessionStore.at(dir).load();
    expect(loaded, isNotNull);
    expect(loaded!.baseUrl, session.baseUrl);
    expect(loaded.accessToken, session.accessToken);
    expect(loaded.username, 'tester');
    expect(loaded.keyB64, 'a2V5LWJ5dGVz', reason: '主密钥必须能恢复，否则日记解不开');
    expect(loaded.kdfSalt, 'c2FsdA==');
    expect(loaded.kdfIterations, 210000);
  });

  test('会话：没有文件时返回 null 而不是抛异常', () async {
    expect(await SessionStore.at(dir).load(), isNull);
  });

  test('会话：文件损坏时返回 null，不能让程序起不来', () async {
    await File('${dir.path}${Platform.pathSeparator}session.json')
        .writeAsString('{ 这不是合法 JSON');
    expect(await SessionStore.at(dir).load(), isNull);
  });

  test('会话：空文件也视为未登录', () async {
    await File('${dir.path}${Platform.pathSeparator}session.json').writeAsString('   ');
    expect(await SessionStore.at(dir).load(), isNull);
  });

  test('会话：退出登录后文件被清除', () async {
    final store = SessionStore.at(dir);
    await store.save(Session(
      baseUrl: 'http://x',
      accessToken: 'a',
      refreshToken: 'r',
    ));
    expect(await store.load(), isNotNull);

    await store.clear();
    expect(await store.load(), isNull);
  });

  test('会话：调试路径指向真实的文件位置', () async {
    final store = SessionStore.at(dir);
    expect(store.debugPath, contains('session.json'));
    expect(store.debugPath, startsWith(dir.path));
  });

  test('会话：JSON 里带未知字段也能正常读取（向后兼容）', () async {
    final file = File('${dir.path}${Platform.pathSeparator}session.json');
    await file.writeAsString(jsonEncode({
      'baseUrl': 'http://x',
      'accessToken': 'a',
      'refreshToken': 'r',
      'futureField': 'v2 才有的字段',
    }));
    final loaded = await SessionStore.at(dir).load();
    expect(loaded, isNotNull, reason: '旧版本读到新字段不应崩溃');
    expect(loaded!.accessToken, 'a');
  });
}
