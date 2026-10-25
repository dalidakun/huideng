import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/blessing_service.dart';

void main() {
  group('BlessingProject 自然周期', () {
    const project = BlessingProject(
      id: 'p1',
      totalDays: 7,
      startDate: '2026-10-23',
    );

    test('结束日期为起始日 + 天数 - 1', () {
      expect(project.endDate, '2026-10-29');
    });

    test('最后一天仍在周期内', () {
      expect(project.isExpiredAt('2026-10-29'), isFalse);
    });

    test('次日起自然过期，与打卡天数无关', () {
      expect(project.isExpiredAt('2026-10-30'), isTrue);
    });

    test('缺少起始日期时不判定过期', () {
      const p = BlessingProject(id: 'p2', totalDays: 7);
      expect(p.isExpiredAt('2030-01-01'), isFalse);
    });
  });
}
