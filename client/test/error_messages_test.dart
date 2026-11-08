import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:riji_client/core/api_client.dart';
import 'package:riji_client/core/error_messages.dart';

void main() {
  test('登录过期提示要引导重新登录', () {
    final msg = describeError(ApiException(401, 'UNAUTHORIZED', 'unauthorized'));
    expect(msg, contains('重新登录'));
    expect(msg, isNot(contains('401')), reason: '不要把状态码甩给用户');
  });

  test('文件过大要给出可操作建议', () {
    final msg = describeError(ApiException(413, 'TOO_LARGE', 'too large'));
    expect(msg, contains('文件太大'));
    expect(msg, anyOf(contains('更小的文件'), contains('上限')), reason: '要说明怎么办');
  });

  test('服务器 5xx 要说明是服务端问题并建议看日志', () {
    final msg = describeError(ApiException(500, 'INTERNAL', 'boom'));
    expect(msg, contains('服务器出错'));
    expect(msg, contains('日志'));
  });

  test('服务端返回的中文说明要原样保留', () {
    final msg = describeError(ApiException(400, 'BAD', '当前密码不正确'));
    expect(msg, '当前密码不正确');
  });

  test('网络错误要指出检查方向', () {
    final msg = describeError(const SocketException('refused'));
    expect(msg, contains('连不上服务器'));
    expect(msg, anyOf(contains('服务端'), contains('地址')));
  });

  test('超时与文件系统错误各有专属提示', () {
    expect(describeError(TimeoutException('t')), contains('超时'));
    final fs = FileSystemException('denied', 'C:/x');
    expect(describeError(fs), contains('磁盘'));
  });

  test('未知错误保留原始信息但不刷屏', () {
    final long = describeError(StateError('x' * 500));
    expect(long.length, lessThanOrEqualTo(161));
  });

  test('相机/麦克风被系统拒绝时给出设置路径', () {
    final msg = describeError(PlatformException(code: 'CameraAccessDenied', message: 'Failed to create camera'));
    expect(msg, contains('隐私'));
    expect(msg, contains('相机'));
    expect(msg, isNot(contains('PlatformException')), reason: '不要把异常类名甩给用户');

    final mic = describeError(PlatformException(code: 'Record', message: '拒绝访问。'));
    expect(mic, contains('麦克风'));
    expect(mic, contains('隐私'));
  });
  test('http 客户端异常归入网络问题', () {
    final msg = describeError(http.ClientException('failed'));
    expect(msg, contains('连不上服务器'));
  });
}
