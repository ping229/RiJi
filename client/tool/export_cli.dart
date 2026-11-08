/// 导出命令行：用真实服务器跑一遍完整导出流程。
///
/// 用法：
///   set RJJ_PASS=你的密码
///   dart run tool/export_cli.dart <目标目录> [html|md]
///
/// 环境变量：RJJ_SERVER / RJJ_USER / RJJ_PASS
library;

import 'dart:io';

import 'package:riji_client/core/api_client.dart';
import 'package:riji_client/core/export_service.dart';
import 'package:riji_client/core/local_store.dart';

Future<void> main(List<String> args) async {
  final base = Platform.environment['RJJ_SERVER'] ?? 'http://127.0.0.1:8080';
  final username = Platform.environment['RJJ_USER'] ?? 'admin';
  final password = Platform.environment['RJJ_PASS'] ?? '';
  final targetPath = args.isNotEmpty ? args[0] : Directory.current.path;
  final format = args.length > 1 ? args[1] : 'html';

  if (password.isEmpty) {
    stderr.writeln('缺少 RJJ_PASS 环境变量');
    exit(2);
  }

  final api = ApiClient(baseUrl: base);
  final login = await api.login(
    username: username,
    password: password,
    deviceName: '导出工具',
    platform: 'windows',
  );
  stdout.writeln('已登录：${login.username}');

  final calendar = await api.calendar();
  final diaries = await api.listDiaries(
    from: _shift(calendar.today, -30),
    to: calendar.today,
  );
  final dates = diaries.map((d) => d.diaryDate).toList()..sort();
  stdout.writeln('可导出日记：${dates.length} 篇（${dates.isEmpty ? '无' : '${dates.first} ~ ${dates.last}'}）');
  if (dates.isEmpty) {
    stdout.writeln('没有可导出的内容');
    api.close();
    return;
  }

  final cacheRoot = await Directory.systemTemp.createTemp('riji_export_cache_');
  final store = await LocalStore.open(cacheRoot);
  final service = ExportService(api: api, store: store);
  final target = Directory(targetPath);
  await target.create(recursive: true);

  final progress = (int done, int total, String label) {
    stdout.writeln('  [$done/$total] $label');
  };

  final result = switch (format) {
    'md' || 'markdown' => await service.exportMarkdown(
        dates: dates, target: target, username: username, onProgress: progress),
    'pdf' => await service.exportPdf(
        dates: dates, target: target, username: username, onProgress: progress),
    'zip' => await service.exportZip(
        dates: dates, target: target, username: username, onProgress: progress),
    _ => await service.exportHtml(
        dates: dates, target: target, username: username, onProgress: progress),
  };

  stdout.writeln(result.summary);
  stdout.writeln('输出目录：${result.directory.path}');
  if (result.failures.isNotEmpty) {
    stdout.writeln('失败清单：${result.failures.join(', ')}');
  }
  api.close();
}

String _shift(String isoDate, int days) {
  final parts = isoDate.split('-').map(int.parse).toList();
  final d = DateTime.utc(parts[0], parts[1], parts[2]).add(Duration(days: days));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
