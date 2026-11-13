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

  /// 查看大图时的长边上限：再大对屏幕没意义，只会在手机上吃内存
  static const int maxViewEdge = 4096;

  /// 压缩质量
  static const int jpegQuality = 85;

  /// 查看大图前把图片"摆正"。
  ///
  /// 手机拍的 JPEG 通常把旋转写在 EXIF（Orientation=6/8）里，而 Flutter 的
  /// `Image.memory` 并不总是按 EXIF 旋转 —— 横屏照片就会歪着显示、看起来还特别小。
  /// 这里真正把像素转过来，顺便把超大原图缩到 [maxViewEdge]，避免 OOM。
  ///
  /// 没有旋转、尺寸也合适时**原样返回**，不做无谓的重新编码。
  static Uint8List normalizeForViewing(Uint8List bytes, {int maxEdge = maxViewEdge}) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      decoded = null;
    }
    if (decoded == null) return bytes;

    final orientation = decoded.exif.imageIfd.orientation ?? 1;
    final longEdge = decoded.width > decoded.height ? decoded.width : decoded.height;
    if (orientation == 1 && longEdge <= maxEdge) return bytes;

    var out = orientation == 1 ? decoded : img.bakeOrientation(decoded);
    // 已经转正了，就别再让 EXIF 里的旧方向被重复应用
    out.exif.imageIfd.orientation = 1;
    if (out.width > maxEdge || out.height > maxEdge) {
      out = out.width >= out.height
          ? img.copyResize(out, width: maxEdge, interpolation: img.Interpolation.average)
          : img.copyResize(out, height: maxEdge, interpolation: img.Interpolation.average);
    }
    return Uint8List.fromList(img.encodeJpg(out, quality: 92));
  }

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
