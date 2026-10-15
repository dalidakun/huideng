import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/sutra_edit_page.dart';

void main() {
  // 经名输入框：maxLines == 1；正文输入框：expands 故 maxLines == null。
  EditableText titleEditableOf(WidgetTester tester) => tester
      .widgetList<EditableText>(find.byType(EditableText))
      .firstWhere((e) => e.maxLines == 1);

  EditableText contentEditableOf(WidgetTester tester) => tester
      .widgetList<EditableText>(find.byType(EditableText))
      .firstWhere((e) => e.maxLines == null);

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: SutraEditPage(
        title: '原始经名',
        initialTitle: '原始经名',
        content: '正文内容',
        keyPath: 'test/key.txt',
      ),
    ));
  }

  Future<void> enterTitle(WidgetTester tester, String text) async {
    await tester.enterText(find.byWidget(titleEditableOf(tester)), text);
  }

  Future<void> enterContent(WidgetTester tester, String text) async {
    await tester.enterText(find.byWidget(contentEditableOf(tester)), text);
  }

  testWidgets('撤销可回退经名编辑（不做其它操作）', (tester) async {
    await pumpPage(tester);

    await enterTitle(tester, '修改后的经名');
    await tester.pump();
    expect(titleEditableOf(tester).controller.text, '修改后的经名');

    await tester.tap(find.text('撤销'));
    await tester.pump();

    expect(titleEditableOf(tester).controller.text, '原始经名');
  });

  testWidgets('撤销可回退经名编辑（输入后立刻撤销，未过防抖）', (tester) async {
    await pumpPage(tester);

    await enterTitle(tester, '修改后的经名');
    // 不等待，立即点撤销。
    await tester.tap(find.text('撤销'));
    await tester.pump();

    expect(titleEditableOf(tester).controller.text, '原始经名');
  });

  testWidgets('撤销可回退正文编辑', (tester) async {
    await pumpPage(tester);

    await enterContent(tester, '正文改过了');
    await tester.pump();
    expect(contentEditableOf(tester).controller.text, '正文改过了');

    await tester.tap(find.text('撤销'));
    await tester.pump();

    expect(contentEditableOf(tester).controller.text, '正文内容');
  });
}
