/// 日历网格计算（需求 3.3 的"按日期浏览"）。
///
/// 纯逻辑，便于测试：闰年、月初落在星期几、跨月补位都不能错。
library;

class CalendarDay {
  const CalendarDay({required this.date, required this.inMonth});

  /// 形如 2026-11-04
  final String date;

  /// 是否属于当前月（补位的上下月日期为 false）
  final bool inMonth;
}

class CalendarGrid {
  /// 某月的完整网格（按周分行，每行 7 天，周一为第一列）
  static List<List<CalendarDay>> month(int year, int month) {
    final first = DateTime(year, month, 1);
    final last = DateTime(year, month + 1, 0);
    // DateTime.weekday: 周一=1 ... 周日=7
    final leading = first.weekday - 1;
    final total = leading + last.day;
    final weeks = <List<CalendarDay>>[];

    final start = first.subtract(Duration(days: leading));
    var cursor = start;
    final rows = (total / 7).ceil();
    for (var r = 0; r < rows; r += 1) {
      final week = <CalendarDay>[];
      for (var c = 0; c < 7; c += 1) {
        week.add(CalendarDay(
          date: _format(cursor),
          inMonth: cursor.month == month && cursor.year == year,
        ));
        cursor = cursor.add(const Duration(days: 1));
      }
      weeks.add(week);
    }
    return weeks;
  }

  /// 上个月 / 下个月（处理跨年）
  static (int, int) shift(int year, int month, int delta) {
    final total = year * 12 + (month - 1) + delta;
    return (total ~/ 12, total % 12 + 1);
  }

  static String _format(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
