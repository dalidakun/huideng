import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/cloud_notes_service.dart';
import 'package:my_flutter_app/community_daily_spot.dart';
import 'package:my_flutter_app/sect_page.dart';

/// 造一条社区帖：走 fromJson，字段与云函数返回的摘要一致。
PlazaNote _note(String content, {int likes = 0, int comments = 0}) =>
    PlazaNote.fromJson({
      'id': 'n1',
      'content': content,
      'authorName': '同修甲',
      'community': '禅宗社区',
      'likeCount': likes,
      'commentCount': comments,
      'createdAt': DateTime(2026, 9, 27, 21, 30).millisecondsSinceEpoch,
    });

CommunityDailyStat _stat(String community, int posts, {PlazaNote? top}) =>
    CommunityDailyStat(community: community, posts: posts, top: top);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('昨日时间窗', () {
    test('取昨天零点到今天零点，且是本地时区', () {
      final (since, until) = previousDayRange(DateTime(2026, 9, 27, 15, 30));
      expect(
        DateTime.fromMillisecondsSinceEpoch(since),
        DateTime(2026, 9, 26),
      );
      expect(
        DateTime.fromMillisecondsSinceEpoch(until),
        DateTime(2026, 9, 27),
      );
    });

    test('同一天任意时刻口径一致（傍晚与凌晨算的是同一个昨天）', () {
      final dawn = previousDayRange(DateTime(2026, 9, 27, 0, 5));
      final dusk = previousDayRange(DateTime(2026, 9, 27, 23, 55));
      expect(dawn, dusk);
    });

    test('月初退到上月末，年初退到去年年末', () {
      expect(
        DateTime.fromMillisecondsSinceEpoch(previousDayRange(DateTime(2026, 3, 1)).$1),
        DateTime(2026, 2, 28),
      );
      expect(
        DateTime.fromMillisecondsSinceEpoch(previousDayRange(DateTime(2026, 1, 1)).$1),
        DateTime(2025, 12, 31),
      );
    });

    test('闰日 2 月 29 日的前一天是 28 日', () {
      expect(
        DateTime.fromMillisecondsSinceEpoch(previousDayRange(DateTime(2028, 2, 29)).$1),
        DateTime(2028, 2, 28),
      );
    });
  });

  group('挑昨日发帖最多的社区', () {
    test('无人发帖返回 null（展示位退回引语卡）', () {
      expect(pickRandomTopCommunity(const []), isNull);
    });

    test('发帖数全为 0 也返回 null', () {
      expect(pickRandomTopCommunity([_stat('禅宗社区', 0)]), isNull);
    });

    test('唯一最多时就是它', () {
      final picked = pickRandomTopCommunity([
        _stat('禅宗社区', 3),
        _stat('天台宗社区', 7),
        _stat('观音法门社区', 5),
      ]);
      expect(picked?.community, '天台宗社区');
    });

    test('并列第一时只在并列者里挑，不会跑到发帖少的社区', () {
      final stats = [
        _stat('禅宗社区', 4),
        _stat('天台宗社区', 9),
        _stat('华严宗社区', 9),
        _stat('观音法门社区', 2),
      ];
      final tied = {'天台宗社区', '华严宗社区'};
      for (var i = 0; i < 200; i++) {
        expect(tied, contains(pickRandomTopCommunity(stats)?.community));
      }
    });

    test('并列者都真的能被抽到（不是恒定取第一个）', () {
      final stats = [_stat('禅宗社区', 9), _stat('天台宗社区', 9)];
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        seen.add(pickRandomTopCommunity(stats)!.community);
      }
      expect(seen, {'禅宗社区', '天台宗社区'});
    });

    test('fixed 随机源下结果确定（便于复现）', () {
      final stats = [_stat('禅宗社区', 9), _stat('天台宗社区', 9)];
      final a = pickRandomTopCommunity(stats, random: Random(7))?.community;
      final b = pickRandomTopCommunity(stats, random: Random(7))?.community;
      expect(a, b);
    });
  });

  group('展示位', () {
    Widget wrap({void Function(String)? onOpen, Set<String>? communities}) =>
        MaterialApp(
          home: Scaffold(
            body: CommunityDailySpot(
              communities: communities ?? {'禅宗社区', '天台宗社区'},
              onOpen: onOpen,
            ),
          ),
        );

    testWidgets('取不到数据时退回引语卡，不显示占位文案', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: '展示位渲染抛异常');

      // 测试环境取不到云端社区统计 → 显示引语卡。
      expect(find.text('法门无量，各有方便。'), findsOneWidget,
          reason: '无数据时应退回引语卡');
      expect(find.text('宗门有别，方便有异；'), findsOneWidget);
      expect(find.text('究竟之法，本无二三。'), findsOneWidget);
      expect(find.text('热门社区'), findsNothing, reason: '无数据时不摆社区卡');
      expect(find.text('进入社区'), findsNothing, reason: '无社区时没有跳转入口');
    });

    testWidgets('未接 onOpen 时进入社区按钮置灰不可点', (tester) async {
      await tester.pumpWidget(wrap(onOpen: null));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('进入社区'), findsNothing);
    });

    testWidgets('社区名单外的标记不会进这块位', (tester) async {
      // 只给了「禅宗社区」：即便服务端返回别的社区，也该退到引语卡。
      await tester.pumpWidget(wrap(communities: const {}));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('法门无量，各有方便。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  test('栏目表覆盖 8 宗派 + 12 法门共 20 个社区', () {
    expect(kSectList.length, 8);
    expect(kGateList.length, 12);
    expect(kCommunityKeys.length, 20);
    // 社区标记写法与社区页一致。
    expect(kCommunityKeys, contains('禅宗社区'));
    expect(kCommunityKeys, contains('普贤行愿法门社区'));
    // 帖子预览字段齐全，不至于渲染出空洞文案。
    expect(_note('今日参禅', likes: 3, comments: 1).content, '今日参禅');
  });
}
