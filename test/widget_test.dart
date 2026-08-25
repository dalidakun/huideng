import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/main.dart';

void main() {
  testWidgets('未同意协议时首屏为隐私同意页', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyApp(privacyAgreed: false));
    await tester.pump();

    expect(find.text('欢迎使用燃灯'), findsOneWidget);
    expect(find.text('同意并继续'), findsOneWidget);
    expect(find.text('不同意'), findsOneWidget);
  });

  testWidgets('已同意协议时直接进入应用（启动图）', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'privacy_agreed_version': 1});
    await tester.pumpWidget(const MyApp(privacyAgreed: true));
    await tester.pump();

    // 已同意：不出现同意页按钮。
    expect(find.text('同意并继续'), findsNothing);
  });
}
