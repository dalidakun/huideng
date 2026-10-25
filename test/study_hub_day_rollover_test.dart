import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/study_hub_page.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// 主页配置的功课项名称（与 prefs 里的设置一致）。
const String _itemName = '地藏菩萨本愿经';
const String _day1 = '2024-05-01';
const String _day2 = '2024-05-02';

/// 功课打卡卡片里那一行功课的文案（与 [_buildCheckInItem] 拼装规则一致）。
const String _itemRowText = '诵经·$_itemName × 1遍';

void main() {
  /// 可注入的「现在」：测试里手动改它来模拟应用跨过零点。
  late DateTime fakeNow;

  setUp(() {
    fakeNow = DateTime(2024, 5, 1, 23, 58);
    StudyHubPageState.debugNow = () => fakeNow;

    // 今天（_day1）已经打过卡，页面首次载入应显示为已完成。
    SharedPreferences.setMockInitialValues({
      'setting_reading_titles': jsonEncode([
        {'name': _itemName, 'count': '1'}
      ]),
      'checkin_records': jsonEncode([
        {
          'date': _day1,
          'type': 'reading',
          'label': '诵经',
          'name': _itemName,
          'amount': 1,
        }
      ]),
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsPath') {
        return Directory.systemTemp.path;
      }
      return null;
    });
  });

  tearDown(() {
    StudyHubPageState.debugNow = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
  });

  /// 反复 pump 直到 [finder] 出现（页面有常驻脉冲动画，不能用 pumpAndSettle）。
  ///
  /// 主页 `_loadData` 里有真实的文件读取（经书清单、进度），FakeAsync 里的
  /// 微任务队列不会让真实 IO 回调推进，所以每轮都借 [WidgetTester.runAsync]
  /// 放行一次真实事件循环。
  Future<void> pumpUntil(WidgetTester tester, Finder finder,
      {int attempts = 60}) async {
    for (var i = 0; i < attempts; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    fail('等待超时，未出现控件：$finder\n'
        '当前文本：${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).where((d) => d != null).toList()}');
  }

  /// 挂载主页并等待首次 `_loadData` 完成。
  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await StudyHubPageState.warmPrefs();
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: StudyHubPage()),
    ));
    await pumpUntil(tester, find.text('1/1'));
    expect(find.text(_itemRowText), findsOneWidget);
  }

  /// 模拟系统投递前后台切换（引擎走 `flutter/lifecycle` 通道）。
  Future<void> sendLifecycle(WidgetTester tester, AppLifecycleState state) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/lifecycle',
      const StringCodec().encodeMessage(state.toString()),
      (_) {},
    );
    await tester.pump();
  }

  /// 卸载页面：取消跨天定时器，避免测试结束时残留未完成的 Timer。
  Future<void> disposeHome(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('应用一直开着跨过零点：打卡项自动恢复未打卡，且可正常打新一天的卡',
      (tester) async {
    await pumpHome(tester);

    // 应用没有关闭，时间跨过零点进入第二天（_day2）。
    fakeNow = DateTime(2024, 5, 2, 0, 0, 20);
    // 看门狗每 30 秒比对一次本地日期：跨天/唤醒后一个周期内纠正，
    // 不依赖「一次性定时到零点」在休眠设备上能否准点触发。
    await tester.pump(const Duration(seconds: 31));
    await pumpUntil(tester, find.text('0/1'));

    expect(find.text('1/1'), findsNothing,
        reason: '跨天后不应再显示昨天的已打卡进度');
    expect(find.text('0/1'), findsOneWidget, reason: '跨天后打卡项应恢复未打卡');

    // 历史记录不能被跨天刷新删掉。
    final prefs = await SharedPreferences.getInstance();
    List<dynamic> records() =>
        jsonDecode(prefs.getString('checkin_records')!) as List<dynamic>;
    expect(records().where((r) => r['date'] == _day1).length, 1,
        reason: '昨天的打卡记录必须保留（日历/统计要用）');
    expect(records().where((r) => r['date'] == _day2), isEmpty,
        reason: '新的一天还没打卡');

    // 第二天可以正常打卡，且写在新日期下。
    final item = find.text(_itemRowText);
    await tester.ensureVisible(item);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(item);
    await pumpUntil(tester, find.text('1/1'));

    expect(records().where((r) => r['date'] == _day2).length, 1,
        reason: '第二天的打卡应写在新日期下');
    expect(records().where((r) => r['date'] == _day1).length, 1,
        reason: '昨天的记录仍只有一条');

    await disposeHome(tester);
  });

  testWidgets('后台挂了一夜再回到前台：跨天状态立即纠正，不必等看门狗', (tester) async {
    await pumpHome(tester);

    // 后台被系统冻结：页面里的定时器不会跑，回到前台时日期已经是第二天早上。
    fakeNow = DateTime(2024, 5, 2, 7, 30);
    await sendLifecycle(tester, AppLifecycleState.paused);
    await sendLifecycle(tester, AppLifecycleState.resumed);

    // 只 pump 了几帧，远未到 30 秒看门狗周期：说明是生命周期回调在起作用。
    await pumpUntil(tester, find.text('0/1'));
    expect(find.text('0/1'), findsOneWidget,
        reason: '回到前台后应立刻显示新一天未打卡');

    await disposeHome(tester);
  });
}
