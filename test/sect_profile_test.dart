import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/sect_page.dart';
import 'package:my_flutter_app/sect_profile_card.dart';
import 'package:my_flutter_app/sect_profiles.dart';

void main() {
  group('介绍内容', () {
    test('八宗门 + 十二法门都有介绍，且四维齐全', () {
      expect(kSectProfiles.length, 20);
      for (final sect in [...kSectList, ...kGateList]) {
        final profile = sectProfileOf(sect);
        expect(profile, isNotNull, reason: '${sect.name} 缺介绍');
        expect(profile!.idea, isNotEmpty, reason: sect.name);
        expect(profile.practice, isNotEmpty, reason: sect.name);
        expect(profile.history, isNotEmpty, reason: sect.name);
        expect(profile.masters, isNotEmpty, reason: sect.name);
        for (final m in profile.masters) {
          expect(m.trim(), m, reason: '${sect.name}：不该有首尾空白');
        }
      }
    });

    test('介绍 key 与两栏栏目一一对应，不多不少', () {
      expect(
        kSectProfiles.keys.toSet(),
        [...kSectList, ...kGateList].map((s) => s.icon).toSet(),
      );
    });

    test('宗门祖师条目格式：姓名（贡献说明）', () {
      for (final sect in kSectList) {
        for (final m in sectProfileOf(sect)!.masters) {
          expect(m.contains('（'), isTrue, reason: '${sect.name}：$m');
          expect(m.contains('）'), isTrue, reason: '${sect.name}：$m');
        }
      }
    });

    test('文本不带半角引号，统一用「」', () {
      for (final sect in [...kSectList, ...kGateList]) {
        final profile = sectProfileOf(sect)!;
        final all = [
          profile.idea,
          profile.practice,
          profile.history,
          ...profile.masters,
        ];
        for (final t in all) {
          expect(t.contains('"'), isFalse, reason: '${sect.name}：$t');
          expect(t.contains("'"), isFalse, reason: '${sect.name}：$t');
        }
      }
    });

    test('二十条正文互不相同（防止复制粘贴串栏）', () {
      for (final sel in [
        (SectProfile p) => p.idea,
        (SectProfile p) => p.practice,
        (SectProfile p) => p.history,
      ]) {
        final texts = kSectProfiles.values.map(sel).toList();
        expect(texts.toSet().length, 20);
      }
    });

    test('别称不与其他栏目名/别称相撞', () {
      final names = {...kSectList, ...kGateList}.map((s) => s.name).toSet();
      final aliases = kSectProfiles.values
          .map((p) => p.alias)
          .where((a) => a.isNotEmpty)
          .toList();
      expect(aliases.toSet().length, aliases.length, reason: '别称互撞');
      for (final a in aliases) {
        expect(names.contains(a), isFalse, reason: a);
      }
    });

    test('法门别称按原文：通用工具 / 忏悔 / 内观 / 苦行', () {
      String aliasOf(SectIconKind k) => kSectProfiles[k]!.alias;
      expect(aliasOf(SectIconKind.gmJingtu), '通用工具');
      expect(aliasOf(SectIconKind.gmBaichan), '忏悔法门');
      expect(aliasOf(SectIconKind.gmNianchu), '内观法门');
      expect(aliasOf(SectIconKind.gmToutuo), '苦行法门');
      // 其余法门原文没给别称。
      for (final k in [
        SectIconKind.gmDizang,
        SectIconKind.gmGuanyin,
        SectIconKind.gmYaoshi,
        SectIconKind.gmMile,
        SectIconKind.gmBore,
        SectIconKind.gmLengyan,
        SectIconKind.gmPuxian,
        SectIconKind.gmShishi,
      ]) {
        expect(aliasOf(k), isEmpty, reason: '$k');
      }
    });
  });

  group('介绍卡', () {
    testWidgets('标题行不是开关，收起只由底部「展开全文」控制', (tester) async {
      final profile = sectProfileOf(sectByIcon(SectIconKind.pureLand))!;
      await tester.pumpWidget(_host(profile));
      await tester.pump();

      expect(find.text('宗派介绍'), findsOneWidget);
      // 示意图的卡头只有标题与居中的首节名，别称不再占位。
      expect(find.text('念佛门'), findsNothing);
      for (final label in ['核心思想', '重要祖师', '修行方式', '历史地位']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // 标题行没有折叠箭头。
      expect(find.byIcon(Icons.expand_more), findsNothing);
      expect(find.byType(AnimatedRotation), findsNothing);
      // 正文长，底部给展开入口（长度判断见下一组）。
      expect(find.text('展开全文'), findsOneWidget);
      // 点标题行不起作用：内容不因它增减。
      await tester.tap(find.text('宗派介绍'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('展开全文'), findsOneWidget);
      expect(find.text('核心思想'), findsOneWidget);
    });

    testWidgets('法门标题是「法门介绍」', (tester) async {
      final profile = sectProfileOf(sectByIcon(SectIconKind.gmBaichan))!;
      await tester.pumpWidget(
        _host(profile, title: '法门介绍'),
      );
      await tester.pump();

      expect(find.text('法门介绍'), findsOneWidget);
      expect(find.text('宗派介绍'), findsNothing);
      expect(find.text('忏悔法门'), findsNothing);
      for (final label in ['核心思想', '重要祖师', '修行方式', '历史地位']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('标题贴左，首节名浮在卡头正中', (tester) async {
      final profile = sectProfileOf(sectByIcon(SectIconKind.gmDizang))!;
      expect(profile.alias, isEmpty);
      await tester.pumpWidget(_host(profile, title: '法门介绍'));
      await tester.pump();

      final card = tester.getRect(find.byType(SectProfileCard));
      final title = tester.getTopLeft(find.text('法门介绍'));
      final first = tester.getRect(find.text('核心思想'));
      // 标题在卡内边距处（宿主 20 + 卡 16 + 竖杠 3 + 间距 8 ≈ 47），
      // 首节名不占行宽，整段居中浮在卡头。
      expect(title.dx, closeTo(47, 3));
      expect(first.center.dx, closeTo(card.center.dx, 4));
    });

    testWidgets('二十栏介绍默认收起，展开后四节都在', (tester) async {
      for (final sect in [...kSectList, ...kGateList]) {
        final title =
            sect.kind == SectMenuKind.gate ? '法门介绍' : '宗派介绍';
        await tester.pumpWidget(_host(sectProfileOf(sect)!, title: title));
        await tester.pump();
        // 现有二十栏正文都长过一屏：默认收起，底部给「展开全文」。
        expect(find.text('展开全文'), findsOneWidget, reason: sect.name);
        // 收起时只露一屏，卡片高度不该超过一屏加标题与展开行。
        expect(
          tester.getSize(find.byType(SectProfileCard)).height,
          lessThan(420),
          reason: sect.name,
        );
        // 渲染不抛布局异常即通过（RenderFlex overflow 会在此抛出）。
        expect(tester.takeException(), isNull, reason: sect.name);
      }
    });

    testWidgets('展开全文后四节逐字都在，样式与收起时一致', (tester) async {
      final profile = sectProfileOf(sectByIcon(SectIconKind.pureLand))!;
      await tester.pumpWidget(_host(profile));
      await tester.pump();

      final idea = find.text(profile.idea);
      expect(idea, findsOneWidget);
      final clippedStyle = tester.widget<Text>(idea).style;

      await tester.ensureVisible(find.text('展开全文'));
      await tester.tap(find.text('展开全文'));
      await tester.pump();

      for (final label in ['核心思想', '重要祖师', '修行方式', '历史地位']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      for (final m in profile.masters) {
        expect(find.text(m), findsOneWidget, reason: m);
      }
      expect(find.text(profile.practice), findsOneWidget);
      expect(find.text(profile.history), findsOneWidget);
      // 排版一个字都没改，只是把折起来的半截放出来。
      expect(tester.widget<Text>(find.text(profile.idea)).style, clippedStyle);
      expect(find.text('收起'), findsOneWidget);
    });

    testWidgets('正文过长时默认收起，展开全文后再收起', (tester) async {
      await tester.pumpWidget(_host(_overlong()));
      await tester.pump();

      expect(find.text('展开全文'), findsOneWidget);
      final collapsed = tester.getSize(find.byType(SectProfileCard)).height;

      // 收起线很长，展开入口在首屏之外，滚过去再点。
      await tester.ensureVisible(find.text('展开全文'));
      await tester.tap(find.text('展开全文'));
      await tester.pump();
      expect(find.text('收起'), findsOneWidget);
      final expanded = tester.getSize(find.byType(SectProfileCard)).height;
      expect(expanded, greaterThan(collapsed + 50));

      await tester.ensureVisible(find.text('收起'));
      await tester.tap(find.text('收起'));
      await tester.pump();
      expect(find.text('展开全文'), findsOneWidget);
      expect(
        tester.getSize(find.byType(SectProfileCard)).height,
        closeTo(collapsed, 0.5),
      );
    });

    testWidgets('首帧就是收起的样子，量完高度画面不再变', (tester) async {
      final profile = sectProfileOf(sectByIcon(SectIconKind.pureLand))!;
      await tester.pumpWidget(_host(profile));
      // 第一帧：还没量到高度，也已经按收起排。
      final first = tester.getSize(find.byType(SectProfileCard)).height;
      expect(find.text('展开全文'), findsOneWidget);
      // 量完高度后的下一帧：高度一模一样，看不到「先展开再收起」的一跳。
      await tester.pump();
      expect(
        tester.getSize(find.byType(SectProfileCard)).height,
        closeTo(first, 0.5),
      );
    });

    testWidgets('换栏目时不带上一门的展开状态', (tester) async {
      await tester.pumpWidget(_host(_overlong()));
      await tester.pump();
      await tester.ensureVisible(find.text('展开全文'));
      await tester.tap(find.text('展开全文'));
      await tester.pump();
      expect(find.text('收起'), findsOneWidget);

      await tester.pumpWidget(
        _host(sectProfileOf(sectByIcon(SectIconKind.gmShishi))!,
            title: '法门介绍'),
      );
      await tester.pump();
      // 换栏目回到默认收起（重新量高度），不是接着上一门的展开态。
      expect(find.text('展开全文'), findsOneWidget);
      expect(find.text('收起'), findsNothing);
      expect(find.text('历史地位'), findsOneWidget);
    });
  });
}

/// 造一条远超收起线的介绍，用来验「太长才收起」这条规则。
SectProfile _overlong() => SectProfile(
      alias: '超长样例',
      idea: '核心思想一段话，用来把正文撑到收起线以上。' * 120,
      masters: ['某祖师（把这一门的关键处讲定）', '另一位祖师（定下法门的规矩）'],
      practice: '修行方式一段话，同样把正文撑长。' * 120,
      history: '历史地位一段话，同样把正文撑长。' * 120,
    );

/// 介绍卡自带卡片外观，测试里只给一个可滚动的居中容器，避免屏幕高度截断长文本。
Widget _host(SectProfile profile, {String title = '宗派介绍'}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: SectProfileCard(
          profile: profile,
          title: title,
        ),
      ),
    ),
  );
}

/// 按图标取栏目，避免测试里另写一份 SectInfo 与真实列表走偏。
SectInfo sectByIcon(SectIconKind kind) =>
    (kind.isGate ? kGateList : kSectList).firstWhere((s) => s.icon == kind);
