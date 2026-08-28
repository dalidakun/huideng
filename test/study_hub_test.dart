import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/bodhi_space_page.dart';
import 'package:my_flutter_app/user_avatar.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('bodhi space header, tabs and sort sheet do not crash',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: BodhiSpacePage(),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull,
        reason: 'initial study hub build threw');

    final customScroll = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );

    // Reveal the tab bar header.
    await tester.scrollUntilVisible(find.byIcon(Icons.menu), 300,
        scrollable: customScroll.first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull,
        reason: 'header reveal threw');

    // Tabs are now 热门/推荐/关注; 公告 moved to a top-right icon entry.
    expect(find.text('热门'), findsOneWidget, reason: '热门 tab missing');
    expect(find.text('推荐'), findsOneWidget, reason: '推荐 tab missing');
    expect(find.text('关注'), findsOneWidget, reason: '关注 tab missing');
    expect(find.text('公告'), findsNothing,
        reason: '公告 should no longer be a tab');

    // Announce icon (gao1/gao2) present in the top bar.
    final announceIcon = find.image(const AssetImage('assets/images/gao1.png'));
    final announceIconPlain =
        find.image(const AssetImage('assets/images/gao2.png'));
    expect(
      announceIcon.evaluate().length + announceIconPlain.evaluate().length,
      1,
      reason: 'announce icon should be present in the top bar',
    );

    // Switch to 关注 tab.
    await tester.tap(find.text('关注'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: 'follow tab threw');

    // Open the tab-sort bottom sheet.
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: 'sort sheet threw');
    expect(find.text('栏目排序'), findsOneWidget);

    // Drag 关注 above 热门 via its drag handle.
    final handle = find.descendant(
      of: find.widgetWithText(ListTile, '关注'),
      matching: find.byIcon(Icons.drag_handle),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveBy(const Offset(0, -160));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: 'reorder drag threw');

    // Confirm the new order and close the sheet.
    await tester.tap(find.text('完成'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'completing sort threw');
  });

  testWidgets('top bar is not fixed: avatar, title and tabs scroll with content',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: BodhiSpacePage(),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: 'initial build threw');

    // 不再有固定 AppBar：顶部栏整体移入滚动内容，随内容一起滚走。
    expect(find.byType(AppBar), findsNothing);

    final scrollable = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );

    // 头像、图标 + 「菩提空间」标题、栏目栏都在滚动视口内。
    expect(
      find.descendant(of: scrollable.first, matching: find.byType(UserAvatar)),
      findsOneWidget,
      reason: 'avatar should live inside the scrollable content',
    );
    expect(
      find.descendant(of: scrollable.first, matching: find.text('菩提空间')),
      findsOneWidget,
      reason: 'title should live inside the scrollable content',
    );
    expect(
      find.descendant(of: scrollable.first, matching: find.byIcon(Icons.menu)),
      findsOneWidget,
      reason: 'tab bar should live inside the scrollable content',
    );

    // 栏目栏不再吸顶：随内容滚走而非固定。
    final header = tester.widget<SliverPersistentHeader>(
      find.byType(SliverPersistentHeader),
    );
    expect(header.pinned, isFalse,
        reason: 'tab bar must not be pinned in the new design');
  });

  testWidgets('new-note FAB is present on the bodhi space', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: BodhiSpacePage(),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.image(const AssetImage('assets/images/write.png')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

