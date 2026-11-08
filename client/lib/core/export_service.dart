/// 导出服务：生成可离线阅读的 HTML 包与 Markdown 包。
///
/// 为什么不用 PDF/DOCX 承载媒体：它们无法内联播放音视频，
/// 与"媒体是内容的一部分"的核心设计冲突（需求 3.5.1）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'api_client.dart';
import 'crypto_service.dart';
import 'local_store.dart';
import 'models.dart';
import 'rich_text.dart';

/// 四种导出格式（需求 3.5.3）
enum ExportFormat {
  html('HTML 包'),
  markdown('Markdown 包'),
  pdf('PDF'),
  zip('平台归档 ZIP');

  const ExportFormat(this.label);

  final String label;
}

class ExportResult {
  ExportResult({
    required this.directory,
    required this.diaryCount,
    required this.mediaCount,
    required this.failures,
  });

  final Directory directory;
  final int diaryCount;
  final int mediaCount;
  final List<String> failures;

  String get summary =>
      '导出完成：$diaryCount 篇日记，$mediaCount 个媒体文件'
      '${failures.isEmpty ? '' : '，${failures.length} 个媒体失败'}';
}

typedef ExportProgress = void Function(int done, int total, String label);

/// 导出被用户取消
class ExportCancelled implements Exception {
  const ExportCancelled();
  @override
  String toString() => '导出已取消';
}

/// 取消令牌：界面点"取消"时置位，导出循环每步检查
class ExportCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const ExportCancelled();
  }
}

class ExportService {
  ExportService({required this.api, required this.store, this.crypto});

  final ApiClient api;
  final DiaryStore store;

  /// 启用端到端加密时，用于解开服务器返回的媒体密文
  final CryptoService? crypto;

  static String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

  /// 生成 HTML 自包含包：index.html + style.css + assets/
  Future<ExportResult> exportHtml({
    required List<String> dates,
    required Directory target,
    String? username,
    ExportProgress? onProgress,
    ExportCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final folder = await _prepareFolder(target, dates, username, 'HTML');
    final assetsDir = Directory(_join(folder.path, 'assets'));
    await assetsDir.create(recursive: true);

    final articles = <String>[];
    final toc = <String>[];
    var mediaCount = 0;
    final failures = <String>[];
    final sorted = [...dates]..sort();

    for (var i = 0; i < sorted.length; i += 1) {
      final date = sorted[i];
      cancellation?.throwIfCancelled();
      onProgress?.call(i, sorted.length, date);
      final blocks = await _blocksFor(date);
      if (blocks.isEmpty) continue;

      toc.add('<li><a href="#d-$date">${_dateLabel(date)}</a></li>');
      final body = StringBuffer();
      for (final block in blocks) {
        switch (block.blockType) {
          case BlockType.text:
            if (block.text.trim().isEmpty) continue;
            body.writeln(_richHtml(block.text));
          case BlockType.image:
            final file = await _asset(block, assetsDir, failures);
            if (file != null) {
              mediaCount += 1;
              body.writeln(
                '<figure><img src="assets/${_escape(file)}" alt="${_escape(block.fileName ?? '插图')}" loading="lazy"></figure>',
              );
            }
          case BlockType.audio:
            final file = await _asset(block, assetsDir, failures);
            if (file != null) {
              mediaCount += 1;
              body.writeln(
                '<figure class="audio"><audio controls preload="metadata" src="assets/${_escape(file)}"></audio>'
                '<figcaption>语音 ${_durationLabel(block.durationMs)}</figcaption></figure>',
              );
            }
          case BlockType.video:
            final file = await _asset(block, assetsDir, failures);
            if (file != null) {
              mediaCount += 1;
              body.writeln(
                '<figure class="video"><video controls playsinline preload="metadata" src="assets/${_escape(file)}"></video>'
                '<figcaption>视频 ${_durationLabel(block.durationMs)}</figcaption></figure>',
              );
            }
          case BlockType.divider:
            body.writeln('<hr>');
        }
      }

      articles.add(
        '<article id="d-$date"><h2>${_dateLabel(date)}</h2>$body</article>',
      );
    }

    final html = '''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>日记导出</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<header>
  <h1>日记</h1>
  <p class="meta">导出时间 ${DateTime.now().toString().substring(0, 19)} · 共 ${articles.length} 篇</p>
</header>
<nav><ul>${toc.join()}</ul></nav>
<main>
${articles.join('\n')}
</main>
</body>
</html>
''';

    await File(_join(folder.path, 'index.html')).writeAsString(html, encoding: utf8);
    await File(_join(folder.path, 'style.css')).writeAsString(_stylesheet, encoding: utf8);
    onProgress?.call(sorted.length, sorted.length, '完成');

    return ExportResult(
      directory: folder,
      diaryCount: articles.length,
      mediaCount: mediaCount,
      failures: failures,
    );
  }

  /// 生成 Markdown 包：每篇一个 .md + assets/
  Future<ExportResult> exportMarkdown({
    required List<String> dates,
    required Directory target,
    String? username,
    ExportProgress? onProgress,
    ExportCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final folder = await _prepareFolder(target, dates, username, 'Markdown');
    final assetsDir = Directory(_join(folder.path, 'assets'));
    await assetsDir.create(recursive: true);

    var count = 0;
    var mediaCount = 0;
    final failures = <String>[];
    final sorted = [...dates]..sort();

    for (var i = 0; i < sorted.length; i += 1) {
      final date = sorted[i];
      cancellation?.throwIfCancelled();
      onProgress?.call(i, sorted.length, date);
      final blocks = await _blocksFor(date);
      if (blocks.isEmpty) continue;

      final md = StringBuffer();
      md.writeln('---');
      md.writeln('date: $date');
      md.writeln('---');
      md.writeln();
      md.writeln('# $date');
      md.writeln();

      for (final block in blocks) {
        switch (block.blockType) {
          case BlockType.text:
            if (block.text.trim().isEmpty) continue;
            md.writeln(block.text);
            md.writeln();
          case BlockType.image:
            final file = await _asset(block, assetsDir, failures);
            if (file != null) {
              mediaCount += 1;
              md.writeln('![${block.fileName ?? '图片'}](assets/$file)');
              md.writeln();
            }
          case BlockType.audio:
            final file = await _asset(block, assetsDir, failures);
            if (file != null) {
              mediaCount += 1;
              md.writeln('🎙 [语音 ${_durationLabel(block.durationMs)}](assets/$file)');
              md.writeln();
            }
          case BlockType.video:
            final file = await _asset(block, assetsDir, failures);
            if (file != null) {
              mediaCount += 1;
              md.writeln('🎬 [视频 ${_durationLabel(block.durationMs)}](assets/$file)');
              md.writeln();
            }
          case BlockType.divider:
            md.writeln('---');
            md.writeln();
        }
      }

      await File(_join(folder.path, '$date.md')).writeAsString(md.toString(), encoding: utf8);
      count += 1;
    }

    onProgress?.call(sorted.length, sorted.length, '完成');
    return ExportResult(
      directory: folder,
      diaryCount: count,
      mediaCount: mediaCount,
      failures: failures,
    );
  }

  /// 生成 PDF：文本与图片正常排版，音视频以占位框说明（需求 3.5.3 格式三）。
  ///
  /// 必须内嵌中文字体，否则中文会是空白方块。
  Future<ExportResult> exportPdf({
    required List<String> dates,
    required Directory target,
    String? username,
    ExportProgress? onProgress,
    ExportCancellation? cancellation,
  }) async {
    final font = await _loadCjkFont();
    final doc = pw.Document(title: '日记导出', author: 'RiJi');

    final bodyStyle = font == null ? null : pw.TextStyle(font: font, fontSize: 11, lineSpacing: 5);
    final headingStyle =
        font == null ? null : pw.TextStyle(font: font, fontSize: 18, fontWeight: pw.FontWeight.bold);
    final smallStyle =
        font == null ? null : pw.TextStyle(font: font, fontSize: 8.5, color: PdfColors.grey700);

    final failures = <String>[];
    var count = 0;
    var mediaCount = 0;
    final sorted = [...dates]..sort();

    for (var i = 0; i < sorted.length; i += 1) {
      final date = sorted[i];
      cancellation?.throwIfCancelled();
      onProgress?.call(i, sorted.length, date);
      final blocks = await _blocksFor(date);
      if (blocks.isEmpty) continue;

      final content = <pw.Widget>[
        pw.Text(_dateLabel(date), style: headingStyle),
        pw.SizedBox(height: 14),
      ];

      for (final block in blocks) {
        switch (block.blockType) {
          case BlockType.text:
            if (block.text.trim().isEmpty) continue;
            content.add(pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 10),
              child: pw.Text(block.text, style: bodyStyle),
            ));
          case BlockType.image:
            final key = block.mediaRef;
            if (key == null) continue;
            final bytes = await _mediaBytes(key, failures);
            if (bytes == null) continue;
            try {
              content.add(pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 12),
                child: pw.Image(pw.MemoryImage(bytes), height: 220, fit: pw.BoxFit.contain),
              ));
              mediaCount += 1;
            } catch (_) {
              failures.add(key);
            }
          case BlockType.audio:
          case BlockType.video:
            mediaCount += 1;
            final label = block.blockType == BlockType.audio ? '语音' : '视频';
            content.add(pw.Container(
              width: double.infinity,
              margin: const pw.EdgeInsets.only(bottom: 10),
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey400),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    '$label 占位 — ${block.fileName ?? ''} ${_durationLabel(block.durationMs)}'.trim(),
                    style: bodyStyle,
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    '媒体未包含在 PDF 中。需要完整媒体请使用 HTML 自包含包或平台归档 ZIP。',
                    style: smallStyle,
                  ),
                ],
              ),
            ));
          case BlockType.divider:
            content.add(pw.Divider(color: PdfColors.grey400));
        }
      }

      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(42, 42, 42, 42),
          theme: font == null ? null : pw.ThemeData.withFont(base: font),
          footer: (context) => pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              '${date} · 第 ${context.pageNumber} / ${context.pagesCount} 页',
              style: smallStyle,
            ),
          ),
          build: (_) => content,
        ),
      );
      count += 1;
    }

    if (count == 0) {
      doc.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: font == null ? null : pw.ThemeData.withFont(base: font),
        build: (_) => [pw.Text('没有可导出的日记', style: bodyStyle)],
      ));
    }

    cancellation?.throwIfCancelled();
    final file = await _prepareFile(target, sorted, username, 'PDF', 'pdf');
    await file.writeAsBytes(await doc.save(), flush: true);
    onProgress?.call(sorted.length, sorted.length, '完成');

    return ExportResult(
      directory: target,
      diaryCount: count,
      mediaCount: mediaCount,
      failures: failures,
    );
  }

  /// 生成平台归档 ZIP：manifest + entries + media + README（需求 3.5.3 格式四）
  Future<ExportResult> exportZip({
    required List<String> dates,
    required Directory target,
    String? username,
    ExportProgress? onProgress,
    ExportCancellation? cancellation,
  }) async {
    final archive = Archive();
    final failures = <String>[];
    final sorted = [...dates]..sort();
    final exportedDates = <String>[];
    final mediaNames = <String>[];
    var count = 0;

    for (var i = 0; i < sorted.length; i += 1) {
      final date = sorted[i];
      cancellation?.throwIfCancelled();
      onProgress?.call(i, sorted.length, date);
      final blocks = await _blocksFor(date);
      if (blocks.isEmpty) continue;

      final entry = {
        'diaryDate': date,
        'blocks': blocks
            .map((b) => {
                  'blockId': b.blockId,
                  'blockType': b.blockType.name,
                  'orderKey': b.orderKey,
                  'hlc': b.hlc,
                  'versionVector': b.vv,
                  'mediaRef': b.mediaRef,
                  'mime': b.mime,
                  'durationMs': b.durationMs,
                  'width': b.width,
                  'height': b.height,
                  if (b.blockType == BlockType.text) 'text': b.text,
                })
            .toList(),
      };

      const encoder = JsonEncoder.withIndent('  ');
      archive.addFile(ArchiveFile.string('entries/$date.json', encoder.convert(entry)));
      exportedDates.add(date);
      count += 1;

      for (final block in blocks) {
        final key = block.mediaRef;
        if (key == null) continue;
        final name = '$key.${_extensionFor(block.mime)}';
        if (mediaNames.contains(name)) continue;
        final bytes = await _mediaBytes(key, failures);
        if (bytes == null) continue;
        archive.addFile(ArchiveFile.bytes('media/$name', bytes));
        mediaNames.add(name);
      }
    }

    final manifest = {
      'formatVersion': '1.0',
      'generator': 'RiJi',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'user': _maskUser(username),
      'diaryCount': count,
      'mediaCount': mediaNames.length,
      'entries': exportedDates,
      'media': mediaNames,
    };
    archive.addFile(ArchiveFile.string('manifest.json', const JsonEncoder.withIndent('  ').convert(manifest)));
    archive.addFile(ArchiveFile.string('README.txt', _zipReadme));

    cancellation?.throwIfCancelled();
    final file = await _prepareFile(target, sorted, username, '归档', 'zip');
    final bytes = ZipEncoder().encodeBytes(archive);
    await file.writeAsBytes(bytes, flush: true);
    onProgress?.call(sorted.length, sorted.length, '完成');

    return ExportResult(
      directory: target,
      diaryCount: count,
      mediaCount: mediaNames.length,
      failures: failures,
    );
  }

  // ------------------------------------------------------------------ 内部

  /// PDF 需要内嵌中文字体，否则中文会渲染成方块。
  /// 优先用系统自带的黑体，找不到就退回内置拉丁字体（此时只能显示英文）。
  static pw.Font? _cachedCjkFont;
  static bool _cjkLookupDone = false;

  static Future<pw.Font?> _loadCjkFont() async {
    if (_cjkLookupDone) return _cachedCjkFont;
    _cjkLookupDone = true;

    final candidates = <String>[
      if (Platform.isWindows) ...[
        r'C:\Windows\Fonts\simhei.ttf',
        r'C:\Windows\Fonts\Deng.ttf',
        r'C:\Windows\Fonts\simfang.ttf',
        r'C:\Windows\Fonts\simkai.ttf',
      ],
      if (!Platform.isWindows) ...[
        '/system/fonts/DroidSansFallback.ttf',
        '/system/fonts/NotoSansSC-Regular.ttf',
        '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc',
      ],
    ];

    for (final path in candidates) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        _cachedCjkFont = pw.Font.ttf(ByteData.view(bytes.buffer));
        return _cachedCjkFont;
      } catch (_) {
        // 换下一个候选
      }
    }
    return null;
  }

  /// 取媒体字节：优先本地缓存，其次从服务器拉取。
  /// 失败时记入 failures 并返回 null——导出要继续，不能因为一个文件中断整篇。
  Future<Uint8List?> _mediaBytes(String key, List<String> failures) async {
    final cached = await store.readMedia(key);
    if (cached != null) return cached;
    try {
      final blob = await api.downloadMediaBlob(key);
      var bytes = blob.bytes;
      // 服务器返回的可能是密文：必须先解密，否则导出的图片/视频是坏数据
      if (blob.isEncrypted) {
        final mediaCrypto = crypto;
        if (mediaCrypto == null || blob.nonce == null) {
          failures.add('\：已加密但本机没有密钥');
          return null;
        }
        bytes = await mediaCrypto.open(
          cipher: blob.bytes,
          nonce: base64Decode(blob.nonce!),
          aad: mediaAad(mediaKey: key),
        );
      }
      await store.cacheMedia(key, bytes);
      return bytes;
    } catch (e) {
      failures.add('$key：$e');
      return null;
    }
  }

  Future<List<Block>> _blocksFor(String date) async {
    final cached = await store.readBlocks(date);
    if (cached != null) return cached;
    final remote = await api.getDiary(date);
    if (remote == null) return const [];
    await store.applyServerBlocks(date, remote.blocks);
    return remote.blocks;
  }

  Future<String?> _asset(Block block, Directory assetsDir, List<String> failures) async {
    final key = block.mediaRef;
    if (key == null) return null;
    final name = '$key.${_extensionFor(block.mime)}';
    final target = File(_join(assetsDir.path, name));
    if (await target.exists()) return name;
    try {
      final bytes = await _mediaBytes(key, failures);
      if (bytes == null) return null;
      await target.writeAsBytes(bytes, flush: true);
      return name;
    } catch (_) {
      failures.add('${block.blockType.name} $key');
      return null;
    }
  }

  Future<Directory> _prepareFolder(
    Directory target,
    List<String> dates,
    String? username,
    String kind,
  ) async {
    final sortedDates = [...dates]..sort();
    final from = sortedDates.isEmpty ? '' : sortedDates.first;
    final to = sortedDates.isEmpty ? '' : sortedDates.last;
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    // 只用数字，避免任何平台上的非法字符（空格、冒号都会出问题）
    final stamp = '${now.year}${two(now.month)}${two(now.day)}'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final safeUser = (username == null || username.isEmpty)
        ? '用户'
        : '${username.substring(0, 1)}··';
    final name = _sanitizeFileName('日记导出_${safeUser}_${from}_${to}_$stamp$kind');
    final dir = Directory(_join(target.path, name));
    await dir.create(recursive: true);
    return dir;
  }

  /// 单文件导出（PDF / ZIP）的落盘路径
  Future<File> _prepareFile(
    Directory target,
    List<String> dates,
    String? username,
    String kind,
    String extension,
  ) async {
    final sortedDates = [...dates]..sort();
    final from = sortedDates.isEmpty ? '' : sortedDates.first;
    final to = sortedDates.isEmpty ? '' : sortedDates.last;
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final name = _sanitizeFileName('日记导出_${_maskUser(username)}_${from}_${to}_$stamp$kind');
    await target.create(recursive: true);
    return File('${target.path}${Platform.pathSeparator}$name.$extension');
  }

  static String _maskUser(String? username) =>
      (username == null || username.isEmpty) ? '用户' : '${username.substring(0, 1)}··';

  static const _zipReadme = '''
RiJi 日记平台 · 平台归档包
================================

这个压缩包保留了日记的完整块结构与原始媒体，供长期归档、平台迁移和故障排查使用。
它不是给人直接阅读的格式；想直接阅读请用同一次导出生成的 HTML 自包含包。

目录结构
--------
manifest.json
    导出时间、用户标识（已脱敏）、日记数量、媒体数量、格式版本号。

entries/YYYY-MM-DD.json
    每篇日记的完整块序列。字段说明：
      blockId       块 ID（稳定，跨设备一致）
      blockType     text / image / audio / video / divider
      orderKey      块的排序键（字典序即正文顺序）
      text          仅文本块有，正文内容
      mediaRef      媒体块指向 media/ 目录里的文件名前缀
      mime          媒体类型
      durationMs    音视频时长（毫秒）
      width/height  图片与视频的尺寸
      hlc           混合逻辑时钟，用于冲突仲裁
      versionVector 版本向量，用于判断并发修改

media/
    原始媒体文件，按内容哈希命名，同一文件只存一份。

解析建议
--------
1. 读 manifest.json 确认 formatVersion。
2. 遍历 entries/ 下每个 JSON，把 blocks 按 orderKey 升序排列即为正文顺序。
3. 媒体块用 mediaRef 前缀在 media/ 里找对应文件。

注意：导出的内容是明文，不再受平台加密保护，请妥善保管。
''';

  /// 把标记文本转成 HTML，保持粗体/标题/列表等排版（需求 3.2）
  static String _richHtml(String source) {
    final buffer = StringBuffer();
    String? openTag;

    void closeList() {
      if (openTag != null) {
        buffer.writeln('</$openTag>');
        openTag = null;
      }
    }

    String inline(List<RichSpan> spans) {
      final out = StringBuffer();
      for (final span in spans) {
        var text = _escape(span.text);
        if (span.code) text = '<code>${text}</code>';
        if (span.bold) text = '<strong>$text</strong>';
        if (span.italic) text = '<em>$text</em>';
        if (span.underline) text = '<u>$text</u>';
        if (span.strike) text = '<del>$text</del>';
        if (span.link != null) {
          text = '<a href="${_escape(span.link!)}" rel="noreferrer">$text</a>';
        }
        out.write(text);
      }
      return out.toString();
    }

    for (final line in RichTextParser.parse(source)) {
      switch (line.kind) {
        case LineKind.bullet:
          if (openTag != 'ul') {
            closeList();
            buffer.writeln('<ul>');
            openTag = 'ul';
          }
          buffer.writeln('<li>${inline(line.spans)}</li>');
        case LineKind.ordered:
          if (openTag != 'ol') {
            closeList();
            buffer.writeln('<ol>');
            openTag = 'ol';
          }
          buffer.writeln('<li>${inline(line.spans)}</li>');
        case LineKind.heading1:
          closeList();
          buffer.writeln('<h1>${inline(line.spans)}</h1>');
        case LineKind.heading2:
          closeList();
          buffer.writeln('<h2>${inline(line.spans)}</h2>');
        case LineKind.quote:
          closeList();
          buffer.writeln('<blockquote>${inline(line.spans)}</blockquote>');
        case LineKind.code:
          closeList();
          buffer.writeln('<pre>${_escape(line.plainText)}</pre>');
        case LineKind.divider:
          closeList();
          buffer.writeln('<hr>');
        case LineKind.todo:
          closeList();
          final mark = (line.checked ?? false) ? '☑' : '☐';
          buffer.writeln('<p>$mark ${inline(line.spans)}</p>');
        case LineKind.paragraph:
          closeList();
          if (line.plainText.trim().isEmpty) {
            buffer.writeln('<p class="blank"></p>');
          } else {
            buffer.writeln('<p>${inline(line.spans)}</p>');
          }
      }
    }
    closeList();
    return buffer.toString();
  }

  static String _escape(String input) => input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// Windows 不允许 < > : " / \ | ? * 出现在文件名里，统一替换掉
  static String _sanitizeFileName(String name) =>
      name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

  static String _dateLabel(String isoDate) {
    final parts = isoDate.split('-');
    if (parts.length != 3) return isoDate;
    return '${parts[0]} 年 ${int.parse(parts[1])} 月 ${int.parse(parts[2])} 日';
  }

  static String _durationLabel(int? ms) {
    if (ms == null || ms <= 0) return '';
    final totalSeconds = (ms / 1000).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '· $minutes 分 $seconds 秒';
  }

  static String _extensionFor(String mime) {
    switch (mime.toLowerCase()) {
      case 'image/png':
        return 'png';
      case 'image/gif':
        return 'gif';
      case 'image/webp':
        return 'webp';
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'audio/mp4':
      case 'audio/m4a':
      case 'audio/aac':
        return 'm4a';
      case 'audio/mpeg':
        return 'mp3';
      case 'audio/ogg':
        return 'ogg';
      case 'video/mp4':
        return 'mp4';
      case 'video/webm':
        return 'webm';
      default:
        return 'bin';
    }
  }

  static const _stylesheet = '''
:root {
  --ink: #2b2b2b;
  --muted: #7a7a7a;
  --paper: #faf8f3;
  --line: #e2ddd2;
  --accent: #6b7f5e;
}
* { box-sizing: border-box; }
body {
  margin: 0 auto;
  padding: 40px 20px 80px;
  max-width: 760px;
  background: var(--paper);
  color: var(--ink);
  font-family: "Microsoft YaHei", "PingFang SC", "Noto Sans SC", system-ui, sans-serif;
  line-height: 1.8;
  font-size: 17px;
}
header h1 { font-size: 30px; margin: 0 0 6px; letter-spacing: 2px; }
header .meta { color: var(--muted); font-size: 13px; margin: 0 0 28px; }
nav ul { list-style: none; padding: 0; display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 32px; }
nav a {
  display: inline-block; padding: 4px 12px; border-radius: 999px;
  background: #fff; border: 1px solid var(--line);
  color: var(--ink); text-decoration: none; font-size: 13px;
}
nav a:hover { border-color: var(--accent); color: var(--accent); }
article { border-top: 1px solid var(--line); padding-top: 28px; margin-top: 36px; }
article h2 { font-size: 20px; color: var(--accent); margin: 0 0 16px; }
article p { white-space: pre-wrap; margin: 0 0 18px; }
figure { margin: 22px 0; }
figure img, figure video { width: 100%; border-radius: 10px; display: block; }
figure audio { width: 100%; }
figcaption { color: var(--muted); font-size: 13px; margin-top: 8px; }
hr { border: none; border-top: 1px solid var(--line); margin: 28px 0; }
''';
}
