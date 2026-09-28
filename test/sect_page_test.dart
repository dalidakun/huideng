import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/sect_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpPage(WidgetTester tester,
      {void Function(SectInfo)? onOpen}) async {
    // 视口开到能一次装下「展示位 + 八宗 + 十二法门」，省得逐段滚动验证。
    tester.view.physicalSize = const Size(1080, 6300);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: SectPage(onOpen: onOpen),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '宗门页渲染抛异常');
  }

  testWidgets('八宗与十二法门同屏上下排布，不再分栏切换', (tester) async {
    await pumpPage(tester);

    // 分栏切换的两个标签、示意图里多余的「了解… ›」入口都不在了。
    expect(find.text('门派'), findsNothing, reason: '分栏标签应已移除');
    expect(find.text('法门'), findsNothing, reason: '分栏标签应已移除');
    expect(find.text('了解各宗门 ›'), findsNothing, reason: '无入口');
    expect(find.text('了解法门分类 ›'), findsNothing, reason: '无入口');
    expect(find.text('宗门'), findsOneWidget, reason: '顶栏标题固定为宗门');

    // 两段标题同屏。
    expect(find.text('八大宗派'), findsOneWidget, reason: '宗门段标题');
    expect(find.text('十二法门'), findsOneWidget, reason: '法门段标题');

    // 8 宗 + 12 法门一次全部在页面上，不用切栏。
    for (final s in kSectList) {
      expect(find.text(s.name), findsOneWidget, reason: '缺宗门 ${s.name}');
    }
    for (final g in kGateList) {
      expect(find.text(g.name), findsOneWidget, reason: '缺法门 ${g.name}');
    }
  });

  testWidgets('宗门段在法门段上方', (tester) async {
    await pumpPage(tester);
    final sectY = tester.getTopLeft(find.text('八大宗派')).dy;
    final gateY = tester.getTopLeft(find.text('十二法门')).dy;
    final firstSectY = tester.getTopLeft(find.text(kSectList.first.name)).dy;
    final firstGateY = tester.getTopLeft(find.text(kGateList.first.name)).dy;
    expect(sectY < gateY, isTrue, reason: '宗门标题应在法门标题之上');
    expect(firstSectY < firstGateY, isTrue, reason: '宗门格子应在法门列表之上');
    // 宗门段两列：同一行的两宗 y 相同、下一宗往下排。
    expect(tester.getTopLeft(find.text(kSectList[0].name)).dy,
        tester.getTopLeft(find.text(kSectList[1].name)).dy);
    expect(tester.getTopLeft(find.text(kSectList[2].name)).dy,
        tester.getTopLeft(find.text(kSectList[3].name)).dy);
    expect(
        tester.getTopLeft(find.text(kSectList[2].name)).dy,
        greaterThan(
            tester.getTopLeft(find.text(kSectList[0].name)).dy));
    // 两列左右分开。
    expect(tester.getTopLeft(find.text(kSectList[1].name)).dx,
        greaterThan(tester.getTopLeft(find.text(kSectList[0].name)).dx));
  });

  testWidgets('点宗门格子/法门行都能打开详情回调', (tester) async {
    SectInfo? opened;
    await pumpPage(tester, onOpen: (s) => opened = s);

    await tester.tap(find.text(kSectList.first.name));
    await tester.pump(const Duration(milliseconds: 200));
    expect(opened?.name, kSectList.first.name, reason: '宗门格子点击无效');

    opened = null;
    await tester.tap(find.text(kGateList.first.name));
    await tester.pump(const Duration(milliseconds: 200));
    expect(opened?.name, kGateList.first.name, reason: '法门行点击无效');
  });
}
