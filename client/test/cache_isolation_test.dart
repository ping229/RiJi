import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riji_client/core/local_store.dart';
import 'package:riji_client/core/models.dart';

Block _block(String id, String date) => Block(
      blockId: id,
      blockType: BlockType.text,
      orderKey: '000001',
      vv: const {},
      hlc: '000000000001-0000-dev',
      data: {'text': '来自 $id'},
    );

void main() {
  test('本地缓存按账号隔离：换账号看不到上一个账号的日记', () async {
    final base = await Directory.systemTemp.createTemp('riji_iso_');

    final alice = await LocalStore.open(base, account: 'alice');
    await alice.cacheBlocks('2026-11-03', [_block('a1', '2026-11-03')]);
    expect(await alice.readBlocks('2026-11-03'), isNotNull);

    final bob = await LocalStore.open(base, account: 'bob');
    expect(
      await bob.readBlocks('2026-11-03'),
      isNull,
      reason: 'bob 不能读到 alice 的本地缓存',
    );

    // 再切回 alice，数据还在
    final aliceAgain = await LocalStore.open(base, account: 'alice');
    expect(await aliceAgain.readBlocks('2026-11-03'), isNotNull);

    await base.delete(recursive: true);
  });

  test('升级前的老缓存归第一个登录的账号，后续账号不会继承', () async {
    final base = await Directory.systemTemp.createTemp('riji_legacy_');
    // 模拟旧版本：数据写在 diary/ 下，没有归属标记
    final legacyStore = await LocalStore.open(base);
    await legacyStore.cacheBlocks('2026-11-02', [_block('l1', '2026-11-02')]);

    final first = await LocalStore.open(base, account: 'first');
    expect(await first.readBlocks('2026-11-02'), isNotNull, reason: '第一个账号继承老缓存');

    final second = await LocalStore.open(base, account: 'second');
    expect(await second.readBlocks('2026-11-02'), isNull, reason: '第二个账号不应继承');

    await base.delete(recursive: true);
  });

  test('同一账号重复打开指向同一个目录', () async {
    final base = await Directory.systemTemp.createTemp('riji_same_');
    final a = await LocalStore.open(base, account: 'same');
    final b = await LocalStore.open(base, account: 'same');
    expect(a.root.path, b.root.path);
    await base.delete(recursive: true);
  });
}
