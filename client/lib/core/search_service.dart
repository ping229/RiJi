/// 全文搜索（需求 3.3）。
///
/// 为什么在客户端做：日记正文是端到端加密的，服务端只有密文，**根本搜不了**。
/// 所以搜索基于本地已解密的缓存进行——这也保证了搜索行为不泄露给服务端。
///
/// 代价：只能搜到本机缓存过的日记。对于"本地优先 + 全量副本"的设计这是自然结果，
/// 且用户实际使用中，写过的日记都会在本地留一份。
library;

import 'local_store.dart';
import 'models.dart';

class SearchHit {
  SearchHit({
    required this.date,
    required this.blockId,
    required this.snippet,
    required this.matchOffset,
    required this.matchLength,
    required this.blockType,
  });

  final String date;
  final String blockId;

  /// 命中处的上下文片段
  final String snippet;

  /// 匹配文字在 snippet 中的起始位置（用于高亮）
  final int matchOffset;
  final int matchLength;

  final BlockType blockType;
}

class SearchResult {
  SearchResult({required this.hits, required this.scannedDiaries, required this.truncated});

  final List<SearchHit> hits;

  /// 实际扫描了多少篇日记（用于告诉用户搜索范围）
  final int scannedDiaries;

  /// 是否因为达到上限而截断
  final bool truncated;
}

class SearchService {
  SearchService({required this.store, this.snippetRadius = 24});

  final DiaryStore store;
  final int snippetRadius;

  Future<SearchResult> search(String query, {int limit = 60}) async {
    final needle = query.trim();
    if (needle.isEmpty) {
      return SearchResult(hits: const [], scannedDiaries: 0, truncated: false);
    }

    final lowerNeedle = needle.toLowerCase();
    final summaries = await store.cachedSummaries();
    final hits = <SearchHit>[];
    var truncated = false;

    for (final summary in summaries) {
      final blocks = await store.readBlocks(summary.diaryDate);
      if (blocks == null) continue;
      for (final block in blocks) {
        if (block.tombstone) continue;

        final haystack = _searchableText(block);
        if (haystack.isEmpty) continue;
        final index = haystack.toLowerCase().indexOf(lowerNeedle);
        if (index < 0) continue;

        final start = (index - snippetRadius).clamp(0, haystack.length);
        final end = (index + needle.length + snippetRadius).clamp(0, haystack.length);
        final prefix = start > 0 ? '…' : '';
        final suffix = end < haystack.length ? '…' : '';
        final snippetText = '$prefix${haystack.substring(start, end)}$suffix';
        final offset = prefix.length + (index - start);

        hits.add(SearchHit(
          date: summary.diaryDate,
          blockId: block.blockId,
          snippet: snippetText.replaceAll('\n', ' '),
          matchOffset: offset,
          matchLength: needle.length,
          blockType: block.blockType,
        ));

        if (hits.length >= limit) {
          truncated = true;
          break;
        }
      }
      if (truncated) break;
    }

    // 新的日期排前面
    hits.sort((a, b) => b.date.compareTo(a.date));
    return SearchResult(hits: hits, scannedDiaries: summaries.length, truncated: truncated);
  }

  /// 参与搜索的文本：文字块取正文，媒体块取文件名（方便找"那个视频"）
  String _searchableText(Block block) {
    switch (block.blockType) {
      case BlockType.text:
        return block.text;
      case BlockType.image:
      case BlockType.video:
      case BlockType.audio:
        final name = block.data['name'] as String?;
        return name ?? '';
      case BlockType.divider:
        return '';
    }
  }
}
