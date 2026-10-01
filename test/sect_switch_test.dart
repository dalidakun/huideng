import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/app_palette.dart';
import 'package:my_flutter_app/sect_detail_page.dart';
import 'package:my_flutter_app/sect_page.dart';
import 'package:my_flutter_app/sect_switch.dart';

void main() {
  final tone = Color(0xFF6E7F66);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSwitch(
    WidgetTester tester, {
    required int index,
    required ValueChanged<int> onChanged,
    String left = '核心经典',
    String right = '天台宗社区',
    double width = 300,
  }) async {
    tester.view.physicalSize = const Size(400, 120);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: AppPalette.p.bg,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SectSwitch(
              index: index,
              onChanged: onChanged,
              leftLabel: left,
              rightLabel: right,
              tone: tone,
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('切换方式', () {
    testWidgets('点左半 / 点右半都能切', (tester) async {
      var to = -1;
      await pumpSwitch(tester, index: 0, onChanged: (i) => to = i);

      // 点右半：核心经典 → 社区（切换条被屏宽夹到 200，取右半中心）。
      await tester.tapAt(tester.getTopLeft(find.byType(SectSwitch)) +
          const Offset(150, 20));
      await tester.pump(const Duration(milliseconds: 400));
      expect(to, 1, reason: '点右半切到社区');

      // 再点回左半：社区 → 核心经典
      to = -1;
      await pumpSwitch(tester, index: 1, onChanged: (i) => to = i);
      await tester.tapAt(tester.getTopLeft(find.byType(SectSwitch)) +
          const Offset(50, 20));
      await tester.pump(const Duration(milliseconds: 400));
      expect(to, 0, reason: '点左半切回核心经典');
    });

    testWidgets('点在已选中的一侧不重复回调', (tester) async {
      var to = -1;
      await pumpSwitch(tester, index: 0, onChanged: (i) => to = i);
      await tester.tapAt(tester.getTopLeft(find.byType(SectSwitch)) +
          const Offset(50, 20));
      await tester.pump(const Duration(milliseconds: 400));
      expect(to, -1, reason: '已经在左侧了，不该再回调');
    });

    testWidgets('胶囊自己不认领横向拖拽，把手势让给页面', (tester) async {
      var to = -1;
      await pumpSwitch(tester, index: 0, onChanged: (i) => to = i);

      await tester.drag(find.byType(SectSwitch), const Offset(90, 0));
      await tester.pump(const Duration(milliseconds: 400));
      expect(to, -1,
          reason: '横向滑动由外层 PageView 翻页，胶囊只做点选，不能自己吃掉手势');
    });

    testWidgets('两段标签都在，两侧都可点', (tester) async {
      await pumpSwitch(tester, index: 0, onChanged: (_) {});
      expect(find.text('核心经典'), findsOneWidget);
      expect(find.text('天台宗社区'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('两段连成一颗胶囊：中间无空当、共同被一个圆角外框包住',
        (tester) async {
      await pumpSwitch(tester, index: 0, onChanged: (_) {}, width: 300);

      final box = tester.getRect(find.byType(SectSwitch));
      final l = tester.getRect(find.byKey(SectSwitch.leftKey));
      final r = tester.getRect(find.byKey(SectSwitch.rightKey));

      // 两段文字紧挨着，中线就是接缝，不留空当、不画线。
      expect(r.left, closeTo(l.right, 0.5), reason: '两段之间没有空当');
      expect(l.width, closeTo(r.width, 0.5), reason: '两段等宽');
      // 两段合起来正好铺满整颗外框 —— 它们是被同一个框包住的，不是各自一颗。
      expect(l.left, closeTo(box.left, 0.5));
      expect(r.right, closeTo(box.right, 0.5));
      expect(l.height, SectSwitch.height);
      expect(l.height, closeTo(box.height, 0.5));
    });

    testWidgets('整块不描边：按钮所在区域不要实体线框框', (tester) async {
      await pumpSwitch(tester, index: 0, onChanged: (_) {});

      final boxes = tester.widgetList<DecoratedBox>(find.descendant(
          of: find.byType(SectSwitch), matching: find.byType(DecoratedBox)));
      expect(boxes, isNotEmpty, reason: '外框与滑动填充都该走 DecoratedBox');
      for (final b in boxes) {
        final d = b.decoration as BoxDecoration;
        expect(d.border, isNull, reason: '整块不要描边，只留淡底与滑动填充');
      }
    });

    testWidgets('长名字不撑破胶囊：文字省略而不是横向溢出', (tester) async {
      await pumpSwitch(tester,
          index: 1,
          onChanged: (_) {},
          right: '普贤行愿法门社区社区社区',
          width: 240);
      expect(tester.takeException(), isNull);
      expect(find.text('普贤行愿法门社区社区社区'), findsOneWidget);
    });
  });

  group('与页面配合', () {
    /// 判断停在哪一侧看右下角浮钮：经典侧只在展开文件夹且下滑后才挂「回到顶部」，
    /// 社区侧恒定挂「发帖」浮钮，所以浮钮在不在就是两半的可靠分界。
    final communitySide = find.byType(FloatingActionButton);

    /// 页面里常有一直转的加载指示器，pumpAndSettle 永远等不到静，只能定时推进。
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: SectDetailPage(sect: kSectList[2]), // 天台宗
      ));
      await tester.pump(const Duration(milliseconds: 300));
      expect(communitySide, findsNothing, reason: '默认停在核心经典那一侧');
    }

    testWidgets('左右拖过阈值换内容，途中画面一点不横移', (tester) async {
      await pumpPage(tester);
      final backBefore = tester.getRect(find.byIcon(Icons.arrow_back_ios_new));

      // 拖到一半就松手：还没过阈值，不该换。
      final g = await tester.startGesture(
          tester.getCenter(find.byType(SectDetailPage)));
      await g.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 16));
      // 拖动途中画面不跟着手指走：标题图 x 一动没动。
      expect(tester.getRect(find.byIcon(Icons.arrow_back_ios_new)).left,
          backBefore.left, reason: '拖动途中不该有任何横向位移');
      await g.up();
      await settle(tester);
      expect(communitySide, findsNothing, reason: '没过阈值不该换边');

      // 拖过阈值再松手 → 换到社区内容。
      await tester.drag(find.byType(SectDetailPage), const Offset(-260, 0));
      await settle(tester);
      expect(communitySide, findsOneWidget, reason: '向左拖过阈值应换到社区');
      expect(find.text('0 成员'), findsOneWidget, reason: '社区成员行进来了');
      // 换完之后头仍在原处（x 不变），只是换成了社区那半自己的一套。
      expect(tester.getRect(find.byIcon(Icons.arrow_back_ios_new)).left,
          backBefore.left, reason: '换边只换内容，不横移整页');

      // 再向右拖回核心经典。
      await tester.drag(find.byType(SectDetailPage), const Offset(260, 0));
      await settle(tester);
      expect(communitySide, findsNothing, reason: '向右拖过阈值应换回经典');
      expect(find.text('0 成员'), findsNothing, reason: '社区内容退出屏幕');
      expect(tester.takeException(), isNull);
    });

    testWidgets('任一时刻屏上只有一套切换条', (tester) async {
      await pumpPage(tester);
      expect(find.byType(SectSwitch), findsOneWidget,
          reason: '非当前侧 Offstage，屏上只有经典那半的一套');

      await tester.drag(find.byType(SectDetailPage), const Offset(-260, 0));
      await settle(tester);
      expect(find.byType(SectSwitch), findsOneWidget,
          reason: '换到社区后屏上换成社区那半自己的一套');
      expect(tester.takeException(), isNull);
    });

    testWidgets('标题图下就是切换条，整块随内容上滑滚走', (tester) async {
      tester.view.physicalSize = const Size(1080, 1200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: SectDetailPage(sect: kSectList[2]),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      final bar = tester.getRect(find.byType(SectSwitch));
      final back = tester.getRect(find.byIcon(Icons.arrow_back_ios_new));

      // 切换条紧贴在标题图下方（图高 118~190，再加 14 的上边距）。
      expect(bar.top, greaterThan(back.bottom),
          reason: '切换条应当在图片下方，而不是跑到页面最顶上');
      expect(bar.top, greaterThan(100), reason: '切换条没被提到图片上方');
      expect(bar.top, lessThan(260), reason: '切换条应当贴着图片下沿');

      // 两者都在这一半的滚动区里，所以上滑时一起走（图片与胶囊都藏起来）。
      expect(
        find.ancestor(of: find.byType(SectSwitch), matching: find.byType(ListView)),
        findsWidgets,
        reason: '标题图与胶囊应归内容滚动区管，才能随上滑隐藏',
      );

      await tester.drag(find.byType(SectDetailPage), const Offset(0, -300));
      await settle(tester);
      final backAfter = tester.getRect(find.byIcon(Icons.arrow_back_ios_new));
      final barAfter = tester.getRect(find.byType(SectSwitch));
      expect(backAfter.top, lessThan(back.top),
          reason: '上滑时标题图应跟着往上走');
      expect(barAfter.top, lessThan(bar.top),
          reason: '上滑时切换条应跟着一起走、最终隐藏');
      // 图与胶囊位移一致，说明是同一块内容整体上移。
      expect(barAfter.top - backAfter.top, closeTo(bar.top - back.top, 0.5),
          reason: '图与胶囊应当整体一起上移');
      expect(tester.takeException(), isNull);
    });

    testWidgets('拖得太短不算换边', (tester) async {
      await pumpPage(tester);

      // 阈值是 56：8 次各 2px 共 16px，远不到，不该换。
      final g = await tester.startGesture(
          tester.getCenter(find.byType(SectDetailPage)));
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(-2, 0));
        await tester.pump(const Duration(milliseconds: 60));
      }
      await g.up();
      await settle(tester);
      expect(communitySide, findsNothing, reason: '拖得太短，不该换边');
      expect(tester.takeException(), isNull);
    });

    testWidgets('点胶囊右段也切到社区，左段切回经典', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('天台宗社区').last);
      await tester.pump();
      await settle(tester);
      expect(communitySide, findsOneWidget, reason: '点右段切到社区');
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('核心经典').last);
      await tester.pump();
      await settle(tester);
      expect(communitySide, findsNothing, reason: '点左段切回经典');
      expect(tester.takeException(), isNull);
    });
  });
}