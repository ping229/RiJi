/// 诊断模式：用真实的播放引擎验证音频/视频能否解码与播放。
///
/// 用法：riji_client.exe --selftest=2026-11-02
/// 输出：每个媒体块的解码结果、播放位置是否推进。
///
/// 这是给开发和排障用的自检入口，不参与正常界面流程。
library;

import 'dart:convert';
import 'dart:io';

import 'package:video_player/video_player.dart';

import '../core/api_client.dart';
import '../core/local_store.dart';
import '../core/media_service.dart';
import '../core/models.dart';
import '../core/session_store.dart';

Future<int> runMediaSelfTest(String date) async {
  final store = await SessionStore.open();
  final session = await store.load();
  if (session == null || !session.isLoggedIn) {
    stdout.writeln('SELFTEST_ERROR 未登录，无法自检');
    return 2;
  }

  final api = ApiClient(baseUrl: session.baseUrl)
    ..accessToken = session.accessToken
    ..refreshToken = session.refreshToken
    ..deviceId = session.deviceId;

  final local = await LocalStore.open(store.dir);
  final media = MediaService(api: api, store: local);

  stdout.writeln('SELFTEST 开始，日期 $date');
  final detail = await api.getDiary(date);
  if (detail == null) {
    stdout.writeln('SELFTEST_ERROR 该日期没有日记');
    return 3;
  }

  final results = <Map<String, dynamic>>[];
  for (final block in detail.blocks) {
    if (block.mediaRef == null) continue;
    if (block.blockType != BlockType.audio && block.blockType != BlockType.video) continue;

    final key = block.mediaRef!;
    final extension = block.mime == 'audio/mp4' ? 'm4a' : 'mp4';
    final result = <String, dynamic>{
      'blockType': block.blockType.name,
      'mediaKey': key.substring(0, 12),
    };

    VideoPlayerController? controller;
    try {
      final file = await media.fileFor(key, extension: extension);
      controller = VideoPlayerController.file(file);
      final watch = Stopwatch()..start();
      await controller.initialize();
      result['initMs'] = watch.elapsedMilliseconds;
      result['durationMs'] = controller.value.duration.inMilliseconds;
      result['size'] = '${controller.value.size.width.round()}x${controller.value.size.height.round()}';
      await controller.play();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      result['positionAfterPlayMs'] = controller.value.position.inMilliseconds;
      result['isPlaying'] = controller.value.isPlaying;
      await controller.pause();
    } catch (e) {
      result['error'] = e.toString();
    } finally {
      await controller?.dispose();
    }
    results.add(result);
  }

  stdout.writeln('SELFTEST_RESULT ${jsonEncode(results)}');
  api.close();
  return results.any((r) => r.containsKey('error')) ? 1 : 0;
}
