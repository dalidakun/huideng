import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/collapsible_bottom_sheet.dart';

void main() {
  testWidgets('收起后能操作底层页面，再展开输入内容还在', (tester) async {
    var backgroundTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return Column(
                children: [
                  TextButton(
                    key: const ValueKey('background_button'),
                    onPressed: () => backgroundTaps++,
                    child: const Text('底层按钮'),
                  ),
                  const TextField(key: ValueKey('background_field')),
                  const SelectableText(
                    '背景文字',
                    key: ValueKey('background_selectable'),
                  ),
                  TextButton(
                    key: const ValueKey('show_snack'),
                    onPressed: () =>
                        showCollapsibleAwareSnackBar(context, '已复制'),
                    child: const Text('显示提示'),
                  ),
                  TextButton(
                    key: const ValueKey('open_sheet'),
                    onPressed: () {
                      showCollapsibleBottomSheet<void>(
                        context,
                        collapsedTitle: '添加神咒',
                        builder: (_) => const _SheetBody(),
                      );
                    },
                    child: const Text('打开面板'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open_sheet')));
    await tester.pumpAndSettle();
    expect(isCollapsibleSheetOpen, isTrue);
    final sheetField = find.descendant(
      of: find.byKey(const ValueKey('collapsible_sheet_panel')),
      matching: find.byType(TextField),
    );
    expect(sheetField, findsOneWidget);

    await tester.enterText(sheetField, '草稿内容');
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('collapsible_sheet_handle')),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(collapsibleSheetCollapsed.value, isTrue);

    await tester.tap(find.byKey(const ValueKey('background_button')));
    await tester.pumpAndSettle();
    expect(backgroundTaps, 1);

    await tester.enterText(
      find.byKey(const ValueKey('background_field')),
      '底层输入',
    );
    final backgroundField = tester.widget<EditableText>(find.descendant(
      of: find.byKey(const ValueKey('background_field')),
      matching: find.byType(EditableText),
    ));
    expect(backgroundField.controller.text, '底层输入');

    await tester.longPress(find.byKey(const ValueKey('background_selectable')));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('show_snack')));
    await tester.pumpAndSettle();
    final snack = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snack.behavior, SnackBarBehavior.floating);
    expect(
      tester.getRect(find.text('已复制')).bottom,
      lessThan(
        tester
            .getRect(find.byKey(const ValueKey('collapsible_sheet_panel')))
            .top,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('collapsible_sheet_handle')));
    await tester.pumpAndSettle();
    expect(collapsibleSheetCollapsed.value, isFalse);
    final editable = tester.widget<EditableText>(find.descendant(
      of: find.byKey(const ValueKey('collapsible_sheet_panel')),
      matching: find.byType(EditableText),
    ));
    expect(editable.controller.text, '草稿内容');
  });
}

class _SheetBody extends StatelessWidget {
  const _SheetBody();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(20),
      child: TextField(),
    );
  }
}
