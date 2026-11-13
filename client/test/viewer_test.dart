import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:riji_client/core/image_utils.dart';
import 'package:riji_client/ui/photo_viewer_page.dart';

/// 1x1 透明 PNG
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

void main() {
  test('查看大图：EXIF 横拍方向会被真正转正（横屏照片不再歪/偏小）', () {
    final base = img.Image(width: 40, height: 20);
    base.exif.imageIfd.orientation = 6; // 顺时针 90°
    final bytes = Uint8List.fromList(img.encodeJpg(base));

    final out = ImageUtils.normalizeForViewing(bytes);
    final decoded = img.decodeImage(out)!;

    expect(decoded.width, 20, reason: '转正后宽高应互换');
    expect(decoded.height, 40);
    expect(decoded.exif.imageIfd.orientation ?? 1, 1, reason: '不能保留旧方向，否则会被再转一次');
  });

  test('查看大图：没有旋转的小图原样返回，不做无谓重编码', () {
    final bytes = Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 6)));
    final out = ImageUtils.normalizeForViewing(bytes);
    expect(identical(out, bytes) || out.length == bytes.length, isTrue);
  });

  testWidgets('看图页：失败时给出原因和重试，且仍显示已缓存的压缩图', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
      home: PhotoViewerPage(
        preview: _tinyPng,
        title: '原图',
        loader: () async {
          attempts += 1;
          if (attempts == 1) throw Exception('网络断了');
          return _tinyPng;
        },
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.textContaining('原图加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget, reason: '失败时压缩图仍要能看到');

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(attempts, 2);
    expect(find.textContaining('原图加载失败'), findsNothing);
  });

  testWidgets('看图页：加载成功后不再报错，图片可显示', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PhotoViewerPage(
        preview: _tinyPng,
        loader: () async => _tinyPng,
      ),
    ));
    await tester.pump();
    // compute / decodeImageFromList 都是真异步，需要 runAsync 放行
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('原图加载失败'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('双击缩放'), findsOneWidget);
  });
}
