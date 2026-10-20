import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/app_palette.dart';
import 'package:my_flutter_app/app_state.dart';
import 'package:my_flutter_app/sutra_list_page.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

Future<void> _pumpSutraList(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: SutraListPage()));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      return Directory.systemTemp.path;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
  });

  testWidgets('素白：右上角搜索图标取代助手入口，点击顶部悬浮搜索框',
      (tester) async {
    await AppPalette.instance.load();
    expect(AppPalette.instance.isPlain, isTrue);

    await _pumpSutraList(tester);
    expect(tester.takeException(), isNull, reason: '经藏页首屏不应抛异常');

    // 顶部不再有常驻搜索入口行。
    expect(find.text('搜索经文'), findsNothing,
        reason: '素白顶部搜索入口行应已移到右上角图标');
    // 右上角是搜索图标：素白外观下经藏页不再提供 DeepSeek 入口
    // （原「顶部下拉露出 DeepSeek」手势与助手图标都已移除）。
    final appBarIcons = find.descendant(
        of: find.byType(AppBar), matching: find.byIcon(Icons.search));
    expect(appBarIcons, findsOneWidget, reason: 'AppBar 右上角应有搜索图标');
    expect(find.image(const AssetImage('assets/images/assistant000.png')),
        findsNothing,
        reason: '素白外观不在右上角放助手图标');
    expect(find.byType(TextField), findsNothing, reason: '未点搜索前不显示搜索框');

    await tester.tap(appBarIcons);
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull, reason: '展开搜索框不应抛异常');
    expect(find.byType(TextField), findsOneWidget,
        reason: '点击搜索图标后顶部应悬浮出搜索框');

    // 关闭按钮退出搜索，回到普通页面。
    final closeBtn = find.descendant(
        of: find.byType(TextField), matching: find.byIcon(Icons.close));
    expect(closeBtn, findsOneWidget, reason: '搜索框内应有关闭按钮');
    await tester.tap(closeBtn);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TextField), findsNothing, reason: '点关闭应退出搜索');
    expect(find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.search)),
        findsOneWidget,
        reason: '退出后搜索图标回来');
  });

  testWidgets('素白：下拉不再露出 DeepSeek（手势已移除，回归防线）', (tester) async {
    await AppPalette.instance.load();
    expect(AppPalette.instance.isPlain, isTrue);

    await _pumpSutraList(tester);
    expect(tester.takeException(), isNull, reason: '经藏页首屏不应抛异常');
    expect(homeReveal.value, isFalse);
    expect(homeRevealScrub.value, 0);

    final scrollable = find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(Scrollable));
    expect(scrollable, findsOneWidget, reason: '应有内容滚动区');

    // 大幅下拉：不应展开 DeepSeek。
    await tester.drag(scrollable, const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 100));
    expect(homeReveal.value, isFalse,
        reason: '经藏页的「下拉露出 DeepSeek」手势已移除，下拉不应打开 DeepSeek');
    expect(homeRevealScrub.value, 0, reason: '不应有任何露出进度');

    // 跟手手势同样不应被接管：没有露出进度，也没有内容被钉死。
    final gesture = await tester.startGesture(tester.getCenter(scrollable));
    await gesture.moveBy(const Offset(0, 200));
    await tester.pump();
    expect(homeRevealScrub.value, 0, reason: '跟手下拉不应产生露出进度');
    expect(homeReveal.value, isFalse, reason: '未松手也不应展开');

    await gesture.moveBy(const Offset(0, -200));
    await tester.pump();
    expect(homeRevealScrub.value, 0, reason: '反向上拖同样不应有露出进度');

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 450));
    expect(homeReveal.value, isFalse, reason: '松手后也不应打开 DeepSeek');
    expect(homeRevealScrub.value, 0);

    homeReveal.value = false;
    homeRevealScrub.value = 0;
  });

  testWidgets('米黄：保留右上角助手入口，搜索框仍在「经典入口」行',
      (tester) async {
    await AppPalette.instance.load();
    await AppPalette.instance.setMode(AppearanceMode.warm);
    expect(AppPalette.instance.isPlain, isFalse);

    await _pumpSutraList(tester);
    expect(tester.takeException(), isNull, reason: '经藏页首屏不应抛异常');

    expect(find.image(const AssetImage('assets/images/assistant000.png')),
        findsOneWidget,
        reason: '米黄外观保留右上角助手入口');
    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.byIcon(Icons.search)),
        findsNothing,
        reason: '米黄不在 AppBar 放搜索图标');
    expect(find.text('搜索经文'), findsOneWidget,
        reason: '米黄搜索框仍在「经典入口」标题行右侧');

    // 米黄外观不启用下拉打开 DeepSeek 的手势。
    final scrollable = find.descendant(
        of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable));
    expect(scrollable, findsOneWidget, reason: '应有内容滚动区');
    await tester.drag(scrollable, const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 100));
    expect(homeReveal.value, isFalse,
        reason: '米黄保留右上角入口，顶部下拉不应打开 DeepSeek');
    expect(homeRevealScrub.value, 0, reason: '米黄不应有露出进度');
    if (homeReveal.value) homeReveal.value = false;

    await tester.ensureVisible(find.text('搜索经文'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('搜索经文'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TextField), findsOneWidget,
        reason: '米黄点搜索框进入搜索态');

    await AppPalette.instance.setMode(AppearanceMode.plain);
  });
}
