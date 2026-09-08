import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/sutra_highlights_page.dart';
import 'package:my_flutter_app/sutra_underline.dart';

/// 旧实现逐行调用 TextPainter.getBoxesForSelection（每次 O(n)、累计 O(n²)），
/// 对「总长不足 800 却因 `\n` 断成几十行」的画线文本也能卡死界面（画线归集
/// 页无法打开）。改用 computeLineMetrics（线性）后该场景必须能即时渲染。
String multiLineText(int lines) {
  final sb = StringBuffer();
  for (var i = 0; i < lines; i++) {
    for (var j = 0; j < 6; j++) {
      sb.writeCharCode(0x4e00 + (i + j) % 30);
    }
    sb.write('\n');
  }
  return sb.toString();
}

void main() {
  testWidgets('SutraHighlightsPage renders one huge highlight', (tester) async {
    // 模拟地藏经卷二式极端数据：单条画线内容巨大（~100KB）。
    final big = StringBuffer();
    for (var i = 0; i < 30000; i++) {
      big.write('众生度尽方证菩提地狱未空誓不成佛');
    }
    final text = big.toString();
    await tester.pumpWidget(MaterialApp(
      home: SutraHighlightsPage(
        title: '地藏菩萨本愿经卷二',
        highlights: [text],
        itemSegments: [
          [
            (para: 0, start: 0, end: text.length),
          ],
        ],
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(Scaffold), findsOneWidget);
  });

  testWidgets(
      'SutraUnderlineText renders many-lines-under-threshold text (was O(n²) freeze)',
      (tester) async {
    final text = multiLineText(80); // 480 字符、80 行，远低于旧 800 字阈值
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SutraUnderlineText(
          text: text,
          style: const TextStyle(fontSize: 14, height: 1.6, color: Color(0xFF212121)),
          lineColor: Colors.orange.withValues(alpha: 0.8),
        ),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SutraUnderlineText), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 20)));

  testWidgets('SutraHighlightsPage renders multis 行 merged item (was freeze)',
      (tester) async {
    final text = multiLineText(40); // 240 字符、40 行，合并后展示的画线条目
    await tester.pumpWidget(MaterialApp(
      home: SutraHighlightsPage(
        title: '测试经',
        highlights: [text],
        itemSegments: [
          [
            (para: 0, start: 0, end: 40),
            (para: 1, start: 0, end: 40),
          ],
        ],
        canDelete: true,
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(Scaffold), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 20)));
}