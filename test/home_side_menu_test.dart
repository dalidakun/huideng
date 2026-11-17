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
          onOpenSubscription: () {},
          onOpenBookmarks: () {},
          onOpenFollowing: () {},
          onOpenSettings: () {},
          onLogin: () {},
          onLogout: () {},
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    final ex = tester.takeException();
    expect(ex, isNull, reason: 'warm sidebar exception: $ex');
    expect(find.text('个人资料'), findsOneWidget);
    expect(find.text('订阅服务'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    // 订阅图标为空心徽标（内部对号）。
    expect(find.byIcon(Icons.verified_outlined), findsOneWidget);

    // 订阅服务位于时间线与书签之间。
    final timelineY = tester.getTopLeft(find.text('时间线')).dy;
    final subscriptionY = tester.getTopLeft(find.text('订阅服务')).dy;
    final bookmarkY = tester.getTopLeft(find.text('书签')).dy;
    expect(subscriptionY, greaterThan(timelineY));
    expect(subscriptionY, lessThan(bookmarkY));
  });
}
