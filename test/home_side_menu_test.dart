import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/app_palette.dart';
import 'package:my_flutter_app/home_side_menu.dart';

void main() {
  testWidgets('米黄外观侧边栏构建无异常', (tester) async {
    SharedPreferences.setMockInitialValues({'appearance_mode': 'warm'});
    await AppPalette.instance.load();
    expect(AppPalette.instance.isPlain, isFalse);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HomeSideMenu(
          onOpenProfile: () {},
          onOpenRecord: () {},
          onOpenFollowing: () {},
          onOpenSettings: () {},
          onLogin: () {},
          onLogout: () {},
          onCertify: () {},
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    final ex = tester.takeException();
    expect(ex, isNull, reason: 'warm sidebar exception: $ex');
    expect(find.text('个人资料'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });
}
