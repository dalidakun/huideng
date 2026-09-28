import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/hot_discussion_spot.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('热门讨论展示位按天轮流', () {
    test('连续 400 天逐日交替', () {
      var day = DateTime(2026, 9, 27);
      final first = hotSpotShowsSutraOn(day);
      for (var i = 1; i <= 400; i++) {
        day = day.add(const Duration(days: 1));
        expect(hotSpotShowsSutraOn(day), i.isOdd ? !first : first,
            reason: '第 $i 天类型应与前一天相反');
      }
    });

    test('跨月/跨年/闰日都交替（按「几号」取奇偶会在月末连着两天同类型）', () {
      expect(hotSpotShowsSutraOn(DateTime(2026, 1, 31)),
          !hotSpotShowsSutraOn(DateTime(2026, 2, 1)));
      expect(hotSpotShowsSutraOn(DateTime(2028, 2, 29)),
          !hotSpotShowsSutraOn(DateTime(2028, 3, 1)));
      expect(hotSpotShowsSutraOn(DateTime(2026, 12, 31)),
          !hotSpotShowsSutraOn(DateTime(2027, 1, 1)));
    });

    test('同一天任意时刻口径一致', () {
      expect(hotSpotShowsSutraOn(DateTime(2026, 9, 27, 0, 5)),
          hotSpotShowsSutraOn(DateTime(2026, 9, 27, 7, 30)));
      expect(hotSpotShowsSutraOn(DateTime(2026, 9, 27, 7, 30)),
          hotSpotShowsSutraOn(DateTime(2026, 9, 27, 23, 55)));
    });
  });

  testWidgets('展示位：取不到数据时退回引语卡，不显示占位文案', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HotDiscussionSpot()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '展示位渲染抛异常');

    // 测试环境取不到云端热门数据 → 显示原来的引语卡。
    expect(find.text('法门无量，各有方便。'), findsOneWidget,
        reason: '无数据时应退回引语卡');
    expect(find.text('宗门有别，方便有异；'), findsOneWidget);
    expect(find.text('究竟之法，本无二三。'), findsOneWidget);
    expect(find.text('暂无热门讨论'), findsNothing, reason: '不该再出现占位文案');
    expect(find.text('进入讨论'), findsNothing, reason: '无数据时没有讨论入口');
  });
}
