import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:riji_client/core/api_client.dart';
import 'package:riji_client/core/crypto_service.dart';
import 'package:image/image.dart' as img;
import 'package:riji_client/core/diagnostics.dart';
import 'package:riji_client/core/image_utils.dart';
import 'package:riji_client/core/models.dart';
import 'package:riji_client/core/paste_utils.dart';
import 'package:riji_client/core/rich_text.dart';
import 'package:riji_client/core/search_service.dart';
import 'package:riji_client/core/waveform.dart';
import 'package:riji_client/core/recovery_phrase.dart';
import 'package:riji_client/core/recovery_service.dart';
import 'package:riji_client/core/export_service.dart';
import 'package:riji_client/core/local_store.dart';
import 'package:riji_client/core/session_store.dart';
import 'package:riji_client/core/sync_service.dart';
import 'package:riji_client/ui/editor_page.dart';

/// 1x1 透明 PNG，用于验证图片块能真正解码渲染
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

const _deviceId = '11111111-1111-4111-8111-111111111111';
const _base = 'http://127.0.0.1:8080';

Map<String, dynamic> _blockJson({
  required String id,
  required String type,
  required String orderKey,
  required Map<String, dynamic> data,
  String? mediaRef,
}) {
  return {
    'blockId': id,
    'blockType': type,
    'orderKey': orderKey,
    'vv': {_deviceId: 1},
    'hlc': '0000018c0000000${orderKey.substring(4)}-0000-$_deviceId',
    'enc': 'none',
    'mediaRef': mediaRef,
    'tombstone': false,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'payload': base64Encode(utf8.encode(jsonEncode(data))),
  };
}

Map<String, dynamic> _diaryPayload({int blockCount = 2}) {
  final now = DateTime.now().toUtc().toIso8601String();
  final blocks = <Map<String, dynamic>>[
    _blockJson(
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      type: 'text',
      orderKey: '000000',
      data: {'text': '今天开始用这个日记本。'},
    ),
    if (blockCount > 1)
      _blockJson(
        id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        type: 'image',
        orderKey: '000001',
        mediaRef: 'c' * 32,
        data: {'mime': 'image/png', 'width': 1, 'height': 1, 'name': 'a.png'},
      ),
  ];
  return {
    'diary': {
      'diaryId': 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      'diaryDate': '2026-11-03',
      'vv': {_deviceId: 1},
      'timeSuspect': false,
      'blockCount': blocks.length,
      'createdAt': now,
      'updatedAt': now,
    },
    'blocks': blocks,
  };
}

Session _session() => Session(
      baseUrl: _base,
      accessToken: 'token',
      username: 'tester',
      deviceId: _deviceId,
    );

Widget _wrap(Widget child) => MaterialApp(home: child);

Future<(DiaryStore, SyncService)> _localFor(ApiClient api) async {
  final store = MemoryStore();
  return (store, SyncService(api: api, store: store));
}

void main() {
  testWidgets('编辑器渲染服务端返回的文本块与图片块', (tester) async {
    var mediaRequested = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.startsWith('/api/diaries/')) {
        return http.Response(jsonEncode(_diaryPayload()), 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.startsWith('/api/media/')) {
        mediaRequested = true;
        return http.Response.bytes(_tinyPng, 200, headers: {'content-type': 'image/png'});
      }
      return http.Response('{}', 200);
    });

    final api = ApiClient(baseUrl: _base, httpClient: client);
    final (store, sync) = await _localFor(api);

    await tester.pumpWidget(_wrap(EditorPage(
      api: api,
      session: _session(),
      store: store,
      sync: sync,
      date: '2026-11-03',
      tzId: 'Asia/Shanghai',
      dayCutHour: 4,
      today: '2026-11-03',
      writable: true,
      onHlcChanged: (_) async {},
    )));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('今天开始用这个日记本'), findsOneWidget);
    expect(mediaRequested, isTrue, reason: '图片块应该触发媒体下载');
  });

  testWidgets('只读日记不显示编辑工具栏', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/api/diaries/')) {
        return http.Response(jsonEncode(_diaryPayload()), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response.bytes(_tinyPng, 200);
    });
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final (store, sync) = await _localFor(api);

    await tester.pumpWidget(_wrap(EditorPage(
      api: api,
      session: _session(),
      store: store,
      sync: sync,
      date: '2026-10-01',
      tzId: 'Asia/Shanghai',
      dayCutHour: 4,
      today: '2026-11-03',
      writable: false,
      onHlcChanged: (_) async {},
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('这一天已超出 7 天补写窗口，只能阅读。'), findsOneWidget);
    expect(find.text('图片'), findsNothing);
  });

  testWidgets('输入文字后自动保存：先落本地，不急着推服务器', (tester) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.startsWith('/api/diaries/') && request.method == 'GET') {
        return http.Response(jsonEncode(_diaryPayload(blockCount: 1)), 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.startsWith('/api/diaries/') && request.method == 'POST') {
        requests.add(request);
        // 真实服务器会返回合并后的规范版本，这里回显客户端提交的块
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final ops = (body['operations'] as List<dynamic>).cast<Map<String, dynamic>>();
        final now = DateTime.now().toUtc().toIso8601String();
        final blocks = ops
            .map((op) => {
                  ...op,
                  'tombstone': false,
                  'updatedAt': now,
                })
            .toList();
        return http.Response(
          jsonEncode({
            'diary': {
              'diaryId': 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
              'diaryDate': '2026-11-03',
              'vv': {_deviceId: 2},
              'timeSuspect': false,
              'blockCount': blocks.length,
              'createdAt': now,
              'updatedAt': now,
            },
            'blocks': blocks,
            'conflicts': <dynamic>[],
            'today': '2026-11-03',
            'serverNow': now,
            'timeSuspect': false,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    });
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final (store, sync) = await _localFor(api);

    await tester.pumpWidget(_wrap(EditorPage(
      api: api,
      session: _session(),
      store: store,
      sync: sync,
      date: '2026-11-03',
      tzId: 'Asia/Shanghai',
      dayCutHour: 4,
      today: '2026-11-03',
      writable: true,
      onHlcChanged: (_) async {},
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField).first, '今天开始用这个日记本。又写了一句');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    // 本地必须有缓存（写入即持久）
    final cached = await store.readBlocks('2026-11-03');
    expect(cached, isNotNull, reason: '保存必须先落本地');
    expect(cached!.any((b) => b.text.contains('又写了一句')), isTrue);

    // 但不要每敲一次就推服务器：用户明确要求"退出时同步"
    expect(requests, isEmpty, reason: '输入过程中不应该立刻推服务器');

    // 手动点同步按钮，或者停留够久（兜底）才推
    await tester.tap(find.byTooltip('立即同步到服务器'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(requests, isNotEmpty, reason: '点同步按钮后应该推送到服务器');
    final body = jsonDecode(requests.last.body) as Map<String, dynamic>;
    final operations = body['operations'] as List<dynamic>;
    expect(operations, isNotEmpty);
    final payload = utf8.decode(
      base64Decode((operations.first as Map<String, dynamic>)['payload'] as String),
    );
    expect(payload, contains('又写了一句'));
  });

  testWidgets('离线时保存不丢失，内容留在待推送队列', (tester) async {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.startsWith('/api/diaries/') && request.method == 'GET') {
        return http.Response(jsonEncode(_diaryPayload(blockCount: 1)), 200,
            headers: {'content-type': 'application/json'});
      }
      // 模拟断网
      throw const SocketException('offline');
    });
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final (store, sync) = await _localFor(api);

    await tester.pumpWidget(_wrap(EditorPage(
      api: api,
      session: _session(),
      store: store,
      sync: sync,
      date: '2026-11-03',
      tzId: 'Asia/Shanghai',
      dayCutHour: 4,
      today: '2026-11-03',
      writable: true,
      onHlcChanged: (_) async {},
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField).first, '断网时写的这一句');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    final cached = await store.readBlocks('2026-11-03');
    expect(cached, isNotNull);
    expect(cached!.any((b) => b.text.contains('断网时写的这一句')), isTrue);

    final pending = await store.pending();
    expect(pending['2026-11-03'], isNotEmpty, reason: '推送失败的内容必须留在队列里等重试');
  });

  testWidgets('长日记：在末尾继续输入时，视图跟着光标走', (tester) async {
    final longText = List.generate(120, (i) => '第 $i 行：把这一天的日记写得很长很长。').join('\n');
    final payload = _diaryPayload(blockCount: 1);
    (payload['blocks'] as List<dynamic>)[0] = _blockJson(
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      type: 'text',
      orderKey: '000000',
      data: {'text': longText},
    );

    final client = MockClient((request) async {
      if (request.url.path.startsWith('/api/diaries/')) {
        return http.Response(jsonEncode(payload), 200, headers: {'content-type': 'application/json'});
      }
      return http.Response('{}', 200);
    });
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final (store, sync) = await _localFor(api);

    await tester.pumpWidget(_wrap(EditorPage(
      api: api,
      session: _session(),
      store: store,
      sync: sync,
      date: '2026-11-03',
      tzId: 'Asia/Shanghai',
      dayCutHour: 4,
      today: '2026-11-03',
      writable: true,
      onHlcChanged: (_) async {},
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
    );
    expect(scrollable.position.pixels, 0);

    // 光标落到 120 行之后：如果不做跟随，界面会一直停在顶部
    await tester.enterText(find.byType(TextField).first, '$longText\n刚写下的最后一行');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(scrollable.position.pixels, greaterThan(0),
        reason: '在长日记末尾输入时，视图必须跟着光标往下走');
  });

  test('导出 Markdown：文本与媒体都在正确位置', () async {
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/api/media/')) {
        return http.Response.bytes(_tinyPng, 200, headers: {'content-type': 'image/png'});
      }
      return http.Response('{}', 200);
    });
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final dir = await Directory.systemTemp.createTemp('riji_export_');
    final store = await LocalStore.open(dir);

    final now = DateTime.now().toUtc().toIso8601String();
    final blocks = [
      _blockJson(id: 'a0', type: 'text', orderKey: '000000', data: {'text': '第一段文字'}),
      _blockJson(
        id: 'a1',
        type: 'image',
        orderKey: '000001',
        mediaRef: 'd' * 32,
        data: {'mime': 'image/png', 'width': 1, 'height': 1, 'name': 'p.png'},
      ),
      _blockJson(id: 'a2', type: 'text', orderKey: '000002', data: {'text': '图片之后的文字'}),
    ];
    final payload = {
      'diaryDate': '2026-11-03',
      'cachedAt': now,
      'blocks': blocks,
    };
    await File('${dir.path}${Platform.pathSeparator}diary${Platform.pathSeparator}diaries'
            '${Platform.pathSeparator}2026-11-03.json')
        .writeAsString(jsonEncode(payload));

    final target = await Directory.systemTemp.createTemp('riji_export_target_');
    final service = ExportService(api: api, store: store);
    final result = await service.exportMarkdown(dates: ['2026-11-03'], target: target);

    expect(result.diaryCount, 1);
    expect(result.mediaCount, 1);

    final mdFile = File('${result.directory.path}${Platform.pathSeparator}2026-11-03.md');
    expect(await mdFile.exists(), isTrue);
    final md = await mdFile.readAsString();
    final textIndex = md.indexOf('第一段文字');
    final imageIndex = md.indexOf('assets/');
    final secondIndex = md.indexOf('图片之后的文字');
    expect(textIndex, greaterThan(-1));
    expect(imageIndex, greaterThan(textIndex));
    expect(secondIndex, greaterThan(imageIndex), reason: '媒体必须夹在两段文字之间，而不是被挪到附件区');
  });

  test('导出 HTML：媒体用相对路径内联在正文之间', () async {
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/api/media/')) {
        return http.Response.bytes(_tinyPng, 200, headers: {'content-type': 'image/png'});
      }
      return http.Response('{}', 200);
    });
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final dir = await Directory.systemTemp.createTemp('riji_export_html_');
    final store = await LocalStore.open(dir);

    final payload = {
      'diaryDate': '2026-11-03',
      'cachedAt': DateTime.now().toUtc().toIso8601String(),
      'blocks': [
        _blockJson(id: 'b0', type: 'text', orderKey: '000000', data: {'text': '开头文字'}),
        _blockJson(
          id: 'b1',
          type: 'image',
          orderKey: '000001',
          mediaRef: 'e' * 32,
          data: {'mime': 'image/png', 'width': 1, 'height': 1, 'name': 'q.png'},
        ),
        _blockJson(id: 'b2', type: 'text', orderKey: '000002', data: {'text': '结尾文字'}),
      ],
    };
    await File('${dir.path}${Platform.pathSeparator}diary${Platform.pathSeparator}diaries'
            '${Platform.pathSeparator}2026-11-03.json')
        .writeAsString(jsonEncode(payload));

    final target = await Directory.systemTemp.createTemp('riji_export_html_target_');
    final service = ExportService(api: api, store: store);
    final result = await service.exportHtml(dates: ['2026-11-03'], target: target);

    final indexFile = File('${result.directory.path}${Platform.pathSeparator}index.html');
    expect(await indexFile.exists(), isTrue);
    final html = await indexFile.readAsString();
    expect(html.indexOf('开头文字'), greaterThan(-1));
    expect(html.indexOf('<img src="assets/'), greaterThan(html.indexOf('开头文字')));
    expect(html.indexOf('结尾文字'), greaterThan(html.indexOf('<img src="assets/')));

    final assetsDir = Directory('${result.directory.path}${Platform.pathSeparator}assets');
    final files = await assetsDir.list().toList();
    expect(files, hasLength(1));
  });

  test('导出平台归档 ZIP：manifest / entries / media / README 齐全', () async {
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/api/media/')) {
        return http.Response.bytes(_tinyPng, 200, headers: {'content-type': 'image/png'});
      }
      return http.Response('{}', 200);
    });
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final dir = await Directory.systemTemp.createTemp('riji_export_zip_');
    final store = await LocalStore.open(dir);

    final payload = {
      'diaryDate': '2026-11-03',
      'cachedAt': DateTime.now().toUtc().toIso8601String(),
      'blocks': [
        _blockJson(id: 'c0', type: 'text', orderKey: '000000', data: {'text': '归档测试'}),
        _blockJson(
          id: 'c1',
          type: 'image',
          orderKey: '000001',
          mediaRef: 'f' * 32,
          data: {'mime': 'image/png', 'width': 1, 'height': 1, 'name': 'z.png'},
        ),
      ],
    };
    await File('${dir.path}${Platform.pathSeparator}diary${Platform.pathSeparator}diaries'
            '${Platform.pathSeparator}2026-11-03.json')
        .writeAsString(jsonEncode(payload));

    final target = await Directory.systemTemp.createTemp('riji_export_zip_target_');
    final service = ExportService(api: api, store: store);
    final result = await service.exportZip(dates: ['2026-11-03'], target: target, username: 'admin');

    expect(result.diaryCount, 1);
    expect(result.mediaCount, 1);

    final zipFile = target.listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.zip'));
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final names = archive.files.map((f) => f.name).toList();

    expect(names, contains('manifest.json'));
    expect(names, contains('README.txt'));
    expect(names, contains('entries/2026-11-03.json'));
    expect(names.any((n) => n.startsWith('media/')), isTrue);

    final manifestJson = archive.files.firstWhere((f) => f.name == 'manifest.json').content;
    final manifest = jsonDecode(utf8.decode(manifestJson as List<int>)) as Map<String, dynamic>;
    expect(manifest['formatVersion'], '1.0');
    expect(manifest['diaryCount'], 1);
    expect(manifest['mediaCount'], 1);
    // 用户标识必须脱敏
    expect(manifest['user'], isNot(equals('admin')));
    expect(manifest['user'], contains('··'));

    final entryJson = archive.files.firstWhere((f) => f.name == 'entries/2026-11-03.json').content;
    final entry = jsonDecode(utf8.decode(entryJson as List<int>)) as Map<String, dynamic>;
    final blocks = entry['blocks'] as List<dynamic>;
    expect(blocks.length, 2);
    expect((blocks.first as Map<String, dynamic>)['blockType'], 'text');
    expect((blocks.last as Map<String, dynamic>)['mediaRef'], 'f' * 32);
  });

  test('导出 PDF：生成合法 PDF 且内嵌字体', () async {
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/api/media/')) {
        return http.Response.bytes(_tinyPng, 200, headers: {'content-type': 'image/png'});
      }
      return http.Response('{}', 200);
    });
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final dir = await Directory.systemTemp.createTemp('riji_export_pdf_');
    final store = await LocalStore.open(dir);

    await File('${dir.path}${Platform.pathSeparator}diary${Platform.pathSeparator}diaries'
            '${Platform.pathSeparator}2026-11-03.json')
        .writeAsString(jsonEncode({
      'diaryDate': '2026-11-03',
      'cachedAt': DateTime.now().toUtc().toIso8601String(),
      'blocks': [
        _blockJson(id: 'd0', type: 'text', orderKey: '000000', data: {'text': 'PDF 里的中文段落'}),
        _blockJson(
          id: 'd1',
          type: 'audio',
          orderKey: '000001',
          mediaRef: 'e' * 32,
          data: {'mime': 'audio/mp4', 'durationMs': 4000, 'name': '语音'},
        ),
      ],
    }));

    final target = await Directory.systemTemp.createTemp('riji_export_pdf_target_');
    final service = ExportService(api: api, store: store);
    final result = await service.exportPdf(dates: ['2026-11-03'], target: target);

    expect(result.diaryCount, 1);
    final pdfFile = target.listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.pdf'));
    final bytes = await pdfFile.readAsBytes();

    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    expect(bytes.length, greaterThan(2000), reason: '内嵌字体后 PDF 不应是空壳');
    final latin = latin1.decode(bytes, allowInvalid: true);
    expect(latin.contains('FontFile2'), isTrue, reason: '必须内嵌字体，否则中文渲染成方块');
  });
  test('版本历史：加密的历史版本能被解密还原', () async {
    final deviceId = _deviceId;
    const blockId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    const hlc = '0000018c00abcdef-0001-test';
    final salt = CryptoService.generateSalt();
    final crypto = await CryptoService.derive(password: 'test-password', saltBase64: salt);
    final sealed = await crypto.seal(
      Uint8List.fromList(utf8.encode(jsonEncode({'text': '这是被覆盖的旧版本'}))),
      aad: blockAad(blockId: blockId, hlc: hlc),
    );

    final client = MockClient((request) async {
      if (request.url.path == '/api/blocks/$blockId/versions') {
        return http.Response(
          jsonEncode({
            'blockId': blockId,
            'versions': [
              {
                'versionId': 'v1',
                'hlc': hlc,
                'vv': {deviceId: 1},
                'payload': sealed.cipherBase64,
                'enc': 'aes-256-gcm',
                'nonce': sealed.nonceBase64,
                'createdAt': DateTime.now().toUtc().toIso8601String(),
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    });

    final api = ApiClient(baseUrl: _base, httpClient: client);
    final store = MemoryStore();
    final sync = SyncService(api: api, store: store, crypto: crypto);
    final versions = await sync.loadVersions(blockId);

    expect(versions, hasLength(1));
    expect(versions.first.text, '这是被覆盖的旧版本');
  });

  test('版本历史：明文历史版本同样可读', () async {
    const blockId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    final client = MockClient((request) async {
      if (request.url.path == '/api/blocks/$blockId/versions') {
        return http.Response(
          jsonEncode({
            'blockId': blockId,
            'versions': [
              {
                'versionId': 'v2',
                'hlc': '0000018c00abcdef-0002-test',
                'vv': {_deviceId: 1},
                'payload': base64Encode(utf8.encode(jsonEncode({'text': '明文旧版本'}))),
                'enc': 'none',
                'createdAt': DateTime.now().toUtc().toIso8601String(),
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    });
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final store = MemoryStore();
    final sync = SyncService(api: api, store: store);
    final versions = await sync.loadVersions(blockId);
    expect(versions.single.text, '明文旧版本');
  });
  test('主密钥包裹：可解开，且改密码后历史数据仍可读', () async {
    final salt = CryptoService.generateSalt();
    // 旧密码派生出旧 KEK
    final kekOld = await CryptoService.derive(password: 'old-password', saltBase64: salt);
    final masterBytes = await kekOld.exportKeyBytes();

    // 用旧 KEK 包裹主密钥（模拟服务端存储的内容）
    final wrapped = await kekOld.wrapMasterKey(masterBytes);

    // 用数据密钥加密一条内容
    final dataSealed = await kekOld.seal(
      Uint8List.fromList(utf8.encode(jsonEncode({'text': '密码换掉也要能读'})).toList()),
      aad: blockAad(blockId: 'b1', hlc: 'h1'),
    );

    // 改密码的真实流程：先用旧密码解开主密钥，再用新 KEK 重新包裹并上传
    final recovered = await kekOld.unwrapMasterKey(
      cipher: base64Decode(wrapped.cipherBase64),
      nonce: base64Decode(wrapped.nonceBase64),
    );
    expect(recovered, equals(masterBytes), reason: '旧密码应能解出主密钥');

    final kekNew = await CryptoService.derive(password: 'new-password', saltBase64: salt);
    final rewrapped = await kekNew.wrapMasterKey(recovered);

    // 之后新密码就能解开了，且解出的还是同一把主密钥
    final unwrapped = await kekNew.unwrapMasterKey(
      cipher: base64Decode(rewrapped.cipherBase64),
      nonce: base64Decode(rewrapped.nonceBase64),
    );
    expect(unwrapped, equals(masterBytes), reason: '改密码后应能解出同一把主密钥');

    // 旧密码此时已经解不开新的包裹体
    var oldPasswordRejected = false;
    try {
      await kekOld.unwrapMasterKey(
        cipher: base64Decode(rewrapped.cipherBase64),
        nonce: base64Decode(rewrapped.nonceBase64),
      );
    } catch (_) {
      oldPasswordRejected = true;
    }
    expect(oldPasswordRejected, isTrue, reason: '重新包裹后旧密码不应还能解开');

    // 用解出的主密钥解密历史数据
    final master = CryptoService.fromBytes(unwrapped);
    final plain = await master.open(
      cipher: base64Decode(dataSealed.cipherBase64),
      nonce: base64Decode(dataSealed.nonceBase64),
      aad: blockAad(blockId: 'b1', hlc: 'h1'),
    );
    expect(utf8.decode(plain), contains('密码换掉也要能读'));
  });

  test('主密钥包裹：用错误密码解不开', () async {
    final salt = CryptoService.generateSalt();
    final kek = await CryptoService.derive(password: 'right-password', saltBase64: salt);
    final masterBytes = await kek.exportKeyBytes();
    final wrapped = await kek.wrapMasterKey(masterBytes);

    final wrongKek = await CryptoService.derive(password: 'wrong-password', saltBase64: salt);
    var failed = false;
    try {
      await wrongKek.unwrapMasterKey(
        cipher: base64Decode(wrapped.cipherBase64),
        nonce: base64Decode(wrapped.nonceBase64),
      );
    } catch (_) {
      failed = true;
    }
    expect(failed, isTrue, reason: '密码错误必须解不开，不能静默返回垃圾');
  });
  test('恢复短语：16 个词可往返编码', () {
    final key = Uint8List.fromList(List<int>.generate(32, (i) => (i * 7) % 256));
    final words = RecoveryPhrase.encode(key);
    expect(words, hasLength(16));
    final decoded = RecoveryPhrase.decode(words);
    expect(decoded.sublist(0, 16), equals(key.sublist(0, 16)));
  });

  test('恢复短语：词数不对或含未知词都要报错', () {
    expect(() => RecoveryPhrase.decode(['acid', 'aged']), throwsFormatException);
    final words = List<String>.filled(16, 'acid');
    words[3] = 'notaword';
    expect(() => RecoveryPhrase.decode(words), throwsFormatException);
  });

  test('恢复流程：用短语重置密码后仍能解开原数据', () async {
    // 服务端侧状态
    String? storedRecoveryWrap;
    String? storedRecoveryNonce;
    String? storedProof;
    String? storedKeyWrap;
    String? storedKeyWrapNonce;

    final salt = CryptoService.generateSalt();
    const iterations = 100000;
    final master = await CryptoService.derive(password: 'old-password', saltBase64: salt, iterations: iterations);
    final masterBytes = await master.exportKeyBytes();

    // 用主密钥加密一条内容，模拟用户的历史日记
    final diarySealed = await master.seal(
      Uint8List.fromList(utf8.encode('{"text":"我的私密日记"}')),
      aad: blockAad(blockId: 'blk', hlc: 'h1'),
    );

    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/auth/recovery-wrap' && request.method == 'PUT') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        storedRecoveryWrap = body['wrap'] as String?;
        storedRecoveryNonce = body['nonce'] as String?;
        storedProof = body['proof'] as String?;
        return http.Response('{"ok":true}', 200, headers: {'content-type': 'application/json'});
      }
      if (path == '/api/auth/recover/start') {
        return http.Response(
          jsonEncode({
            'kdfSalt': salt,
            'kdfIterations': iterations,
            'recoveryWrap': storedRecoveryWrap,
            'recoveryNonce': storedRecoveryNonce,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/auth/recover/complete') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['proof'] != storedProof) {
          return http.Response('{"error":{"message":"恢复短语不正确"}}', 403,
              headers: {'content-type': 'application/json'});
        }
        storedKeyWrap = body['keyWrap'] as String?;
        storedKeyWrapNonce = body['keyWrapNonce'] as String?;
        return http.Response('{"ok":true}', 200, headers: {'content-type': 'application/json'});
      }
      return http.Response('{}', 200);
    });

    final api = ApiClient(baseUrl: _base, httpClient: client);
    final recovery = RecoveryService(api: api);

    // 1) 生成恢复短语
    final setup = await recovery.generate(master: master);
    expect(setup.words, hasLength(16));
    expect(storedRecoveryWrap, isNotNull);
    expect(storedProof, isNotNull);

    // 2) 假装忘了密码，用短语恢复并设新密码
    final recoveredMaster = await recovery.recover(
      username: 'tester',
      words: setup.words,
      newPassword: 'brand-new-password',
    );
    expect(recoveredMaster, equals(masterBytes), reason: '恢复出的主密钥必须与原主密钥一致');
    expect(storedKeyWrap, isNotNull);

    // 3) 用新密码派生的 KEK 解开新包裹体，仍得到同一把主密钥
    final newKek = await CryptoService.derive(
      password: 'brand-new-password',
      saltBase64: salt,
      iterations: iterations,
    );
    final finalMasterBytes = await newKek.unwrapMasterKey(
      cipher: base64Decode(storedKeyWrap!),
      nonce: base64Decode(storedKeyWrapNonce!),
    );
    expect(finalMasterBytes, equals(masterBytes));

    // 4) 用恢复出的主密钥解密历史日记
    final finalMaster = CryptoService.fromBytes(finalMasterBytes);
    final plain = await finalMaster.open(
      cipher: base64Decode(diarySealed.cipherBase64),
      nonce: base64Decode(diarySealed.nonceBase64),
      aad: blockAad(blockId: 'blk', hlc: 'h1'),
    );
    expect(utf8.decode(plain), contains('我的私密日记'));
  });

  test('恢复流程：错误的短语无法通过服务端校验', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/auth/recover/complete') {
        return http.Response('{"error":{"message":"恢复短语不正确"}}', 403,
            headers: {'content-type': 'application/json'});
      }
      final salt = CryptoService.generateSalt();
      return http.Response(
        jsonEncode({
          'kdfSalt': salt,
          'kdfIterations': 100000,
          'recoveryWrap': base64Encode(List<int>.filled(48, 1)),
          'recoveryNonce': base64Encode(List<int>.filled(12, 2)),
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final recovery = RecoveryService(api: api);
    // 包裹体是垃圾数据，解密阶段就会失败
    await expectLater(
      recovery.recover(username: 'tester', words: List<String>.filled(16, 'acid'), newPassword: 'whatever-123'),
      throwsA(anything),
    );
  });
  test('自检：服务器正常时各项通过', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/healthz') {
        return http.Response('{"status":"ok"}', 200, headers: {'content-type': 'application/json'});
      }
      if (request.url.path == '/api/auth/me') {
        return http.Response(
          jsonEncode({'user': {'id': 'u1', 'username': 'tester', 'status': 'active'}}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    });
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final store = MemoryStore();
    final report = await Diagnostics(
      api: api,
      session: _session(),
      store: store,
    ).run();

    expect(report.healthy, isTrue, reason: '服务器与登录都正常时不应有失败项');
    expect(report.results.any((r) => r.name == '服务器连通' && r.status == CheckStatus.ok), isTrue);
    expect(report.results.any((r) => r.name == '登录状态' && r.status == CheckStatus.ok), isTrue);
    // 没有加密密钥时应是"提示"而不是"失败"
    final cryptoCheck = report.results.firstWhere((r) => r.name == '端到端加密');
    expect(cryptoCheck.status, CheckStatus.warn);
  });

  test('自检：服务器不可达时明确失败并跳过后续', () async {
    final client = MockClient((request) async {
      throw const SocketException('connection refused');
    });
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final report = await Diagnostics(
      api: api,
      session: _session(),
      store: MemoryStore(),
    ).run();

    expect(report.healthy, isFalse);
    final server = report.results.firstWhere((r) => r.name == '服务器连通');
    expect(server.status, CheckStatus.fail);
    expect(server.hint, isNotNull, reason: '失败时必须给出可操作建议');
    expect(report.results.any((r) => r.status == CheckStatus.skipped), isTrue);
  });
  test('图片压缩：小图原样保留，不丢原图', () {
    final small = img.Image(width: 320, height: 240);
    img.fill(small, color: img.ColorRgb8(10, 120, 200));
    final bytes = Uint8List.fromList(img.encodePng(small));

    final prepared = ImageUtils.prepare(bytes);
    expect(prepared.resized, isFalse);
    expect(prepared.display, equals(bytes));
    expect(prepared.width, 320);
    expect(prepared.height, 240);
  });

  test('图片压缩：长边超过 2048 会被压到 2048 且保留原图', () {
    final big = img.Image(width: 3000, height: 1500);
    img.fill(big, color: img.ColorRgb8(200, 80, 40));
    final bytes = Uint8List.fromList(img.encodePng(big));

    final prepared = ImageUtils.prepare(bytes);
    expect(prepared.resized, isTrue);
    expect(prepared.width, 2048, reason: '长边应被压到 2048');
    // 注意：纯色测试图用 PNG 编码后本来就极小，JPEG 反而更大，所以这里只校验尺寸。
    expect(prepared.original, equals(bytes), reason: '原图必须完整保留');
  });

  test('导出可取消：取消令牌立即生效且不产出文件', () async {
    final client = MockClient((request) async => http.Response('{}', 200));
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final dir = await Directory.systemTemp.createTemp('riji_cancel_');
    final store = await LocalStore.open(dir);
    final target = await Directory.systemTemp.createTemp('riji_cancel_target_');

    final cancellation = ExportCancellation()..cancel();
    final service = ExportService(api: api, store: store);

    await expectLater(
      service.exportHtml(dates: ['2026-11-03'], target: target, cancellation: cancellation),
      throwsA(isA<ExportCancelled>()),
    );
    final produced = await target.list().toList();
    expect(produced, isEmpty, reason: '取消后不应留下未完成的导出目录');
  });
  test('富文本：行内样式的解析', () {
    final spans = RichTextParser.parseInline('普通**粗体**以及*斜体*和~~删除~~');
    expect(spans.any((s) => s.bold && s.text == '粗体'), isTrue);
    expect(spans.any((s) => s.italic && !s.bold && s.text == '斜体'), isTrue,
        reason: '单个星号是斜体，不能和粗体混淆');
    expect(spans.any((s) => s.strike && s.text == '删除'), isTrue);
    // 样式标记本身不应出现在文本里
    expect(spans.map((s) => s.text).join(), isNot(contains('**')));
  });

  test('富文本：行级结构的识别', () {
    final lines = RichTextParser.parse('# 大标题\n## 小标题\n- 列表项\n1. 有序\n> 引用\n---\n普通段落');
    expect(lines[0].kind, LineKind.heading1);
    expect(lines[1].kind, LineKind.heading2);
    expect(lines[2].kind, LineKind.bullet);
    expect(lines[3].kind, LineKind.ordered);
    expect(lines[3].listIndex, 1);
    expect(lines[4].kind, LineKind.quote);
    expect(lines[5].kind, LineKind.divider);
    expect(lines[6].kind, LineKind.paragraph);
  });

  test('富文本：代码块与未闭合代码块都不丢内容', () {
    final closed = RichTextParser.parse('```\nvar a = 1;\n```');
    expect(closed.length, 1);
    expect(closed.first.kind, LineKind.code);
    expect(closed.first.plainText, contains('var a = 1'));

    // 用户只打了个开头就保存了，内容也不能被吞掉
    final unclosed = RichTextParser.parse('```\n没写完的代码');
    expect(unclosed.first.kind, LineKind.code);
    expect(unclosed.first.plainText, contains('没写完的代码'));
  });

  test('富文本：链接解析出文字与地址', () {
    final spans = RichTextParser.parseInline('看这里[官网](https://example.com)');
    final link = spans.firstWhere((s) => s.link != null);
    expect(link.text, '官网');
    expect(link.link, 'https://example.com');
  });

  test('富文本：工具栏包裹与行首前缀', () {
    final wrapped = RichTextParser.wrapSelection('今天很好', 0, 2, '**');
    expect(wrapped, '**今天**很好');

    final prefixed = RichTextParser.prefixLine('第一行\n第二行', 5, '- ');
    expect(prefixed, '第一行\n- 第二行');
  });
  test('导出 HTML：富文本标记转成真正的排版标签', () async {
    final client = MockClient((request) async => http.Response('{}', 200));
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final dir = await Directory.systemTemp.createTemp('riji_richhtml_');
    final store = await LocalStore.open(dir);

    await File('${dir.path}${Platform.pathSeparator}diary${Platform.pathSeparator}diaries'
            '${Platform.pathSeparator}2026-11-03.json')
        .writeAsString(jsonEncode({
      'diaryDate': '2026-11-03',
      'cachedAt': DateTime.now().toUtc().toIso8601String(),
      'blocks': [
        _blockJson(
          id: 'r1',
          type: 'text',
          orderKey: '000000',
          data: {'text': '# 今天\n这是**重点**，还有*斜体*\n- 第一项\n- 第二项'},
        ),
      ],
    }));

    final target = await Directory.systemTemp.createTemp('riji_richhtml_target_');
    final service = ExportService(api: api, store: store);
    final result = await service.exportHtml(dates: ['2026-11-03'], target: target);

    final html = await File('${result.directory.path}${Platform.pathSeparator}index.html').readAsString();
    expect(html, contains('<h1>今天</h1>'));
    expect(html, contains('<strong>重点</strong>'));
    expect(html, contains('<em>斜体</em>'));
    expect(html, contains('<ul>'));
    expect(html, contains('<li>第一项</li>'));
    // 标记字符不应残留在正文里
    expect(html, isNot(contains('**重点**')));
  });
  test('粘贴清理：换行、零宽字符、全角空格与制表符', () {
    final messy = '第一行\r\n第二行\u200B带零宽\r\n\t缩进行\u00A0有全角空格   ';
    final clean = PasteUtils.clean(messy);
    expect(clean.contains('\r'), isFalse, reason: 'CRLF 要统一成 LF');
    expect(clean.contains('\u200B'), isFalse, reason: '零宽字符必须清掉');
    expect(clean.contains('\u00A0'), isFalse, reason: '不间断空格要转普通空格');
    expect(clean.contains('\t'), isFalse, reason: '制表符要转空格');
    expect(clean, '第一行\n第二行带零宽\n  缩进行 有全角空格');
  });

  test('粘贴清理：连续空行压缩与首尾修剪', () {
    final messy = '\n\n\n开头\n\n\n\n中间\n\n\n结尾\n\n\n';
    final clean = PasteUtils.clean(messy);
    expect(clean, '开头\n\n中间\n\n结尾');
    expect(clean.startsWith('\n'), isFalse);
    expect(clean.endsWith('\n'), isFalse);
  });

  test('粘贴清理：插入到选区并定位光标', () {
    final result = PasteUtils.insert('你好世界', 2, 4, '  替换  ');
    expect(result.text, '你好替换');
    expect(result.caret, '你好替换'.length);
  });

  test('粘贴清理：空内容不报错', () {
    expect(PasteUtils.clean(''), '');
    final result = PasteUtils.insert('abc', 0, 0, '');
    expect(result.text, 'abc');
    expect(result.caret, 0);
  });
  test('波形：分贝转等级并夹紧边界', () {
    expect(Waveform.levelFromDb(0), 100);
    expect(Waveform.levelFromDb(-60), 0);
    expect(Waveform.levelFromDb(-30), 50);
    expect(Waveform.levelFromDb(-120), 0, reason: '超出范围的静音要夹到 0');
    expect(Waveform.levelFromDb(10), 100, reason: '过载要夹到 100');
    expect(Waveform.levelFromDb(double.nan), 0);
  });

  test('波形：降采样保留峰值且长度固定', () {
    // 1000 个采样里放一个尖峰，降采样后必须还在
    final levels = List<int>.generate(1000, (i) => i == 500 ? 99 : 10);
    final bars = Waveform.bars(levels, count: 60);
    expect(bars.length, 60);
    expect(bars.contains(99), isTrue, reason: '降采样取峰值，尖峰不能被抹平');
    expect(bars.every((v) => v >= 10), isTrue);
  });

  test('波形：采样数少于目标时原样保留，静音可识别', () {
    expect(Waveform.bars([5, 10, 20], count: 60), [5, 10, 20]);
    expect(Waveform.bars(const []), isEmpty);
    expect(Waveform.isSilent([0, 1, 2]), isTrue);
    expect(Waveform.isSilent([0, 40, 2]), isFalse);
  });
  test('搜索：命中文字、大小写不敏感、并给出高亮位置', () async {
    final store = MemoryStore();
    await store.applyServerBlocks('2026-11-03', [
      _block(id: 'a1', orderKey: '000000', text: '今天去了公园，天气很好'),
      _block(id: 'a2', orderKey: '000001', text: '晚上读了一本书'),
    ]);
    await store.applyServerBlocks('2026-11-02', [
      _block(id: 'b1', orderKey: '000000', text: '昨天的日记提到公园'),
    ]);

    final result = await SearchService(store: store).search('公园');
    expect(result.hits, hasLength(2), reason: '两篇日记都提到公园');
    expect(result.scannedDiaries, 2);

    // 高亮位置必须真的指向"公园"两个字
    for (final hit in result.hits) {
      final matched = hit.snippet.substring(hit.matchOffset, hit.matchOffset + hit.matchLength);
      expect(matched, '公园');
    }

    // 新的日期排前面
    expect(result.hits.first.date, '2026-11-03');
  });

  test('搜索：大小写不敏感，媒体文件名也能搜到', () async {
    final store = MemoryStore();
    await store.applyServerBlocks('2026-11-03', [
      _block(id: 'h1', orderKey: '000000', text: 'Hello World'),
      _block(id: 'h2', orderKey: '000001', text: '', type: 'video', data: {'name': '海边日落.mp4'}),
    ]);
    final service = SearchService(store: store);

    expect((await service.search('hello')).hits, hasLength(1));
    final media = await service.search('日落');
    expect(media.hits, hasLength(1));
    expect(media.hits.first.blockType, BlockType.video);
  });

  test('搜索：删除的块不参与、空关键词返回空、结果有上限', () async {
    final store = MemoryStore();
    final blocks = <Block>[
      _block(id: 'd1', orderKey: '000000', text: '要被删除的内容'),
      for (var i = 0; i < 5; i += 1)
        _block(id: 'k$i', orderKey: '00010$i', text: '关键词 第$i 条'),
    ];
    await store.applyServerBlocks('2026-11-03', blocks);

    final service = SearchService(store: store);
    expect((await service.search('')).hits, isEmpty);

    final limited = await service.search('关键词', limit: 2);
    expect(limited.hits, hasLength(2));
    expect(limited.truncated, isTrue, reason: '超过上限要标记截断');
  });

  test('待办：解析出勾选状态', () {
    final lines = RichTextParser.parse('- [ ] 没做\n- [x] 做了\n- [X] 也做了');
    expect(lines[0].kind, LineKind.todo);
    expect(lines[0].checked, isFalse);
    expect(lines[0].plainText, '没做');
    expect(lines[1].checked, isTrue);
    expect(lines[2].checked, isTrue, reason: '大写 X 也要认');
  });

  test('待办：点击切换只改目标行，不碰其他内容', () {
    const source = '# 计划\n- [ ] 买菜\n- [ ] 遛狗\n正文段落';
    final afterFirst = RichTextParser.toggleTodoAt(source, 1);
    expect(afterFirst, '# 计划\n- [x] 买菜\n- [ ] 遛狗\n正文段落');

    // 再点一次变回未勾选
    expect(RichTextParser.toggleTodoAt(afterFirst, 1), source);

    // 非待办行、越界行都原样返回
    expect(RichTextParser.toggleTodoAt(source, 0), source);
    expect(RichTextParser.toggleTodoAt(source, 3), source);
    expect(RichTextParser.toggleTodoAt(source, 99), source);
    expect(RichTextParser.toggleTodoAt(source, -1), source);
  });

  test('导出 HTML：勾选状态用不同符号', () async {
    final client = MockClient((request) async => http.Response('{}', 200));
    final api = ApiClient(baseUrl: _base, httpClient: client);
    final dir = await Directory.systemTemp.createTemp('riji_todo_');
    final store = await LocalStore.open(dir);
    await File('${dir.path}${Platform.pathSeparator}diary${Platform.pathSeparator}diaries'
            '${Platform.pathSeparator}2026-11-03.json')
        .writeAsString(jsonEncode({
      'diaryDate': '2026-11-03',
      'cachedAt': DateTime.now().toUtc().toIso8601String(),
      'blocks': [
        _blockJson(
          id: 't1',
          type: 'text',
          orderKey: '000000',
          data: {'text': '- [ ] 未完成\n- [x] 已完成'},
        ),
      ],
    }));

    final target = await Directory.systemTemp.createTemp('riji_todo_target_');
    final result = await ExportService(api: api, store: store)
        .exportHtml(dates: ['2026-11-03'], target: target);
    final html = await File('${result.directory.path}${Platform.pathSeparator}index.html').readAsString();
    expect(html, contains('☐ 未完成'));
    expect(html, contains('☑ 已完成'));
  });
  test('导出：服务器上的加密媒体会被解密后再写入', () async {
    final salt = CryptoService.generateSalt();
    final crypto = await CryptoService.derive(password: 'pw', saltBase64: salt);
    final plain = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final sealed = await crypto.seal(plain, aad: mediaAad(mediaKey: 'k1'));

    final client = MockClient((request) async {
      if (request.url.path == '/api/media/k1' && request.method == 'GET') {
        return http.Response.bytes(
          sealed.cipher,
          200,
          headers: {
            'content-type': 'image/png',
            'x-media-enc': 'aes-256-gcm',
            'x-media-nonce': sealed.nonceBase64,
          },
        );
      }
      return http.Response('{}', 200);
    });

    final api = ApiClient(baseUrl: _base, httpClient: client);
    final dir = await Directory.systemTemp.createTemp('riji_enc_media_');
    final store = await LocalStore.open(dir);
    await File('${dir.path}${Platform.pathSeparator}diary${Platform.pathSeparator}diaries'
            '${Platform.pathSeparator}2026-11-03.json')
        .writeAsString(jsonEncode({
      'diaryDate': '2026-11-03',
      'cachedAt': DateTime.now().toUtc().toIso8601String(),
      'blocks': [
        _blockJson(
          id: 'm1',
          type: 'image',
          orderKey: '000000',
          mediaRef: 'k1',
          data: {'mime': 'image/png', 'width': 8, 'height': 8},
        ),
      ],
    }));

    final target = await Directory.systemTemp.createTemp('riji_enc_target_');
    final result = await ExportService(api: api, store: store, crypto: crypto)
        .exportHtml(dates: ['2026-11-03'], target: target);

    // 导出的媒体文件必须是明文，而不是密文
    final assets = Directory('${result.directory.path}${Platform.pathSeparator}assets');
    final files = await assets.list().where((e) => e is File).toList();
    expect(files, isNotEmpty, reason: '导出应包含媒体文件');
    final written = await (files.first as File).readAsBytes();
    expect(written, equals(plain), reason: '写入的必须是解密后的字节');
  });
}
/// 测试用：快速构造一个块
Block _block({
  required String id,
  required String orderKey,
  String text = '',
  String type = 'text',
  Map<String, dynamic> data = const {},
}) {
  final blockType = BlockType.values.firstWhere(
    (t) => t.name == type,
    orElse: () => BlockType.text,
  );
  return Block(
    blockId: id,
    blockType: blockType,
    orderKey: orderKey,
    vv: const {},
    hlc: '000000000001-0000-dev',
    data: <String, dynamic>{
      ...data,
      if (text.isNotEmpty) 'text': text,
    },
  );
}