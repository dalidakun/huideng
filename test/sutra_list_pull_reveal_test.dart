import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/app_palette.dart';
import 'package:my_flutter_app/app_state.dart';
import 'package:my_flutter_app/sutra_list_page.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

Future<void> _pump(WidgetTester tester, {required bool enabled}) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await AppPalette.instance.load();
  await tester.pumpWidget(MaterialApp(
    home: SutraListPage(enableShanZhiShiReveal: enabled),
  ));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _drag(WidgetTester tester) async {
  final scrollable = find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.byType(Scrollable));
  final gesture = await tester.startGesture(tester.getCenter(scrollable));
  await gesture.moveBy(const Offset(0, 200));
  await tester.pump();
  expect(shanzhishiRevealScrub.value, greaterThan(0));
  expect(homeRevealScrub.value, 0);
  await gesture.moveBy(const Offset(0, 500));
  await tester.pump();
  expect(shanzhishiRevealScrub.value, greaterThan(0.5));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 50));
  expect(shanzhishiReveal.value, isTrue);
  expect(homeReveal.value, isFalse);
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
    shanzhishiReveal.value = false;
    shanzhishiRevealScrub.value = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
  });

  testWidgets('开启时下拉露出善知识', (tester) async {
    await _pump(tester, enabled: true);
    await _drag(tester);
  });

  testWidgets('未开启（push 进来的经藏页）下拉不露出', (tester) async {
    await _pump(tester, enabled: false);
    final scrollable = find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(Scrollable));
    final gesture = await tester.startGesture(tester.getCenter(scrollable));
    await gesture.moveBy(const Offset(0, 700));
    await tester.pump();
    expect(shanzhishiRevealScrub.value, 0);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));
    expect(shanzhishiReveal.value, isFalse);
  });
}
