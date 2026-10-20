import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/shanzhishi_mantra_edit_sheet.dart';
import 'package:my_flutter_app/shanzhishi_mantra_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ShanZhiShiMantraStore.instance.resetForTest();
  });

  Future<ShanZhiShiMantraStore> loadedStore() async {
    final store = ShanZhiShiMantraStore.instance;
    await store.load();
    return store;
  }

  Future<void> openSheet(WidgetTester tester,
      {String? editing,
      String? initialSource,
      String? initialText}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => ShanZhiShiMantraEditSheet.show(
                context,
                editing: editing,
                initialSource: initialSource,
                initialText: initialText,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text(editing == null ? '添加密咒' : '编辑密咒'), findsOneWidget);
  }

  group('查重与合并（store）', () {
    test('完全同名或摘掉通用尊称后 ≥2 个相同字符都算相似', () async {
      final store = await loadedStore();
      // 完全同名必命中（内置名单里就有「大悲咒」）。
      expect(store.findSimilarEntries('大悲咒'), contains('大悲咒'));
      // 「心咒」是通用尊称：「六字大明心咒」与「六字大明咒」剩「六字大明」，
      // 4 个相同字符，算相似。
      expect(store.findSimilarEntries('六字大明心咒'), contains('六字大明咒'));
      // 编辑场景跳过自己。
      expect(store.findSimilarEntries('大悲咒', skip: '大悲咒'), isEmpty);
      // 毫无关系的名字不命中。
      expect(store.findSimilarEntries('一二三四五'), isEmpty);
    });

    test('mergeInto：出处/原文并进现有密咒，原有内容一处不丢', () async {
      final store = await loadedStore();
      await store.add('我的咒', source: '出处甲', text: '原文甲');
      await store.mergeInto('我的咒', source: '出处乙', text: '原文乙');
      expect(store.sourceOf('我的咒'), '出处甲 / 出处乙');
      expect(store.textOf('我的咒'), '原文甲\n\n原文乙');
      // 新内容为空：原样不动。
      await store.mergeInto('我的咒', source: '', text: '');
      expect(store.sourceOf('我的咒'), '出处甲 / 出处乙');
      expect(store.textOf('我的咒'), '原文甲\n\n原文乙');
      // 不在名单里的名字合并不了。
      expect(await store.mergeInto('不存在的咒', text: 'x'), isFalse);
    });

    test('mergeAndRemove：内容并进 keep，然后删掉 drop', () async {
      final store = await loadedStore();
      await store.add('甲咒', source: '甲出处', text: '甲原文');
      await store.add('乙咒', source: '乙出处', text: '乙原文');
      final ok = await store.mergeAndRemove('甲咒', '乙咒');
      expect(ok, isTrue);
      expect(store.mantras.contains('乙咒'), isFalse);
      expect(store.mantras.contains('甲咒'), isTrue);
      expect(store.sourceOf('甲咒'), '甲出处 / 乙出处');
      expect(store.textOf('甲咒'), '甲原文\n\n乙原文');
    });
  });

  testWidgets('从阅读页打开新增面板：自动填入当前经文出处与选中文字', (tester) async {
    await loadedStore();
    await openSheet(
      tester,
      initialSource: '妙法莲华经卷一',
      initialText: '观自在菩萨行深般若波罗蜜多时',
    );

    final sourceField = tester.widget<TextField>(
      find.byKey(const ValueKey('shanzhishi_mantra_source_field')),
    );
    expect(sourceField.controller?.text, '妙法莲华经卷一');
    final textField = tester.widget<TextField>(
      find.byKey(const ValueKey('shanzhishi_mantra_text_field')),
    );
    expect(textField.controller?.text, '观自在菩萨行深般若波罗蜜多时');
  });

  group('保存时的合并选择（面板）', () {
    testWidgets('添加撞名：弹合并框，选已有那条即两条并成一条', (tester) async {
      final store = await loadedStore();
      await store.update('大悲咒', source: '旧出处', text: '旧原文');
      await openSheet(tester);

      await tester.enterText(
          find.byKey(const ValueKey('shanzhishi_mantra_name_field')), '大悲咒');
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('shanzhishi_mantra_source_field')), '新出处');
      await tester.enterText(
          find.byKey(const ValueKey('shanzhishi_mantra_text_field')), '新原文');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '添加'));
      await tester.pumpAndSettle();

      expect(find.text('或有重名密咒'), findsOneWidget);
      // 名字一模一样：必须合并，只剩两个合并方向和取消。
      expect(
          find.byKey(const ValueKey('shanzhishi_mantra_keep_both')), findsNothing);
      expect(find.byKey(const ValueKey('shanzhishi_mantra_keep_new_name')),
          findsOneWidget);

      await tester
          .tap(find.byKey(const ValueKey('shanzhishi_mantra_merge_existing')));
      await tester.pumpAndSettle();

      // 面板关闭，内容并进已有的「大悲咒」。
      expect(find.text('添加密咒'), findsNothing);
      expect(store.sourceOf('大悲咒'), '旧出处 / 新出处');
      expect(store.textOf('大悲咒'), '旧原文\n\n新原文');
    });

    testWidgets('添加相似名：可选「两个都留着」，两条并存', (tester) async {
      final store = await loadedStore();
      final before = store.mantras.length;
      await openSheet(tester);

      await tester.enterText(
          find.byKey(const ValueKey('shanzhishi_mantra_name_field')),
          '六字大明心咒');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '添加'));
      await tester.pumpAndSettle();

      expect(find.text('或有重名密咒'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('shanzhishi_mantra_keep_both')));
      await tester.pumpAndSettle();

      expect(store.mantras.length, before + 1);
      expect(store.mantras, contains('六字大明心咒'));
      // 原来那条不受影响。
      expect(store.mantras, contains('六字大明咒'));
    });

    testWidgets('添加相似名选「保留新名号」：旧条目并进来后删掉', (tester) async {
      final store = await loadedStore();
      await openSheet(tester);

      await tester.enterText(
          find.byKey(const ValueKey('shanzhishi_mantra_name_field')),
          '六字大明心咒');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '添加'));
      await tester.pumpAndSettle();
      expect(find.text('或有重名密咒'), findsOneWidget);

      await tester
          .tap(find.byKey(const ValueKey('shanzhishi_mantra_keep_new_name')));
      await tester.pumpAndSettle();

      // 保留刚输入的名字，相似条目删掉。
      expect(store.mantras, contains('六字大明心咒'));
      expect(store.mantras.contains('六字大明咒'), isFalse);
    });

    testWidgets('没有相似项：照常添加，不弹合并框', (tester) async {
      final store = await loadedStore();
      final before = store.mantras.length;
      await openSheet(tester);

      await tester.enterText(
          find.byKey(const ValueKey('shanzhishi_mantra_name_field')), '我的新咒');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '添加'));
      await tester.pumpAndSettle();

      expect(find.text('或有重名密咒'), findsNothing);
      expect(store.mantras.length, before + 1);
      expect(store.mantras, contains('我的新咒'));
    });
  });
}
