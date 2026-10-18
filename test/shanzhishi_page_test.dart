import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/shanzhishi_page.dart';
import 'package:my_flutter_app/shanzhishi_sphere.dart';
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

  testWidgets('初始不显示底部面板（点名号后才出现）', (tester) async {
    await pumpPage(tester);
    expect(find.text('善知识'), findsNothing);
    expect(find.text('关联经文'), findsNothing);
    expect(find.text('名号'), findsNothing);
    // 编辑不再由点选触发；「第 x / y 位」已移除。
    expect(find.text('编辑善知识'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.textContaining(RegExp(r'第 \d+ / \d+ 位')), findsNothing);
  });

  testWidgets('点球面名号后拉出面板，显示该名号与关联经文', (tester) async {
    await pumpPage(tester);
    final store = ShanZhiShiStore.instance;
    // 初始朝向对准离正前方最近的那一位（与球体 _aimInitial 一致）。
    final layout = computeSphereLayout(store.length);
    var front = 0;
    var bestZ = double.negativeInfinity;
    for (var i = 0; i < layout.n; i++) {
      final p = layout.points[i];
      if (p.z > bestZ) {
        bestZ = p.z;
        front = i;
      }
    }
    final shown = store[front];
    expect(shown, isNotNull);
    // 初始无面板。
    expect(find.text('关联经文'), findsNothing);
    // 点球心（正对的那一位）。
    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();
    // header 显示名号，面板铺开关联经文。
    expect(find.text(shown!.name), findsOneWidget);
    expect(find.text('关联经文'), findsOneWidget);
    // 不弹编辑面板。
    expect(find.text('编辑善知识'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    // 再点 header 收起面板。
    await tester.tap(find.text(shown.name));
    await tester.pumpAndSettle();
    expect(find.text('关联经文'), findsNothing);
  });

  testWidgets('空名单时球面显示引导文案，无旧提示', (tester) async {
    await pumpPage(tester);
    final store = ShanZhiShiStore.instance;
    while (store.length > 0) {
      await store.removeAt(0);
    }
    await tester.pumpAndSettle();
    expect(find.text('球面还没有名号'), findsOneWidget);
    expect(find.text('点选球面名号，查看它出现过的经文'), findsNothing);
  });

  testWidgets('顶部有添加与搜索按钮（无随机按钮）', (tester) async {
    await pumpPage(tester);
    expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.casino_outlined), findsNothing);
  });
}
