import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/ai_summary.dart';
import '../core/image_utils.dart';
import '../core/media_service.dart';
import '../core/models.dart';
import '../core/session_store.dart';
import '../core/sync_service.dart';

/// AI 总结页：选时间段 + 写指令 → 把日记发给大模型 → 显示结果。
class SummaryPage extends StatefulWidget {
  const SummaryPage({super.key, required this.sync});

  final SyncService sync;

  @override
  State<SummaryPage> createState() => _SummaryPageState();
}

class _SummaryPageState extends State<SummaryPage> {
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _model = TextEditingController();
  final TextEditingController _prompt = TextEditingController();

  AiSettings? _settings;
  DateTime _start = DateTime.now().subtract(const Duration(days: 30));
  DateTime _end = DateTime.now();
  bool _showSettings = false;
  bool _sendImages = true;
  bool _busy = false;
  String _progress = '';
  String? _result;
  String? _resultNote;
  String _mediaSummary = '';
  int _maxImages = 20;
  String? _error;

  static const _presets = [
    '请总结我这些天做了什么',
    '请按主题分类总结这些天的记录',
    '这些天我拿了多少次快递？请数一下并列出日期',
    '这些天我的心情怎么样？',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = await SessionStore.open();
    final settings = await AiSettings.load(store.dir);
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _baseUrl.text = settings.baseUrl;
      _apiKey.text = settings.apiKey;
      _model.text = settings.model;
      _sendImages = settings.sendImages;
      _maxImages = settings.maxImages;
      _showSettings = !settings.isConfigured;
    });
  }

  Future<void> _saveSettings() async {
    final settings = AiSettings(
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      model: _model.text.trim(),
      sendImages: _sendImages,
      maxImages: _maxImages,
    );
    final store = await SessionStore.open();
    await settings.save(store.dir);
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _showSettings = !settings.isConfigured;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(settings.isConfigured ? '配置已保存在本机' : '还缺 API Key，保存了也不能用')),
    );
  }

  String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _start : _end,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      helpText: isStart ? '开始日期' : '结束日期',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _start = picked;
        if (_start.isAfter(_end)) _end = picked;
      } else {
        _end = picked;
        if (_end.isBefore(_start)) _start = picked;
      }
    });
  }

  /// 收集所选时间段里的图片：先数清楚有多少张，再均匀抽样下载。
  /// 这样"共 N 张、实际发送 M 张"是准确的，也不会因为图片太多而全部下载。
  Future<({List<AiAttachment> attachments, int total})> _collectImages(
    List<({String date, List<Block> blocks})> diaries,
    int maxImages,
  ) async {
    if (maxImages <= 0) return (attachments: const <AiAttachment>[], total: 0);

    // 先收集所有候选（只记引用，不下载）
    final candidates = <({int order, String ref, String mime})>[];
    var order = 0;
    for (final diary in diaries) {
      for (final block in diary.blocks) {
        final ref = block.mediaRef;
        if (ref == null || block.blockType != BlockType.image) continue;
        candidates.add((
          order: order++,
          ref: ref,
          mime: (block.data['mime'] as String?) ?? 'image/jpeg',
        ));
      }
    }
    final total = candidates.length;
    if (total == 0) return (attachments: const <AiAttachment>[], total: 0);

    final picked = MediaSampler.evenly(candidates, maxImages);
    final media = MediaService(
      api: widget.sync.api,
      store: widget.sync.store,
      crypto: widget.sync.crypto,
    );

    final attachments = <AiAttachment>[];
    var totalBytes = 0;
    const maxTotalBytes = 20 * 1024 * 1024; // 防止请求体过大导致超时

    for (final candidate in picked) {
      if (totalBytes >= maxTotalBytes) break;
      try {
        final bytes = await media.bytesFor(candidate.ref);
        if (bytes.isEmpty) continue;
        final prepared = ImageUtils.prepare(bytes, maxEdge: 1024);
        attachments.add(AiAttachment(
          kind: 'image',
          mime: prepared.resized ? 'image/jpeg' : candidate.mime,
          bytes: prepared.display,
        ));
        totalBytes += prepared.display.length;
      } catch (_) {
        // 单张取不到就跳过，不影响整体总结
      }
    }
    return (attachments: attachments, total: total);
  }
  Future<void> _run() async {
    final settings = _settings;
    if (settings == null || !settings.isConfigured) {
      setState(() => _showSettings = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先填好接口地址、API Key 和模型名')),
      );
      return;
    }
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('写一句你想让模型做什么')));
      return;
    }
    if (_end.difference(_start).inDays > 400) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('时间段太长，请控制在 400 天以内')));
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _progress = '正在读取日记…';
    });

    try {
      final diaries = <({String date, List<Block> blocks})>[];
      var cursor = _start;
      var index = 0;
      final total = _end.difference(_start).inDays + 1;
      while (!cursor.isAfter(_end)) {
        index += 1;
        if (index % 5 == 0 && mounted) {
          setState(() => _progress = '正在读取日记 $index/$total…');
        }
        final date = _fmt(cursor);
        final blocks = await widget.sync.loadDiary(date);
        if (blocks != null && blocks.isNotEmpty) {
          diaries.add((date: date, blocks: blocks));
        }
        cursor = cursor.add(const Duration(days: 1));
      }

      if (diaries.isEmpty) {
        setState(() {
          _busy = false;
          _error = '所选时间段内没有找到任何日记，换个时间段试试';
        });
        return;
      }

      final transcript = TranscriptBuilder.build(diaries);
      final collected = settings.sendImages
          ? await _collectImages(diaries, settings.maxImages)
          : (attachments: const <AiAttachment>[], total: 0);
      final attachments = collected.attachments;
      _mediaSummary = collected.total == 0
          ? ''
          : '共 ${collected.total} 张图片，本次发送 ${attachments.length} 张';
      if (!mounted) return;
      setState(() => _progress = '正在请求模型（${diaries.length} 篇日记'
          '${attachments.isEmpty ? '' : '，${attachments.length} 张图片'}）…');

      final result = await SummaryService(settings: settings).summarize(
        instruction: prompt,
        transcript: transcript,
        attachments: attachments,
      );
      if (!mounted) return;
      setState(() {
        _result = result.text;
        _resultNote = result.note;
        _busy = false;
        _progress = '';
      });
    } on AiRequestException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = '';
        _error = e.friendly;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = '';
        _error = '请求失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('AI 总结')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          _warning(theme),
          const SizedBox(height: 16),
          _configCard(theme),
          const SizedBox(height: 16),
          _rangeCard(theme),
          const SizedBox(height: 16),
          _promptCard(theme),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _run,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(_busy ? '处理中…' : '生成总结'),
          ),
          if (_busy && _progress.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_progress, style: theme.textTheme.bodySmall),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (_result != null) ...[
            const SizedBox(height: 20),
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('总结结果', style: theme.textTheme.titleSmall),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _result!));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制')),
                            );
                          },
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('复制'),
                        ),
                      ],
                    ),
                    if (_mediaSummary.isNotEmpty)
                      Text(
                        _mediaSummary,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                      ),
                    if (_resultNote != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _resultNote!,
                        style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange.shade800),
                      ),
                    ],
                    const SizedBox(height: 8),
                    SelectableText(_result!, style: theme.textTheme.bodyMedium?.copyWith(height: 1.6)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _warning(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: theme.colorScheme.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '此功能会把所选时间段内的日记发送给你配置的大模型：'
              '文字一定会发；开启「附带图片」时，日记里的照片也会一起发（需要模型能看图，'
              '例如 gpt-4o、qwen-vl 等）。语音和视频暂时不发——多数接口还不支持，'
              '会以文字说明代替。模型不支持图片时会自动退回只发文字，不会报错。'
              '日记在你这台设备上解密后再发出，我们的服务器只存密文。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _configCard(ThemeData theme) {
    final settings = _settings;
    return Card(
      elevation: 0,
      child: ExpansionTile(
        initiallyExpanded: _showSettings,
        title: const Text('模型配置'),
        subtitle: Text(
          settings == null
              ? '读取中…'
              : (settings.isConfigured ? '已配置：${settings.model}' : '还没配置'),
          style: theme.textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
              labelText: '接口地址',
              hintText: 'https://api.deepseek.com/v1',
              helperText: '兼容 OpenAI 的地址即可；本地 Ollama 填 http://127.0.0.1:11434/v1',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API Key',
              helperText: '只保存在本机文件里，不会上传到日记服务器',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            decoration: const InputDecoration(
              labelText: '模型名',
              hintText: 'deepseek-chat / gpt-4o-mini / qwen-plus …',
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('附带图片'),
                    SizedBox(height: 2),
                    Text(
                      '超出上限时会在整个时间段内均匀抽取；0 表示不发。图片会消耗模型的额度。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              DropdownButton<int>(
                value: _maxImages,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('不发')),
                  DropdownMenuItem(value: 5, child: Text('5 张')),
                  DropdownMenuItem(value: 10, child: Text('10 张')),
                  DropdownMenuItem(value: 15, child: Text('15 张')),
                  DropdownMenuItem(value: 20, child: Text('20 张')),
                  DropdownMenuItem(value: 30, child: Text('30 张')),
                  DropdownMenuItem(value: 50, child: Text('50 张')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _maxImages = value;
                    _sendImages = value > 0;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(onPressed: _saveSettings, child: const Text('保存配置')),
          ),
        ],
      ),
    );
  }

  Widget _rangeCard(ThemeData theme) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('时间范围', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _pickDate(isStart: true),
                    child: Text('从 ${_fmt(_start)}'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _pickDate(isStart: false),
                    child: Text('到 ${_fmt(_end)}'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '共 ${_end.difference(_start).inDays + 1} 天',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _promptCard(ThemeData theme) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('你想让模型做什么', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            TextField(
              controller: _prompt,
              maxLines: 4,
              minLines: 2,
              decoration: const InputDecoration(hintText: '例如：请总结我这些天做了什么'),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final preset in _presets)
                  ActionChip(
                    label: Text(preset, style: theme.textTheme.bodySmall),
                    onPressed: () => setState(() => _prompt.text = preset),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
