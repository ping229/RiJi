import 'package:flutter_test/flutter_test.dart';
import 'package:riji_client/core/calendar_grid.dart';

void main() {
  test('月份网格：每周 7 天，包含当月每一天', () {
    final weeks = CalendarGrid.month(2026, 11);
    expect(weeks.every((w) => w.length == 7), isTrue);

    final inMonth = weeks.expand((w) => w).where((d) => d.inMonth).toList();
    expect(inMonth, hasLength(30), reason: '2026 年 11 月有 30 天');
    expect(inMonth.first.date, '2026-11-01');
    expect(inMonth.last.date, '2026-11-30');
  });

  test('月份网格：月初落在周一时没有补位', () {
    // 2026-06-01 是周一
    final weeks = CalendarGrid.month(2026, 6);
    expect(weeks.first.first.date, '2026-06-01');
    expect(weeks.first.first.inMonth, isTrue);
  });

  test('月份网格：月初不是周一时用上月补位', () {
    // 2026-11-01 是周日 → 前面应补 6 天（10-26 到 10-31）
    final weeks = CalendarGrid.month(2026, 11);
    expect(weeks.first.first.date, '2026-10-26');
    expect(weeks.first.first.inMonth, isFalse);
    expect(weeks.first.last.date, '2026-11-01');
    expect(weeks.first.last.inMonth, isTrue);
  });

  test('月份网格：闰年二月有 29 天', () {
    final inMonth =
        CalendarGrid.month(2024, 2).expand((w) => w).where((d) => d.inMonth).toList();
    expect(inMonth, hasLength(29));
    expect(inMonth.last.date, '2024-02-29');
  });

  test('月份切换：跨年正确', () {
    expect(CalendarGrid.shift(2026, 1, -1), (2025, 12));
    expect(CalendarGrid.shift(2026, 12, 1), (2027, 1));
    expect(CalendarGrid.shift(2026, 6, -6), (2025, 12));
    expect(CalendarGrid.shift(2026, 6, 18), (2027, 12));
  });
}
