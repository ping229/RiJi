import 'package:flutter_test/flutter_test.dart';
import 'package:riji_client/core/diary_date.dart';
import 'package:riji_client/core/hlc.dart';
import 'package:riji_client/core/vv.dart';

void main() {
  const shanghai = Duration(hours: 8);

  group('业务日归属（凌晨 4:00 日切）', () {
    test('23:30 属于当天', () {
      final at = DateTime.utc(2026, 11, 3, 15, 30);
      expect(businessDate(at, shanghai), '2026-11-03');
    });

    test('次日 00:10 仍属于前一天', () {
      final at = DateTime.utc(2026, 11, 3, 16, 10);
      expect(businessDate(at, shanghai), '2026-11-03');
    });

    test('凌晨 03:59 仍属于前一天', () {
      final at = DateTime.utc(2026, 11, 3, 19, 59);
      expect(businessDate(at, shanghai), '2026-11-03');
    });

    test('凌晨 04:00 属于新一天', () {
      final at = DateTime.utc(2026, 11, 3, 20, 0);
      expect(businessDate(at, shanghai), '2026-11-04');
    });

    test('跨时区不漂移：同一时刻在不同时区归属不同，但计算结果稳定', () {
      final at = DateTime.utc(2026, 11, 4, 2, 0);
      expect(businessDate(at, shanghai), '2026-11-04');
      expect(businessDate(at, const Duration(hours: -5)), '2026-11-03');
    });
  });

  group('可写窗口', () {
    final now = DateTime.utc(2026, 11, 10, 8, 0); // 上海 11-10 16:00

    test('今天与过去 7 天可写', () {
      expect(writability('2026-11-10', now, shanghai).writable, isTrue);
      expect(writability('2026-11-03', now, shanghai).writable, isTrue);
    });

    test('过去第 8 天只读', () {
      final v = writability('2026-11-02', now, shanghai);
      expect(v.writable, isFalse);
      expect(v.reason, 'past-window');
    });

    test('未来日期一律拒绝', () {
      final v = writability('2026-11-11', now, shanghai);
      expect(v.writable, isFalse);
      expect(v.reason, 'future');
    });

    test('窗口正好 8 个日期且今天在末尾', () {
      final dates = writableDates(now, shanghai);
      expect(dates.length, 8);
      expect(dates.first, '2026-11-03');
      expect(dates.last, '2026-11-10');
    });
  });

  group('版本向量', () {
    test('支配与并发判定与服务器一致', () {
      expect(compareVv({'a': 1}, {'a': 1}), VvRelation.equal);
      expect(compareVv({'a': 2}, {'a': 1}), VvRelation.aDominates);
      expect(compareVv({'a': 1}, {'a': 1, 'b': 1}), VvRelation.bDominates);
      expect(compareVv({'a': 2, 'b': 1}, {'a': 1, 'b': 2}), VvRelation.concurrent);
    });

    test('合并取逐维度最大值', () {
      expect(mergeVv({'a': 1}, {'a': 2, 'b': 3}), {'a': 2, 'b': 3});
    });

    test('递增只影响本设备维度', () {
      expect(incrementVv({'a': 1}, 'b'), {'a': 1, 'b': 1});
    });
  });

  group('混合逻辑时钟', () {
    test('同一毫秒内逻辑计数递增', () {
      final clock = HlcClock('device-a');
      final first = clock.next(DateTime.fromMillisecondsSinceEpoch(1000));
      final second = clock.next(DateTime.fromMillisecondsSinceEpoch(1000));
      expect(second.counter, first.counter + 1);
      expect(second > first, isTrue);
    });

    test('时钟回拨不会产生更小的时间戳', () {
      final clock = HlcClock('device-a');
      final first = clock.next(DateTime.fromMillisecondsSinceEpoch(5000));
      final second = clock.next(DateTime.fromMillisecondsSinceEpoch(1000));
      expect(second > first, isTrue);
    });

    test('编码后的字符串序与时间序一致', () {
      final a = const Hlc(1000, 0, 'dev-a');
      final b = const Hlc(1000, 1, 'dev-a');
      final c = const Hlc(1001, 0, 'dev-a');
      expect(a.encode().compareTo(b.encode()) < 0, isTrue);
      expect(b.encode().compareTo(c.encode()) < 0, isTrue);
      expect(Hlc.decode(b.encode()), b);
    });

    test('收到远端时间戳后本地时钟被推高', () {
      final clock = HlcClock('device-a');
      clock.next(DateTime.fromMillisecondsSinceEpoch(1000));
      final remote = const Hlc(2000, 3, 'device-b');
      final observed = clock.observe(remote);
      expect(observed > remote, isTrue);
    });
  });
}
