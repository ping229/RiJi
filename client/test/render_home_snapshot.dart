import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:riji_client/core/api_client.dart';
import 'package:riji_client/core/local_store.dart';
import 'package:riji_client/core/session_store.dart';
import 'package:riji_client/core/sync_service.dart';
import 'package:riji_client/main.dart';
import 'package:riji_client/ui/home_page.dart';

/// 把主页真实渲染成一张 PNG，用于人工核对界面元素是否真的被画出来。
/// 这条路径不依赖 Windows 窗口截图，能排除"截图工具"的干扰。
void main() {
  testWidgets('渲染主页快照', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final client = MockClient((request) async {
      if (request.url.path == '/healthz') {
        return http.Response('{"status":"ok"}', 200, headers: {'content-type': 'application/json'});
      }
      if (request.url.path == '/api/calendar') {
        return http.Response(
          '{"today":"2026-11-04","tzId":"Asia/Shanghai","writableDates":["2026-10-28","2026-10-29","2026-10-30","2026-10-31","2026-11-01","2026-11-02","2026-11-03","2026-11-04"]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/diaries') {
        return http.Response(
          '{"diaries":[{"diaryId":"a","diaryDate":"2026-11-03","blockCount":10,"updatedAt":"2026-11-03T10:00:00Z"},'
          '{"diaryId":"b","diaryDate":"2026-11-02","blockCount":4,"updatedAt":"2026-11-02T10:00:00Z"}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200, headers: {'content-type': 'application/json'});
    });

    final api = ApiClient(baseUrl: 'http://127.0.0.1:8080', httpClient: client);
    final store = MemoryStore();
    final session = Session(
      baseUrl: 'http://127.0.0.1:8080',
      accessToken: 't',
      refreshToken: 'r',
      deviceId: 'd',
      username: 'tester',
    );
    final sync = SyncService(api: api, store: store);
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(RepaintBoundary(
      key: boundaryKey,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: HomePage(
          api: api,
          session: session,
          local: store,
          sync: sync,
          onLogout: () async {},
          onSessionChanged: (_) async {},
        ),
      ),
    ));
    // 让 bootstrap 的网络请求完成
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));

    final boundary = boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final out = File('${Directory.systemTemp.path}riji-home-render.png');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(data!.buffer.asUint8List());
    // ignore: avoid_print
    print('RENDERED ${out.path} ${out.lengthSync()} bytes');

    expect(out.lengthSync(), greaterThan(1000));
  });
}
