import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/auth_service.dart';
import 'package:my_flutter_app/cloud_notes_service.dart';
import 'package:my_flutter_app/custom_tab_store.dart';
import 'package:my_flutter_app/my_page.dart';
import 'package:my_flutter_app/sect_community_page.dart';
import 'package:my_flutter_app/sect_detail_page.dart';
import 'package:my_flutter_app/sect_page.dart';
import 'package:my_flutter_app/sect_switch.dart';

void main() {
  /// 沿祖先链找带边框的盒子：规则项若被卡片包住，这里会返回 true。
  bool hasBorderedAncestor(WidgetTester tester, Finder f) {
    var found = false;
    tester.element(f).visitAncestorElements((e) {
      final w = e.widget;
      final dec = w is DecoratedBox
          ? w.decoration
          : (w is Container ? w.decoration : null);
      if (dec is BoxDecoration && dec.border != null) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 合并页默认落在核心经典那一侧，`initialTab` 可直接指定停在哪一半。
  Future<void> pumpSect(WidgetTester tester, SectInfo sect,
      {int initialTab = 0}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: SectDetailPage(sect: sect, initialTab: initialTab),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '宗门页渲染抛异常');
  }

  /// 直接进社区那一侧（`initialTab: 1`）：合并页打开就落在社区，不用先点一次胶囊。
  Future<void> pumpCommunity(WidgetTester tester, SectInfo sect) async {
    await pumpSect(tester, sect, initialTab: 1);
  }

  testWidgets('合并页：胶囊两段写「核心经典 / xx社区」，标题只留栏目名',
      (tester) async {
    await pumpSect(tester, kSectList[2]); // 天台宗，默认落在核心经典

    expect(find.byType(SectSwitch), findsOneWidget, reason: '顶部要有一颗切换胶囊');
    expect(find.text('核心经典'), findsWidgets, reason: '左段标签');
    expect(find.text('天台宗社区'), findsWidgets, reason: '右段标签 = 栏目名 + 社区');
    expect(find.text('天台宗'), findsWidgets, reason: '顶图只写栏目名');
    expect(find.text('天台宗 · 核心经典'), findsNothing,
        reason: '栏目名后面不再缀「· 核心经典」');
    // 社区那半还没轮到 PageView 建出来，所以社区专属内容此时不在树上。
    expect(find.text('展开全文'), findsNothing, reason: '社区那半应当还没显示');
    expect(tester.takeException(), isNull);
  });

  testWidgets('合并页：旧右下角「进入社区」入口已删，浮钮不再重复出现',
      (tester) async {
    await pumpSect(tester, kSectList[2]);
    // 新的「进入社区」只能由胶囊右段承担，不再额外挂一颗入口。
    expect(find.text('天台宗社区'), findsWidgets);
    expect(find.byType(SectSwitch), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('合并页：点胶囊右段切到社区，左段切回经典', (tester) async {
    await pumpSect(tester, kSectList[2]);

    // 经典侧：社区那半留在树上但 Offstage（不画、不参与命中），社区内容看不到。
    expect(find.text('展开全文'), findsNothing);
    expect(find.byType(CommunitySection), findsNothing,
        reason: '社区那半此刻应当不在屏上');
    expect(find.byType(CommunitySection, skipOffstage: false), findsOneWidget,
        reason: '它只是被 Offstage 收起来，滚动位置要留着，切回来还在原处');

    await tester.tap(find.text('天台宗社区').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('展开全文'), findsOneWidget, reason: '切到社区侧后社区介绍在');
    expect(find.text('0 成员'), findsOneWidget, reason: '社区成员行在');
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('核心经典').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('0 成员'), findsNothing, reason: '切回经典侧后社区成员行不在');
    expect(tester.takeException(), isNull);
  });

  testWidgets('合并页：initialTab = 1 直接落在社区侧', (tester) async {
    await pumpSect(tester, kGateList[0], initialTab: 1); // 地藏法门社区
    expect(find.text('地藏法门社区'), findsWidgets, reason: '右段标签');
    expect(find.text('展开全文'), findsOneWidget, reason: '直接就在社区那一侧');
    expect(tester.takeException(), isNull);
  });

  testWidgets('合并页：左右滑动整页互换两半', (tester) async {
    await pumpSect(tester, kSectList[2]); // 天台宗

    // [PageScrollPhysics] 用弹簧把两半送到位，松手后还要再推进一会儿才彻底停稳；
    // 页面里又有一直转的加载指示器，pumpAndSettle 等不到静，只能定时推进。
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    await tester.drag(find.byType(SectDetailPage), const Offset(-260, 0));
    await settle();
    expect(find.text('展开全文'), findsOneWidget,
        reason: '向左滑应翻到社区那一半');
    expect(find.text('0 成员'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(SectDetailPage), const Offset(260, 0));
    await settle();
    expect(find.text('0 成员'), findsNothing,
        reason: '向右滑应翻回核心经典那一半');
    expect(tester.takeException(), isNull);
  });

  testWidgets('宗门社区页：标题、成员行与三个 tab 都在', (tester) async {
    await pumpCommunity(tester, kSectList[2]); // 天台宗

    expect(find.text('天台宗社区'), findsWidgets, reason: '标题与介绍里的社区名');
    expect(find.text('0 成员'), findsOneWidget, reason: '成员数占位');
    expect(find.text('加入'), findsOneWidget, reason: '加入按钮');
    expect(find.text('展开全文'), findsOneWidget, reason: '介绍展开入口');
    for (final label in ['热门', '最新', '规则']) {
      expect(find.text(label), findsOneWidget, reason: '缺 tab「$label」');
    }
    // 发帖浮钮
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('介绍展开后再收起，正文随之变化', (tester) async {
    await pumpCommunity(tester, kSectList[2]);

    await tester.tap(find.text('展开全文'));
    await tester.pump();
    expect(find.text('收起'), findsOneWidget, reason: '展开后入口变收起');
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('收起'));
    await tester.pump();
    expect(find.text('展开全文'), findsOneWidget, reason: '收起后入口还原');
  });

  testWidgets('加入按钮：点一下成员数 0 → 1，再点退出回到 0', (tester) async {
    AuthService.instance.currentUser.value = const AuthUser(id: 'u_test');
    addTearDown(() => AuthService.instance.currentUser.value = null);
    await pumpCommunity(tester, kSectList[2]); // 天台宗

    expect(find.text('0 成员'), findsOneWidget, reason: '未加入时 0 成员');
    expect(find.text('加入'), findsOneWidget);

    await tester.tap(find.text('加入'));
    await tester.pump();
    expect(find.text('1 成员'), findsOneWidget, reason: '加入后成员数立即 +1');
    expect(find.text('已加入'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('已加入'));
    await tester.pump();
    expect(find.text('0 成员'), findsOneWidget, reason: '退出后成员数 -1');
    expect(find.text('加入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('规则 tab：十条规则逐条可见', (tester) async {
    await pumpCommunity(tester, kGateList[0]); // 地藏法门

    await tester.tap(find.text('规则'));
    await tester.pump();
    expect(find.text('社区规则'), findsOneWidget);
    expect(find.text('尊重他人'), findsOneWidget);
    // 规则项不该再被卡片包住：标题的祖先里不能有带边框的盒子。
    expect(hasBorderedAncestor(tester, find.text('尊重他人')), isFalse,
        reason: '规则项应为裸列表，不再包卡片');

    // 第 10 条在屏外，滚到底确认列表确实能滚动、十条都排上了
    await tester.scrollUntilVisible(
      find.text('共同维护社区环境'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('共同维护社区环境'), findsOneWidget, reason: '规则列表可滚动');

    await tester.tap(find.text('热门'));
    await tester.pump();
    expect(find.text('社区规则'), findsNothing, reason: '已离开规则 tab');
    expect(tester.takeException(), isNull);
  });

  testWidgets('律宗没有切图，顶部栏目图标走手绘不抛异常', (tester) async {
    await pumpCommunity(tester, kSectList[5]); // 律宗
    expect(find.text('律宗社区'), findsWidgets);
    expect(find.byType(CustomPaint), findsWidgets, reason: '手绘图标走 CustomPaint');
    // 顶图只画栏目名，不再缀「· 核心经典」。
    expect(find.text('律宗'), findsWidgets, reason: '顶部只留栏目名，不再缀「· 核心经典」');
    expect(find.text('律宗 · 核心经典'), findsNothing);
  });

  testWidgets('十二法门社区页逐个渲染都不抛异常', (tester) async {
    for (final gate in kGateList) {
      await pumpCommunity(tester, gate);
      expect(find.text('${gate.name}社区'), findsWidgets,
          reason: '缺栏目「${gate.name}」的社区标题');
      expect(find.text('加入'), findsOneWidget, reason: gate.name);
      expect(tester.takeException(), isNull, reason: gate.name);
    }
  });

  test('成员头像个数：没人给 1 个，1~5 照实显示，再往后封顶 5', () {
    expect(communityAvatarCount(0), 1, reason: '一个成员都没有也要有 1 个占位');
    expect(communityAvatarCount(-1), 1, reason: '负数兜底成 1');
    expect(communityAvatarCount(1), 1);
    expect(communityAvatarCount(3), 3, reason: '不到 5 个就显示具体的数量');
    expect(communityAvatarCount(5), 5);
    expect(communityAvatarCount(128), 5, reason: '到 5 个封顶');
  });

  test('最新成员：按发言倒序去重、自己排最前、最多 5 个', () {
    expect(communityRecentMembers(const []), isEmpty,
        reason: '没人时留给占位头像');
    expect(communityRecentMembers(const ['a', 'b', 'a']), ['a', 'b'],
        reason: '同一人只算一次，顺序不变');
    expect(
        communityRecentMembers(const ['a', 'b'], selfId: 'me', joined: true),
        ['me', 'a', 'b'],
        reason: '自己刚加入 → 排最前面（最新的成员）');
    expect(
        communityRecentMembers(const ['a', 'b'], selfId: 'me', joined: false),
        ['a', 'b'],
        reason: '没加入就不该把自己算进去');
    expect(
        communityRecentMembers(const ['a', 'b'], selfId: 'a', joined: true),
        ['a', 'b'],
        reason: '自己发过帖又加入过，不重复出现');
    expect(communityRecentMembers(const ['1', '2', '3', '4', '5', '6', '7']),
        ['1', '2', '3', '4', '5'],
        reason: '头像最多 5 个');
  });

  testWidgets('成员头像：0 成员时是 1 个正圆头像，且尺寸加大到 36', (tester) async {
    await pumpCommunity(tester, kSectList[2]); // 天台宗

    final appIcons = find.byWidgetPredicate((w) =>
        w is Image &&
        w.image is AssetImage &&
        (w.image as AssetImage).assetName == 'assets/images/app_icon.png');
    expect(appIcons, findsOneWidget, reason: '0 成员只放 1 个占位头像');

    // 沿祖先链找圆形装饰，确认是圆的不是方的，再量外框尺寸。
    Element? circle;
    tester.element(appIcons).visitAncestorElements((e) {
      final w = e.widget;
      if (w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle) {
        circle = e;
        return false;
      }
      return true;
    });
    expect(circle, isNotNull, reason: '头像必须是圆形（BoxShape.circle）');
    expect(find.byType(ClipOval), findsOneWidget, reason: '正圆裁切，不能露方角');
    final box = tester.getRect(
        find.byElementPredicate((e) => identical(e, circle)));
    expect(box.width, closeTo(36, 0.5), reason: '头像加大到 36');
  });

  testWidgets('发帖输入框不给提示语', (tester) async {
    AuthService.instance.currentUser.value = const AuthUser(id: 'u_test');
    addTearDown(() => AuthService.instance.currentUser.value = null);
    await pumpCommunity(tester, kSectList[2]);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.hintText ?? '', isEmpty,
        reason: '正文框不该有 #话题 之类的提示语');
  });

  testWidgets('帖子行：昵称右侧有三个点，自己与他人都有', (tester) async {
    AuthService.instance.currentUser.value = const AuthUser(id: 'u_me');
    addTearDown(() => AuthService.instance.currentUser.value = null);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    PlazaNote note(String id, String owner) => PlazaNote(
          id: id,
          ownerUserId: owner,
          title: '',
          content: '一条很平常的帖子正文。',
          authorName: '行深',
          authorAccount: 'hangshen',
          visibility: 'public',
          status: 'published',
          likeCount: 1,
          commentCount: 0,
          createdAt: 1759276800000,
          updatedAt: 1759276800000,
        );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PostFeedRow(
          note: note('n1', 'u_other'),
          showFollowButton: false,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.more_horiz), findsOneWidget,
        reason: '他人帖子要有三点（关注/屏蔽）');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PostFeedRow(
          note: note('n2', 'u_me'),
          showFollowButton: false,
          onEdit: () {},
          onDelete: () {},
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.more_horiz), findsOneWidget,
        reason: '自己帖子也要有三点（编辑/删除）');
  });

  testWidgets('菩提空间帖子：xx社区 色块与昵称至少拉开 12px', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    const note = PlazaNote(
      id: 'n1',
      ownerUserId: 'u1',
      title: '',
      content: '一条很平常的帖子正文。',
      authorName: '行深',
      authorAccount: 'hangshen',
      community: '天台宗社区',
      visibility: 'public',
      status: 'published',
      likeCount: 0,
      commentCount: 0,
      createdAt: 1759276800000,
      updatedAt: 1759276800000,
    );

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PostFeedRow(note: note)),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    final nick = tester.getRect(find.text('行深'));
    final tag = tester.getRect(find.byType(CommunityTag));
    expect(tag.top, greaterThan(nick.bottom), reason: '色块在昵称下方');
    expect(tag.top - nick.bottom, greaterThanOrEqualTo(12),
        reason: '与昵称要拉开距离，不能贴着');

    final body = tester.getRect(find.textContaining('很平常'));
    expect(body.top - tag.bottom, lessThanOrEqualTo(8),
        reason: '色块要紧跟着自己的帖子，与正文间距要小');
  });

  testWidgets('社区小标签：底色块不描边，点一下进该社区', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: CommunityTag(community: '天台宗社区'),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('天台宗社区'), findsOneWidget);
    expect(hasBorderedAncestor(tester, find.text('天台宗社区')), isFalse,
        reason: '是带颜色的底色块，不是实体线框');

    await tester.tap(find.text('天台宗社区'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SectDetailPage), findsWidgets,
        reason: '点标签直接进入该社区（合并页的社区那一侧）');
    expect(tester.takeException(), isNull);
  });

  test('PlazaNote.community：读得到社区标记，普通帖子为空且 copyWith 不丢', () {
    Map<String, dynamic> json({String? community}) => {
          '_id': 'n1',
          'ownerUserId': 'u1',
          'title': '',
          'content': '正文',
          'visibility': 'public',
          'status': 'normal',
          'likeCount': 0,
          'commentCount': 0,
          'createdAt': 1,
          'updatedAt': 1,
          if (community != null) 'community': community,
        };

    expect(PlazaNote.fromJson(json(community: '天台宗社区')).community,
        '天台宗社区');
    expect(PlazaNote.fromJson(json()).community, isEmpty,
        reason: '普通帖子没有社区标记');
    expect(PlazaNote.fromJson(json(community: '天台宗社区')).copyWith(likeCount: 9).community,
        '天台宗社区',
        reason: '补齐作者字段的 copyWith 别把社区标记弄丢');
  });

  test('自定义列表：社区条目读得进读得出，老配置照样兼容', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await CustomTabStore.isStarred('天台宗社区'), isFalse);

    expect(await CustomTabStore.setStarred('天台宗社区', true), isTrue,
        reason: '星标返回的就是加进去了');
    final items = await CustomTabStore.loadItems();
    expect(items, hasLength(1));
    expect(items.single.isCommunity, isTrue, reason: '加进去的是社区条目');
    expect(items.single.name, '天台宗社区');
    expect(items.single.countKey, 'c:天台宗社区', reason: '面板计数键跟经文/话题不撞');
    expect((await CustomTabStore.read())['name'], '列表',
        reason: '没改过栏目名时用默认名');
    expect(await CustomTabStore.isStarred('天台宗社区'), isTrue);

    expect(await CustomTabStore.setStarred('天台宗社区', false), isFalse,
        reason: '再点一次移出');
    expect(await CustomTabStore.loadItems(), isEmpty);
    expect(await CustomTabStore.isStarred('天台宗社区'), isFalse);

    // 老配置兼容：没有 type 字段按话题，sutra 照旧是经文。
    expect(CustomTabItem.fromJson({'name': '心经'})?.isTopic, isTrue);
    expect(CustomTabItem.fromJson({'name': '心经', 'type': 'sutra'})?.isSutra,
        isTrue);
    expect(
        CustomTabItem.fromJson({'name': '天台宗社区', 'type': 'community'})
            ?.isCommunity,
        isTrue);
  });

  testWidgets('成员行：星标 / 分享 / 加入三个按钮等高，且都加大到 32', (tester) async {
    AuthService.instance.currentUser.value = const AuthUser(id: 'u_test');
    addTearDown(() => AuthService.instance.currentUser.value = null);
    await pumpCommunity(tester, kSectList[2]); // 天台宗

    Size size(String key) =>
        tester.getSize(find.byKey(ValueKey(key)));
    final star = size('sect_community_star');
    final share = size('sect_community_share');
    final join = size('sect_community_join');

    expect(star.height, share.height, reason: '星标与分享等高');
    expect(share.height, join.height, reason: '加入按钮与前两个等高');
    expect(star.height, 32.0, reason: '比原来的 26 大一圈');
    expect(star.width, 32.0, reason: '星标是正圆');
    expect(tester.takeException(), isNull, reason: '未加入时成员行不许溢出');

    // 切到「已加入」：胶囊变宽（多了对勾 + 一个字），高度必须还是 32、整行不溢出。
    await tester.tap(find.text('加入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已加入'), findsOneWidget);
    final join2 = size('sect_community_join');
    expect(join2.height, 32.0, reason: '已加入后高度不变');
    expect(join2.width, greaterThan(join.width), reason: '已加入文案更宽');
    expect(size('sect_community_star').height, join2.height, reason: '三个仍然等高');
    expect(tester.takeException(), isNull, reason: '已加入后成员行不许溢出');
  });

  testWidgets('成员行：星标 / 分享在加入按钮左侧，星标点亮即写进自定义列表',
      (tester) async {
    await pumpCommunity(tester, kSectList[2]); // 天台宗

    final starFinder = find.byIcon(Icons.star_outline_rounded);
    final shareFinder = find.byIcon(Icons.ios_share_rounded);
    expect(starFinder, findsOneWidget, reason: '星标按钮');
    expect(shareFinder, findsOneWidget, reason: '分享按钮');
    expect(await CustomTabStore.isStarred('天台宗社区'), isFalse,
        reason: '还没收藏');

    final starDx = tester.getCenter(starFinder).dx;
    final shareDx = tester.getCenter(shareFinder).dx;
    final joinDx = tester.getCenter(find.text('加入')).dx;
    expect(starDx < shareDx, isTrue, reason: '星标在分享左边');
    expect(shareDx < joinDx, isTrue, reason: '分享在加入左边');

    await tester.tap(starFinder);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(await CustomTabStore.isStarred('天台宗社区'), isTrue,
        reason: '写进了菩提空间的自定义列表');
    expect(find.byIcon(Icons.star_rounded), findsOneWidget, reason: '点亮了');
    expect(find.text('已添加到「列表」'), findsOneWidget, reason: 'toast 提示');

    // 清掉 toast 的 2 秒移除定时器，免得测试收尾报 pending timer。
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.star_rounded));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(await CustomTabStore.isStarred('天台宗社区'), isFalse,
        reason: '再点一次移出列表');
    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('社区流用的帖子卡片 PostFeedRow 独立渲染不抛异常', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    const note = PlazaNote(
      id: 'n1',
      ownerUserId: 'u1',
      title: '',
      content: '读《心经》有感：照见五蕴皆空，度一切苦厄。',
      authorName: '行深',
      authorAccount: 'hangshen',
      visibility: 'public',
      status: 'published',
      likeCount: 3,
      commentCount: 1,
      createdAt: 1759276800000,
      updatedAt: 1759276800000,
    );

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PostFeedRow(
          note: note,
          showFollowButton: false,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '帖子卡片渲染抛异常');
    expect(find.text('行深'), findsOneWidget, reason: '作者昵称');
    expect(find.textContaining('五蕴皆空'), findsOneWidget, reason: '正文');
  });
}
