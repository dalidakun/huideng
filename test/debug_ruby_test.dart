import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/shanzhishi_mantra_store.dart';
import 'package:my_flutter_app/shanzhishi_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('detail notes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ShanZhiShiMantraStore.instance.resetForTest();
    await tester.pumpWidget(const MaterialApp(home: ShanZhiShiPage()));
    await tester.pumpAndSettle();
    await ShanZhiShiMantraStore.instance.add(
      '批注咒',
      source: '《药师经》',
      text: '嗡嘛呢叭咪吽',
      annotations: const [
        MantraAnnotation(start: 0, end: 1, ruby: 'ōng', note: '一'),
        MantraAnnotation(start: 1, end: 2, note: '二'),
        MantraAnnotation(start: 2, end: 3, note: '三'),
        MantraAnnotation(start: 3, end: 4, note: '四'),
        MantraAnnotation(start: 4, end: 5, note: '五'),
      ],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_fab_switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shanzhishi_mantra_0')));
    await tester.pumpAndSettle();
    while (tester.takeException() != null) {}
    final block = find.byKey(const ValueKey('shanzhishi_mantra_notes'));
    debugPrint('BLOCK=${block.evaluate().length} rect=${tester.getRect(block)}');
    final listRect = tester.getRect(find.byKey(const ValueKey('shanzhishi_mx_list')));
    debugPrint('LIST=$listRect');
    for (final t in ['一','二','三','四','五']) {
      debugPrint('FOUND $t => ${find.textContaining(t, findRichText: true).evaluate().length}');
    }
  });
}
