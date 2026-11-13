/// 开发者诊断：`riji_client.exe --devicetest`
///
/// 只做一件事：在当前这台 Windows 上，用应用真正依赖的插件去
///   1) 枚举并初始化摄像头
///   2) 申请麦克风权限并录 1 秒
/// 把底层错误码原样打出来（同时写日志文件），用来区分
/// "系统拒绝" 与 "插件/代码问题"。
library;

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:record/record.dart';

Future<int> runDeviceTest() async {
  final buffer = StringBuffer();
  var ok = 0;
  var fail = 0;

  void log(String line) {
    buffer.writeln(line);
    stdout.writeln(line);
  }

  log('=== camera ===');
  try {
    final cameras = await availableCameras();
    log('availableCameras: ${cameras.length}');
    for (final camera in cameras) {
      log('  ${camera.name} | ${camera.lensDirection} | sensor=${camera.sensorOrientation}');
    }
    for (final camera in cameras) {
      final controller = CameraController(camera, ResolutionPreset.low, enableAudio: false);
      try {
        await controller.initialize().timeout(const Duration(seconds: 8));
        log('  initialize(${camera.name}): OK');
        ok += 1;
        // 成功时不再 dispose：某些 Windows 版本上 camera_windows 的 dispose 会卡住，
        // 诊断进程马上就要退出，不值得为它冒挂死的风险。
        continue;
      } on CameraException catch (e) {
        log('  initialize(${camera.name}): FAIL code=${e.code} description=${e.description}');
        fail += 1;
      } catch (e) {
        log('  initialize(${camera.name}): FAIL $e');
        fail += 1;
      }
      await controller.dispose().timeout(const Duration(seconds: 3), onTimeout: () {});
    }
  } catch (e) {
    log('availableCameras: FAIL $e');
    fail += 1;
  }

  log('=== filesystem ===');
  final probeDirs = <String>[
    Platform.environment['TEMP'] ?? '',
    Platform.environment['LOCALAPPDATA'] ?? '',
    r'C:\dev',
  ].where((d) => d.isNotEmpty).toList();
  for (final dir in probeDirs) {
    try {
      final file = File('$dir${Platform.pathSeparator}riji_probe_${DateTime.now().microsecondsSinceEpoch}.txt');
      await file.writeAsString('ok', flush: true);
      await file.delete();
      log('write $dir: OK');
    } catch (e) {
      log('write $dir: FAIL $e');
    }
  }

  log('=== microphone ===');
  final recorder = AudioRecorder();
  try {
    final hasPermission = await recorder.hasPermission();
    log('hasPermission: $hasPermission');
    if (!hasPermission) {
      fail += 1;
    } else {
      // 故意不用 systemTemp：先确认到底是真的录不了，还是临时目录写不了
      final dir = Directory(r'C:\dev');
      final path = '${dir.path}${Platform.pathSeparator}riji_mic_test.m4a';
      await recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final stoppedPath = await recorder.stop();
      final file = File(stoppedPath ?? path);
      final size = await file.exists() ? await file.length() : -1;
      log('record: OK path=$stoppedPath bytes=$size');
      ok += size > 0 ? 1 : 0;
      if (size <= 0) fail += 1;
    }
  } catch (e) {
    log('record: FAIL $e');
    fail += 1;
  } finally {
    await recorder.dispose();
  }

  log('=== SUMMARY ok=$ok fail=$fail ===');
  try {
    final out = File('${Directory.systemTemp.path}${Platform.pathSeparator}riji-devicetest.log');
    await out.writeAsString(buffer.toString(), flush: true);
    stdout.writeln('log written: ${out.path}');
  } catch (_) {
    // 写不了日志也不影响结论
  }
  return fail == 0 ? 0 : 1;
}
