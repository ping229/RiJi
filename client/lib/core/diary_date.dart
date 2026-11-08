/// 日记的时间归属规则（与服务端 `domain/calendar.ts` 完全一致）。
///
/// 三条不可混淆的规则：
///  1. 业务日在"写入时"计算一次并冻结，之后永不重算（跨时区不漂移）
///  2. "今天"和可写窗口在每次读取时按当前时区重新计算
///  3. 日切点为本地时间凌晨 4:00
library;

const int defaultDayCutHour = 4;

/// 补写窗口：今天 + 过去 7 天 = 8 个可写日期
const int defaultWriteWindowDays = 7;

class LocalInstant {
  const LocalInstant(this.year, this.month, this.day, this.hour, this.minute, this.second);

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;

  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')} ${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}:${second.toString().padLeft(2, '0')}';
}

/// 把 UTC 时刻换算成目标时区的本地时间分量。
/// 用 DateTime.toLocal 无法指定时区，所以这里用 UTC 偏移差反推：
/// 先按 UTC 取本地钟面，再用该时刻在目标时区的偏移修正。
LocalInstant localParts(DateTime at, Duration utcOffset) {
  final shifted = at.toUtc().add(utcOffset);
  return LocalInstant(
    shifted.year,
    shifted.month,
    shifted.day,
    shifted.hour,
    shifted.minute,
    shifted.second,
  );
}

String isoDateOf(int year, int month, int day) =>
    '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

DateTime _utcOf(String isoDate) {
  final parts = isoDate.split('-');
  if (parts.length != 3) throw FormatException('非法日期: $isoDate');
  return DateTime.utc(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
}

bool isValidIsoDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final d = _utcOf(value);
  return isoDateOf(d.year, d.month, d.day) == value;
}

/// 按自然日加减，不跨时区（跨时区会引入 DST 误差，这里只处理日历日）
String addDays(String isoDate, int delta) {
  final d = _utcOf(isoDate).add(Duration(days: delta));
  return isoDateOf(d.year, d.month, d.day);
}

/// toIso 相对 fromIso 的天数；正数表示 toIso 更晚
int daysBetween(String fromIso, String toIso) =>
    _utcOf(toIso).difference(_utcOf(fromIso)).inDays;

/// 计算某一时刻归属的业务日。
/// 例：UTC+8 时区下 2026-11-04 03:30 本地时间 → 归属 2026-11-03。
String businessDate(DateTime at, Duration utcOffset, {int cutHour = defaultDayCutHour}) {
  final local = localParts(at, utcOffset);
  final base = isoDateOf(local.year, local.month, local.day);
  return local.hour < cutHour ? addDays(base, -1) : base;
}

/// 当前时刻的业务日
String today(DateTime? at, Duration utcOffset, {int cutHour = defaultDayCutHour}) =>
    businessDate(at ?? DateTime.now(), utcOffset, cutHour: cutHour);

class Writability {
  const Writability({required this.writable, required this.today, required this.offsetDays, this.reason});

  final bool writable;
  final String today;
  final int offsetDays;
  final String? reason; // 'future' | 'past-window'
}

/// 画窗口为闭区间 [today - windowDays, today]；未来日期一律拒绝。
Writability writability(
  String diaryDate,
  DateTime now,
  Duration utcOffset, {
  int cutHour = defaultDayCutHour,
  int windowDays = defaultWriteWindowDays,
}) {
  final todayIso = businessDate(now, utcOffset, cutHour: cutHour);
  final offset = daysBetween(diaryDate, todayIso);
  if (offset < 0) {
    return Writability(writable: false, today: todayIso, offsetDays: offset, reason: 'future');
  }
  if (offset > windowDays) {
    return Writability(writable: false, today: todayIso, offsetDays: offset, reason: 'past-window');
  }
  return Writability(writable: true, today: todayIso, offsetDays: offset);
}

/// 当前窗口内全部可写日期，从旧到新
List<String> writableDates(
  DateTime now,
  Duration utcOffset, {
  int cutHour = defaultDayCutHour,
  int windowDays = defaultWriteWindowDays,
}) {
  final todayIso = businessDate(now, utcOffset, cutHour: cutHour);
  return List<String>.generate(windowDays + 1, (i) => addDays(todayIso, -(windowDays - i)));
}
