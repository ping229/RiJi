/// AI 总结所需的配置与服务（需求：接入大模型总结日记）。
///
/// 设计要点：
///   * 走 OpenAI 兼容的 /chat/completions，因此接哪家都行（OpenAI、DeepSeek、
///     通义、Kimi、本地 Ollama 等只要兼容这个协议）；
///   * 配置（地址 / 密钥 / 模型）保存在本机文件里，不上传服务器；
///   * 加密日记在客户端解密后再发给模型——服务端始终只见密文；
///   * 只发送文字内容；图片/语音/视频以占位说明代替，因为多数模型不支持。
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

class AiSettings {
  AiSettings({
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.apiKey = '',
    this.model = 'deepseek-chat',
    this.temperature = 0.3,
    this.sendImages = true,
    this.maxImages = 20,
  });

  /// 兼容 OpenAI 的接口根地址，例如：
  ///   https://api.deepseek.com/v1
  ///   https://api.openai.com/v1
  ///   http://127.0.0.1:11434/v1   （本地 Ollama）
  String baseUrl;
  String apiKey;
  String model;
  double temperature;

  /// 是否把图片一并发给模型（需要多模态模型；不支持时会自动退回纯文本）
  bool sendImages;

  /// 最多附带几张图片（0 = 不发）。超出时在整个时间段内均匀抽样
  int maxImages;

  bool get isConfigured => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'temperature': temperature,
        'sendImages': sendImages,
        'maxImages': maxImages,
      };

  static AiSettings fromJson(Map<String, dynamic> json) => AiSettings(
        baseUrl: json['baseUrl'] as String? ?? 'https://api.deepseek.com/v1',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? 'deepseek-chat',
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.3,
        sendImages: json['sendImages'] as bool? ?? true,
        maxImages: (json['maxImages'] as num?)?.toInt() ?? 20,
      );

  static Future<File> _file(Directory dir) =>
      Future.value(File('${dir.path}${Platform.pathSeparator}ai-settings.json'));

  static Future<AiSettings> load(Directory dir) async {
    try {
      final file = await _file(dir);
      if (!await file.exists()) return AiSettings();
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return AiSettings();
      return AiSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // 配置损坏就当作没配置，不能让总结功能把程序带崩
      return AiSettings();
    }
  }

  Future<void> save(Directory dir) async {
    final file = await _file(dir);
    await file.writeAsString(jsonEncode(toJson()), flush: true);
  }
}

/// 把一段时间内的日记拼成大模型能读的文本
class TranscriptBuilder {
  /// [diaries] 按日期升序传入；返回带时间戳的纯文本
  static String build(List<({String date, List<Block> blocks})> diaries) {
    final buffer = StringBuffer();
    for (final diary in diaries) {
      final texts = <String>[];
      final media = <String>[];
      for (final block in diary.blocks) {
        if (block.tombstone) continue;
        switch (block.blockType) {
          case BlockType.text:
            final text = block.text.trim();
            if (text.isNotEmpty) texts.add(text);
          case BlockType.image:
            media.add('[图片 ${block.data['name'] ?? ''}]'.replaceAll(' ]', ']'));
          case BlockType.audio:
            final ms = block.data['durationMs'];
            final secs = ms is int ? (ms / 1000).round() : 0;
            media.add('[语音 ${secs}秒]');
          case BlockType.video:
            final ms = block.data['durationMs'];
            final secs = ms is int ? (ms / 1000).round() : 0;
            media.add('[视频 ${secs}秒]');
          case BlockType.divider:
            break;
        }
      }
      if (texts.isEmpty && media.isEmpty) continue;

      buffer.writeln('## ${diary.date}');
      for (final text in texts) {
        buffer.writeln(text);
      }
      if (media.isNotEmpty) {
        buffer.writeln('（本篇还包含：${media.join('、')}，内容未包含在文本中）');
      }
      buffer.writeln();
    }
    return buffer.toString().trim();
  }
}

class SummaryService {
  SummaryService({required this.settings, http.Client? client})
      : _client = client ?? http.Client();

  final AiSettings settings;
  final http.Client _client;

  /// 归一化接口地址：用户可能只填域名，这里补成 /chat/completions
  String get endpoint {
    var base = settings.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/chat/completions')) return base;
    return '$base/chat/completions';
  }

  /// 发送总结请求，返回模型输出文本
  Future<AiSummaryResult> summarize({
    required String instruction,
    required String transcript,
    List<AiAttachment> attachments = const [],
    Duration timeout = const Duration(seconds: 180),
  }) async {
    final system = '你是一个帮助用户回顾日记的助手。'
        '用户会给你一段时间内带日期的日记文本，可能还附带日记里的照片。'
        '请严格依据给定内容回答，不要编造；没有相关信息就直说没有记录到。';

    final userContent = '时间范围：${_rangeHint(transcript)}\n\n'
        '以下是日记原文（按日期排列，每篇以“## 日期”开头）：\n\n'
        '$transcript\n\n'
        '我的要求：$instruction';

    // 先尝试带媒体；如果模型不支持，再退回纯文本重试一次
    if (attachments.isNotEmpty) {
      try {
        final text = await _request(
          system: system,
          userContent: userContent,
          attachments: attachments,
          timeout: timeout,
        );
        return AiSummaryResult(text: text, mediaSent: attachments.length, mediaSkipped: 0);
      } on AiRequestException catch (e) {
        // 4xx 多半是"这个模型不支持图片/音频"，退回纯文本再试一次
        final retriable = e.statusCode >= 400 && e.statusCode < 500;
        if (!retriable) rethrow;
        final text = await _request(
          system: system,
          userContent: '$userContent\n\n（注：本次未能附带照片或音频，模型可能不支持多模态输入）',
          attachments: const [],
          timeout: timeout,
        );
        return AiSummaryResult(
          text: text,
          mediaSent: 0,
          mediaSkipped: attachments.length,
          note: '这个模型没有接受图片/音频，已改为只发文字（${_reasonOf(e)}）',
        );
      }
    }

    final text = await _request(
      system: system,
      userContent: userContent,
      attachments: const [],
      timeout: timeout,
    );
    return AiSummaryResult(text: text, mediaSent: 0, mediaSkipped: 0);
  }

  String _reasonOf(AiRequestException e) {
    if (e.statusCode == 401) return 'API Key 无效';
    if (e.statusCode == 403) return '没有该模型的权限';
    if (e.statusCode == 404) return '接口或模型名不对';
    if (e.statusCode == 429) return '额度或频率受限';
    return 'HTTP ${e.statusCode}';
  }

  Future<String> _request({
    required String system,
    required String userContent,
    required List<AiAttachment> attachments,
    required Duration timeout,
  }) async {
    // 有媒体时 content 用数组（OpenAI 多模态格式），否则用纯字符串以兼容更多服务
    final Object content = attachments.isEmpty
        ? userContent
        : [
            {'type': 'text', 'text': userContent},
            for (final a in attachments)
              if (a.kind == 'image')
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:${a.mime};base64,${base64Encode(a.bytes)}'},
                }
              else
                {
                  'type': 'input_audio',
                  'input_audio': {'data': base64Encode(a.bytes), 'format': a.audioFormat},
                },
          ];

    final body = jsonEncode({
      'model': settings.model,
      'temperature': settings.temperature,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': content},
      ],
      'stream': false,
    });

    final response = await _client
        .post(
          Uri.parse(endpoint),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${settings.apiKey}',
          },
          body: body,
        )
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiRequestException(
        response.statusCode,
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final choices = (decoded is Map<String, dynamic>) ? decoded['choices'] : null;
    if (choices is! List || choices.isEmpty) {
      throw const AiRequestException(0, '模型没有返回内容，检查接口地址与模型名是否正确');
    }
    final message = (choices.first as Map<String, dynamic>)['message'];
    final text = (message is Map<String, dynamic>) ? message['content'] : null;
    if (text is! String || text.trim().isEmpty) {
      throw const AiRequestException(0, '模型返回了空内容');
    }
    return text.trim();
  }
  String _rangeHint(String transcript) {
    final dates = RegExp(r'^## (\d{4}-\d{2}-\d{2})$', multiLine: true)
        .allMatches(transcript)
        .map((m) => m.group(1)!)
        .toList();
    if (dates.isEmpty) return '（无内容）';
    if (dates.length == 1) return dates.first;
    return '${dates.first} 至 ${dates.last}，共 ${dates.length} 天有记录';
  }
}

/// 媒体抽样：图片太多时不要只取前几张，而是在整个时间段里均匀取，
/// 保证月初到月底都有代表，而不是永远只有开头那几天。
class MediaSampler {
  static List<T> evenly<T>(List<T> items, int max) {
    if (max <= 0 || items.isEmpty) return const [];
    if (items.length <= max) return List<T>.of(items);
    final out = <T>[];
    for (var i = 0; i < max; i += 1) {
      final index = (((i + 0.5) * items.length) / max).floor().clamp(0, items.length - 1);
      out.add(items[index]);
    }
    return out;
  }
}

/// 随请求一起发送的媒体（图片 / 音频）
class AiAttachment {
  const AiAttachment({
    required this.kind,
    required this.mime,
    required this.bytes,
    this.audioFormat = 'wav',
  });

  /// 'image' 或 'audio'
  final String kind;
  final String mime;
  final List<int> bytes;

  /// 音频格式：wav / mp3（服务端只认这两种）
  final String audioFormat;
}

class AiSummaryResult {
  AiSummaryResult({
    required this.text,
    required this.mediaSent,
    required this.mediaSkipped,
    this.note,
  });

  final String text;
  final int mediaSent;
  final int mediaSkipped;

  /// 退回到纯文本时给用户的说明
  final String? note;
}

class AiRequestException implements Exception {
  const AiRequestException(this.statusCode, this.body);

  final int statusCode;

  /// 服务端返回的原始内容（可能很长，展示时截断）
  final String body;

  String get friendly {
    if (statusCode == 401) return 'API Key 无效或已过期';
    if (statusCode == 403) return '这个 Key 没有调用该模型的权限';
    if (statusCode == 404) return '接口地址不对，检查是否少了 /v1 或模型名写错';
    if (statusCode == 429) return '请求太频繁或额度用完了，稍后再试';
    if (statusCode >= 500) return '模型服务暂时不可用，稍后重试';
    final trimmed = body.length > 300 ? '${body.substring(0, 300)}…' : body;
    return '调用失败（HTTP $statusCode）：$trimmed';
  }

  @override
  String toString() => friendly;
}
