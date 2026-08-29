import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/bodhi_space_page.dart';
import 'package:my_flutter_app/user_avatar.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('bodhi space header, tabs and custom sheet do not crash',
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
    await tester.scrollUntilVisible(find.text('自定义'), 300,
        scrollable: customScroll.first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull,
        reason: 'header reveal threw');

    // Tabs are now 讨论/推荐/关注; 公告 moved to a top-right icon entry.
    expect(find.text('讨论'), findsOneWidget, reason: '讨论 tab missing');
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

    // Open the custom dropdown panel via the custom tab,
    // then enter the add sheet via the in-panel add row.
    await tester.tap(find.text('自定义'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('添加关注的经文和话题'), findsOneWidget,
        reason: 'empty panel should show the add row');
    await tester.tap(find.text('添加关注的经文和话题'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: 'custom sheet threw');
    expect(find.text('添加经文或话题，数量不限'), findsOneWidget);

    // Close the sheet without saving.
    await tester.tap(find.text('完成'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'closing custom sheet threw');
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
      find.descendant(of: scrollable.first, matching: find.text('自定义')),
      findsOneWidget,
      reason: 'tab bar should live inside the scrollable content',
    );

    // 栏目栏吸顶：与个人主页同款，上滑时钉在顶部。
    final header = tester.widget<SliverPersistentHeader>(
      find.byType(SliverPersistentHeader),
    );
    expect(header.pinned, isTrue,
        reason: 'tab bar must be pinned like the user-space toolbar');
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

