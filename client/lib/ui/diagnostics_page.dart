import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/diagnostics.dart';
import '../core/local_store.dart';
import '../core/session_store.dart';
import 'dart:io';

import '../core/sync_service.dart';

/// 自检页：逐项检查客户端的关键能力，给非技术用户一个"能不能用"的结论。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({
    super.key,
    required this.api,
    required this.session,
    required this.store,
    required this.sync,
  });

  final ApiClient api;
  final Session session;
  final DiaryStore store;
  final SyncService sync;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  final List<CheckResult> _results = [];
  DiagnosticsReport? _report;
  bool _running = true;
  String? _dataDir;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _results.clear();
      _report = null;
      _running = true;
    });
    try {
      final store = await SessionStore.open();
      _dataDir = store.dir.path;
    } catch (_) {
      _dataDir = null;
    }

    final report = await Diagnostics(
      api: widget.api,
      session: widget.session,
      store: widget.store,
      crypto: widget.sync.crypto,
    ).run(onEach: (result) {
      if (mounted) setState(() => _results.add(result));
    });
    if (!mounted) return;
    setState(() {
      _report = report;
      _running = false;
    });
  }

  IconData _icon(CheckStatus status) {
    switch (status) {
      case CheckStatus.ok:
        return Icons.check_circle;
      case CheckStatus.warn:
        return Icons.warning_amber_rounded;
      case CheckStatus.fail:
        return Icons.cancel;
      case CheckStatus.skipped:
        return Icons.remove_circle_outline;
    }
  }

  Color _color(CheckStatus status, ThemeData theme) {
    switch (status) {
      case CheckStatus.ok:
        return Colors.green.shade600;
      case CheckStatus.warn:
        return Colors.orange.shade700;
      case CheckStatus.fail:
        return theme.colorScheme.error;
      case CheckStatus.skipped:
        return theme.colorScheme.outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = _report;

    return Scaffold(
      appBar: AppBar(
        title: const Text('自检'),
        actions: [
          if (_dataDir != null && Platform.isWindows)
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: '打开数据目录',
              onPressed: () => Process.run('explorer', [_dataDir!]),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _running ? null : _run,
            tooltip: '重新检查',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          if (report != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: report.healthy
                    ? Colors.green.withValues(alpha: 0.08)
                    : theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    report.healthy ? Icons.verified : Icons.error_outline,
                    color: report.healthy ? Colors.green.shade700 : theme.colorScheme.error,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      report.healthy
                          ? (report.warned == 0
                              ? '全部检查通过，可以正常使用'
                              : '通过（${report.warned} 项提示，不影响使用）')
                          : '${report.failed} 项未通过，请按下面的建议处理',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          if (_dataDir != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: SelectableText(
                '数据目录：$_dataDir',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          const SizedBox(height: 16),
          for (final result in _results) ...[
            Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 10),
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_icon(result.status), color: _color(result.status, theme), size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(result.name, style: theme.textTheme.titleSmall),
                          const SizedBox(height: 4),
                          Text(
                            result.detail,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                          ),
                          if (result.hint != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              '建议：${result.hint}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: result.status == CheckStatus.fail
                                    ? theme.colorScheme.error
                                    : Colors.orange.shade800,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_running)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
