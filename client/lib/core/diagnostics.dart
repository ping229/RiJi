/// 自检：把"客户端到底能不能用"拆成一组可独立判断的检查项。
///
/// 设计目的：不依赖开发者也能确认环境是否健康。
/// 每项都有明确的通过/失败标准，失败时给出可操作的建议。
library;

import 'dart:io';

import 'api_client.dart';
import 'error_messages.dart';
import 'crypto_service.dart';
import 'local_store.dart';
import 'session_store.dart';

enum CheckStatus { ok, warn, fail, skipped }

class CheckResult {
  CheckResult({
    required this.name,
    required this.status,
    required this.detail,
    this.hint,
  });

  final String name;
  final CheckStatus status;
  final String detail;

  /// 失败时的下一步建议
  final String? hint;
}

class DiagnosticsReport {
  DiagnosticsReport(this.results, this.finishedAt);

  final List<CheckResult> results;
  final DateTime finishedAt;

  int get failed => results.where((r) => r.status == CheckStatus.fail).length;
  int get warned => results.where((r) => r.status == CheckStatus.warn).length;
  bool get healthy => failed == 0;
}

class Diagnostics {
  Diagnostics({
    required this.api,
    required this.session,
    required this.store,
    this.crypto,
  });

  final ApiClient api;
  final Session session;
  final DiaryStore store;
  final CryptoService? crypto;

  Future<DiagnosticsReport> run({void Function(CheckResult)? onEach}) async {
    final results = <CheckResult>[];

    Future<void> add(CheckResult result) async {
      results.add(result);
      onEach?.call(result);
    }

    // 1. 服务器连通性
    final watch = Stopwatch()..start();
    final reachable = await api.health();
    watch.stop();
    await add(CheckResult(
      name: '服务器连通',
      status: reachable ? CheckStatus.ok : CheckStatus.fail,
      detail: reachable
          ? '${session.baseUrl} 响应正常（${watch.elapsedMilliseconds}ms）'
          : '${session.baseUrl} 无响应',
      hint: reachable ? null : '确认服务端已启动；手机端要填电脑的局域网 IP，不能用 127.0.0.1',
    ));

    if (!reachable) {
      await add(CheckResult(
        name: '后续检查',
        status: CheckStatus.skipped,
        detail: '服务器不通，其余检查已跳过',
      ));
      return DiagnosticsReport(results, DateTime.now());
    }

    // 2. 登录态
    try {
      final me = await api.me();
      final user = me['user'] as Map<String, dynamic>? ?? const {};
      final status = user['status'] as String? ?? 'active';
      await add(CheckResult(
        name: '登录状态',
        status: status == 'active' ? CheckStatus.ok : CheckStatus.warn,
        detail: '账号 ${user['username'] ?? '?'}，状态 $status',
        hint: status == 'active' ? null : '账号被禁用或待删除，请联系管理员',
      ));
    } catch (e) {
      await add(CheckResult(
        name: '登录状态',
        status: CheckStatus.fail,
        detail: '令牌无效：${describeError(e)}',
        hint: '退出登录后重新登录',
      ));
    }

    // 3. 加密状态
    final hasKey = crypto != null;
    await add(CheckResult(
      name: '端到端加密',
      status: hasKey ? CheckStatus.ok : CheckStatus.warn,
      detail: hasKey ? '主密钥已在本机内存，日记按密文传输与存储' : '未启用加密（历史数据或未设置）',
      hint: hasKey ? null : '重新登录一次即可完成加密初始化',
    ));

    // 4. 待同步积压
    try {
      final pending = await store.pendingCount();
      await add(CheckResult(
        name: '同步队列',
        status: pending == 0 ? CheckStatus.ok : CheckStatus.warn,
        detail: pending == 0 ? '没有待推送内容' : '有 $pending 条待推送',
        hint: pending == 0 ? null : '回到主页点「立即同步」；持续失败说明服务器不可写',
      ));
    } catch (e) {
      await add(CheckResult(
        name: '同步队列',
        status: CheckStatus.warn,
        detail: '读取失败：${describeError(e)}',
      ));
    }

    // 5. 本地缓存可写
    try {
      final summaries = await store.cachedSummaries();
      await add(CheckResult(
        name: '本地缓存',
        status: CheckStatus.ok,
        detail: summaries.isEmpty ? '缓存可用（还没有本地日记）' : '缓存了 ${summaries.length} 篇日记',
      ));
    } catch (e) {
      await add(CheckResult(
        name: '本地缓存',
        status: CheckStatus.fail,
        detail: '读写失败：${describeError(e)}',
        hint: '磁盘可能已满或没有写权限',
      ));
    }

    // 6. 存储空间（管理员可以限制配额）
    try {
      final usage = await api.storageUsage();
      final used = (usage['usedBytes'] as num?)?.toDouble() ?? 0;
      final quota = (usage['quotaBytes'] as num?)?.toDouble();
      final percent = (usage['percent'] as num?)?.toDouble() ?? 0;
      String gb(double bytes) => '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
      if (quota == null || quota <= 0) {
        await add(CheckResult(
          name: '存储空间',
          status: CheckStatus.ok,
          detail: '已用 ${gb(used)}，未设置上限',
        ));
      } else {
        final status = percent >= 95
            ? CheckStatus.fail
            : percent >= 80
                ? CheckStatus.warn
                : CheckStatus.ok;
        await add(CheckResult(
          name: '存储空间',
          status: status,
          detail: '已用 ${gb(used)} / ${gb(quota)}（${percent.toStringAsFixed(0)}%）',
          hint: status == CheckStatus.ok
              ? null
              : '空间快满了：删掉一些图片/视频，或请管理员调高配额',
        ));
      }
    } catch (e) {
      await add(CheckResult(
        name: '存储空间',
        status: CheckStatus.warn,
        detail: '用量查询失败：${describeError(e)}',
      ));
    }

    // 7. PDF 中文字体（导出能力的前提）
    // 各系统字体位置不同，按候选列表逐个探测，避免在安卓上永远报"没找到"
    final candidates = Platform.isWindows
        ? <String>[
            r'C:\Windows\Fonts\simhei.ttf',
            r'C:\Windows\Fonts\msyh.ttc',
            r'C:\Windows\Fonts\simsun.ttc',
          ]
        : <String>[
            '/system/fonts/NotoSansCJK-Regular.ttc',
            '/system/fonts/DroidSansFallback.ttf',
            '/system/fonts/NotoSansSC-Regular.otf',
            '/system/fonts/DroidSansChinese.ttf',
          ];
    String? fontPath;
    for (final candidate in candidates) {
      if (await File(candidate).exists()) {
        fontPath = candidate;
        break;
      }
    }
    await add(CheckResult(
      name: 'PDF 导出字体',
      status: fontPath != null ? CheckStatus.ok : CheckStatus.warn,
      detail: fontPath != null ? '找到中文字体：$fontPath' : '没找到中文字体（已尝试 ${candidates.length} 个常见位置）',
      hint: fontPath != null ? null : '导出 PDF 时中文会显示为方块，但不影响其他三种导出格式',
    ));

    return DiagnosticsReport(results, DateTime.now());
  }
}
