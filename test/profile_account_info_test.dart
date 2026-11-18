import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/profile_account_info.dart';

/// 个人资料 / 编辑资料页的账户信息块：
/// - 邮箱已绑定时显示地址 +「更换」；
/// - 未绑定时留空，显示「绑定邮箱」提示；
/// - 用户ID 始终展示，并有不可修改说明。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required String email,
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
              email: email,
              uid: uid,
              onBindEmail: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('未绑定邮箱时留空并提示绑定', (tester) async {
    await pump(tester, email: '', uid: 'uid_1234567890');
    expect(tester.takeException(), isNull);

    expect(find.text('绑定邮箱'), findsOneWidget);
    expect(find.textContaining('尚未绑定邮箱'), findsOneWidget);
    expect(find.text('user@example.com'), findsNothing);
    expect(find.text('uid_1234567890'), findsOneWidget);
    expect(find.textContaining('注册后不可更改'), findsOneWidget);
  });

  testWidgets('已绑定邮箱时显示地址与更换入口', (tester) async {
    await pump(tester, email: 'user@example.com', uid: 'uid_1234567890');
    expect(tester.takeException(), isNull);

    expect(find.text('user@example.com'), findsOneWidget);
    expect(find.text('更换'), findsOneWidget);
    expect(find.text('绑定邮箱'), findsNothing);
    expect(find.text('uid_1234567890'), findsOneWidget);
  });
}
