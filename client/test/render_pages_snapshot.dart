import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riji_client/core/rich_text.dart';
import 'package:riji_client/main.dart';
import 'package:riji_client/ui/calendar_page.dart';
import 'package:riji_client/ui/widgets/rich_text_view.dart';

/// 手动渲染工具：把关键界面导出成 PNG，用于界面导览与人工核对。
/// 不会随 `flutter test` 自动运行（文件名不以 _test.dart 结尾）。
///
///   flutter test test/render_pages_snapshot.dart
void main() {
  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final out = File('${Directory.systemTemp.path}${Platform.pathSeparator}$name');
    out.writeAsBytesSync(data!.buffer.asUint8List());
    // ignore: avoid_print
    print('RENDERED ${out.path} ${out.lengthSync()}');
  }

  testWidgets('渲染日历页', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: CalendarPage(
          today: '2026-11-04',
          writableDates: {
            for (var d = 28; d <= 31; d += 1) '2026-10-$d',
            for (var d = 1; d <= 4; d += 1) '2026-11-0$d',
          },
          datesWithContent: {'2026-11-04', '2026-11-03', '2026-11-02', '2026-11-01'},
        ),
      ),
    ));
    await tester.pump();
    await capture(tester, key, 'riji-calendar.png');
  });

  testWidgets('渲染富文本效果', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    const sample = '''
# 十一月四日

今天试了新版本，**块序列编辑器**用起来顺手多了，*尤其是*可以直接插图片和录音。

- [x] 写日记
- [ ] 整理照片
- [ ] 给朋友打电话

> 心情：平静
> 天气：晴，12℃

## 待办回顾

1. 早上跑步 3 公里
2. 读完《人类简史》第三章

`flutter test` 全绿，共 **63 项**。

---
以上。
''';
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: RichTextView(text: sample),
          ),
        ),
      ),
    ));
    await tester.pump();
    await capture(tester, key, 'riji-richtext.png');
  });

  test('示例文本可被解析', () {
    final lines = RichTextParser.parse('# 标题\n- [x] 已完成');
    expect(lines.first.kind, LineKind.heading1);
    expect(lines.last.checked, isTrue);
  });
}
