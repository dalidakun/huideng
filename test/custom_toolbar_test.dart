import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/bodhi_space_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('add custom item then finish does not crash', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: BodhiSpacePage()));
    await tester.pump(const Duration(milliseconds: 400));

    final customScroll = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.text('自定义'), 300,
        scrollable: customScroll.first);
    await tester.pump(const Duration(milliseconds: 200));

    // 自定义栏目 → 下拉面板（空时只有添加行）→ 添加行 → 添加弹窗。
    await tester.tap(find.text('自定义'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('添加关注的经文和话题'), findsOneWidget,
        reason: 'empty panel should show the add row');
    await tester.tap(find.text('添加关注的经文和话题'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'sheet open threw');

    // 输入 #话题：触发联想（测试环境无网络，走「创建话题」入口）。
    await tester.enterText(
        find.byType(TextField).last, '#打坐');
    await tester.pump(const Duration(milliseconds: 300));
    final createRow = find.text('创建话题 #打坐');
    expect(createRow, findsOneWidget, reason: 'create-topic row missing');
    await tester.tap(createRow);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull, reason: 'adding item threw');

    // 点击完成：关闭弹窗并保存。
    await tester.tap(find.text('完成'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'finishing sheet threw');

    // 保存后下拉面板保持展开：直接显示新条目与「继续添加」行。
    expect(find.text('自定义'), findsOneWidget);
    expect(find.text('打坐'), findsOneWidget);
    expect(find.text('继续添加经文和话题'), findsOneWidget);
    // 面板是悬浮层（Overlay + LayerLink 锚定），不占滚动列表位置。
    expect(find.byType(CompositedTransformFollower), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'expanding panel threw');

    // 点击面板外区域：悬浮面板收起。
    await tester.tapAt(const Offset(200, 800));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('打坐'), findsNothing,
        reason: 'panel should close on outside tap');
    expect(tester.takeException(), isNull, reason: 'closing panel threw');
  });

  testWidgets('finish while search pending does not crash', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: BodhiSpacePage()));
    await tester.pump(const Duration(milliseconds: 400));

    final customScroll = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.text('自定义'), 300,
        scrollable: customScroll.first);
    await tester.pump(const Duration(milliseconds: 200));

    // 自定义栏目 → 下拉面板 → 添加行 → 添加弹窗。
    await tester.tap(find.text('自定义'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('添加关注的经文和话题'));
    await tester.pump(const Duration(milliseconds: 400));

    // 输入后立即点完成：防抖搜索仍在进行，关闭后回调不得 setSheet。
    await tester.enterText(find.byType(TextField).last, r'$地藏');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('完成'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(BottomSheet), findsNothing,
        reason: 'sheet should be closed after 完成');
    expect(tester.takeException(), isNull,
        reason: 'finishing with pending search threw');
  });
}
