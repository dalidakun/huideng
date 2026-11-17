import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/dedication_page.dart';
import 'package:my_flutter_app/dedication_store.dart';

/// 打开抽屉的测试壳：按钮拿到页面 context，点击后把抽屉返回值写进 result。
Widget _host(Future<void> Function(BuildContext context) onOpen) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => onOpen(context),
            child: const Text('打开回向'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('当前回向到期后归入历史，可从历史再次使用并重新计时', (tester) async {
    SharedPreferences.setMockInitialValues({
      DedicationStore.textKey: '愿以此功德，回向给我的父母。',
      DedicationStore.startKey: '2020-01-01',
      DedicationStore.endKey: '2020-01-07',
    });

    String? result;
    await tester.pumpWidget(_host((context) async {
      result = await showDedicationSheet(context);
    }));

    await tester.tap(find.text('打开回向'));
    await tester.pumpAndSettle();

    // 右上角不再有叉号，改成历史记录入口。
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byIcon(Icons.history), findsOneWidget);

    // 已到期：对账后当前回向为空，编辑框显示默认回向状态。
    expect(find.text('默认回向'), findsOneWidget);
    expect(find.textContaining('当前使用默认回向'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byType(TextField).first)
          .controller!
          .text,
      isEmpty,
    );

    // 打开历史：到期的那条带开始时间、持续天数。
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    expect(find.text('回向历史'), findsOneWidget);
    expect(find.text('愿以此功德，回向给我的父母。'), findsOneWidget);
    expect(find.text('共 7 天'), findsOneWidget);
    expect(find.textContaining('2020年1月1日'), findsOneWidget);

    // 再次使用后回填到编辑框，并恢复持续时间设置。
    await tester.tap(find.text('再次使用'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byType(TextField).first)
          .controller!
          .text,
      '愿以此功德，回向给我的父母。',
    );
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result, '愿以此功德，回向给我的父母。');
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    expect(
      prefs.getString(DedicationStore.startKey),
      DedicationStore.dateKey(now),
    );
    expect(
      prefs.getString(DedicationStore.endKey),
      DedicationStore.dateKey(DateTime(now.year, now.month, now.day + 6)),
      reason: '从历史再次使用后按 7 天重新计时',
    );
  });

  testWidgets('填写回向并选持续时间后保存，天数输入与选项同高', (tester) async {
    String? result;
    await tester.pumpWidget(_host((context) async {
      result = await showDedicationSheet(context);
    }));

    await tester.tap(find.text('打开回向'));
    await tester.pumpAndSettle();

    // 未设置过回向：默认回向，持续天数输入框不出现。
    expect(find.text('默认回向'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget,
        reason: '默认回向时不显示持续天数输入框');
    expect(find.textContaining('默认回向长期有效'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '愿以此功德，回向法界。');
    await tester.pump();

    // 填了正文之后才出现持续时间设置。
    expect(find.byType(TextField), findsNWidgets(2));
    expect(tester.getSize(find.byType(TextField).at(1)).height, lessThan(34),
        reason: '自定义天数输入应和上方天数选项一样是胶囊高度');

    await tester.tap(find.text('21 天'));
    await tester.pump();
    expect(find.textContaining('共 21 天'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result, '愿以此功德，回向法界。');
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    expect(
      prefs.getString(DedicationStore.endKey),
      DedicationStore.dateKey(DateTime(now.year, now.month, now.day + 20)),
    );
    expect(DedicationStore.effective(prefs), '愿以此功德，回向法界。');
  });

  testWidgets('周期未结束时修改回向内容：不进历史，开始与结束日期不变', (tester) async {
    final now = DateTime.now();
    final startDate = DedicationStore.dateKey(
        DateTime(now.year, now.month, now.day - 3));
    final endDate = DedicationStore.dateKey(
        DateTime(now.year, now.month, now.day + 10));
    SharedPreferences.setMockInitialValues({
      DedicationStore.textKey: '愿以此功德，回向给我的母亲。',
      DedicationStore.startKey: startDate,
      DedicationStore.endKey: endDate,
    });

    String? result;
    await tester.pumpWidget(_host((context) async {
      result = await showDedicationSheet(context);
    }));

    await tester.tap(find.text('打开回向'));
    await tester.pumpAndSettle();

    // 生效中：显示终止按钮，没有历史记录。
    expect(find.textContaining('生效中'), findsOneWidget);
    expect(find.text('终止当前回向'), findsOneWidget);
    expect(find.textContaining('当前回向生效至'), findsNothing,
        reason: '生效日期已由状态标签和剩余天数展示，不再单独占一行');

    // 只改几个字，持续时间不动。
    const edited = '愿以此功德，回向给我的母亲，愿她安康。';
    await tester.enterText(find.byType(TextField).first, edited);
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result, edited);
    final prefs = await SharedPreferences.getInstance();
    expect(DedicationStore.history(prefs), isEmpty,
        reason: '持续时间还没结束，不能出现在历史里');
    expect(prefs.getString(DedicationStore.textKey), edited);
    expect(prefs.getString(DedicationStore.startKey), startDate,
        reason: '还是同一次回向，开始日期不变');
    expect(prefs.getString(DedicationStore.endKey), endDate,
        reason: '持续时间未结束，结束日期不变');
  });

  testWidgets('终止当前回向：确认后进历史并恢复默认回向', (tester) async {
    final now = DateTime.now();
    final startDate = DedicationStore.dateKey(
        DateTime(now.year, now.month, now.day - 3));
    final endDate = DedicationStore.dateKey(
        DateTime(now.year, now.month, now.day + 10));
    SharedPreferences.setMockInitialValues({
      DedicationStore.textKey: '愿以此功德，回向给我的母亲。',
      DedicationStore.startKey: startDate,
      DedicationStore.endKey: endDate,
    });

    String? result;
    await tester.pumpWidget(_host((context) async {
      result = await showDedicationSheet(context);
    }));

    await tester.tap(find.text('打开回向'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('终止当前回向'));
    await tester.pumpAndSettle();
    expect(find.text('终止当前回向？'), findsOneWidget);

    await tester.tap(find.text('终止'));
    await tester.pumpAndSettle();

    // 抽屉关闭，回到默认回向；被终止的那条进入历史并标记「已终止」。
    expect(result, DedicationStore.defaultText);
    final prefs = await SharedPreferences.getInstance();
    expect(DedicationStore.current(prefs), isNull);
    expect(DedicationStore.effective(prefs), DedicationStore.defaultText);
    final history = DedicationStore.history(prefs);
    expect(history, hasLength(1));
    expect(history.first.text, '愿以此功德，回向给我的母亲。');
    expect(history.first.endReason, DedicationEntry.reasonTerminated);

    await tester.tap(find.text('打开回向'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    expect(find.text('已终止'), findsOneWidget);
  });

  testWidgets('保存默认回向时清掉旧期限并记入历史', (tester) async {
    SharedPreferences.setMockInitialValues({
      DedicationStore.textKey: '上一条回向',
      DedicationStore.startKey: '2020-01-01',
      DedicationStore.endKey: '2020-01-07',
    });

    String? result;
    await tester.pumpWidget(_host((context) async {
      result = await showDedicationSheet(context);
    }));

    await tester.tap(find.text('打开回向'));
    await tester.pumpAndSettle();

    // 清空正文即回到默认回向。
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result, DedicationStore.defaultText);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(DedicationStore.textKey), isNull);
    expect(prefs.getString(DedicationStore.endKey), isNull);
    expect(DedicationStore.effective(prefs), DedicationStore.defaultText);
    expect(DedicationStore.history(prefs).first.text, '上一条回向');
  });

  testWidgets('没有历史记录时显示空状态', (tester) async {
    await tester.pumpWidget(_host((context) async {
      await showDedicationSheet(context);
    }));

    await tester.tap(find.text('打开回向'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();

    expect(find.text('回向历史'), findsOneWidget);
    expect(find.text('还没有回向历史'), findsOneWidget);
    expect(find.textContaining('会记录在这里'), findsOneWidget);
    expect(find.text('再次使用'), findsNothing);
  });
}
