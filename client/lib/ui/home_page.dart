import 'dart:io';

import 'package:flutter/services.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/error_messages.dart';

import '../core/api_client.dart';
import '../core/diary_date.dart' as dd;
import '../core/export_service.dart';
import '../core/local_store.dart';
import '../core/models.dart';
import '../core/session_store.dart';
import '../core/crypto_service.dart';
import '../core/recovery_service.dart';
import '../core/sync_service.dart';
import 'calendar_page.dart';
import 'diagnostics_page.dart';
import 'search_page.dart';
import 'summary_page.dart';
import 'editor_page.dart';

/// 主页：可写窗口 + 最近日记列表 + 导出入口。
///
/// 启动顺序是"先本地后网络"：缓存立刻显示，网络结果到了再刷新，
/// 断网时依然能看到并打开所有写过的日记。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.api,
    required this.session,
    required this.local,
    required this.sync,
    required this.onLogout,
    required this.onSessionChanged,
    this.initialDiaryDate,
  });

  final ApiClient api;
  final Session session;
  final DiaryStore local;
  final SyncService sync;
  final Future<void> Function() onLogout;
  final Future<void> Function(Session session) onSessionChanged;

  /// 启动时直接打开的日期（来自命令行参数）
  final String? initialDiaryDate;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  CalendarWindow? _calendar;
  /// 最近日记当前显示多少条（点「加载更多」递增）
  int _visibleCount = 20;
  List<DiarySummary> _diaries = const [];
  bool _loading = true;
  bool _offline = false;
  int _pending = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _load();
    final target = widget.initialDiaryDate;
    if (target == null || !mounted) return;
    final calendar = _calendar ?? _localCalendar();
    await _openEditor(target, writable: calendar.writableDates.contains(target));
  }

  Future<void> _load() async {
    setState(() => _error = null);

    // 1) 先把本地缓存显示出来，保证离线可用
    final cached = await widget.local.cachedSummaries();
    final pendingBefore = await widget.local.pendingCount();

    // 2) 尝试把待同步内容推上去
    final tzId = _calendar?.tzId ?? 'Asia/Shanghai';
    final push = await widget.sync.pushAll(tzId: tzId);
    final pendingAfter = await widget.local.pendingCount();

    // 3) 拉服务端最新
    CalendarWindow? calendar;
    List<DiarySummary>? diaries;
    var offline = false;
    try {
      calendar = await widget.api.calendar();
      diaries = await widget.api.listDiaries(
        from: dd.addDays(calendar.today, -30),
        to: calendar.today,
      );
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await widget.onLogout();
        return;
      }
      offline = true;
    } catch (_) {
      offline = true;
    }

    if (!mounted) return;
    final effectiveCalendar = calendar ?? _calendar ?? _localCalendar();
    final merged = _mergeSummaries(diaries ?? const [], cached);
    setState(() {
      _calendar = effectiveCalendar;
      _diaries = merged;
      _offline = offline;
      _pending = pendingAfter;
      _loading = false;
      if (pendingBefore > 0 && pendingAfter == 0 && push.online) {
        _error = null;
      }
    });
  }

  /// 断网时用设备本地时区推算可写窗口
  CalendarWindow _localCalendar() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    final todayIso = dd.businessDate(now, offset);
    return CalendarWindow(
      tzId: _tzIdForOffset(offset),
      dayCutHour: dd.defaultDayCutHour,
      today: todayIso,
      writableDates: dd.writableDates(now, offset),
      serverNow: now.toUtc().toIso8601String(),
    );
  }

  static String _tzIdForOffset(Duration offset) {
    final hours = offset.inMinutes / 60;
    if (hours == 8) return 'Asia/Shanghai';
    if (hours == 9) return 'Asia/Tokyo';
    if (hours == 7) return 'Asia/Bangkok';
    if (hours == 5.5) return 'Asia/Kolkata';
    if (hours == 0) return 'UTC';
    if (hours == -5) return 'America/New_York';
    if (hours == -8) return 'America/Los_Angeles';
    if (hours == 1) return 'Europe/Berlin';
    return 'UTC';
  }

  List<DiarySummary> _mergeSummaries(List<DiarySummary> remote, List<DiarySummary> cached) {
    final byDate = <String, DiarySummary>{};
    for (final item in cached) {
      byDate[item.diaryDate] = item;
    }
    for (final item in remote) {
      final local = byDate[item.diaryDate];
      // 服务端版本优先，但本地块数更多时（有未推送内容）保留本地计数
      byDate[item.diaryDate] = local != null && local.blockCount > item.blockCount ? local : item;
    }
    final list = byDate.values.toList()..sort((a, b) => a.diaryDate.compareTo(b.diaryDate));
    return list;
  }

  Map<String, DiarySummary> get _byDate => {for (final d in _diaries) d.diaryDate: d};

  /// 打开日历：按月浏览，有日记的日子带标记，点一天直接进入
  Future<void> _pickDate() async {
    final calendar = _calendar ?? _localCalendar();
    final date = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => CalendarPage(
          today: calendar.today,
          writableDates: calendar.writableDates.toSet(),
          datesWithContent: _diaries
              .where((d) => d.blockCount > 0)
              .map((d) => d.diaryDate)
              .toSet(),
        ),
      ),
    );
    if (date == null || !mounted) return;
    await _openEditor(date, writable: calendar.writableDates.contains(date));
  }

  /// 打开搜索页；选中某一天就直接进入那篇日记
  Future<void> _openSearch() async {
    final date = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => SearchPage(store: widget.local)),
    );
    if (date == null || !mounted) return;
    final writable = _calendar?.writableDates.contains(date) ?? false;
    await _openEditor(date, writable: writable);
  }

  Future<void> _openEditor(String date, {required bool writable}) async {
    final calendar = _calendar ?? _localCalendar();
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditorPage(
          api: widget.api,
          session: widget.session,
          store: widget.local,
          sync: widget.sync,
          date: date,
          tzId: calendar.tzId,
          dayCutHour: calendar.dayCutHour,
          today: calendar.today,
          writable: writable,
          onHlcChanged: (hlc) async {
            widget.session.lastHlc = hlc;
            await widget.onSessionChanged(widget.session);
          },
        ),
      ),
    );
    if (changed == true) await _load();
  }

  Future<void> _syncNow() async {
    final calendar = _calendar ?? _localCalendar();
    final outcome = await widget.sync.pushAll(tzId: calendar.tzId);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(outcome.online
          ? (outcome.pushedBlocks == 0
              ? '已是最新，没有待同步内容'
              : '已同步 ${outcome.pushedBlocks} 个块${outcome.conflicts > 0 ? '，${outcome.conflicts} 处冲突已合并' : ''}')
          : '离线中，内容已保存在本地，联网后会自动同步'),
    ));
  }

  Future<void> _export(ExportFormat format) async {
    final dates = _diaries.map((d) => d.diaryDate).toList();
    if (dates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('还没有可导出的日记')));
      return;
    }
    final targetPath = await FilePicker.getDirectoryPath(dialogTitle: '选择导出位置');
    if (targetPath == null) return;

    final progress = ValueNotifier<(int, int, String)>((0, dates.length, '准备中'));
    final cancellation = ExportCancellation();
    final targetDir = Directory(targetPath);
    // 记录导出前已有的内容，取消时只清理本次新增的
    final before = <String>{};
    try {
      await for (final entity in targetDir.list()) {
        before.add(entity.path);
      }
    } catch (_) {
      // 目录读不了就让服务层自己报错
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('正在导出${format.label}'),
        content: ValueListenableBuilder<(int, int, String)>(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: value.$2 == 0 ? null : value.$1 / value.$2),
              const SizedBox(height: 12),
              Text('${value.$1} / ${value.$2} · ${value.$3}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancellation.cancel();
              progress.value = (0, dates.length, '正在取消…');
            },
            child: const Text('取消'),
          ),
        ],
      ),
    );

    final service = ExportService(api: widget.api, store: widget.local, crypto: widget.sync.crypto);
    try {
      final onProgress = (int done, int total, String label) {
        progress.value = (done, total, label);
      };
      final result = switch (format) {
        ExportFormat.html => await service.exportHtml(
            dates: dates,
            target: Directory(targetPath),
            username: widget.session.username,
            onProgress: onProgress,
            cancellation: cancellation,
          ),
        ExportFormat.markdown => await service.exportMarkdown(
            dates: dates,
            target: Directory(targetPath),
            username: widget.session.username,
            onProgress: onProgress,
            cancellation: cancellation,
          ),
        ExportFormat.pdf => await service.exportPdf(
            dates: dates,
            target: Directory(targetPath),
            username: widget.session.username,
            onProgress: onProgress,
            cancellation: cancellation,
          ),
        ExportFormat.zip => await service.exportZip(
            dates: dates,
            target: Directory(targetPath),
            username: widget.session.username,
            onProgress: onProgress,
            cancellation: cancellation,
          ),
      };
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.summary),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: '打开文件夹',
          onPressed: () {
            if (Platform.isWindows) {
              Process.run('explorer.exe', [result.directory.path]);
            }
          },
        ),
      ));
    } on ExportCancelled {
      if (!mounted) return;
      Navigator.of(context).pop();
      // 只清理本次新增的文件，不动用户原有的东西
      try {
        await for (final entity in targetDir.list()) {
          if (!before.contains(entity.path)) {
            if (entity is File) {
              await entity.delete();
            } else if (entity is Directory) {
              await entity.delete(recursive: true);
            }
          }
        }
      } catch (_) {
        // 清理失败不影响"已取消"这个结论
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已取消导出，未完成的文件已清理')),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败：${describeError(e)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final calendar = _calendar;

    return Scaffold(
      appBar: AppBar(
        title: const Text('日记'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month_outlined),
            tooltip: '按日期跳转',
            onPressed: _pickDate,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '搜索（本机进行，不联网）',
            onPressed: _openSearch,
          ),
          if (_pending > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text('待同步 $_pending'),
                  avatar: const Icon(Icons.cloud_upload_outlined, size: 14),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.sync),
            onPressed: _loading ? null : _syncNow,
            tooltip: '立即同步',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
            tooltip: '刷新',
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'export-html':
                  _export(ExportFormat.html);
                case 'export-md':
                  _export(ExportFormat.markdown);
                case 'export-pdf':
                  _export(ExportFormat.pdf);
                case 'export-zip':
                  _export(ExportFormat.zip);
                case 'summary':
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => SummaryPage(sync: widget.sync),
                  ));
                case 'diagnostics':
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DiagnosticsPage(
                      api: widget.api,
                      session: widget.session,
                      store: widget.local,
                      sync: widget.sync,
                    ),
                  ));
                case 'password':
                  _showChangePassword();
                case 'recovery':
                  _showRecoveryPhrase();
                case 'logout':
                  widget.onLogout();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Text('账号：${widget.session.username ?? ''}'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'export-html', child: Text('导出 HTML 包（媒体可播放）')),
              const PopupMenuItem(value: 'export-md', child: Text('导出 Markdown 包')),
              const PopupMenuItem(value: 'export-pdf', child: Text('导出 PDF（音视频为占位）')),
              const PopupMenuItem(value: 'export-zip', child: Text('导出平台归档 ZIP')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'recovery', child: Text('恢复短语（忘记密码时用）')),
              const PopupMenuItem(value: 'password', child: Text('修改密码')),
              const PopupMenuItem(value: 'summary', child: Text('AI 总结（用大模型回顾日记）')),
              const PopupMenuItem(value: 'diagnostics', child: Text('自检（检查是否可用）')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
          ),
        ],
      ),
      floatingActionButton: calendar == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openEditor(calendar.today, writable: true),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('写今天'),
            ),
      body: Column(
        children: [
          if (_offline)
            MaterialBanner(
              content: const Text('当前离线，正在使用本地数据。写下的内容会先存本地，联网后自动同步。'),
              leading: const Icon(Icons.cloud_off),
              backgroundColor: theme.colorScheme.secondaryContainer,
              actions: [
                TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          Expanded(child: _body(theme)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 恢复短语

  Future<void> _showRecoveryPhrase() async {
    final crypto = widget.sync.crypto;
    if (crypto == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前账号没有启用加密，无需恢复短语')));
      return;
    }

    var hasRecovery = false;
    try {
      hasRecovery = await widget.api.hasRecovery();
    } catch (_) {
      // 查询失败按未设置处理
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复短语'),
        content: Text(
          hasRecovery
              ? '已设置过恢复短语，重新生成会让旧短语立刻失效。\n\n请把 16 个词抄在纸上，不要截图。'
              : '恢复短语用于「忘记密码时找回日记」，由 16 个英文单词组成，只显示这一次。\n\n'
                  '任何人拿到这 16 个词都能解开你的全部日记，请抄在纸上、不要截图。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('生成')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final setup = await RecoveryService(api: widget.api).generate(master: crypto);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('请抄下这 16 个词'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(dialogContext).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 10,
                    children: [
                      for (var i = 0; i < setup.words.length; i += 1)
                        SizedBox(
                          width: 96,
                          child: Text('${i + 1}. ${setup.words[i]}',
                              style: const TextStyle(fontFamily: 'Consolas', fontSize: 15)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text('关掉这个窗口就再也看不到这些词了。',
                    style: Theme.of(dialogContext).textTheme.bodySmall),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: setup.words.join(' ')));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制，但更建议抄在纸上')),
                );
              },
              child: const Text('复制'),
            ),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('我已抄好')),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('生成失败：${describeError(e)}')));
    }
  }

  // ------------------------------------------------------------ 修改密码

  Future<void> _showChangePassword() async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? error;
    var busy = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('修改密码'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('改密码只会更换「解锁日记的钥匙」的外壳，日记内容不会重新加密，也不会丢失。\n'
                    '改完后其他设备需要重新登录。'),
                const SizedBox(height: 12),
                TextField(
                  controller: currentCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '当前密码'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: newCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '新密码（至少 8 位）'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirmCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '再输一次新密码'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('取消')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (newCtrl.text.length < 8) {
                        setDialogState(() => error = '新密码至少 8 位');
                        return;
                      }
                      if (newCtrl.text != confirmCtrl.text) {
                        setDialogState(() => error = '两次输入的新密码不一致');
                        return;
                      }
                      final master = widget.sync.crypto;
                      final salt = widget.session.kdfSalt;
                      if (master == null || salt == null) {
                        setDialogState(() => error = '当前账号未启用加密，暂不支持在此修改密码');
                        return;
                      }
                      setDialogState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final masterBytes = await master.exportKeyBytes();
                        final newKek = await CryptoService.derive(
                          password: newCtrl.text,
                          saltBase64: salt,
                          iterations: widget.session.kdfIterations,
                        );
                        final rewrapped = await newKek.wrapMasterKey(masterBytes);
                        await widget.api.changePassword(
                          currentPassword: currentCtrl.text,
                          newPassword: newCtrl.text,
                          keyWrap: rewrapped.cipherBase64,
                          keyWrapNonce: rewrapped.nonceBase64,
                        );
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop();
                        if (!mounted) return;

                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('密码已修改，其他设备需要重新登录')),
                        );
                      } catch (e) {
                        setDialogState(() {
                          busy = false;
                          error = '修改失败：${describeError(e)}';
                        });
                      }
                    },
              child: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('确认修改'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    final calendar = _calendar;

    if (_loading && _diaries.isEmpty && calendar == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          if (calendar != null) ...[
            _SectionTitle(
              title: '可写窗口',
              subtitle: '今天 ${calendar.today} · 往前 7 天都可以补写',
            ),
            _WindowStrip(
              dates: calendar.writableDates,
              today: calendar.today,
              byDate: _byDate,
              onTap: (date) => _openEditor(date, writable: true),
            ),
            const SizedBox(height: 24),
          ],
          const _SectionTitle(title: '最近日记', subtitle: '按日期倒序'),
          if (_diaries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  '还没有日记，点右下角开始写第一篇。',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            )
          else
            ..._buildDiaryList(theme),
        ],
      ),
    );
  }

  /// 日记列表：按月份分组 + 分批加载。
  /// 日记一多（几百篇）如果一次性渲染，滚动会卡、界面会被拉得很长。
  List<Widget> _buildDiaryList(ThemeData theme) {
    final desc = _diaries.reversed.toList();
    final visible = desc.take(_visibleCount).toList();
    final widgets = <Widget>[];
    String? currentMonth;

    for (final diary in visible) {
      final month = diary.diaryDate.substring(0, 7);
      if (month != currentMonth) {
        currentMonth = month;
        final year = month.substring(0, 4);
        final mon = int.tryParse(month.substring(5, 7)) ?? 0;
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 6),
          child: Text(
            '$year 年 $mon 月',
            style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.outline),
          ),
        ));
      }
      final calendar = _calendar;
      widgets.add(_DiaryTile(
        diary: diary,
        onTap: () => _openEditor(
          diary.diaryDate,
          writable: calendar?.writableDates.contains(diary.diaryDate) ?? false,
        ),
      ));
    }

    if (desc.length > visible.length) {
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: OutlinedButton(
            onPressed: () => setState(() => _visibleCount += 30),
            child: Text('加载更多（还有 ${desc.length - visible.length} 篇）'),
          ),
        ),
      ));
    }
    return widgets;
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          if (subtitle != null)
            Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
        ],
      ),
    );
  }
}

class _WindowStrip extends StatelessWidget {
  const _WindowStrip({
    required this.dates,
    required this.today,
    required this.byDate,
    required this.onTap,
  });

  final List<String> dates;
  final String today;
  final Map<String, DiarySummary> byDate;
  final void Function(String date) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: dates.length,
        separatorBuilder: (context, index) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final date = dates[index];
          final isToday = date == today;
          final diary = byDate[date];
          return InkWell(
            onTap: () => onTap(date),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 104,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isToday
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(14),
                border: isToday ? Border.all(color: theme.colorScheme.primary, width: 1.5) : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(isToday ? '今天' : date.substring(5), style: theme.textTheme.labelLarge),
                  Text(
                    diary == null ? '还没写' : '${diary.blockCount} 个块',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DiaryTile extends StatelessWidget {
  const _DiaryTile({required this.diary, required this.onTap});

  final DiarySummary diary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(diary.diaryDate.substring(8), style: theme.textTheme.labelLarge),
        ),
        title: Text(diary.diaryDate),
        subtitle: Text('${diary.blockCount} 个块'),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
