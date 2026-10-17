import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/app_palette.dart';
import 'package:my_flutter_app/reading_page.dart';
import 'package:my_flutter_app/reading_stage_page.dart';
import 'package:my_flutter_app/sutra_list_page.dart';
import 'package:my_flutter_app/twenty_classics_data.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// 经藏页「廿册精选典籍」区块与「查看更多」按钮的定位键
/// （见 sutra_list_page._buildTwentyClassicsSection / _buildTwentyMoreEntry）。
const ValueKey<String> _sectionKey = ValueKey('twenty_classics_section');
const ValueKey<String> _moreKey = ValueKey('twenty_classics_more');

/// 全站统一的「已标记完成」经名色（金棕）。
const Color _kReadDone = Color(0xFFcf9e66);

/// mock path_provider 到一次性临时目录，避免测试之间互相污染。
Directory _mockDocsDir(WidgetTester tester) {
  final dir = Directory.systemTemp.createTempSync('sutra_ui_');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProviderChannel, (call) async {
    if (call.method == 'getApplicationDocumentsDirectory' ||
        call.method == 'getApplicationSupportDirectory') {
      return dir.path;
    }
    return null;
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// 泵起经藏页。
///
/// [loadCatalog] 为真时用 [WidgetTester.runAsync] 让目录 JSON 的真实资源 I/O
/// 跑完（fake async 下不跑完则 _allSutras 一直为空，廿册卡的部类/字数与廿册页
/// 的文件夹都出不来）；这时视口放宽到 582dp：测试字体每个字符都是方框，窄视口下
/// 阅藏进度卡底部统计行会因数字变宽而报溢出（与本次改动无关）。
Future<void> _pumpSutraList(
  WidgetTester tester, {
  bool loadCatalog = false,
}) async {
  tester.view.physicalSize = Size(loadCatalog ? 1600 : 1080, 2340);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: SutraListPage()));
  for (var i = 0; i < 12; i++) {
    if (loadCatalog) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
    }
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// 交替推进真实异步与假异步：进入 [ReadingPage] 这类会按 100ms 轮询「内容是否
/// 加载完」的页面后，若不把真实文件 I/O 跑完，页面会一直重排 100ms 定时器，
/// 测试收尾时会因「定时器未清理」而失败。此法让内容真正加载完、轮询自然结束。
Future<void> _settleAsync(WidgetTester tester, {int iterations = 15}) async {
  for (var i = 0; i < iterations; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// 先备好 SharedPreferences（[AppPalette.instance.load] 会读它，未 mock 会挂起），
/// 再载入外观偏好并泵起经藏页。所有用例都必须经此入口，不能先 load 后 setMock。
Future<void> _initAndPump(
  WidgetTester tester, {
  bool loadCatalog = false,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  await AppPalette.instance.load();
  // rootBundle 会把「挂起中的 loadString Future」缓存下来：上一个用例在 fake
  // async 里发起、runAsync 才跑完的真实资源 I/O 若未结束，后续用例拿到的是同一个
  // 永不完成的 Future，_loadCatalogFromAsset 便挂死、_allSutras 恒为空。
  // 每个用例前清掉该键的缓存，保证本次 runAsync 能拿到一份新鲜、可完成的加载。
  rootBundle.evict('assets/sutras_catalog.json');
  await _pumpSutraList(tester, loadCatalog: loadCatalog);
}

Finder _pageScrollable() => find.descendant(
    of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable));

/// 滚到目标可见（廿册区块在首屏下方，不滚过去点不到）。
Future<Finder> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 260, scrollable: _pageScrollable());
  await tester.pump(const Duration(milliseconds: 200));
  return target;
}

/// 封面切图按显示尺寸压缩（cacheWidth），此时 Image 的 provider 是
/// [ResizeImage]，因此不能直接用 find.image(AssetImage(...)) 匹配。
Finder _coverImage(String asset) {
  return find.byWidgetPredicate((w) {
    if (w is! Image) return false;
    final provider = w.image;
    final inner = provider is ResizeImage ? provider.imageProvider : provider;
    return inner == AssetImage(asset);
  });
}

/// 廿册页（[ReadingStagePage]）里某个经名 Text 的实际颜色。
Color _folderNameColor(WidgetTester tester, String name) {
  final t = tester.widget<Text>(find.descendant(
      of: find.byType(ReadingStagePage), matching: find.text(name)));
  return t.style!.color!;
}

void main() {
  testWidgets('廿册精选典籍：区块在随缘读经与百册之间，首屏只展示前四部', (tester) async {
    _mockDocsDir(tester);
    await _initAndPump(tester);
    expect(tester.takeException(), isNull, reason: '经藏页首屏不应抛异常');

    final section = await _scrollTo(tester, find.byKey(_sectionKey));
    expect(section, findsOneWidget, reason: '应存在廿册精选典籍区块');

    // 标题 / 副标题。
    expect(find.descendant(of: section, matching: find.text('廿册精选典籍')),
        findsOneWidget);
    expect(
        find.descendant(
            of: section, matching: find.text('汇聚佛门经典，传承千年诵读名篇')),
        findsOneWidget);

    // 只展示前四部：四张封面 + 四个经名。
    final sutras = kTwentyClassics.sutras;
    expect(find.descendant(of: section, matching: find.byType(Image)),
        findsNWidgets(kTwentyClassicsShowcaseCount),
        reason: '首屏封面图数量应等于展示部数');
    for (final s in sutras.take(kTwentyClassicsShowcaseCount)) {
      expect(find.descendant(of: section, matching: find.text(s.name)),
          findsOneWidget,
          reason: '首屏应展示《${s.name}》');
      expect(find.descendant(of: section, matching: _coverImage(s.icon!)),
          findsOneWidget,
          reason: '《${s.name}》应带封面切图');
    }
    expect(
        find.descendant(of: section, matching: find.text(sutras[4].name)),
        findsNothing,
        reason: '第五部及以后只在「查看更多」页展示');

    // 「查看更多」是整行宽按钮，文案居中（与经典卡同宽）。
    final more = find.byKey(_moreKey);
    expect(more, findsOneWidget);
    final sectionW = tester.getSize(section).width;
    expect(tester.getSize(more).width, closeTo(sectionW - 56, 0.5),
        reason: '查看更多按钮应与经典卡同宽（区块左右各 16 外边距 + 12 内边距）');
    expect(tester.getCenter(more).dx,
        closeTo(tester.getCenter(section).dx, 1),
        reason: '查看更多按钮应整行居中（与区块中线对齐）');

    // 区块位置：随缘读经 → 廿册精选典籍 → 百册经论指南。
    final yRandom = tester.getTopLeft(find.text('随机选择，一切皆是因缘')).dy;
    final yTwenty = tester.getTopLeft(section).dy;
    final yHundred = tester.getTopLeft(find.text('百册经论指南')).dy;
    expect(yRandom < yTwenty, isTrue, reason: '廿册区块应在随缘读经下方');
    expect(yTwenty < yHundred, isTrue, reason: '廿册区块应在百册经论指南上方');
  });

  testWidgets('廿册首屏卡片：简介换成所属部类与字数', (tester) async {
    _mockDocsDir(tester);
    await _initAndPump(tester, loadCatalog: true);

    final section = await _scrollTo(tester, find.byKey(_sectionKey));

    // 部类取自随包目录（与经藏页其它卡片同一份部类名），字数按整部经合计。
    expect(
        find.descendant(of: section, matching: find.text('T08般若部 · 944 字')),
        findsOneWidget,
        reason: '《心经》应显示所属部类与字数');
    expect(find.descendant(of: section, matching: find.text('T13大集部 · 1.68万字')),
        findsOneWidget,
        reason: '多卷《地藏经》字数应合计两卷');

    // 简介不再出现在卡片上。
    expect(find.descendant(of: section, matching: find.textContaining('简称《心经》')),
        findsNothing,
        reason: '卡片右侧不再显示简介');
  });

  testWidgets('廿册「查看更多」：进入含全部 20 部、每部带完成进度的读经页', (tester) async {
    _mockDocsDir(tester);
    await _initAndPump(tester, loadCatalog: true);

    final more = await _scrollTo(tester, find.byKey(_moreKey));
    await tester.tap(more);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull, reason: '廿册页不应抛异常');
    // 统计条证明 20 部全部解析成文件夹展示出来了。
    expect(find.text('20 部经典'), findsOneWidget, reason: '廿册页应展示全部 20 部');
    // 首屏没展示的第五部，在廿册页里能看到。
    expect(find.text(kTwentyClassics.sutras[4].name), findsOneWidget);
    // 每个文件夹副标题带「已完成 已读/总卷」进度（全部未读即 0/N）。
    expect(
        find.descendant(
            of: find.byType(ReadingStagePage),
            matching: find.textContaining(RegExp(r'已完成 0/\d+$'))),
        findsWidgets,
        reason: '文件夹副行应显示完成进度');
  });

  testWidgets('廿册首屏点某一部：直接进入阅读页', (tester) async {
    _mockDocsDir(tester);
    // 该册标记为已下载：走经藏页同一套「能打开就直接进阅读页」的判定。
    await _initAndPump(tester, loadCatalog: true, prefs: {
      'downloaded_sutra_ids': <String>['T08n0251_001'],
    });

    final card = await _scrollTo(
        tester,
        find.descendant(
            of: find.byKey(_sectionKey), matching: find.text('般若波罗蜜多心经')));
    await tester.tap(card);
    await _settleAsync(tester);

    expect(find.byType(ReadingPage), findsOneWidget,
        reason: '点首屏经典卡应直接进入阅读页，而不是文件夹页');

    // 阅读页会按 100ms 轮询「内容是否加载完」，测试环境里内容未必能就此加载完，
    // 收尾时留下未触发的定时器会触发 binding 断言。销毁页面并再推一帧让该定时器
    // 落地（mounted=false 后轮询自然终止）。
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('已完成的经文显示完成色，文件夹不染色但显示完成进度', (tester) async {
    _mockDocsDir(tester);
    // 云端同步下来的状态：心经（1 卷）读完、地藏经（2 卷）只读完卷一。
    await _initAndPump(tester, loadCatalog: true, prefs: {
      'sutra_states': '{"般若波罗蜜多心经T08n0251_001":{"r":true},'
          '"地藏菩萨本愿经T13n0412_001":{"r":true}}',
    });

    final section = await _scrollTo(tester, find.byKey(_sectionKey));
    Color cardNameColor(String name) => tester
        .widget<Text>(find.descendant(of: section, matching: find.text(name)))
        .style!
        .color!;
    expect(cardNameColor('般若波罗蜜多心经'), _kReadDone,
        reason: '已完成的经文名应显示完成色');
    expect(cardNameColor('地藏菩萨本愿经'), _kReadDone,
        reason: '多卷经只要有一卷完成就显示完成色');
    expect(cardNameColor('金刚般若波罗蜜经'), isNot(_kReadDone),
        reason: '未标记完成的经文名保持正文色');

    // 廿册页：文件夹名不再染色（只有其中的分卷才显示完成色），
    // 副标题追加「已完成 已读/总卷」进度。
    await tester.tap(find.byKey(_moreKey));
    await _settleAsync(tester);

    expect(_folderNameColor(tester, '般若波罗蜜多心经'), AppPalette.p.text,
        reason: '文件夹不再显示完成色');
    expect(_folderNameColor(tester, '地藏菩萨本愿经'), AppPalette.p.text,
        reason: '文件夹不再显示完成色');
    expect(_folderNameColor(tester, '金刚般若波罗蜜经'), AppPalette.p.text,
        reason: '未读文件夹保持正文色');

    Finder inPage(RegExp text) => find.descendant(
        of: find.byType(ReadingStagePage), matching: find.textContaining(text));
    expect(inPage(RegExp(r'已完成 1/1$')), findsOneWidget,
        reason: '读完的文件夹（心经 1/1）进度应为 1/1');
    expect(inPage(RegExp(r'已完成 1/2$')), findsOneWidget,
        reason: '《地藏经》2 卷读了 1 卷，进度应为 1/2');
    // 整部读完的文件夹（心经）在进度文案末尾带一枚完成对勾；
    // 未读完的地藏经、未读的金刚经都不显示对勾。
    expect(
        find.descendant(
            of: find.byType(ReadingStagePage),
            matching: find.byIcon(Icons.check_circle)),
        findsOneWidget,
        reason: '只有整部读完的文件夹才显示完成对勾');
  });
}
