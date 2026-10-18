import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/shanzhishi_page.dart';
import 'package:my_flutter_app/shanzhishi_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ShanZhiShiStore.instance.resetForTest();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: ShanZhiShiPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('预置名号加载后，面板显示球心当前名号', (tester) async {
    await pumpPage(tester);
    expect(find.text('善知识'), findsOneWidget);
    expect(find.textContaining(RegExp(r'第 \d+ / 35 位')), findsOneWidget);
    // 面板大字是某个预置名号（球心位次由初始铺排决定，不写死）。
    final names = [
      for (final e in ShanZhiShiStore.instance.entries) e.name,
    ];
    expect(names, isNotEmpty);
    expect(names.any((n) => tester.any(find.text(n))), isTrue);
  });

  testWidgets('点编辑图标弹出编辑面板', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text('编辑善知识'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('出现过的经文'), findsOneWidget);
  });

  testWidgets('空名单时球面与面板显示引导文案', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ShanZhiShiPage()));
    // 不等 load：先塞入「已加载且为空」的状态再重建。
    final store = ShanZhiShiStore.instance;
    await tester.pumpAndSettle();
    while (store.length > 0) {
      await store.removeAt(0);
    }
    await tester.pumpAndSettle();
    expect(find.text('球面还没有名号'), findsOneWidget);
    expect(find.text('名号下方会显示它出现过的经文'), findsOneWidget);
  });
}
