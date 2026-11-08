/// 语音块的波形摘要（需求 3.2）。
///
/// 波形在**录音时**采集：`record` 包每 150ms 报一次振幅（dBFS），
/// 归一化成 0..100 存进块数据。这样播放时不用解码音频就能画出波形，
/// 对端到端加密也很友好——波形只是数字，不涉及音频内容。
library;

import 'dart:math' as math;

class Waveform {
  /// 最多保留的柱子数量
  static const int defaultBars = 72;

  /// dBFS 转 0..100 的等级。-60dB 视为静音，0dB 视为满幅。
  static int levelFromDb(double db) {
    if (db.isNaN || db.isInfinite) return 0;
    final clamped = db.clamp(-60.0, 0.0);
    final ratio = (clamped + 60) / 60;
    return (ratio * 100).round().clamp(0, 100);
  }

  /// 把任意长度的采样降采样成固定根数，每根取该段的峰值
  static List<int> bars(List<int> levels, {int count = defaultBars}) {
    if (levels.isEmpty) return const [];
    final target = math.max(1, count);
    if (levels.length <= target) return List<int>.from(levels);

    final result = <int>[];
    final step = levels.length / target;
    for (var i = 0; i < target; i += 1) {
      final start = (i * step).floor();
      final end = math.min(levels.length, ((i + 1) * step).ceil());
      var peak = 0;
      for (var k = start; k < end; k += 1) {
        if (levels[k] > peak) peak = levels[k];
      }
      result.add(peak);
    }
    return result;
  }

  /// 波形是否"几乎没有起伏"——纯静音时画一条细线比画一堆空柱子好看
  static bool isSilent(List<int> bars) {
    if (bars.isEmpty) return true;
    return bars.every((v) => v < 3);
  }
}
