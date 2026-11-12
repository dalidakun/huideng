import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/reading_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

const _dirty = '佛说阿弥陀经\r\n'
    'No. 366\r\n'
    '佛说阿弥陀经\r\n'
    '姚秦龟兹三藏鸠摩罗什译\r\n'
    '如是我闻：\r\n'
    '一时，佛在舍卫国祇树给孤独园。\r\n'
    '佛说此经已，皆大欢喜，信受奉行。\r\n'
    '佛说阿弥陀经卷第一\r\n'
    '【经文资讯】大正新修大藏经 第 12 册 No. 366 佛说阿弥陀经\r\n'
    '【版本记录】发行日期：2025-12\r\n'
    '【编辑说明】本资料库由 CBETA 编辑\r\n'
    '【原始资料】萧镇国大德提供\r\n'
    '【版权宣告】https://cbeta.org/copyright\r\n'
    '【制作说明】感谢志工\r\n';

void main() {
  testWidgets('已下载的旧正文在阅读页自动去掉文末说明块', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('sutra_clean_e2e_');
    addTearDown(() => dir.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationSupportDirectory') {
        return dir.path;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null));

    final local = File('${dir.path}/sutras/T12/T12n0366_001.txt');
    local.parent.createSync(recursive: true);
    local.writeAsStringSync(_dirty);

    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(
        home: ReadingPage(
          title: '佛说阿弥陀经T12n0366_001',
          filePath: 'assets/sutras_ascii/T12/T12n0366_001.txt',
        ),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 300));

    final plain = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((t) => t.textSpan?.toPlainText() ?? t.data ?? '')
        .join('\n');
    expect(plain.contains('如是我闻'), isTrue, reason: '正文应正常显示');
    expect(plain.contains('【经文资讯】'), isFalse, reason: '说明块应被去掉');
    expect(plain.contains('佛说阿弥陀经卷第一'), isFalse, reason: '重复卷末题名应被去掉');
  });
}
