/// 图片处理：插入前压缩到合理体积，同时保留原图（需求 3.4）。
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

class PreparedImage {
  PreparedImage({
    required this.display,
    required this.original,
    required this.width,
    required this.height,
    required this.resized,
  });

  /// 用于日常显示与同步的压缩版本
  final Uint8List display;

  /// 原始字节（没有压缩时与 display 相同）
  final Uint8List original;

  final int width;
  final int height;

  /// 是否真的做了缩放
  final bool resized;
}

class ImageUtils {
  /// 长边上限（需求 3.4 指定 2048px）
  static const int maxLongEdge = 2048;

  /// 压缩质量
  static const int jpegQuality = 85;

  /// 解析并压缩。无法解码时原样返回，绝不因为"处理不了"而丢失用户的内容。
  static PreparedImage prepare(Uint8List bytes, {int maxEdge = maxLongEdge}) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      decoded = null;
    }
    if (decoded == null) {
      return PreparedImage(
        display: bytes,
        original: bytes,
        width: 0,
        height: 0,
        resized: false,
      );
    }

    final longEdge = decoded.width > decoded.height ? decoded.width : decoded.height;
    if (longEdge <= maxEdge) {
      return PreparedImage(
        display: bytes,
        original: bytes,
        width: decoded.width,
        height: decoded.height,
        resized: false,
      );
    }

    final resizedImage = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: maxEdge, interpolation: img.Interpolation.average)
        : img.copyResize(decoded, height: maxEdge, interpolation: img.Interpolation.average);

    final encoded = img.encodeJpg(resizedImage, quality: jpegQuality);
    return PreparedImage(
      display: Uint8List.fromList(encoded),
      original: bytes,
      width: resizedImage.width,
      height: resizedImage.height,
      resized: true,
    );
  }
}
