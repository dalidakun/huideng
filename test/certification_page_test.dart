import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/app_palette.dart';
import 'package:my_flutter_app/certification_page.dart';

/// 订阅服务页（未登录态）在各外观下的构建检查：
/// - 标题为「订阅服务」，说明重点为 AI 翻译；
/// - 微信 / 支付宝两个收款码并排展示；
/// - 不再出现交易单号、剩余次数等旧文案；
/// - 页面在 360×800 窄屏下不溢出。
void main() {
  Future<void> pumpPage(WidgetTester tester, String mode) async {
    SharedPreferences.setMockInitialValues({'appearance_mode': mode});
    await AppPalette.instance.load();

    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: CertificationPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('订阅服务页（暖黄）构建无异常', (tester) async {
    await pumpPage(tester, 'warm');
    final ex = tester.takeException();
    expect(ex, isNull, reason: 'warm subscription page exception: $ex');

    expect(find.text('订阅服务'), findsOneWidget);
    expect(find.textContaining('AI 翻译'), findsWidgets);
    expect(find.text('徽标认证'), findsOneWidget);
    expect(find.textContaining('交易单号'), findsNothing);
    expect(find.textContaining('剩余'), findsNothing);
    expect(find.textContaining('开通徽标'), findsNothing);

    // 未登录时先提示登录，不展示收款码（避免付款后无法对应账号）。
    await tester.scrollUntilVisible(
      find.text('去登录'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('微信'), findsNothing);
    expect(find.text('支付宝'), findsNothing);

    // 滚到页尾，确认底部说明也不溢出。
    await tester.scrollUntilVisible(
      find.textContaining('虚拟服务'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final scrollEx = tester.takeException();
    expect(scrollEx, isNull, reason: 'warm subscription page scroll exception: $scrollEx');
  });

  testWidgets('订阅服务页（素白）构建无异常', (tester) async {
    await pumpPage(tester, 'plain');
    final ex = tester.takeException();
    expect(ex, isNull, reason: 'plain subscription page exception: $ex');

    // 重点文案是 AI 翻译，徽标为附赠。
    expect(find.textContaining('AI 翻译'), findsWidgets);
    expect(find.text('徽标认证'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('虚拟服务'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final scrollEx = tester.takeException();
    expect(scrollEx, isNull, reason: 'plain subscription page scroll exception: $scrollEx');
  });
}
