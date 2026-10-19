import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/note_sutra_links.dart';
import 'package:my_flutter_app/shanzhishi_edit_sheet.dart';
import 'package:my_flutter_app/shanzhishi_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ShanZhiShiStore.instance.resetForTest();
  });

  Future<void> openEdit(WidgetTester tester, {required void Function(int?) save}) async {
    final store = ShanZhiShiStore.instance;
    await store.load();
    final entry = store[0]!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                save(await ShanZhiShiEditSheet.show(
                  context,
                  index: 0,
                  entry: entry,
                ));
              },
              child: const Text('打开编辑'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();
    expect(find.text('编辑善知识'), findsOneWidget);
  }

  testWidgets('引用段落是一片输入区：改名号 + 填段落后保存', (tester) async {
    int? saved;
    await openEdit(tester, save: (v) => saved = v);
    final store = ShanZhiShiStore.instance;

    // 改名号。
    await tester.enterText(find.byType(TextField).first, '测试菩萨');
    await tester.pump();

    // 引用段落就是一片多行输入区，一段一条。
    final paraField = find.byKey(const ValueKey('shanzhishi_paragraphs_field'));
    expect(paraField, findsOneWidget);
    await tester.enterText(paraField, '测试段落一\n\n测试段落二\n');
    await tester.pump();

    // 保存。
    final saveButton = find.widgetWithText(FilledButton, '保存');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(saved, 0);
    expect(store[0]!.name, '测试菩萨');
    expect(store[0]!.paragraphs, ['测试段落一', '测试段落二']);
    // 新版不再按经书存段落。
    expect(store[0]!.quotes, isEmpty);
  });

  testWidgets('编辑面板打开时回填已有段落（旧数据也能回填）', (tester) async {
    final store = ShanZhiShiStore.instance;
    await store.load();
    await store.update(0, paragraphs: ['第一段', '第二段']);
    // 重新打开面板：段落应回填到输入区。
    int? saved;
    await openEdit(tester, save: (v) => saved = v);
    final controller = tester
        .widget<TextField>(
            find.byKey(const ValueKey('shanzhishi_paragraphs_field')))
        .controller!;
    expect(controller.text, '第一段\n\n第二段');
    // 不改内容直接保存：段落保持。
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(saved, 0);
    expect(store[0]!.paragraphs, ['第一段', '第二段']);
  });

  testWidgets('待选经文浮在经名输入框下方，不被引用段落区遮住', (tester) async {
    // 先把经书目录在真实异步里加载好，后面搜索才会在 pump 中立刻返回。
    await tester.runAsync(() => NoteSutraCatalog.search('地藏'));
    await openEdit(tester, save: (_) {});
    final sutraField = find.byType(TextField).at(1);
    await tester.enterText(sutraField, '地藏');
    // 等防抖 + 检索结果。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('shanzhishi_sutra_suggest'));
    expect(panel, findsOneWidget);
    final rows = find.descendant(of: panel, matching: find.byType(InkWell));
    expect(rows, findsWidgets);

    // 浮层顶部紧贴输入框下沿，且能命中（说明浮在上面，没有被下面区域盖住）。
    final fieldRect = tester.getRect(sutraField);
    final panelRect = tester.getRect(panel);
    expect(panelRect.top, greaterThanOrEqualTo(fieldRect.bottom - 1));
    expect(panelRect.top, lessThan(fieldRect.bottom + 48));
    expect(rows.hitTestable(), findsWidgets);
  });

  testWidgets('编辑面板只能编辑，没有删除按钮', (tester) async {
    await openEdit(tester, save: (_) {});
    expect(find.text('删除'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('编辑页提示语：两句都在', (tester) async {
    await openEdit(tester, save: (_) {});
    expect(find.text('输入和佛菩萨关联的经文段落'), findsOneWidget);
    expect(find.text('一段一条，空行分隔'), findsOneWidget);
  });

  testWidgets('编辑改名撞车：提示「保留名号 / 合并」', (tester) async {
    int? saved;
    await openEdit(tester, save: (v) => saved = v);
    final store = ShanZhiShiStore.instance;
    final before = store.length;

    // 「地藏菩萨摩」与种子里的「地藏王菩萨」字符重合 4/5 = 80%。
    await tester.enterText(find.byType(TextField).first, '地藏菩萨摩');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('已有相似的善知识'), findsOneWidget);

    // 保留名号：照常保存，条数不变。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_add_new')));
    await tester.pumpAndSettle();
    expect(saved, 0);
    expect(store.length, before);
    expect(store[0]!.name, '地藏菩萨摩');
  });

  testWidgets('编辑改名撞车选合并：并进目标并删掉这一位', (tester) async {
    final store = ShanZhiShiStore.instance;
    await store.load();
    await store.update(0, paragraphs: ['来自地藏菩萨的段落']);
    final before = store.length;
    int? saved;
    await openEdit(tester, save: (v) => saved = v);

    await tester.enterText(find.byType(TextField).first, '地藏王菩萨');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('已有相似的善知识'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shanzhishi_merge_existing')));
    await tester.pumpAndSettle();
    expect(store.length, before - 1);
    final merged = store.entries.firstWhere((e) => e.name == '地藏王菩萨');
    expect(merged.paragraphs, contains('来自地藏菩萨的段落'));
    expect(saved, isNotNull);
    expect(store[saved!]!.name, '地藏王菩萨');
  });

  testWidgets('编辑同名重复项：保存时提示合并', (tester) async {
    final store = ShanZhiShiStore.instance;
    await store.load();
    // 造一个完全同名的重复（模拟之前选「保留名号」留下的两条）。
    await store.update(1, name: store[0]!.name, paragraphs: ['第二位的段落']);
    final before = store.length;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => ShanZhiShiEditSheet.show(
                context,
                index: 1,
                entry: store[1],
              ),
              child: const Text('打开编辑'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();

    // 名号没改也查：另一位完全同名，提示合并。
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('已有相似的善知识'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shanzhishi_merge_existing')));
    await tester.pumpAndSettle();
    expect(store.length, before - 1);
  });
}
