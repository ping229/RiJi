import 'dart:async';

import 'package:flutter/material.dart';

import '../core/error_messages.dart';

import '../core/local_store.dart';
import '../core/models.dart';
import '../core/search_service.dart';

/// 搜索页：在本地缓存的日记里找内容。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.store});

  final DiaryStore store;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  SearchResult? _result;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _run(value));
  }

  Future<void> _run(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _result = null;
        _busy = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await SearchService(store: widget.store).search(query);
      if (!mounted) return;
      setState(() {
        _result = result;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '搜索失败：${describeError(e)}';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '搜索日记内容…',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                _run('');
              },
            ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_error != null) {
      return Center(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)));
    }
    if (_busy) {
      return const Center(child: CircularProgressIndicator());
    }
    final result = _result;
    if (result == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search, size: 44, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text('输入关键词开始搜索', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 6),
              Text(
                '搜索在本机进行，不会把关键词发给服务器',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      );
    }
    if (result.hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off, size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text('没有找到「${_controller.text.trim()}」', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 6),
              Text(
                '已在本机的 ${result.scannedDiaries} 篇日记中查找',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
          child: Row(
            children: [
              Text(
                '找到 ${result.hits.length} 处，扫描 ${result.scannedDiaries} 篇',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
              if (result.truncated) ...[
                const SizedBox(width: 8),
                Text('（已截断）', style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange.shade700)),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: result.hits.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final hit = result.hits[index];
              return ListTile(
                leading: Icon(_iconFor(hit), color: theme.colorScheme.outline, size: 20),
                title: _highlighted(hit, theme),
                subtitle: Text(hit.date, style: theme.textTheme.bodySmall),
                onTap: () => Navigator.of(context).pop(hit.date),
              );
            },
          ),
        ),
      ],
    );
  }

  IconData _iconFor(SearchHit hit) {
    switch (hit.blockType) {
      case BlockType.text:
        return Icons.subject;
      case BlockType.image:
        return Icons.image_outlined;
      case BlockType.audio:
        return Icons.mic_none;
      case BlockType.video:
        return Icons.videocam_outlined;
      case BlockType.divider:
        return Icons.horizontal_rule;
    }
  }

  Widget _highlighted(SearchHit hit, ThemeData theme) {
    final base = theme.textTheme.bodyMedium;
    final snippet = hit.snippet;
    final start = hit.matchOffset.clamp(0, snippet.length);
    final end = (start + hit.matchLength).clamp(start, snippet.length);
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: snippet.substring(0, start)),
        TextSpan(
          text: snippet.substring(start, end),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.18),
          ),
        ),
        TextSpan(text: snippet.substring(end)),
      ]),
      style: base,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}
