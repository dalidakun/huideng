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
    // 右上角是搜索图标，DeepSeek 助手入口已让位。
    final appBarIcons = find.descendant(
        of: find.byType(AppBar), matching: find.byIcon(Icons.search));
    expect(appBarIcons, findsOneWidget, reason: 'AppBar 右上角应有搜索图标');
    expect(find.image(const AssetImage('assets/images/assistant000.png')),
        findsNothing,
        reason: '素白下拉打开 DeepSeek，右上角不再放助手图标');
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

  testWidgets('素白：经藏页顶部下拉打开 DeepSeek（主页同款手势）', (tester) async {
    await AppPalette.instance.load();
    expect(AppPalette.instance.isPlain, isTrue);

    await _pumpSutraList(tester);
    expect(tester.takeException(), isNull, reason: '经藏页首屏不应抛异常');
    expect(homeReveal.value, isFalse);

    final scrollable = find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(Scrollable));
    expect(scrollable, findsOneWidget, reason: '应有内容滚动区');

    await tester.drag(scrollable, const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 100));
    expect(homeReveal.value, isFalse,
        reason: '素白小滑动不应触发 DeepSeek');
    expect(homeRevealScrub.value, 0, reason: '小滑动不应有露出进度');

    await tester.drag(scrollable, const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 100));
    expect(homeReveal.value, isTrue,
        reason: '素白右上角换成搜索后，顶部下拉过半应展开 DeepSeek');

    homeReveal.value = false;
    homeRevealScrub.value = 0;
    await tester.pump(const Duration(milliseconds: 450));
  });

  testWidgets('素白：下拉跟手逐渐露出，反向上拖再收回就不显示',
      (tester) async {
    await AppPalette.instance.load();
    expect(AppPalette.instance.isPlain, isTrue);

    await _pumpSutraList(tester);
    expect(tester.takeException(), isNull, reason: '经藏页首屏不应抛异常');
    expect(homeReveal.value, isFalse);
    expect(homeRevealScrub.value, 0);

    final scrollable = find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(Scrollable));
    final gesture = await tester.startGesture(tester.getCenter(scrollable));

    // 小滑动（未过起始阈值）：完全不露出。
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(homeRevealScrub.value, 0, reason: '小滑动不应触发露出');
    expect(homeReveal.value, isFalse);

    // 过阈值后下拉：进度随手指增长，且未到展开阈值时不会直接弹出。
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(homeRevealScrub.value, greaterThan(0),
        reason: '过阈值后下拉应按位移逐渐露出');
    expect(homeReveal.value, isFalse, reason: '未过半不应直接展开');

    // 继续下拉：露出量持续增长。
    final growing = homeRevealScrub.value;
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(homeRevealScrub.value, greaterThan(growing),
        reason: '继续下拉应继续逐渐露出');
    expect(homeReveal.value, isFalse, reason: '松手前只跟手露出，不直接展开');

    // 露出期间底层页面必须「僵死」：内容滚动偏移保持为 0，不跟手滑动。
    final scrollState = tester.state<ScrollableState>(scrollable);
    expect(scrollState.position.pixels, 0,
        reason: '逐渐露出期间经藏页内容应钉死不动');

    await gesture.moveBy(const Offset(0, -240));
    await tester.pump();
    expect(homeRevealScrub.value, 0, reason: '反向上拖应把露出量收回');
    expect(homeReveal.value, isFalse);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 450));
    expect(homeReveal.value, isFalse, reason: '收回后再松手不应打开 DeepSeek');
    expect(homeRevealScrub.value, 0);
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
