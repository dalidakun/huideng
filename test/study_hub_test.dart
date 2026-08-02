import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/study_hub_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('study hub header, tabs and sort sheet do not crash',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: StudyHubPage(),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull,
        reason: 'initial study hub build threw');

    final customScroll = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );

    // Reveal the pinned header.
    await tester.scrollUntilVisible(find.byIcon(Icons.menu), 300,
        scrollable: customScroll.first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull,
        reason: 'header reveal threw');

    // Switch to 公告 tab.
    await tester.tap(find.text('公告'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: 'announce tab threw');
    expect(find.text('暂无公告'), findsOneWidget);

    // Open the tab-sort bottom sheet.
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: 'sort sheet threw');
    expect(find.text('栏目排序'), findsOneWidget);

    // Drag 关注 below 公告 via its drag handle.
    final handle = find.descendant(
      of: find.widgetWithText(ListTile, '关注'),
      matching: find.byIcon(Icons.drag_handle),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: 'reorder drag threw');

    // Confirm the new order and close the sheet.
    await tester.tap(find.text('完成'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'completing sort threw');
  });

  testWidgets('tab bar stays pinned when switching to short-content tabs',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: StudyHubPage(),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    final scrollable = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );

    // Scroll down so the pinned header reaches the appbar bottom edge.
    await tester.drag(scrollable.first, const Offset(0, -700));
    await tester.pump(const Duration(milliseconds: 300));

    final pinnedTop = tester.getTopLeft(find.byIcon(Icons.menu)).dy;
    expect(pinnedTop, lessThan(100),
        reason: 'tab bar should be pinned near the top edge of the viewport');

    // Switch to 关注 (little/no content) - the tab bar must not drop.
    await tester.tap(find.text('关注'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'follow tab threw');
    expect(
      tester.getTopLeft(find.byIcon(Icons.menu)).dy,
      closeTo(pinnedTop, 1.0),
      reason: 'tab bar dropped after switching to 关注',
    );

    // Same for 公告.
    await tester.tap(find.text('公告'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'announce tab threw');
    expect(
      tester.getTopLeft(find.byIcon(Icons.menu)).dy,
      closeTo(pinnedTop, 1.0),
      reason: 'tab bar dropped after switching to 公告',
    );

    // Back to 发现.
    await tester.tap(find.text('发现'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'discover tab threw');
    expect(
      tester.getTopLeft(find.byIcon(Icons.menu)).dy,
      closeTo(pinnedTop, 1.0),
      reason: 'tab bar dropped after switching back to 发现',
    );
  });

  testWidgets('new-note FAB is present on the study hub', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: StudyHubPage(),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

