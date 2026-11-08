import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:riji_client/core/ai_summary.dart';
import 'package:riji_client/core/models.dart';

Block _block(String id, BlockType type, {String text = '', Map<String, dynamic> data = const {}}) {
  return Block(
    blockId: id,
    blockType: type,
    orderKey: '00000$id',
    vv: const {},
    hlc: '000000000001-0000-dev',
    data: <String, dynamic>{...data, if (text.isNotEmpty) 'text': text},
  );
}

void main() {
  test('拼装文本：带日期标题、正文与媒体占位', () {
    final text = TranscriptBuilder.build([
      (
        date: '2026-11-03',
        blocks: [
          _block('a', BlockType.text, text: '今天去拿了快递'),
          _block('b', BlockType.image, data: {'name': '快递.jpg'}),
        ],
      ),
      (
        date: '2026-11-04',
        blocks: [
          _block('c', BlockType.text, text: '又拿了一个快递'),
          _block('d', BlockType.audio, data: {'durationMs': 9000}),
        ],
      ),
    ]);

    expect(text, contains('## 2026-11-03'));
    expect(text, contains('今天去拿了快递'));
    expect(text, contains('[图片 快递.jpg]'));
    expect(text, contains('## 2026-11-04'));
    expect(text, contains('[语音 9秒]'));
    expect(text, contains('内容未包含在文本中'));
  });

  test('拼装文本：跳过空日记与已删除块', () {
    final text = TranscriptBuilder.build([
      (date: '2026-11-01', blocks: <Block>[]),
      (
        date: '2026-11-02',
        blocks: [
          Block(
            blockId: 'x',
            blockType: BlockType.text,
            orderKey: '1',
            vv: const {},
            hlc: 'h',
            tombstone: true,
            data: const {'text': '这条被删了'},
          ),
        ],
      ),
    ]);
    expect(text, isEmpty, reason: '没有可用内容时应返回空串');
  });

  test('接口地址归一化', () {
    AiSettings base(String url) => AiSettings(baseUrl: url, apiKey: 'k', model: 'm');
    expect(SummaryService(settings: base('https://api.deepseek.com/v1')).endpoint,
        'https://api.deepseek.com/v1/chat/completions');
    expect(SummaryService(settings: base('https://api.deepseek.com/v1/')).endpoint,
        'https://api.deepseek.com/v1/chat/completions');
    expect(SummaryService(settings: base('http://127.0.0.1:11434/v1/chat/completions')).endpoint,
        'http://127.0.0.1:11434/v1/chat/completions');
  });

  test('请求体包含模型、指令与日记文本，并正确解析回复', () async {
    late Map<String, dynamic> sent;
    late Map<String, String> headers;
    final client = MockClient((request) async {
      headers = request.headers;
      sent = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '这些天你在整理日记系统。'}
            }
          ]
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = SummaryService(
      settings: AiSettings(baseUrl: 'https://api.example.com/v1', apiKey: 'sk-123', model: 'test-model'),
      client: client,
    );
    final result = await service.summarize(
      instruction: '请总结我这些天做了什么',
      transcript: '## 2026-11-03\n今天写代码',
    );

    expect(result.text, '这些天你在整理日记系统。');
    expect(result.mediaSent, 0);
    expect(sent['model'], 'test-model');
    expect(headers['Authorization'], 'Bearer sk-123');
    final userMessage = (sent['messages'] as List).last['content'] as String;
    expect(userMessage, contains('请总结我这些天做了什么'));
    expect(userMessage, contains('2026-11-03'));
    expect(userMessage, contains('今天写代码'));
  });

  test('附带图片：以 image_url + base64 发送，并统计数量', () async {
    late Map<String, dynamic> sent;
    final client = MockClient((request) async {
      sent = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({'choices': [{'message': {'content': '看到了照片'}}]}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = SummaryService(
      settings: AiSettings(baseUrl: 'https://x/v1', apiKey: 'k', model: 'm'),
      client: client,
    );
    final result = await service.summarize(
      instruction: '看看我拍了什么',
      transcript: '## 2026-11-03\n拍了张照片',
      attachments: [
        AiAttachment(kind: 'image', mime: 'image/jpeg', bytes: [1, 2, 3, 4]),
      ],
    );

    expect(result.mediaSent, 1);
    final content = (sent['messages'] as List).last['content'] as List;
    expect(content.first['type'], 'text');
    final imagePart = content.firstWhere((e) => (e as Map)['type'] == 'image_url');
    final url = imagePart['image_url']['url'] as String;
    expect(url, startsWith('data:image/jpeg;base64,'));
    expect(url.length, greaterThan(20));
  });

  test('模型不支持图片时自动退回纯文本，不报错', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls += 1;
      if (calls == 1) {
        return http.Response('{"error":"unsupported image_url"}', 400);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final content = (body['messages'] as List).last['content'];
      expect(content, isA<String>(), reason: '退回时 content 应该是纯字符串');
      return http.Response(
        jsonEncode({'choices': [{'message': {'content': '只能看文字'}}]}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = SummaryService(
      settings: AiSettings(baseUrl: 'https://x/v1', apiKey: 'k', model: 'text-only'),
      client: client,
    );
    final result = await service.summarize(
      instruction: '总结一下',
      transcript: '## 2026-11-03\n文字内容',
      attachments: [
        AiAttachment(kind: 'image', mime: 'image/png', bytes: [9, 9]),
      ],
    );

    expect(calls, 2, reason: '应重试一次');
    expect(result.text, '只能看文字');
    expect(result.mediaSkipped, 1);
    expect(result.note, isNotNull);
  });
  test('图片抽样：不超上限时全发', () {
    final items = List<int>.generate(5, (i) => i);
    expect(MediaSampler.evenly(items, 20), items);
    expect(MediaSampler.evenly(items, 5), items);
  });

  test('图片抽样：超上限时均匀覆盖首尾', () {
    final items = List<int>.generate(100, (i) => i);
    final picked = MediaSampler.evenly(items, 10);
    expect(picked, hasLength(10));
    expect(picked.first, lessThan(10), reason: '应覆盖开头');
    expect(picked.last, greaterThan(90), reason: '应覆盖结尾');
    // 不重复
    expect(picked.toSet().length, 10);
    // 近似均匀：相邻间距接近 10
    for (var i = 1; i < picked.length; i += 1) {
      expect(picked[i] - picked[i - 1], greaterThan(5));
    }
  });

  test('图片抽样：0 或空输入返回空', () {
    expect(MediaSampler.evenly([1, 2, 3], 0), isEmpty);
    expect(MediaSampler.evenly(<int>[], 10), isEmpty);
    expect(MediaSampler.evenly([1, 2, 3], 1), hasLength(1));
  });

  test('配置：图片上限能保存与读回', () async {
    final dir = await Directory.systemTemp.createTemp('riji_ai2_');
    await AiSettings(baseUrl: 'https://x/v1', apiKey: 'k', model: 'm', maxImages: 8).save(dir);
    final loaded = await AiSettings.load(dir);
    expect(loaded.maxImages, 8);
    await dir.delete(recursive: true);
  });
  test('服务端报错时给出可读原因', () async {
    final client = MockClient((request) async => http.Response('{"error":"bad key"}', 401));
    final service = SummaryService(
      settings: AiSettings(baseUrl: 'https://api.example.com/v1', apiKey: 'x', model: 'm'),
      client: client,
    );
    await expectLater(
      service.summarize(instruction: 'x', transcript: 'y'),
      throwsA(isA<AiRequestException>()),
    );

    expect(const AiRequestException(401, '').friendly, contains('API Key'));
    expect(const AiRequestException(404, '').friendly, contains('接口地址'));
  });

  test('模型返回空内容要报错而不是返回空串', () async {
    final client = MockClient((request) async => http.Response(
          jsonEncode({'choices': []}),
          200,
          headers: {'content-type': 'application/json'},
        ));
    final service = SummaryService(
      settings: AiSettings(baseUrl: 'https://api.example.com/v1', apiKey: 'x', model: 'm'),
      client: client,
    );
    await expectLater(
      service.summarize(instruction: 'x', transcript: 'y'),
      throwsA(isA<AiRequestException>()),
    );
  });

  test('配置保存与读取（含损坏文件容错）', () async {
    final dir = await Directory.systemTemp.createTemp('riji_ai_');
    final settings = AiSettings(baseUrl: 'https://x/v1', apiKey: 'sk-abc', model: 'm1');
    await settings.save(dir);

    final loaded = await AiSettings.load(dir);
    expect(loaded.baseUrl, 'https://x/v1');
    expect(loaded.apiKey, 'sk-abc');
    expect(loaded.model, 'm1');
    expect(loaded.isConfigured, isTrue);

    // 损坏文件不应抛异常
    await File('${dir.path}${Platform.pathSeparator}ai-settings.json').writeAsString('{坏');
    final broken = await AiSettings.load(dir);
    expect(broken.isConfigured, isFalse);

    await dir.delete(recursive: true);
  });
}
