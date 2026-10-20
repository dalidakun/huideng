import 'dart:ui' as ui;

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

  testWidgets('add sheet has no header close button', (tester) async {
    await ShanZhiShiStore.instance.load();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => ShanZhiShiEditSheet.show(context),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsNothing);
  });

  Future<void> openEdit(WidgetTester tester,
      {required void Function(int?) save, int? index}) async {
    final store = ShanZhiShiStore.instance;
    await store.load();
    // 默认挑一条没有任何 80% 近似兄弟的名号，避免「不改名保存」被查重框挡住。
    index ??= store.entries.indexWhere((e) =>
        store.findSimilarIndex(e.name, skip: store.entries.indexOf(e)) == -1);
    final entry = store[index]!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                save(await ShanZhiShiEditSheet.show(
                  context,
                  index: index!,
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
    await openEdit(tester, save: (v) => saved = v, index: 0);
    final store = ShanZhiShiStore.instance;

    // 改名号。
    await tester.enterText(find.byType(TextField).first, '测试菩萨');
    await tester.pump();

    // 引用段落就是一片多行输入区，一段一条。
    final paraField = find.byKey(const ValueKey('shanzhishi_paragraphs_field'));
    expect(paraField, findsOneWidget);
    await tester.enterText(paraField, '测试段落一\n\n测试段落二\n');
    await tester.pump();

    // 保存：「测试菩萨」摘掉通用尊称「菩萨」后是「测试」，与既有名号没有相同
    // 字样，不再弹合并提示，直接存下。
    final saveButton = find.widgetWithText(FilledButton, '保存');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(find.text('或有重名善知识'), findsNothing);

    expect(saved, 0);
    expect(store[0]!.name, '测试菩萨');
    expect(store[0]!.paragraphs, ['测试段落一', '测试段落二']);
    // 人天利益按经文各存一份：这段落在它唯一的那部经名下。
    expect(store[0]!.quotes, {
      '地藏菩萨本愿经': ['测试段落一', '测试段落二']
    });
  });

  testWidgets('编辑面板打开时回填已有段落（旧数据也能回填）', (tester) async {
    final store = ShanZhiShiStore.instance;
    await store.load();
    // 挑一条没有任何 80% 近似兄弟的名号，不改名保存不会被查重框拦住。
    final iSafe = store.entries.indexWhere((e) =>
        store.findSimilarIndex(e.name, skip: store.entries.indexOf(e)) == -1);
    expect(iSafe, greaterThanOrEqualTo(0));
    await store.update(iSafe, paragraphs: ['第一段', '第二段']);
    // 重新打开面板：段落应回填到输入区。
    int? saved;
    await openEdit(tester, save: (v) => saved = v, index: iSafe);
    final controller = tester
        .widget<TextField>(
            find.byKey(const ValueKey('shanzhishi_paragraphs_field')))
        .controller!;
    expect(controller.text, '第一段\n\n第二段');
    // 不改内容直接保存：通用尊称（如来 / 佛 / 菩萨 / 咒）不计入相同字符，
    // 不会再被查重框挡住。
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('或有重名善知识'), findsNothing);
    expect(saved, iSafe);
    expect(store[iSafe]!.paragraphs, ['第一段', '第二段']);
  });

  testWidgets('人天利益按经文分开：点选经文切换各自那一份', (tester) async {
    final store = ShanZhiShiStore.instance;
    await store.load();
    await store.update(
      0,
      sutras: ['甲经', '乙经'],
      quotes: {
        '甲经': ['甲经的一段'],
        '乙经': ['乙经的一段'],
      },
      paragraphs: ['甲经的一段', '乙经的一段'],
    );
    int? saved;
    await openEdit(tester, save: (v) => saved = v, index: 0);
    final field = find.byKey(const ValueKey('shanzhishi_paragraphs_field'));

    // 默认停在第一部经：看到的是它的段落。
    TextEditingController ctrl() => tester.widget<TextField>(field).controller!;
    expect(ctrl().text, '甲经的一段');

    // 点第二部经：下面换成它自己的那一份。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_sutra_chip_乙经')));
    await tester.pumpAndSettle();
    expect(ctrl().text, '乙经的一段');
    await tester.enterText(field, '乙经的一大段');
    await tester.pumpAndSettle();

    // 切回第一部经：它那一份原样还在。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_sutra_chip_甲经')));
    await tester.pumpAndSettle();
    expect(ctrl().text, '甲经的一段');

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    if (find.text('或有重名善知识').evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('shanzhishi_add_new')));
      await tester.pumpAndSettle();
    }
    expect(saved, 0);
    expect(store[0]!.quotes['甲经'], ['甲经的一段']);
    expect(store[0]!.quotes['乙经'], ['乙经的一大段']);
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

  testWidgets('编辑页提示语：人天利益两句都在，且是输入区的占位', (tester) async {
    await openEdit(tester, save: (_) {});
    expect(find.text('人天利益'), findsOneWidget);
    // 两句提示直接作为输入区的占位（光标落在提示开头），不再是区块外的说明文字。
    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('shanzhishi_paragraphs_field')));
    expect(field.decoration!.hintText, '输入佛菩萨人天利益\n一段一条，空行分隔\n点选经文对应人天利益段落');
    expect(find.text('输入佛菩萨人天利益'), findsNothing);
    expect(find.text('一段一条，空行分隔'), findsNothing);
    // 输入之后正文落在提示原位（同一片区域，占位随之隐去）。
    await tester.enterText(
        find.byKey(const ValueKey('shanzhishi_paragraphs_field')), '一段利益');
    await tester.pumpAndSettle();
    expect(find.text('一段利益'), findsOneWidget);
    expect(find.text('引用段落'), findsNothing);
  });

  test('人天利益分段口径：空行分段，整段无空行时一行一段', () {
    expect(paragraphLineRanges('一\n\n二\n三'.split('\n')), [(0, 1), (2, 4)]);
    expect(paragraphLineRanges('一\n二'.split('\n')), [(0, 1), (1, 2)]);
    expect(paragraphLineRanges('\n\n'.split('\n')), isEmpty);
    expect(paragraphLineRanges(''.split('\n')), isEmpty);
  });

  testWidgets('人天利益输入区：段间自动画虚线分隔，且压在文字之下', (tester) async {
    await openEdit(tester, save: (_) {});
    final rules = find.byKey(const ValueKey('shanzhishi_paragraphs_rules'));
    final field = find.byKey(const ValueKey('shanzhishi_paragraphs_field'));
    expect(rules, findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter != null),
        findsWidgets);
    // 虚线层与输入框同尺寸（贴在同一片区域上）。
    expect(tester.getRect(rules).size, tester.getRect(field).size);
    // 多段文本不会让测量/绘制抛错。
    await tester.enterText(field, '第一段\n\n第二段\n\n第三段');
    await tester.pump();
    expect(paragraphLineRanges('第一段\n\n第二段\n\n第三段'.split('\n')).length, 3);
    expect(tester.getRect(rules).size, tester.getRect(field).size);
  });

  testWidgets('人天利益：连按两次换行（还没写下第二段）就画好虚线', (tester) async {
    await openEdit(tester, save: (_) {});
    final rules = find.byKey(const ValueKey('shanzhishi_paragraphs_rules'));
    final field = find.byKey(const ValueKey('shanzhishi_paragraphs_field'));

    // 把虚线层单独画到画布上，看哪些行真的落了墨——直接验「有没有画出来」。
    // 同时记下最深的那个像素：线太浅（贴着背景色）等于没画，用户还是看不见。
    Future<(List<int>, int)> inkRows(String text) async {
      await tester.enterText(field, text);
      // 两帧：第一帧排完版才量得出行位，第二帧才画上虚线。
      await tester.pump();
      await tester.pump();
      final paint = tester.widget<CustomPaint>(rules);
      final size = tester.getSize(rules);
      final recorder = ui.PictureRecorder();
      paint.painter!.paint(Canvas(recorder), size);
      final rows = <int>[];
      var maxAlpha = 0;
      await tester.runAsync(() async {
        final image = await recorder
            .endRecording()
            .toImage(size.width.round(), size.height.round());
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final bytes = data!.buffer.asUint8List();
        final w = size.width.round();
        for (var y = 0; y < size.height.round(); y++) {
          for (var x = 0; x < w; x++) {
            final a = bytes[(y * w + x) * 4 + 3];
            if (a != 0) {
              rows.add(y);
              if (a > maxAlpha) maxAlpha = a;
              break;
            }
          }
        }
      });
      return (rows, maxAlpha);
    }

    // 只有一段时还没有分界。
    expect((await inkRows('第一段')).$1, isEmpty);
    // 按下第一次换行（仍是一段）就开始给下一条留位置，并且看得出来。
    final oneEnter = await inkRows('第一段\n');
    expect(oneEnter.$1, isNotEmpty);
    expect(oneEnter.$2, greaterThanOrEqualTo(120));
    // 换行两次＝空行出现，虚线立即画好，不必等第二段的内容。
    final twoEnter = await inkRows('第一段\n\n');
    expect(twoEnter.$1, isNotEmpty);
    expect(twoEnter.$2, greaterThanOrEqualTo(120));
    final threeEnter = await inkRows('第一段\n\n\n');
    expect(threeEnter.$1, isNotEmpty);
    expect((await inkRows('第一段\n\n第二段')).$1, isNotEmpty);
    // 虚线落在输入区里（不是画到框外去）。
    final box = tester.getSize(rules);
    for (final y in threeEnter.$1) {
      expect(y, lessThan(box.height));
    }
  });

  testWidgets('人天利益：虚线画在空档正中，不贴上一段、也不偏到下一段', (tester) async {
    await openEdit(tester, save: (_) {});
    final rules = find.byKey(const ValueKey('shanzhishi_paragraphs_rules'));
    final field = find.byKey(const ValueKey('shanzhishi_paragraphs_field'));

    Future<void> type(String text) async {
      await tester.enterText(field, text);
      // 两帧：第一帧排完版才量得出行位，第二帧才画上虚线。
      await tester.pump();
      await tester.pump();
    }

    // 当前文本下，虚线层第一处落墨的行号（相对输入区顶部）。
    Future<double> dashY() async {
      final paint = tester.widget<CustomPaint>(rules);
      final size = tester.getSize(rules);
      final recorder = ui.PictureRecorder();
      paint.painter!.paint(Canvas(recorder), size);
      var first = -1.0;
      await tester.runAsync(() async {
        final image = await recorder
            .endRecording()
            .toImage(size.width.round(), size.height.round());
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final bytes = data!.buffer.asUint8List();
        final w = size.width.round();
        for (var y = 0; y < size.height.round() && first < 0; y++) {
          for (var x = 0; x < w; x++) {
            if (bytes[(y * w + x) * 4 + 3] != 0) {
              first = y.toDouble();
              break;
            }
          }
        }
      });
      return first;
    }

    // 光标所在行的顶部（Flutter 自己算出来的，不是我们估的）。
    double caretTop() {
      final state = tester.state<EditableTextState>(
          find.descendant(of: field, matching: find.byType(EditableText)));
      final text = tester.widget<TextField>(field).controller!.text;
      return state.renderEditable
          .getLocalRectForCaret(TextPosition(offset: text.length))
          .top;
    }

    // 量出真实行距：一次换行时光标在第一行下沿，两次换行时又下移一行。
    await type('第一段\n');
    final paraBottom = caretTop();
    await type('第一段\n\n');
    final nextTop = caretTop();
    final lineH = nextTop - paraBottom;
    expect(lineH, greaterThan(20));

    // 空档只有一行：线在正中，上下各留一半。
    await type('第一段\n');
    final dash = await dashY();
    expect(dash - paraBottom, greaterThan(2));
    // 两侧离得一样远（量行位的两套算法差不到四分之一行）。
    expect((dash - paraBottom) - (nextTop - dash), lessThan(lineH * 0.25));

    // 末尾还剩空行、光标已落到最下面一行：虚线画在空行区正中，不贴上一段。
    await type('第一段\n\n\n');
    final dash3 = await dashY();
    expect((dash3 - paraBottom - 1.0 * lineH).abs(), lessThan(lineH * 0.25));

    // 上一段很长、折成好几行时，线也得在它下面，不能落进字里。
    final long = '一二三四五六七八九十' * 12;
    await type('$long\n');
    final wrappedBottom = caretTop();
    expect(wrappedBottom, greaterThan(3 * lineH));
    final dashWrapped = await dashY();
    expect(dashWrapped, greaterThan(wrappedBottom + 2));
    expect(dashWrapped, lessThan(wrappedBottom + lineH));
  });

  testWidgets('人天利益：按一次回车自动补成空行，光标落到分割线下方', (tester) async {
    await openEdit(tester, save: (_) {});
    final field = find.byKey(const ValueKey('shanzhishi_paragraphs_field'));
    final rules = find.byKey(const ValueKey('shanzhishi_paragraphs_rules'));
    final ctrl = tester.widget<TextField>(field).controller!;

    await tester.enterText(field, '第一段');
    await tester.pump();
    expect(ctrl.text, '第一段');

    // 模拟平台送来的一个换行（回车）。
    Future<void> pressEnter() async {
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: '${ctrl.text}\n',
        selection: TextSelection.collapsed(offset: ctrl.text.length + 1),
      ));
      await tester.pump();
      await tester.pump();
    }

    await pressEnter();
    // 一个换行自动补成「空行＋新行」，光标落在空行下面那行（分割线之下）。
    expect(ctrl.text, '第一段\n\n');
    expect(ctrl.selection.extentOffset, 5);
    // 段间虚线随之画出。
    final paint = tester.widget<CustomPaint>(rules);
    expect((paint.painter! as ParaRulePainter).rules, isNotEmpty);

    // 光标已经在空行下面时再按：不叠空行。
    await pressEnter();
    expect(ctrl.text, '第一段\n\n');
    expect(ctrl.selection.extentOffset, 5);
  });

  testWidgets('编辑改名撞车：提示「保存两者 / 合并」', (tester) async {
    int? saved;
    await openEdit(tester, save: (v) => saved = v, index: 0);
    final store = ShanZhiShiStore.instance;
    final before = store.length;

    // 「地藏菩萨摩」与种子里的「地藏王菩萨」字符重合 4/5 = 80%。
    await tester.enterText(find.byType(TextField).first, '地藏菩萨摩');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('或有重名善知识'), findsOneWidget);

    // 保存两者：照常保存，条数不变，相似条目原样留着。
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
    await openEdit(tester, save: (v) => saved = v, index: 0);

    await tester.enterText(find.byType(TextField).first, '地藏王菩萨');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('或有重名善知识'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shanzhishi_merge_existing')));
    await tester.pumpAndSettle();
    expect(store.length, before - 1);
    final merged = store.entries.firstWhere((e) => e.name == '地藏王菩萨');
    expect(merged.paragraphs, contains('来自地藏菩萨的段落'));
    expect(saved, isNotNull);
    expect(store[saved!]!.name, '地藏王菩萨');
  });

  testWidgets('编辑改名撞车选「保存两者」：只改本条，不删相似条目', (tester) async {
    final store = ShanZhiShiStore.instance;
    await store.load();
    await store.update(0, paragraphs: ['来自地藏菩萨的段落']);
    final before = store.length;
    int? saved;
    await openEdit(tester, save: (v) => saved = v, index: 0);

    await tester.enterText(find.byType(TextField).first, '地藏菩萨摩');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('或有重名善知识'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shanzhishi_add_new')));
    await tester.pumpAndSettle();
    expect(store.length, before);
    expect(store.entries.any((e) => e.name == '地藏菩萨摩'), isTrue);
    expect(store.entries.any((e) => e.name == '地藏王菩萨'), isTrue);
    expect(store[0]!.paragraphs, contains('来自地藏菩萨的段落'));
    expect(saved, 0);
    expect(store[saved!]!.name, '地藏菩萨摩');
  });

  testWidgets('编辑完全同名：可合并到已有，也可「保存两者」', (tester) async {
    final store = ShanZhiShiStore.instance;
    await store.load();
    // 造一个完全同名的重复（模拟之前选「保存两者」留下的两条）。
    await store.update(1, name: store[0]!.name);

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

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('或有重名善知识'), findsOneWidget);
    // 只剩两个方向：合并到已有，或保存两者；不再有「合并到当前」。
    expect(find.byKey(const ValueKey('shanzhishi_add_new')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('shanzhishi_keep_new_name')), findsNothing);
    expect(find.byKey(const ValueKey('shanzhishi_merge_existing')),
        findsOneWidget);
  });

  testWidgets('编辑不改名也查重：与现存近似名号提示合并', (tester) async {
    final store = ShanZhiShiStore.instance;
    await store.load();
    // 种子里同时有「地藏菩萨」(index 0) 与「地藏王菩萨」：4/5 = 80%，算重复。
    expect(store[0]!.name, '地藏菩萨');
    final iWangzang = store.entries.indexWhere((e) => e.name == '地藏王菩萨');
    expect(iWangzang, greaterThan(0));
    final before = store.length;

    int? saved;
    await openEdit(tester, save: (v) => saved = v, index: 0);

    // 名号一个字都没改，直接保存：也要查出「地藏王菩萨」这条近似名号。
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('或有重名善知识'), findsOneWidget);

    // 选合并：本条删掉，并入「地藏王菩萨」。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_merge_existing')));
    await tester.pumpAndSettle();
    expect(store.length, before - 1);
    expect(store.entries.any((e) => e.name == '地藏菩萨'), isFalse);
    expect(store.entries.any((e) => e.name == '地藏王菩萨'), isTrue);
    expect(saved, isNotNull);
  });

  testWidgets('编辑同名重复项：保存时提示合并', (tester) async {
    final store = ShanZhiShiStore.instance;
    await store.load();
    // 造一个完全同名的重复（模拟之前选「两个都留着」留下的两条）。
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
    expect(find.text('或有重名善知识'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shanzhishi_merge_existing')));
    await tester.pumpAndSettle();
    expect(store.length, before - 1);
  });

  testWidgets('从阅读页打开新增面板：自动关联当前经文', (tester) async {
    final store = ShanZhiShiStore.instance;
    await store.load();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => ShanZhiShiEditSheet.show(
                context,
                initialSutra: '妙法莲华经卷一',
                initialParagraphs: const ['观自在菩萨行深般若波罗蜜多时'],
              ),
              child: const Text('打开添加'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开添加'));
    await tester.pumpAndSettle();

    expect(find.text('添加善知识'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('shanzhishi_sutra_chip_妙法莲华经卷一')),
      findsOneWidget,
    );
    expect(find.text('当前经文：妙法莲华经卷一'), findsOneWidget);

    final paraField = tester.widget<TextField>(
      find.byKey(const ValueKey('shanzhishi_paragraphs_field')),
    );
    expect(paraField.controller?.text, '观自在菩萨行深般若波罗蜜多时');
  });
}
