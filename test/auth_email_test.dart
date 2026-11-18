import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/auth_service.dart';
import 'package:my_flutter_app/forgot_password_page.dart';
import 'package:my_flutter_app/login_page.dart';

/// 账号/邮箱认证改造后的基础校验：
/// - 邮箱格式校验与云端口径一致；
/// - 登录页可在「登录 / 注册（账号密码注册 / 邮箱注册）」之间切换；
/// - 忘记密码页走邮箱验证码。
void main() {
  group('AuthService.isValidEmail', () {
    test('合法邮箱', () {
      expect(AuthService.isValidEmail('user@example.com'), isTrue);
      expect(AuthService.isValidEmail('foo.bar+tag@sub.example.cn'), isTrue);
      expect(AuthService.isValidEmail('  spaced@example.com  '), isTrue);
    });

    test('非法邮箱', () {
      expect(AuthService.isValidEmail(''), isFalse);
      expect(AuthService.isValidEmail('user'), isFalse);
      expect(AuthService.isValidEmail('user@'), isFalse);
      expect(AuthService.isValidEmail('@example.com'), isFalse);
      expect(AuthService.isValidEmail('user@example'), isFalse);
      expect(AuthService.isValidEmail('user name@example.com'), isFalse);
    });
  });

  testWidgets('登录页：注册可切换账号密码注册 / 邮箱注册', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pumpAndSettle();

    expect(find.text('登录'), findsWidgets);
    expect(find.text('注册'), findsOneWidget);

    await tester.tap(find.text('注册'));
    await tester.pumpAndSettle();

    expect(find.text('账号密码注册'), findsOneWidget);
    expect(find.text('邮箱注册'), findsOneWidget);
    expect(find.textContaining('用于找回密码'), findsOneWidget);

    await tester.tap(find.text('邮箱注册'));
    await tester.pumpAndSettle();

    expect(find.text('获取验证码'), findsOneWidget);
    expect(find.textContaining('自动生成账号名'), findsOneWidget);
  });

  testWidgets('忘记密码页：邮箱 + 验证码 + 新密码', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: ForgotPasswordPage()));
    await tester.pumpAndSettle();

    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('验证码'), findsOneWidget);
    expect(find.text('新密码'), findsOneWidget);
    expect(find.text('获取验证码'), findsOneWidget);
    expect(find.textContaining('重置成功后会自动登录'), findsOneWidget);
  });
}
