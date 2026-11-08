/// 把异常翻译成用户能看懂、且知道下一步该做什么的话。
///
/// 原则：错误提示里不出现堆栈、不出现英文异常名；
/// 每条都要么说明原因，要么给出下一步动作。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';

String describeError(Object error) {
  // 1. 服务端明确返回的错误
  if (error is ApiException) {
    switch (error.statusCode) {
      case 400:
        return error.message.isEmpty ? '提交的内容不符合要求，检查一下再试' : error.message;
      case 401:
        return '登录已过期，请重新登录';
      case 403:
        return '没有权限执行这个操作';
      case 404:
        return '服务器上找不到这条记录，可能已被删除';
      case 409:
        return '这条内容在别处也被改过，已自动合并保留两个版本';
      case 413:
        // 存储配额超限时服务端会给出"已用 X / 配额 Y"的具体数字，直接用
        if (error.code == 'QUOTA_EXCEEDED' && error.message.isNotEmpty) {
          return error.message;
        }
        return '文件太大，服务器拒绝接收；可以换个更小的文件，或调高服务端上传上限';
      case 429:
        return '操作太频繁了，等一会儿再试';
      default:
        if (error.statusCode >= 500) {
          return '服务器出错了，请稍后重试；如果一直这样，查看服务端日志';
        }
        return error.message.isEmpty ? '请求失败（${error.statusCode}）' : error.message;
    }
  }

  // 2. 网络层
  if (error is SocketException || error is http.ClientException) {
    return '连不上服务器：确认服务端已启动、地址填对了、手机和电脑在同一个网络';
  }
  if (error is TimeoutException) {
    return '服务器响应超时，网络可能不稳定，稍后重试';
  }
  if (error is HandshakeException) {
    return 'HTTPS 握手失败：证书可能不被信任，检查服务端证书配置';
  }

  // 3. 权限类：相机/麦克风被系统拒绝（Windows 隐私设置最常见）
  if (error is PlatformException) {
    final code = error.code.toLowerCase();
    final msg = (error.message ?? '').toLowerCase();
    final denied = code.contains('denied') ||
        code.contains('access') ||
        msg.contains('拒绝访问') ||
        msg.contains('denied');
    if (denied) {
      return '系统拒绝了权限：Windows 在「设置 → 隐私和安全性 → 相机/麦克风」里打开'
          '「允许桌面应用访问」；手机在系统设置里给本应用相机/麦克风权限';
    }
    final detail = error.message ?? error.code;
    return detail.isEmpty ? '系统接口调用失败' : '系统接口调用失败：$detail';
  }

  // 4. 本地文件与数据
  if (error is FileSystemException) {
    return '读写本地文件失败：检查磁盘空间和写入权限';
  }
  if (error is FormatException) {
    return '数据格式不正确，文件可能已损坏';
  }

  // 4. 兜底：保留原始信息，方便排查，但不加恐吓性的前缀
  final text = error.toString();
  return text.length > 160 ? '${text.substring(0, 160)}…' : text;
}
