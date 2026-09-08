import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/reading_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  // 复现：读经页点击正文 → 速览面板「画线」→ 打开画线归集页是否会卡死。
  testWidgets('tap body -> 画线 -> highlights page opens', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 读经页加载路径会调用 getApplicationDocumentsDirectory()，
    // 测试环境需 mock，否则正文加载流程提前失败、用例变成空转。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationSupportDirectory') {
        return Directory.systemTemp.path;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null));

    final dir = Directory.systemTemp.createTempSync('sutra_repro_');
    final file = File('${dir.path}/test.txt');
    final sb = StringBuffer();
    for (var i = 1; i <= 80; i++) {
      if (i % 4 == 0) {
        sb.writeln('第$i段文字内容，用来模拟读经正文。。。。///');
      } else {
        sb.writeln('第$i段文字内容，用来模拟读经正文本体，此处有足够汉字以便布局。');
      }
    }
    file.writeAsStringSync(sb.toString());
    addTearDown(() => dir.deleteSync(recursive: true));

    // 正文加载涉及真实文件 IO，需在 runAsync 中等待其完成（fake async
    // 泵不出真实异步 IO，此前用例因正文未加载而空转）。
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: ReadingPage(title: '测试经', filePath: file.path),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump(const Duration(milliseconds: 300));

    // 正文确实已加载（此前 path_provider 未 mock 时为空、用例空转）。
    expect(find.textContaining('第1段文字内容'), findsWidgets);

    // 点击正文中部，应弹出速览面板。
    await tester.tapAt(tester.getCenter(find.byType(ReadingPage)));
    await tester.pump(const Duration(milliseconds: 300));

    final drawBtn = find.text('画线');
    expect(drawBtn, findsOneWidget);

    // 点击「画线」→ 应进入画线归集页（不再卡死）。
    await tester.tap(drawBtn);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('画线：'), findsOneWidget);
  });
}