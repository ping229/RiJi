import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:riji_client/core/api_client.dart';
import 'package:riji_client/core/local_store.dart';
import 'package:riji_client/core/session_store.dart';
import 'package:riji_client/core/sync_service.dart';
import 'package:riji_client/main.dart';
import 'package:riji_client/ui/home_page.dart';

void main() {
  testWidgets('主页标题栏必须包含可点击的入口按钮', (tester) async {
    final client = MockClient((request) async => http.Response('{}', 200));
    final api = ApiClient(baseUrl: 'http://127.0.0.1:8080', httpClient: client);
    final store = MemoryStore();
    final session = Session(
      baseUrl: 'http://127.0.0.1:8080',
      accessToken: 't',
      refreshToken: 'r',
      deviceId: 'd',
      username: 'u',
    );
    final sync = SyncService(api: api, store: store);

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: HomePage(
        api: api,
        session: session,
        local: store,
        sync: sync,
        onLogout: () async {},
        onSessionChanged: (_) async {},
      ),
    ));
    await tester.pump();

    // 打印实际坐标与画布尺寸，确认按钮在可见区域内
    final surface = tester.getSize(find.byType(MaterialApp));
    debugPrint('画布尺寸: $surface');
    for (final tip in ['按日期跳转', '搜索（本机进行，不联网）', '立即同步', '刷新']) {
      final rect = tester.getRect(find.byTooltip(tip));
      debugPrint('$tip → $rect');
      expect(rect.left, greaterThanOrEqualTo(0), reason: '$tip 跑到屏幕左侧外');
      expect(rect.right, lessThanOrEqualTo(surface.width), reason: '$tip 超出右边界');
      expect(rect.top, greaterThanOrEqualTo(0), reason: '$tip 在屏幕上方外');
    }

    // 这些是用户唯一的入口，缺一个就意味着某些功能点不到
    expect(find.byTooltip('按日期跳转'), findsOneWidget, reason: '缺少日历入口');
    expect(find.byTooltip('搜索（本机进行，不联网）'), findsOneWidget, reason: '缺少搜索入口');
    expect(find.byTooltip('立即同步'), findsOneWidget, reason: '缺少同步入口');
    expect(find.byTooltip('刷新'), findsOneWidget, reason: '缺少刷新入口');
  });
}
