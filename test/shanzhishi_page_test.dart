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
    expect(find.text('编辑'), findsNothing);
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
    // 不弹编辑面板，但面板右下角有编辑按钮。
    expect(find.text('编辑善知识'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    // 再点 header 收起面板。
    await tester.tap(find.text(shown.name));
    await tester.pumpAndSettle();
    expect(find.text('关联经文'), findsNothing);
  });

  testWidgets('面板展开高度约占屏幕九成，竖杠与内容左对齐', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();

    final panel =
        tester.getSize(find.byKey(const ValueKey('shanzhishi-shelf-panel')));
    final size = tester.getSize(find.byType(ShanZhiShiSphere));
    // 面板与添加善知识面板一样大：占可用高度的 90%。
    expect(panel.height, closeTo(size.height * 0.9, 0.5));

    // 名号前的竖杠贴左边 20（与下方内容同一条竖线）。
    final bar = tester.getTopLeft(
      find.byKey(const ValueKey('shanzhishi_name_bar')),
    );
    expect(bar.dx, closeTo(20, 0.5));
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

  testWidgets('右下角悬浮球：点开后弹出添加/搜索/切换三个子按钮', (tester) async {
    await pumpPage(tester);
    // 收起态：半透明灰底 + 白圈；子按钮不可点，也没有白叉。
    expect(find.byKey(const ValueKey('shanzhishi_fab_ring')), findsOneWidget);
    expect(find.byKey(const ValueKey('shanzhishi_fab_close')), findsNothing);
    expect(find.byIcon(Icons.casino_outlined), findsNothing);

    // 点主球展开。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shanzhishi_fab_close')), findsOneWidget);
    // 三个子按钮：添加（纯加号，外圈不再套圈）、搜索（放大镜）、切换（左右箭头）。
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.swap_horiz), findsOneWidget);

    // 子按钮点一下先收起菜单（切换暂为占位动作，不跳页）。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_switch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shanzhishi_fab_ring')), findsOneWidget);
    expect(find.byKey(const ValueKey('shanzhishi_fab_close')), findsNothing);

    // 再展开后点空白处也收起。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(40, 40));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shanzhishi_fab_ring')), findsOneWidget);
    expect(find.byKey(const ValueKey('shanzhishi_fab_close')), findsNothing);
  });

  testWidgets('底部面板展开时右下角悬浮球让位', (tester) async {
    await pumpPage(tester);
    expect(find.byKey(const ValueKey('shanzhishi_fab_layer')), findsOneWidget);
    // 点名号拉出面板：悬浮球隐藏，避免压住面板右下角的「编辑」。
    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shanzhishi-shelf-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('shanzhishi_fab_layer')), findsNothing);
  });

  testWidgets('面板右下角编辑按钮打开编辑面板', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text('编辑善知识'), findsOneWidget);
    // 编辑面板里有「引用段落」维护区。
    expect(find.text('引用段落'), findsOneWidget);

    final cancel = find.text('取消');
    await tester.ensureVisible(cancel);
    await tester.pumpAndSettle();
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(find.text('编辑善知识'), findsNothing);
    // 取消编辑后面板仍在。
    expect(find.byKey(const ValueKey('shanzhishi-shelf-panel')), findsOneWidget);
  });

  testWidgets('添加面板文案：关联经文 / 新的引用段落提示语', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_add')));
    await tester.pumpAndSettle();
    expect(find.text('添加善知识'), findsOneWidget);
    // 「出现过的经文」改成「关联经文」。
    expect(find.text('关联经文'), findsOneWidget);
    expect(find.text('出现过的经文'), findsNothing);
    // 引用段落提示语换成新句子，右边那句已经去掉。
    expect(find.text('输入和佛菩萨关联的经文段落'), findsOneWidget);
    expect(find.text('留空则展示时自动识别'), findsNothing);
  });

  testWidgets('新增近似名号：让用户选「添加新的」或「合并」', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_add')));
    await tester.pumpAndSettle();

    // 「地藏菩萨摩」与种子里的「地藏菩萨」字符重合 4/5 = 80%。
    final store = ShanZhiShiStore.instance;
    final before = store.length;
    await tester.enterText(find.byType(TextField).first, '地藏菩萨摩');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();

    // 弹选择框，默认什么都不做。
    expect(find.text('已有相似的善知识'), findsOneWidget);
    expect(find.textContaining('地藏菩萨'), findsWidgets);

    // 选「添加新的」：另起一位。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_add_new')));
    await tester.pumpAndSettle();
    expect(store.length, before + 1);
    expect(store[store.length - 1]!.name, '地藏菩萨摩');
  });

  testWidgets('新增同名名号并选「合并」：不新增条目，直接打开已有那位', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_add')));
    await tester.pumpAndSettle();

    final store = ShanZhiShiStore.instance;
    final before = store.length;
    await tester.enterText(find.byType(TextField).first, '地藏菩萨');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();
    expect(find.text('已有相似的善知识'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shanzhishi_merge_existing')));
    await tester.pumpAndSettle();
    // 没有新增条目，面板直接铺在已有的「地藏菩萨」上。
    expect(store.length, before);
    expect(find.text('添加善知识'), findsNothing);
    expect(find.text('关联经文'), findsOneWidget);
  });

  testWidgets('面板里显示用户填写的引用段落', (tester) async {
    await pumpPage(tester);
    final store = ShanZhiShiStore.instance;
    // 球体初始正对的那一位（与球体 _aimInitial 一致）。
    final layout = computeSphereLayout(store.length);
    var front = 0;
    var bestZ = double.negativeInfinity;
    for (var i = 0; i < layout.n; i++) {
      final point = layout.points[i];
      if (point.z > bestZ) {
        bestZ = point.z;
        front = i;
      }
    }
    await store.update(front, paragraphs: ['这是用户填的段落']);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();
    expect(find.text('引用段落'), findsOneWidget);
    expect(find.text('这是用户填的段落'), findsOneWidget);
  });

  testWidgets('多段引用段落：每段顶部各有一个「引用段落」标志', (tester) async {
    await pumpPage(tester);
    final store = ShanZhiShiStore.instance;
    final layout = computeSphereLayout(store.length);
    var front = 0;
    var bestZ = double.negativeInfinity;
    for (var i = 0; i < layout.n; i++) {
      final point = layout.points[i];
      if (point.z > bestZ) {
        bestZ = point.z;
        front = i;
      }
    }
    await store.update(front, paragraphs: ['第一段内容', '第二段内容']);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();
    // 一段一个标志，不是一整块。
    expect(find.text('引用段落'), findsNWidgets(2));
    expect(find.text('第一段内容'), findsOneWidget);
    expect(find.text('第二段内容'), findsOneWidget);
  });

  testWidgets('面板「恢复」：退回编辑前的版本（同一段内追加也算）', (tester) async {
    await pumpPage(tester);
    final store = ShanZhiShiStore.instance;
    final layout = computeSphereLayout(store.length);
    var front = 0;
    var bestZ = double.negativeInfinity;
    for (var i = 0; i < layout.n; i++) {
      final point = layout.points[i];
      if (point.z > bestZ) {
        bestZ = point.z;
        front = i;
      }
    }
    final original = List<String>.of(store[front]!.paragraphs);
    // 两次编辑：第二次只是在同一段后面追加文字（不是新的引用段）。
    await store.update(front, paragraphs: ['一段']);
    await store.update(front, paragraphs: ['一段又加了一句']);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();
    expect(find.text('一段又加了一句'), findsOneWidget);
    // 恢复按钮一直在「编辑」左边。
    expect(find.text('恢复'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shanzhishi_restore')));
    await tester.pumpAndSettle();
    expect(store[front]!.paragraphs, original);
    expect(find.text('一段又加了一句'), findsNothing);
    // 快照用掉后按钮仍在，但再点没有可恢复版本。
    expect(store.canRestore(store[front]!), isFalse);
    expect(find.text('恢复'), findsOneWidget);
  });

  testWidgets('关联经文上下排列，每行右侧有进入阅读的箭头', (tester) async {
    await pumpPage(tester);
    final store = ShanZhiShiStore.instance;
    final layout = computeSphereLayout(store.length);
    var front = 0;
    var bestZ = double.negativeInfinity;
    for (var i = 0; i < layout.n; i++) {
      final point = layout.points[i];
      if (point.z > bestZ) {
        bestZ = point.z;
        front = i;
      }
    }
    await store.update(front, sutras: ['地藏菩萨本愿经', '占察善恶业报经']);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();
    // 一行一部经，各带一个右箭头。
    expect(find.byKey(const ValueKey('shanzhishi_sutra_row_地藏菩萨本愿经')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('shanzhishi_sutra_row_占察善恶业报经')),
        findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
    // 上下排列：第二行在第一行下面。
    final first = tester.getRect(
        find.byKey(const ValueKey('shanzhishi_sutra_row_地藏菩萨本愿经')));
    final second = tester.getRect(
        find.byKey(const ValueKey('shanzhishi_sutra_row_占察善恶业报经')));
    expect(second.top, greaterThan(first.bottom - 1));
  });
}
