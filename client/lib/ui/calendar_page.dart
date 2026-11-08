import 'package:flutter/material.dart';

import '../core/calendar_grid.dart';

/// 日历页：按月浏览，有日记的日子标出来，点一下直接打开。
class CalendarPage extends StatefulWidget {
  const CalendarPage({
    super.key,
    required this.today,
    required this.writableDates,
    required this.datesWithContent,
  });

  final String today;
  final Set<String> writableDates;
  final Set<String> datesWithContent;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late int _year;
  late int _month;

  @override
  void initState() {
    super.initState();
    final parts = widget.today.split('-');
    _year = int.tryParse(parts[0]) ?? DateTime.now().year;
    _month = int.tryParse(parts[1]) ?? DateTime.now().month;
  }

  void _shift(int delta) {
    final (y, m) = CalendarGrid.shift(_year, _month, delta);
    setState(() {
      _year = y;
      _month = m;
    });
  }

  /// 不允许翻到未来月份
  bool get _canGoNext {
    final now = widget.today.split('-');
    final ty = int.tryParse(now[0]) ?? 0;
    final tm = int.tryParse(now[1]) ?? 0;
    return _year < ty || (_year == ty && _month < tm);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weeks = CalendarGrid.month(_year, _month);

    return Scaffold(
      appBar: AppBar(
        title: Text('$_year 年 $_month 月'),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: '上个月',
            onPressed: () => _shift(-1),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: '下个月',
            onPressed: _canGoNext ? () => _shift(1) : null,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (final label in ['一', '二', '三', '四', '五', '六', '日'])
                  Expanded(
                    child: Center(
                      child: Text(label,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            for (final week in weeks)
              Row(
                children: [
                  for (final day in week)
                    Expanded(child: _dayCell(day, theme)),
                ],
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                _legend(theme, theme.colorScheme.primary, '有日记'),
                const SizedBox(width: 16),
                _legend(theme, theme.colorScheme.primary.withValues(alpha: 0.18), '可写'),
                const SizedBox(width: 16),
                _legend(theme, theme.colorScheme.outlineVariant, '只读'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend(ThemeData theme, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
      ],
    );
  }

  Widget _dayCell(CalendarDay day, ThemeData theme) {
    final isFuture = day.date.compareTo(widget.today) > 0;
    final hasContent = widget.datesWithContent.contains(day.date);
    final writable = widget.writableDates.contains(day.date);
    final isToday = day.date == widget.today;

    final base = day.inMonth ? theme.colorScheme.onSurface : theme.colorScheme.outlineVariant;
    final bg = hasContent
        ? theme.colorScheme.primary.withValues(alpha: isFuture ? 0.06 : 0.14)
        : (writable ? theme.colorScheme.primary.withValues(alpha: 0.06) : Colors.transparent);

    final dayNumber = int.tryParse(day.date.substring(8, 10)) ?? 0;

    return Padding(
      padding: const EdgeInsets.all(2),
      child: AspectRatio(
        aspectRatio: 1,
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: isFuture ? null : () => Navigator.of(context).pop(day.date),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  day.inMonth ? '$dayNumber' : '',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isFuture ? theme.colorScheme.outlineVariant : base,
                    fontWeight: isToday ? FontWeight.bold : null,
                  ),
                ),
                const SizedBox(height: 2),
                if (hasContent)
                  Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
