import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/app_palette.dart';
import 'package:my_flutter_app/checkin_history_stats.dart';
import 'package:my_flutter_app/study_hub_page.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsPath') {
        return Directory.systemTemp.path;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
  });

  Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  Future<void> _useMode(AppearanceMode mode) async {
    await AppPalette.instance.setMode(mode);
  }

  const _sampleEntries = [
    CheckInStatEntry(
        key: 'reading',
        label: '诵经',
        unit: '遍',
        total: 12,
        goal: 40,
        detail: ['地藏菩萨本愿经', '金刚经']),
    CheckInStatEntry(
        key: 'nianfo',
        label: '念佛',
        unit: '声',
        total: 500,
        goal: 1000,
        detail: ['阿弥陀佛']),
  ];

  for (final mode in AppearanceMode.values) {
    testWidgets('历史统计显示具体功课内容（${mode.label}）', (tester) async {
      await _useMode(mode);
      await tester.pumpWidget(_wrap(SizedBox(
        width: 400,
        child: CheckInHistoryStats(
            entries: _sampleEntries, onOrderChanged: (_) {}),
      )));
      expect(find.text('诵经 · 地藏菩萨本愿经·金刚经'), findsOneWidget);
      expect(find.text('念佛 · 阿弥陀佛'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('500'), findsOneWidget);
    });
  }

  for (final mode in AppearanceMode.values) {
    testWidgets('历史统计显示完成百分比与合计（${mode.label}）', (tester) async {
      await _useMode(mode);
      await tester.pumpWidget(_wrap(SizedBox(
        width: 400,
        child: CheckInHistoryStats(entries: _sampleEntries),
      )));
      // 诵经 12/40 = 30%，念佛 500/1000 = 50%
      expect(find.text('/30%'), findsOneWidget);
      expect(find.text('/50%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final mode in AppearanceMode.values) {
    testWidgets('拖动排序回调按新顺序保存（${mode.label}）', (tester) async {
      await _useMode(mode);
      List<String>? saved;
      await tester.pumpWidget(_wrap(SizedBox(
        width: 400,
        child: CheckInHistoryStats(
          entries: const [
            CheckInStatEntry(
                key: 'reading',
                label: '诵经',
                unit: '遍',
                total: 1,
                detail: ['地藏']),
            CheckInStatEntry(
                key: 'nianfo',
                label: '念佛',
                unit: '声',
                total: 2,
                detail: ['阿弥陀佛']),
            CheckInStatEntry(
                key: 'mantra',
                label: '持咒',
                unit: '遍',
                total: 3,
                detail: ['楞严咒']),
          ],
          onOrderChanged: (keys) => saved = keys,
        ),
      )));
      final listView =
          tester.widget<ReorderableListView>(find.byType(ReorderableListView));
      listView.onReorder(2, 0);
      await tester.pump();
      expect(saved, ['mantra', 'reading', 'nianfo']);
      expect(tester.takeException(), isNull);
    });
  }

  for (final mode in AppearanceMode.values) {
    testWidgets('主页历史统计显示具体内容并按保存顺序（${mode.label}）',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 6000);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      SharedPreferences.setMockInitialValues({
        'checkin_records': jsonEncode([
          {
            'date': '2026-08-01',
            'type': 'reading',
            'label': '诵经',
            'name': '地藏菩萨本愿经',
            'amount': 1
          },
          {
            'date': '2026-08-02',
            'type': 'nianfo',
            'label': '念佛',
            'name': '阿弥陀佛',
            'amount': 100
          },
          {
            'date': '2026-08-03',
            'type': 'mantra',
            'label': '持咒',
            'name': '楞严咒',
            'amount': 3
          },
        ]),
        'checkin_goals': jsonEncode({
          'reading': 10,
          'nianfo': 400,
          'mantra': 6,
        }),
        'history_stats_order': ['mantra', 'reading', 'nianfo'],
      });

      await tester.runAsync(() async {
        await _useMode(mode);
        await StudyHubPageState.warmPrefs();

        await tester.pumpWidget(const MaterialApp(home: StudyHubPage()));
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });

      expect(find.text('历史统计'), findsOneWidget);

      final mantra = tester.getTopLeft(find.text('持咒 · 楞严咒'));
      final reading = tester.getTopLeft(find.text('诵经 · 地藏菩萨本愿经'));
      final nianfo = tester.getTopLeft(find.text('念佛 · 阿弥陀佛'));

      expect(mantra.dy, lessThan(reading.dy),
          reason: '持咒应排在保存顺序的第一位');
      expect(reading.dy, lessThan(nianfo.dy),
          reason: '诵经应在念佛之前（保持保存顺序）');

      // 诵经 1/10 = 10%，念佛 100/400 = 25%，持咒 3/6 = 50%
      expect(find.text('/10%'), findsOneWidget);
      expect(find.text('/25%'), findsOneWidget);
      expect(find.text('/50%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}