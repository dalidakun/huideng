import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/profile_account_info.dart';

/// 个人资料 / 编辑资料页的账户信息块：
/// - 手机号已绑定时显示号码 +「更换」；
/// - 未绑定时号码留空，显示「绑定手机号」提示；
/// - 用户ID 始终展示，并有不可修改说明。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required String phone,
    required String uid,
  }) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ProfileAccountInfo(
              phone: phone,
              uid: uid,
              onBindPhone: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('未绑定手机号时留空并提示绑定', (tester) async {
    await pump(tester, phone: '', uid: 'uid_1234567890');
    expect(tester.takeException(), isNull);

    expect(find.text('绑定手机号'), findsOneWidget);
    expect(find.textContaining('尚未绑定手机号'), findsOneWidget);
    expect(find.text('13800000002'), findsNothing);
    expect(find.text('uid_1234567890'), findsOneWidget);
    expect(find.textContaining('注册后不可更改'), findsOneWidget);
  });

  testWidgets('已绑定手机号时显示号码与更换入口', (tester) async {
    await pump(tester, phone: '13800000002', uid: 'uid_1234567890');
    expect(tester.takeException(), isNull);

    expect(find.text('13800000002'), findsOneWidget);
    expect(find.text('更换'), findsOneWidget);
    expect(find.text('绑定手机号'), findsNothing);
    expect(find.text('uid_1234567890'), findsOneWidget);
  });
}
