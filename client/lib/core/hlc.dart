/// 混合逻辑时钟客户端实现（与服务端 `domain/hlc.ts` 保持一致）。
///
/// 物理时钟会漂移，纯逻辑时钟又无法跨设备比较。HLC 用
/// (物理毫秒, 逻辑计数, 设备号) 三元组，既单调又能在设备间全序比较。
library;

/// 定宽十六进制编码，保证字符串序 == 时间序（服务端按字符串排序）。
const int _physHexWidth = 12;
const int _counterHexWidth = 4;

class Hlc implements Comparable<Hlc> {
  const Hlc(this.phys, this.counter, this.device);

  final int phys;
  final int counter;
  final String device;

  String encode() {
    final p = phys.toRadixString(16).padLeft(_physHexWidth, '0');
    final c = counter.toRadixString(16).padLeft(_counterHexWidth, '0');
    return '$p-$c-$device';
  }

  static Hlc decode(String encoded) {
    final firstDash = encoded.indexOf('-');
    final secondDash = encoded.indexOf('-', firstDash + 1);
    if (firstDash <= 0 || secondDash <= firstDash) {
      throw FormatException('非法 HLC 编码: $encoded');
    }
    return Hlc(
      int.parse(encoded.substring(0, firstDash), radix: 16),
      int.parse(encoded.substring(firstDash + 1, secondDash), radix: 16),
      encoded.substring(secondDash + 1),
    );
  }

  @override
  int compareTo(Hlc other) {
    if (phys != other.phys) return phys.compareTo(other.phys);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return device.compareTo(other.device);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc && other.phys == phys && other.counter == counter && other.device == device;

  @override
  int get hashCode => Object.hash(phys, counter, device);

  @override
  String toString() => encode();
}

/// 生成下一枚本地时间戳。
/// 若本地物理时钟落后于已见过的最大值（设备时间被回拨），
/// 沿用旧物理时间并递增逻辑计数，保证全局单调。
class HlcClock {
  HlcClock(this.device, {Hlc? last}) : _last = last;

  final String device;
  Hlc? _last;  Hlc get last => _last ?? Hlc(0, 0, device);

  Hlc next([DateTime? now]) {
    final wall = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final prev = _last;
    if (prev == null) {
      final h = Hlc(wall, 0, device);
      _last = h;
      return h;
    }
    if (wall > prev.phys) {
      final h = Hlc(wall, 0, device);
      _last = h;
      return h;
    }
    final h = Hlc(prev.phys, prev.counter + 1, device);
    _last = h;
    return h;
  }

  /// 收到远端时间戳后推进本地时钟（Lamport 式合并）
  Hlc observe(Hlc remote, [DateTime? now]) {
    final wall = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final local = _last;
    final maxPhys = [wall, local?.phys ?? 0, remote.phys].reduce((a, b) => a > b ? a : b);

    int counter;
    if (local != null && maxPhys == local.phys && maxPhys == remote.phys) {
      counter = (local.counter > remote.counter ? local.counter : remote.counter) + 1;
    } else if (local != null && maxPhys == local.phys) {
      counter = local.counter + 1;
    } else if (maxPhys == remote.phys) {
      counter = remote.counter + 1;
    } else {
      counter = 0;
    }
    final h = Hlc(maxPhys, counter, device);
    _last = h;
    return h;
  }
}
