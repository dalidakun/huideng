import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/shanzhishi_mantra_store.dart';
import 'package:my_flutter_app/shanzhishi_page.dart';
import 'package:my_flutter_app/shanzhishi_sphere.dart';
import 'package:my_flutter_app/shanzhishi_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ShanZhiShiStore.instance.resetForTest();
    ShanZhiShiMantraStore.instance.resetForTest();
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
    // header 显示名号，面板铺开（经文各自成行，不再有「关联经文」标签）。
    expect(find.text(shown!.name), findsOneWidget);
    expect(find.text('关联经文'), findsNothing);
    // 不弹编辑面板，但面板右下角有编辑按钮（只有笔图标，没有「编辑」字样）。
    expect(find.text('编辑善知识'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.text('编辑'), findsNothing);
    // 再点 header 收起面板。
    await tester.tap(find.text(shown.name));
    await tester.pumpAndSettle();
    expect(find.text('关联经文'), findsNothing);
  });

  testWidgets('记住上次点选的名号：重进页面后球心默认对准它', (tester) async {
    await pumpPage(tester);
    final store = ShanZhiShiStore.instance;
    // 选末位（离初始球心很远），记为上次点选。
    final last = store[store.length - 1]!;
    await store.rememberLastTapped(last.name);

    // 模拟退出重进：整棵页面销毁重建，球体重新按上次点选对准。
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home: ShanZhiShiPage()));
    await tester.pumpAndSettle();

    // 点球心：拉出的面板应是上次点的那一位，而不是默认正中间那一位。
    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();
    expect(find.text(last.name), findsOneWidget);
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

    // 子按钮「切换」：整页滑到第 2 页密咒展示面，换成该页的悬浮球。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_switch')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('shanzhishi_mantra_view')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('shanzhishi_mx_fab_ring')), findsOneWidget);
    expect(find.byKey(const ValueKey('shanzhishi_fab_close')), findsNothing);
    // 密咒页的「切换」再滑回佛号球面（先点开悬浮球，再点子按钮）。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mx_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mx_fab_switch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shanzhishi_mantra_view')), findsNothing);
    expect(find.byKey(const ValueKey('shanzhishi_fab_ring')), findsOneWidget);
    expect(find.byKey(const ValueKey('shanzhishi_fab_close')), findsNothing);
  });

  testWidgets('密咒页悬浮球：搜索/添加/切换回佛号', (tester) async {
    await pumpPage(tester);
    // 切到密咒页。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_switch')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('shanzhishi_mantra_view')), findsOneWidget);

    // 密咒页悬浮球：收起态白圈在，展开后三个子按钮。
    expect(
        find.byKey(const ValueKey('shanzhishi_mx_fab_ring')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mx_fab_ring')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('shanzhishi_mx_fab_close')), findsOneWidget);

    // 搜索：搜的是密咒。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mx_fab_search')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('shanzhishi_mx_search_field')), '六字');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shanzhishi_mx_search_results')),
        findsOneWidget);
    expect(find.text('六字大明咒'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mx_search_close')));
    await tester.pumpAndSettle();

    // 添加：新建一条密咒，新条目排在最前。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mx_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mx_fab_add')));
    await tester.pumpAndSettle();
    expect(find.text('添加神咒'), findsOneWidget);
    // 四项：神咒名称、经文出处、神咒原文、人天利益。
    expect(find.text('神咒名称'), findsOneWidget);
    expect(find.text('经文出处'), findsOneWidget);
    expect(find.text('神咒原文'), findsOneWidget);
    expect(find.text('人天利益'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('shanzhishi_mantra_name_field')), '药师灌顶真言');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    // 「药师灌顶真言」与内置「药师心咒」共有「药师」二字，会弹合并选择框；
    // 选「保存两者」：新条目另起一条，排在最前。
    if (find.text('或有重名神咒').evaluate().isNotEmpty) {
      await tester
          .tap(find.byKey(const ValueKey('shanzhishi_mantra_keep_both')));
      await tester.pumpAndSettle();
    }
    // 面板已收起，新密咒排在名单最前（竖排第一条）。
    expect(find.text('添加神咒'), findsNothing);
    expect(find.text('药\n师\n灌\n顶\n真\n言'), findsOneWidget);

    // 搜索命中要「显示出对应密咒」：点结果后名单滚到位，该条出现在视口上部。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mx_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mx_fab_search')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('shanzhishi_mx_search_field')), '楞严');
    await tester.pumpAndSettle();
    await tester.tap(find.text('楞严咒'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shanzhishi_mx_search_results')),
        findsNothing);
    // 「药师灌顶真言」新增后排在最前，楞严咒因此是第 11 条（下标 10）。
    final revealed =
        tester.getRect(find.byKey(const ValueKey('shanzhishi_mantra_10')));
    // 点结果后该条落在视口内（内容装得下就不必滚动，装不下会滚到上部）。
    expect(revealed.top, greaterThan(0));
    expect(revealed.top, lessThan(520));
    expect(revealed.bottom, lessThan(800));
    // 命中那条要有高亮（强调色描边），而且要一直亮着、不自动消失。
    double hitBorderAlpha() {
      final box = tester.widget<AnimatedContainer>(
          find.byKey(const ValueKey('shanzhishi_mantra_10')));
      final border = (box.decoration as BoxDecoration).border as Border;
      return border.top.color.a;
    }

    expect(hitBorderAlpha(), greaterThan(0.5));
    await tester.pump(const Duration(seconds: 3));
    expect(hitBorderAlpha(), greaterThan(0.5));
    // 点一下页面任意位置，高亮才去掉。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mantra_view')));
    await tester.pumpAndSettle();
    expect(hitBorderAlpha(), 0);

    // 切换子按钮：整页滑回佛号球面（密咒页不在视口了，悬浮球收起态在）。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mx_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mx_fab_switch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shanzhishi_mantra_view')), findsNothing);
    expect(find.byKey(const ValueKey('shanzhishi_fab_ring')), findsOneWidget);
  });

  testWidgets('点密咒：弹出详情，显示经文出处与神咒原文', (tester) async {
    await pumpPage(tester);
    await ShanZhiShiMantraStore.instance.add(
      '测试神咒',
      source: '《药师琉璃光如来本愿功德经》',
      text: '嗡嘛呢叭咪吽',
      benefit: ['闻此咒者得安乐'],
    );
    await tester.pumpAndSettle();

    // 切到密咒页。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_switch')));
    await tester.pumpAndSettle();

    // 新密咒排在最前，点它打开详情。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mantra_0')));
    await tester.pumpAndSettle();
    expect(find.text('测试神咒'), findsOneWidget);
    // 详情里不再有「经文出处 / 神咒原文」小标题，直接显示内容。
    expect(find.text('经文出处'), findsNothing);
    expect(find.text('《药师琉璃光如来本愿功德经》'), findsOneWidget);
    // 经文出处是整行可点的经文块，右侧带进入阅读的箭头。
    expect(find.byKey(const ValueKey('shanzhishi_mantra_source_row')),
        findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.text('神咒原文'), findsNothing);
    expect(find.text('嗡嘛呢叭咪吽'), findsOneWidget);
    // 神咒原文下面接着显示人天利益（带「人天利益」标志）。
    expect(find.textContaining('闻此咒者得安乐', findRichText: true), findsOneWidget);
    expect(find.text('人天利益'), findsOneWidget);
    // 没有右上角叉号；点顶部名称即收起。
    expect(find.byIcon(Icons.close), findsNothing);
    await tester.tap(find.text('测试神咒'));
    await tester.pumpAndSettle();
    expect(find.text('嗡嘛呢叭咪吽'), findsNothing);
  });

  testWidgets('神咒详情：注音标在字上、备注集中成块放在咒文下，经文出处居中夹在中间',
      (tester) async {
    await pumpPage(tester);
    await ShanZhiShiMantraStore.instance.add(
      '批注咒',
      source: '《药师经》',
      text: '嗡嘛呢叭咪吽',
      benefit: ['闻此咒者得安乐'],
      annotations: const [
        MantraAnnotation(start: 0, end: 1, ruby: 'ōng', note: '归命'),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mantra_0')));
    await tester.pumpAndSettle();

    final ruby = find.textContaining('ōng', findRichText: true);
    expect(ruby, findsOneWidget);
    final notes = find.byKey(const ValueKey('shanzhishi_mantra_notes'));
    expect(notes, findsOneWidget);
    expect(find.textContaining('归命', findRichText: true), findsOneWidget);
    final textY = tester.getTopLeft(ruby).dy;
    final notesY = tester.getTopLeft(notes).dy;
    final sourceY = tester.getTopLeft(find.text('《药师经》')).dy;
    final benefitY = tester.getTopLeft(find.text('人天利益')).dy;
    expect(textY, lessThan(notesY));
    expect(notesY, lessThan(sourceY));
    expect(sourceY, lessThan(benefitY));

    // 首行注音画在行框上方，不能被咒文列表顶部裁掉：它的上边必须落在
    // 列表可视区之内（列表顶部有一条留白专门让出注音高度）。
    final listTop =
        tester.getRect(find.byKey(const ValueKey('shanzhishi_mx_list'))).top;
    final rubyRect = tester.getRect(find.text('ōng'));
    expect(rubyRect.top, greaterThanOrEqualTo(listTop));
  });

  testWidgets('跨行的大范围注音不会吞掉后面每一条注音', (tester) async {
    await pumpPage(tester);
    await ShanZhiShiMantraStore.instance.add(
      '多行批注咒',
      source: '《药师经》',
      text: '嗡嘛呢\n叭咪吽\n梭哈',
      annotations: const [
        // 整段（跨三行）标了一个注音。
        MantraAnnotation(start: 0, end: 8, ruby: 'BROAD'),
        // 第二、三行各自又单独标了注音。
        MantraAnnotation(start: 4, end: 5, ruby: 'BBB'),
        MantraAnnotation(start: 8, end: 9, ruby: 'CCC'),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mantra_0')));
    await tester.pumpAndSettle();

    expect(find.text('BROAD'), findsOneWidget);
    expect(find.text('BBB'), findsOneWidget);
    expect(find.text('CCC'), findsOneWidget);
    // 第二、三行的注音依次在下方，没有被第一行遮住。
    final broadY = tester.getTopLeft(find.text('BROAD')).dy;
    final bY = tester.getTopLeft(find.text('BBB')).dy;
    final cY = tester.getTopLeft(find.text('CCC')).dy;
    expect(broadY, lessThan(bY));
    expect(bY, lessThan(cY));
    // 三行正文都还在（跨行注音没有把文字吞进一个行内占位符）。
    expect(find.text('叭'), findsOneWidget);
    expect(find.text('梭'), findsOneWidget);
  });

  testWidgets('系统字号调大时：注音仍压在字上方，不进正文', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await pumpPage(tester);
    await ShanZhiShiMantraStore.instance.add(
      '大字号咒',
      source: '《药师经》',
      text: '唵嘛呢\n叭咪吽',
      annotations: const [
        MantraAnnotation(start: 0, end: 1, ruby: 'ōng'),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mantra_0')));
    await tester.pumpAndSettle();
    // 大字号下详情头部有既有的固定高度溢出告警，与本用例无关。
    while (tester.takeException() != null) {}

    final ruby = find.text('ōng');
    final chunk = find.text('唵');
    expect(ruby, findsOneWidget);
    expect(chunk, findsOneWidget);
    final rr = tester.getRect(ruby);
    final cr = tester.getRect(chunk);
    // 注音底边必须在正文字「字面」的上方，不压进字里。
    // （注音画在行距空隙里，允许探进正文行框的上留白，所以和行框顶比没意义；
    //   字面顶 = 行框顶 + 上半行距，行框高 16×2.3×1.3、字面高 16×1.3。）
    final glyphTop = cr.top + (cr.height - 16 * 1.3) / 2;
    expect(glyphTop - rr.bottom, greaterThanOrEqualTo(0));
    // 正文只被系统字号放大一次（16×2.3×1.3≈47.8），不是两倍（≈63）。
    expect(cr.height, inInclusiveRange(44, 51));
    // 咒文段落正好两行：注音不能把正文挤出多余的空白行。
    // 被注音的「唵」在纯文本里是占位符，用后面的「嘛呢」认段落。
    RichText? mainRt;
    for (final el in find.byType(RichText).evaluate()) {
      final w = el.widget as RichText;
      if (w.text.toPlainText().contains('嘛呢')) {
        mainRt = w;
        break;
      }
    }
    expect(mainRt, isNotNull);
    final pr = tester.getRect(find.byWidget(mainRt!));
    expect((pr.height / cr.height).round(), 2);
  });

  testWidgets('密咒面板右下角编辑按钮：回填内容，改完保存即生效', (tester) async {
    await pumpPage(tester);
    await ShanZhiShiMantraStore.instance.add(
      '测试神咒',
      source: '《药师经》',
      text: '嗡嘛呢叭咪吽',
    );
    await tester.pumpAndSettle();

    // 切到密咒页，点开详情。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mantra_0')));
    await tester.pumpAndSettle();

    // 右下角是圆形编辑按钮：只有笔图标，没有「编辑」字样。
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.text('编辑'), findsNothing);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text('编辑神咒'), findsOneWidget);
    // 三项都回填了原值（名称随编辑被改成新名，保存后详情也跟着换）。
    expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('shanzhishi_mantra_name_field')))
            .controller!
            .text,
        '测试神咒');
    expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('shanzhishi_mantra_text_field')))
            .controller!
            .text,
        '嗡嘛呢叭咪吽');

    await tester.enterText(
        find.byKey(const ValueKey('shanzhishi_mantra_text_field')), '新咒文');
    final saveButton = find.widgetWithText(FilledButton, '保存');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    // 面板回详情，原文已经换成新内容。
    expect(find.text('编辑神咒'), findsNothing);
    expect(find.text('新咒文'), findsOneWidget);
    final store = ShanZhiShiMantraStore.instance;
    expect(store.textOf('测试神咒'), '新咒文');
  });

  testWidgets('编辑里给咒文加注音：保存后详情直接显示注音', (tester) async {
    await pumpPage(tester);
    await ShanZhiShiMantraStore.instance.add(
      '流程咒',
      source: '《药师经》',
      text: '嗡嘛呢叭咪吽',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mantra_0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    final textField =
        find.byKey(const ValueKey('shanzhishi_mantra_text_field'));
    final ctrl = tester.widget<TextField>(textField).controller!;
    ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 1);
    await tester.pump();
    final rubyTool = find.byKey(const ValueKey('shanzhishi_mantra_ruby_tool'));
    await tester.ensureVisible(rubyTool);
    await tester.pumpAndSettle();
    await tester.tap(rubyTool);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('shanzhishi_mantra_ruby_input')), 'ōng');
    await tester.tap(
        find.byKey(const ValueKey('shanzhishi_mantra_annotation_save')));
    await tester.pumpAndSettle();
    final saveButton = find.widgetWithText(FilledButton, '保存');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(find.text('编辑神咒'), findsNothing);
    expect(find.text('ōng'), findsOneWidget);
  });

  testWidgets('编辑神咒时名称也删空：保存即删除，不再显示', (tester) async {
    await pumpPage(tester);
    await ShanZhiShiMantraStore.instance.add(
      '测试神咒',
      source: '《药师经》',
      text: '嗡嘛呢叭咪吽',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mantra_0')));
    await tester.pumpAndSettle();

    // 打开编辑，三项全删空（名称是关键：没名字就无从展示）。
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('shanzhishi_mantra_name_field')), '');
    await tester.enterText(
        find.byKey(const ValueKey('shanzhishi_mantra_source_field')), '');
    await tester.enterText(
        find.byKey(const ValueKey('shanzhishi_mantra_text_field')), '');
    final saveButton = find.widgetWithText(FilledButton, '删除');
    expect(saveButton, findsOneWidget);
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    // 保存成功：编辑面板关闭，详情抽屉收起，名单里这条已经没了。
    expect(find.text('编辑神咒'), findsNothing);
    final store = ShanZhiShiMantraStore.instance;
    expect(store.mantras, isNot(contains('测试神咒')));
    expect(
        find.byKey(const ValueKey('shanzhishi_mx_shelf_panel')), findsNothing);
    expect(find.byKey(const ValueKey('shanzhishi_mantra_0')), findsWidgets);
    // 竖排名单里也不再出现这条。
    expect(find.text('测\n试\n神\n咒'), findsNothing);
  });

  testWidgets('内置密咒也能改名：改完名单里换新名', (tester) async {
    await pumpPage(tester);

    // 切到密咒页，第一条就是内置的「六字大明咒」。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mantra_0')));
    await tester.pumpAndSettle();
    expect(find.text('六字大明咒'), findsOneWidget);

    // 打开编辑：名称输入框不再只读，直接改成新名保存。
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text('编辑神咒'), findsOneWidget);
    final nameField = tester.widget<TextField>(
        find.byKey(const ValueKey('shanzhishi_mantra_name_field')));
    expect(nameField.enabled, isTrue);
    await tester.enterText(
        find.byKey(const ValueKey('shanzhishi_mantra_name_field')), '我的六字咒');
    final saveButton = find.widgetWithText(FilledButton, '保存');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    // 面板回详情，显示新名；名单里旧名已被替换。
    expect(find.text('编辑神咒'), findsNothing);
    expect(find.text('我的六字咒'), findsOneWidget);
    final store = ShanZhiShiMantraStore.instance;
    expect(store.mantras, contains('我的六字咒'));
    expect(store.mantras, isNot(contains('六字大明咒')));
  });

  testWidgets('底部面板展开时右下角悬浮球让位', (tester) async {
    await pumpPage(tester);
    expect(find.byKey(const ValueKey('shanzhishi_fab_layer')), findsOneWidget);
    // 点名号拉出面板：悬浮球隐藏，避免压住面板右下角的「编辑」。
    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('shanzhishi-shelf-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('shanzhishi_fab_layer')), findsNothing);
  });

  testWidgets('面板右下角编辑按钮打开编辑面板', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text('编辑善知识'), findsOneWidget);
    // 编辑面板里有「引用段落」维护区：一段一条的大输入区。
    expect(find.byKey(const ValueKey('shanzhishi_paragraphs_field')),
        findsOneWidget);

    final cancel = find.text('取消');
    await tester.ensureVisible(cancel);
    await tester.pumpAndSettle();
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(find.text('编辑善知识'), findsNothing);
    // 取消编辑后面板仍在。
    expect(
        find.byKey(const ValueKey('shanzhishi-shelf-panel')), findsOneWidget);
  });

  testWidgets('添加面板文案：关联经文 / 人天利益提示语', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_add')));
    await tester.pumpAndSettle();
    expect(find.text('添加善知识'), findsOneWidget);
    // 「出现过的经文」改成「关联经文」。
    expect(find.text('关联经文'), findsOneWidget);
    expect(find.text('出现过的经文'), findsNothing);
    // 人天利益：新标签与实际输入区（两句提示作为占位）。
    expect(find.text('人天利益'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('shanzhishi_paragraphs_field')))
            .decoration!
            .hintText,
        '输入佛菩萨人天利益\n一段一条，空行分隔\n点选经文对应人天利益段落');
    expect(find.text('引用段落'), findsNothing);
    expect(find.text('输入和佛菩萨关联的经文段落'), findsNothing);
    expect(find.text('留空则展示时自动识别'), findsNothing);
  });

  testWidgets('新增近似名号：让用户选「保存两者」或「合并」', (tester) async {
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
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    // 弹选择框，默认什么都不做。
    expect(find.text('或有重名善知识'), findsOneWidget);
    expect(find.textContaining('地藏菩萨'), findsWidgets);

    // 选「保存两者」：另起一位。
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
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('或有重名善知识'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shanzhishi_merge_existing')));
    await tester.pumpAndSettle();
    // 没有新增条目，面板直接铺在已有的「地藏菩萨」上。
    expect(store.length, before);
    expect(find.text('添加善知识'), findsNothing);
    expect(find.text('关联经文'), findsNothing);
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
    expect(find.text('人天利益'), findsOneWidget);
    expect(find.textContaining('这是用户填的段落', findRichText: true), findsOneWidget);
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
    expect(find.text('人天利益'), findsNWidgets(2));
    expect(find.textContaining('第一段内容', findRichText: true), findsOneWidget);
    expect(find.textContaining('第二段内容', findRichText: true), findsOneWidget);
  });

  testWidgets('面板右下角只有编辑笔图标：不提供「恢复」，避免误点打乱', (tester) async {
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

    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.text('编辑'), findsNothing);
    expect(find.byKey(const ValueKey('shanzhishi_restore')), findsNothing);
    expect(find.text('恢复'), findsNothing);

    // 编辑并保存过之后，也仍然只有编辑笔图标。
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('shanzhishi_paragraphs_field')), '一段利益');
    final saveButton = find.widgetWithText(FilledButton, '保存');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    if (find.text('或有重名善知识').evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('shanzhishi_add_new')));
      await tester.pumpAndSettle();
    }
    expect(store[front]!.paragraphs, ['一段利益']);
    expect(find.textContaining('一段利益', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.text('编辑'), findsNothing);
    expect(find.text('恢复'), findsNothing);
    expect(find.byKey(const ValueKey('shanzhishi_restore')), findsNothing);
  });

  testWidgets('人天利益按经文分组：每部经的人天利益挂在它那一行下面', (tester) async {
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
    await store.update(
      front,
      sutras: ['甲经', '乙经'],
      quotes: {
        '甲经': ['甲经的人天利益'],
        '乙经': ['乙经的人天利益'],
      },
      paragraphs: ['甲经的人天利益', '乙经的人天利益'],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();
    final rowA = find.byKey(const ValueKey('shanzhishi_sutra_row_甲经'));
    final rowB = find.byKey(const ValueKey('shanzhishi_sutra_row_乙经'));
    expect(rowA, findsOneWidget);
    expect(rowB, findsOneWidget);
    // 甲经 → 甲的段落 → 乙经 → 乙的段落，逐层往下。
    final topA = tester.getRect(rowA).top;
    final topParaA =
        tester.getRect(find.textContaining('甲经的人天利益', findRichText: true)).top;
    final topB = tester.getRect(rowB).top;
    final topParaB =
        tester.getRect(find.textContaining('乙经的人天利益', findRichText: true)).top;
    expect(topA, lessThan(topParaA));
    expect(topParaA, lessThan(topB));
    expect(topB, lessThan(topParaB));

    // 经名一整条色块（铺满宽度）：加粗、字色黑、箭头在色块里。
    final sutraText = tester
        .widget<Text>(find.descendant(of: rowA, matching: find.text('甲经')));
    expect(sutraText.style!.fontWeight, FontWeight.w700);
    expect(sutraText.style!.fontSize, 15);
    expect(sutraText.style!.color, Colors.black);
    expect(
        find.descendant(of: rowA, matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget);
    // 色块铺满整行宽度（不是只裹住字）：箭头落在色块右半边里面。
    final sutraBox = tester.getRect(rowA);
    final arrow = tester.getRect(
        find.descendant(of: rowA, matching: find.byIcon(Icons.chevron_right)));
    expect(arrow.center.dx, greaterThan(sutraBox.center.dx));
    expect(arrow.left, greaterThan(sutraBox.center.dx));

    // 「人天利益」就是段落开头那四个字（比正文小一号，裹着圆角色块），
    // 正文紧跟其后；整段左沿与上面经文色块对齐，换行后回到左边不留白。
    final paraFinder = find.byWidgetPredicate((w) =>
        w is Text &&
        w.textSpan != null &&
        w.textSpan!.toPlainText().contains('甲经的人天利益'));
    expect(paraFinder, findsOneWidget);
    final paraWidget = tester.widget<Text>(paraFinder);
    expect(paraWidget.style!.fontSize, 15);

    // 标记是一枚内嵌小色块：四个圆角（不是直角），字号比正文小一号。
    final markerFinder =
        find.descendant(of: paraFinder, matching: find.text('人天利益'));
    expect(markerFinder, findsOneWidget);
    final markerText = tester.widget<Text>(markerFinder);
    expect(markerText.style!.fontSize, 13);
    expect(
        paraWidget.style!.fontSize, greaterThan(markerText.style!.fontSize!));
    final markerBoxFinder =
        find.ancestor(of: markerFinder, matching: find.byType(Container)).first;
    final markerBox = tester.widget<Container>(markerBoxFinder);
    final markerRect = tester.getRect(markerBoxFinder);
    expect((markerBox.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(6));

    // 左沿与经文色块齐平，并且铺满整行（换行回到同一左沿）。
    final paraBox = tester.getRect(paraFinder);
    expect(paraBox.left, moreOrLessEquals(sutraBox.left, epsilon: 0.5));
    expect(paraBox.width, moreOrLessEquals(sutraBox.width, epsilon: 0.5));
    expect(markerRect.left, moreOrLessEquals(sutraBox.left, epsilon: 0.5));
    // 与上面经文色块之间留出了间距。
    expect(paraBox.top, greaterThan(sutraBox.bottom + 4));
  });

  testWidgets('第二部经与上一部经最后一段的间距，明显大于段落之间的间距', (tester) async {
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
    await store.update(
      front,
      sutras: ['甲经', '乙经'],
      quotes: {
        '甲经': ['甲经第一段', '甲经第二段'],
        '乙经': ['乙经的一段'],
      },
      paragraphs: ['甲经第一段', '甲经第二段', '乙经的一段'],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();

    // 同一部经内：第一段 → 第二段 的间距。
    final withinGap = tester
            .getRect(find.textContaining('甲经第二段', findRichText: true))
            .top -
        tester.getRect(find.textContaining('甲经第一段', findRichText: true)).bottom;
    // 跨部：上一部经最后一段 → 下一部经的经文行，间距要更大。
    final betweenGap = tester
            .getRect(find.byKey(const ValueKey('shanzhishi_sutra_row_乙经')))
            .top -
        tester.getRect(find.textContaining('甲经第二段', findRichText: true)).bottom;
    expect(betweenGap, greaterThan(withinGap));
  });

  testWidgets('新增完全同名选「保存两者」：同名两条并存', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_add')));
    await tester.pumpAndSettle();

    final store = ShanZhiShiStore.instance;
    final before = store.length;
    await tester.enterText(find.byType(TextField).first, '地藏菩萨');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('或有重名善知识'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shanzhishi_add_new')));
    await tester.pumpAndSettle();
    expect(store.length, before + 1);
    expect(store.entries.where((e) => e.name == '地藏菩萨').length, 2);
  });

  testWidgets('新增完全同名：可合并到已有，也可「保存两者」', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_add')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '地藏菩萨');
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

  testWidgets('点击佛号的面板：名号大一号，不再有「关联经文」标签', (tester) async {
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
    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();

    // 名号字号 18（比原来的 16 大两号）。
    final name = tester.widget<Text>(find.text(store[front]!.name));
    expect(name.style!.fontSize, 18);
    // 「关联经文」四个字不再出现。
    expect(find.text('关联经文'), findsNothing);
  });

  testWidgets('搜索：悬浮在本页，点结果只转球不自动开面板', (tester) async {
    await pumpPage(tester);
    final store = ShanZhiShiStore.instance;

    // 展开右下角悬浮球 → 点「搜索」。
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_search')));
    await tester.pumpAndSettle();

    // 搜索框悬浮在本页（没有跳到新页面）。
    final field = find.byKey(const ValueKey('shanzhishi_search_field'));
    expect(field, findsOneWidget);
    expect(
        find.byKey(const ValueKey('shanzhishi_search_results')), findsNothing);

    await tester.enterText(field, '观世音');
    await tester.pumpAndSettle();
    final results = find.byKey(const ValueKey('shanzhishi_search_results'));
    expect(results, findsOneWidget);

    final target = store.entries.indexWhere((e) => e.name.contains('观世音'));
    expect(target, greaterThanOrEqualTo(0));
    await tester.tap(find.text(store[target]!.name));
    await tester.pumpAndSettle();

    // 搜索浮层收起，且没有自动打开底部面板。
    expect(find.byKey(const ValueKey('shanzhishi_search_field')), findsNothing);
    expect(find.byKey(const ValueKey('shanzhishi-shelf-panel')), findsNothing);
    expect(find.text('关联经文'), findsNothing);

    // 点球心（已转到该名号）才展开面板。
    await tester.tap(find.byType(ShanZhiShiSphere));
    await tester.pumpAndSettle();
    expect(find.text(store[target]!.name), findsOneWidget);
    expect(
        find.byKey(const ValueKey('shanzhishi-shelf-panel')), findsOneWidget);
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
    final first = tester
        .getRect(find.byKey(const ValueKey('shanzhishi_sutra_row_地藏菩萨本愿经')));
    final second = tester
        .getRect(find.byKey(const ValueKey('shanzhishi_sutra_row_占察善恶业报经')));
    expect(second.top, greaterThan(first.bottom - 1));
  });
}
