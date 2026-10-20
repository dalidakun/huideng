import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/reader_selection_controls.dart';

const String _sample =
    '观自在菩萨行深般若波罗蜜多时照见五蕴皆空度一切苦厄舍利子色不异空空不异色色即是空空即是色';

Future<void> _pumpReader(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 360,
          child: SelectableText(
            _sample,
            style: const TextStyle(fontSize: 16, height: 1.8),
            selectionControls: readerSelectionControls,
            contextMenuBuilder: (context, state) => const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

EditableTextState _state(WidgetTester tester) =>
    tester.state<EditableTextState>(find.byType(EditableText));

Future<TestGesture> _grab(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(at);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-8, 0));
  }
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pumpAndSettle();
  return gesture;
}

Finder _handles() => find.byWidgetPredicate((widget) =>
    widget is CustomPaint &&
    widget.painter.runtimeType.toString() == '_ReaderSelectionHandlePainter');

void main() {
  testWidgets('short selection handles do not overlap', (tester) async {
    await _pumpReader(tester);
    final state = _state(tester);
    final render = state.renderEditable;

    await tester.longPressAt(render.localToGlobal(Offset.zero) +
        const Offset(60, 16));
    await tester.pumpAndSettle();

    final selection = state.textEditingValue.selection;
    expect(selection.isCollapsed, isFalse);
    final endpoints = render.getEndpointsForSelection(selection);
    final start = render.localToGlobal(endpoints.first.point);
    final end = render.localToGlobal(endpoints.last.point);

    final handles = _handles();
    expect(handles, findsNWidgets(2));
    final leftRect = tester.getRect(handles.at(0));
    final rightRect = tester.getRect(handles.at(1));

    expect(leftRect.right, lessThanOrEqualTo(start.dx + 0.5));
    expect(rightRect.left, greaterThanOrEqualTo(end.dx - 0.5));
    expect(leftRect.right, lessThan(rightRect.left));
  });

  testWidgets('dragging left handle only moves selection base',
      (tester) async {
    await _pumpReader(tester);
    final state = _state(tester);
    final render = state.renderEditable;

    await tester.longPressAt(render.localToGlobal(Offset.zero) +
        const Offset(60, 16));
    await tester.pumpAndSettle();

    final before = state.textEditingValue.selection;
    final endpoints = render.getEndpointsForSelection(before);
    final start = render.localToGlobal(endpoints.first.point);

    await _grab(tester, start + const Offset(-24, -2));

    final after = state.textEditingValue.selection;
    expect(after.extentOffset, before.extentOffset);
    expect(after.baseOffset, lessThan(before.baseOffset));
  });

  testWidgets('dragging right handle only moves selection extent',
      (tester) async {
    await _pumpReader(tester);
    final state = _state(tester);
    final render = state.renderEditable;

    await tester.longPressAt(render.localToGlobal(Offset.zero) +
        const Offset(60, 16));
    await tester.pumpAndSettle();

    final before = state.textEditingValue.selection;
    final endpoints = render.getEndpointsForSelection(before);
    final end = render.localToGlobal(endpoints.last.point);

    final gesture = await tester.startGesture(end + const Offset(24, -2));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveBy(const Offset(8, 0));
    }
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pumpAndSettle();

    final after = state.textEditingValue.selection;
    expect(after.baseOffset, before.baseOffset);
    expect(after.extentOffset, greaterThan(before.extentOffset));
  });
}
