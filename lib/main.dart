import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'theme.dart';
import 'sutra_list_page.dart';
import 'discussion_page.dart';
import 'splash_image_page.dart';
import 'study_hub_page.dart';
import 'my_page.dart';
import 'message_page.dart';
import 'app_state.dart';
import 'assistant_session.dart';
import 'auth_service.dart';
import 'sync_service.dart';
import 'notification_service.dart';
import 'notification_center.dart';
import 'user_avatar_cache.dart';
import 'update_service.dart';

import 'app_palette.dart';
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await StudyHubPageState.warmPrefs();
  // 先加载外观偏好（暖黄/素白），再启动应用，避免首帧闪错主题。
  await AppPalette.instance.load();
  // 预加载磁盘缓存的头像到内存（不阻塞启动，下次 request() 即可命中）。
  unawaited(UserAvatarCache.instance.loadFromDisk());
  runApp(const MyApp());
  // 后台静默恢复登录会话（不阻塞启动，登录态通过 ValueNotifier 广播）。
  unawaited(AuthService.instance.restoreSession());
  // 本地数据云同步：监听登录态变化 + 定时推送 + 生命周期冲刷。
  SyncService.instance.init();
  // 本地通知（打卡提醒）初始化与调度恢复。
  unawaited(NotificationService.instance.init());
  // App 回到前台时重新挂起打卡提醒（国产 ROM 常在后台清掉闹钟任务），
  // 并先续期登录会话：后台停留超过 2 小时（access token 有效期）回来后
  // token 已过期，先修复会话再让界面刷新，避免带着过期 token 的云调用
  // 被网关 401 拦截导致帖子全部加载失败（本地兜底缺作者信息）。
  AppLifecycleListener(
    onResume: () {
      NotificationService.instance.onAppResumed();
      unawaited(AuthService.instance.ensureFreshSession());
    },
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // 监听外观切换：调色板变化时重建整棵树，所有页面即时换肤（无需重启）。
  void _onPaletteChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    AppPalette.instance.addListener(_onPaletteChanged);
  }

  @override
  void dispose() {
    AppPalette.instance.removeListener(_onPaletteChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '佛经阅读器',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      navigatorKey: navigatorKey,
      navigatorObservers: [routeObserver],
      // AI 面板常驻在 Navigator 之上：WebView 不随阅读页销毁，会话可跨页面延续。
      builder: (context, child) {
        return Stack(
          children: [
            if (child != null) child,
            const _AssistantPanelOverlay(),
            const _AssistantRevealOverlay(),
          ],
        );
      },
      home: PopScope(
        // 根路由不允许直接 pop（否则系统会直接退出应用）：所有返回意图都
        // 统一在 onPopInvokedWithResult 里处理（收起面板 → 依次返回 → 最小化）。
        // 不能用已废弃的 WillPopScope：Android 14+ 预测性返回（targetSdk 34+
        // 默认开启）下，系统侧滑返回手势不会触发 onWillPop，导致「侧滑无反应」。
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          // 圆形助手面板展开时，先收起它而不是退出应用。
          if (assistantReveal.value) {
            assistantReveal.value = false;
            return;
          }
          // AI 面板展开时，先收起它而不是退出应用。
          if (assistantVisible.value) {
            assistantVisible.value = false;
            return;
          }
          // 如有可返回的路由（如从主页打开的个人空间页/详情页），先 pop 回上一页，
          // 而不是直接最小化 App。只有在最底层（主页）才执行最小化。
          // 注意：不能在这里用 Navigator.of(context)——MyApp 的 context 在
          // MaterialApp 之上，找不到 Navigator 会抛空错误，改用全局 navigatorKey。
          final nav = navigatorKey.currentState;
          if (nav != null && nav.canPop()) {
            nav.pop();
            return;
          }
          // 最小化应用到后台，模拟从底部滑动的行为
          if (Platform.isAndroid) {
            const platform = MethodChannel('app_channel');
            try {
              await platform.invokeMethod('minimizeApp');
            } catch (e) {
              // 如果失败，使用系统默认行为
              SystemNavigator.pop();
            }
          } else {
            SystemNavigator.pop();
          }
        },
        child: const _AppEntry(),
      ),
    );
  }
}

class _AppEntry extends StatefulWidget {
  const _AppEntry();

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  bool _showMain = false;

  void _finishSplash() {
    if (!mounted) return;
    setState(() => _showMain = true);
    // 启动后静默检查更新（不阻塞使用，失败静默忽略）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(UpdateService.checkAndPrompt(context));
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_showMain) {
      // 启动图跟随外观：米黄（warm）用 splash1.png，素白（plain）用 splash.png。
      return SplashImagePage(
        onFinished: _finishSplash,
        assetPath: AppPalette.instance.isPlain
            ? 'assets/images/splash.png'
            : 'assets/images/splash1.png',
      );
    }
    return const MainPage();
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  bool _searchMode = false;
  final _studyHubKey = GlobalKey<StudyHubPageState>();
  final _myKey = GlobalKey<MyPageState>();
  final _sutraListKey = GlobalKey<SutraListPageState>();
  late final ValueNotifier<int> _tabIndex;
  late final List<Widget> _pages;
  // 底部菜单自动隐藏动画：value 0=完全显示，1=完全隐藏。
  // 惰性初始化，避免热重载后旧实例字段未赋值导致红屏。
  late final AnimationController _navCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  // 上一帧滚动偏移与最近一次方向判定后的滚动方向（1=向下，-1=向上）。
  double _lastScrollPixels = 0;
  int _scrollDir = 0;
  // 修学菜单图标最近一次点击时间戳：无新帖时用于判定双击回到顶部。
  int _lastStudyTabTap = 0;

  @override
  void initState() {
    super.initState();
    _tabIndex = ValueNotifier<int>(0);
    _pages = [
      StudyHubPage(
        key: _studyHubKey,
        onOpenMyPage: _openMyPage,
        onSutraStateChanged: () =>
            unawaited(_sutraListKey.currentState?.reload()),
      ),
      SutraListPage(
        key: _sutraListKey,
        activeTab: _tabIndex,
        onSearchModeChanged: _onSearchModeChanged,
        onOpenAssistant: _openAssistantPage,
      ),
      _AssistantTabPage(),
      MessagePage(onOpenMyPage: _openMyPage, activeTab: _tabIndex),
      MyPage(key: _myKey),
    ];
    WidgetsBinding.instance.addObserver(this);
    SyncService.instance.dataVersion.addListener(_onCloudDataChanged);
    // 外观切换时刷新底部导航图标（素白用黑色版本）。
    AppPalette.instance.addListener(_onPaletteChanged);
    // 消息中心未读数轮询（底部「通知」角标实时同步服务器）。
    NotificationCenter.instance.start();
    // 启动时清理应用目录里残留的旧头像/横幅文件（只保留当前使用的）。
    unawaited(_cleanupAvatarBannerFiles());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForResult();
    });
  }

  @override
  void dispose() {
    SyncService.instance.dataVersion.removeListener(_onCloudDataChanged);
    AppPalette.instance.removeListener(_onPaletteChanged);
    NotificationCenter.instance.stop();
    WidgetsBinding.instance.removeObserver(this);
    _navCtrl.dispose();
    super.dispose();
  }

  /// 外观切换时刷新底部导航图标（素白用黑色版本）。
  void _onPaletteChanged() {
    if (mounted) setState(() {});
  }

  /// 云端同步拉取完成后刷新各页面展示的数据。
  void _onCloudDataChanged() {
    if (!mounted) return;
    _studyHubKey.currentState?.reload();
    _myKey.currentState?.reload();
    unawaited(_sutraListKey.currentState?.reload());
  }

  /// 清理应用文档目录里残留的旧头像/横幅文件（只保留 prefs 当前引用的），
  /// 避免部分 ROM 的系统相册扫描应用目录时显示多份重复图片。
  Future<void> _cleanupAvatarBannerFiles() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final prefs = await SharedPreferences.getInstance();
      final keep = <String>{
        prefs.getString('user_avatar_path') ?? '',
        prefs.getString('user_banner_path') ?? '',
      };
      await for (final e in docs.list()) {
        if (e is! File) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        final isAvatarOrBanner =
            (name.startsWith('avatar_') || name.startsWith('user_banner_')) &&
                name.endsWith('.jpg');
        if (isAvatarOrBanner && !keep.contains(e.path)) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _checkForResult() {
    SharedPreferences.getInstance().then((prefs) {
      final shouldSwitchToSutra = prefs.getBool('switch_to_sutra');
      if (shouldSwitchToSutra == true) {
        setState(() {
          _currentIndex = 1;
        });
        prefs.setBool('switch_to_sutra', false);
      }

      final shouldSwitchToAssistant = prefs.getBool('switch_to_assistant');
      if (shouldSwitchToAssistant == true) {
        setState(() {
          _currentIndex = 2;
        });
        prefs.setBool('switch_to_assistant', false);
      }
      _syncAssistantTab();
    });
  }

  /// 助手 Tab 是否处于选中态，同步给共享 WebView 会话。
  void _syncAssistantTab() {
    AssistantSession.instance.setTabActive(_currentIndex == 2);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _checkForResult();
      // 回到前台立即同步未读数，角标保持实时。
      NotificationCenter.instance.refreshUnread();
    }
  }

  /// 底部导航图标：素白外观用黑色版本（文件名 .png 前加「1」），
  /// 每次构建重新取值，外观切换后立即换图。
  List<BottomNavigationBarItem> get _bottomNavItems => [
    BottomNavigationBarItem(
      // 不用 const：保证外观切换时图标子树会重建、及时换黑色版本。
      icon: _StudyTabIcon(active: false),
      activeIcon: _StudyTabIcon(active: true),
      label: '',
    ),
    BottomNavigationBarItem(
      icon: Image.asset(navIconAsset('assets/images/search.png'),
          width: 24, height: 24),
      activeIcon: Image.asset(navIconAsset('assets/images/search_selected.png'),
          width: 24, height: 24),
      label: '',
    ),
    BottomNavigationBarItem(
      icon: Image.asset(navIconAsset('assets/images/sutra_book.png'),
          width: 27, height: 27),
      activeIcon:
          Image.asset(navIconAsset('assets/images/sutra_book_selected.png'),
              width: 27, height: 27),
      label: '',
    ),
    BottomNavigationBarItem(
      icon: _NotificationTabIcon(active: false),
      activeIcon: _NotificationTabIcon(active: true),
      label: '',
    ),
    BottomNavigationBarItem(
      icon: Image.asset(navIconAsset('assets/images/my.png'),
          width: 21.5, height: 21.5),
      activeIcon: Image.asset(navIconAsset('assets/images/my_selected.png'),
          width: 21.5, height: 21.5),
      label: '',
    ),
  ];

  /// 经藏页搜索模式变化（页内退出搜索时同步菜单高亮）。
  void _onSearchModeChanged(bool active) {
    if (!mounted || _searchMode == active) return;
    setState(() {
      _searchMode = active;
    });
  }

  /// 当前页面索引 → 底部菜单索引（搜索是模式入口；助手无菜单项，不高亮）。
  int _navIndexForCurrent() {
    if (_searchMode) return 1;
    switch (_currentIndex) {
      case 0: // 修学
        return 0;
      case 1: // 经藏
        return 2;
      case 2: // 助手（入口在经藏页右上角）
        return -1;
      case 3: // 消息
        return 3;
      default: // 我的
        return 4;
    }
  }

  void _switchToTab(int index) {
    if (index == 1) {
      // 底部「搜索」：进入/退出经藏搜索激活状态。
      if (_searchMode) {
        _searchMode = false;
        setState(() {
          _currentIndex = 1;
        });
        _sutraListKey.currentState?.deactivateSearch();
      } else {
        _searchMode = true;
        _tabIndex.value = 1;
        setState(() {
          _currentIndex = 1;
        });
        _sutraListKey.currentState?.activateSearch();
      }
      return;
    }
    if (_searchMode) {
      _searchMode = false;
      _sutraListKey.currentState?.deactivateSearch();
    }
    final pageIndex = index == 4
        ? 4
        : (index == 3 ? 3 : (index == 2 ? 1 : 0));
    // 已停留在修学页再次点击修学菜单图标：
    // - 有新帖（角标 > 0）：保持原 reload 行为，刷出新帖。
    // - 无新帖：检测双击，第二次点击则回到页面最顶部。
    if (pageIndex == 0 && _currentIndex == 0) {
      if (StudyHubPageState.newPostBadge.value > 0) {
        _studyHubKey.currentState?.reload();
      } else {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastStudyTabTap < 350) {
          _studyHubKey.currentState?.scrollToTop();
          _lastStudyTabTap = 0;
        } else {
          _lastStudyTabTap = now;
        }
      }
      _tabIndex.value = 0;
      _syncAssistantTab();
      _revealNavBar();
      return;
    }
    _tabIndex.value = pageIndex;
    setState(() {
      _currentIndex = pageIndex;
    });
    _syncAssistantTab();
    _revealNavBar();
    if (pageIndex == 0) _studyHubKey.currentState?.reload();
  }

  /// 经藏页右上角助手入口：以圆形展开/缩回动画开关全屏 DeepSeek 面板。
  void _openAssistantPage() {
    assistantReveal.value = !assistantReveal.value;
  }

  /// 修学页左上角头像入口：打开「我的」页面。
  void _openMyPage() {
    if (_searchMode) {
      _searchMode = false;
      _sutraListKey.currentState?.deactivateSearch();
    }
    _tabIndex.value = 4;
    setState(() {
      _currentIndex = 4;
    });
    _syncAssistantTab();
    _revealNavBar();
    _myKey.currentState?.reload();
  }

  /// 切页时立即弹回菜单并重置滚动方向跟踪。
  void _revealNavBar() {
    _scrollDir = 0;
    _lastScrollPixels = 0;
    if (_navCtrl.value > 0) {
      _navCtrl.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutBack,
      );
    }
  }

  void switchToTab(int index) {
    _switchToTab(index);
  }

  /// 菜单隐藏/显示动画时长：随滚动速度调整，快滑更短、慢拖更长。
  Duration _navDurationFor(double delta) {
    final speed = delta.abs();
    if (speed > 60) return const Duration(milliseconds: 180);
    if (speed > 20) return const Duration(milliseconds: 210);
    return const Duration(milliseconds: 240);
  }

  /// 检测滚动方向并驱动菜单明暗：
  /// - 向下滚动（内容上移）→ 菜单轻微变淡（仅透明度，不隐藏、不位移）
  /// - 向上滚动（内容下移）→ 菜单立即恢复
  /// - 忽略 <8px 的微小移动，方向反转需累积到阈值才生效，避免快速变向闪烁
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification.depth != 0) return false;
    final pixels = notification.metrics.pixels;
    final delta = pixels - _lastScrollPixels;
    _lastScrollPixels = pixels;
    if (delta.abs() < 8) return false;
    final dir = delta > 0 ? 1 : -1;
    if (dir == _scrollDir) return false;
    _scrollDir = dir;
    final duration = _navDurationFor(delta);
    if (dir > 0) {
      // 变淡：透明度从 1 降到 0.6。
      _navCtrl.animateTo(1, duration: duration, curve: Curves.easeOutCubic);
    } else {
      // 恢复：立即弹回全亮。
      _navCtrl.animateTo(0, duration: duration, curve: Curves.easeOutCubic);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // 关闭键盘自适应压缩：WebView（助手/DeepSeek）在 adjustResize 下会被键盘
    // 压成小视口，页面在消息区与输入框之间露出大片空白遮挡内容。
    // 改为不压缩，由 DeepSeek 页面自身处理键盘重叠，输入框保持在键盘上方。
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 内容区：底部让出菜单高度（仅作用于主页内容，不影响跳转后的页面），
          // 列表滚动时内容会从毛玻璃菜单下方掠过。
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: MediaQuery.of(context).padding.copyWith(
                        bottom: MediaQuery.of(context).padding.bottom +
                            _BottomNavBar.heightOnly(context),
                      ),
                  // Scaffold 的 FAB 定位读取的是 viewPadding，需同步加高，
                  // 否则右下角加号按钮会落到菜单栏上重叠。
                  viewPadding: MediaQuery.of(context).viewPadding.copyWith(
                        bottom: MediaQuery.of(context).viewPadding.bottom +
                            _BottomNavBar.heightOnly(context),
                      ),
                ),
                child: IndexedStack(
                  index: _currentIndex,
                  children: _pages,
                ),
              ),
            ),
          ),
          // X 风格毛玻璃悬浮菜单：向下滚动时轻微变淡（不位移、不隐藏），
          // 向上滚动时恢复。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedBuilder(
              animation: _navCtrl,
              builder: (context, child) {
                return Opacity(
                  // 淡出到 0.6，图标仍清晰可见。
                  opacity: 1 - 0.4 * _navCtrl.value,
                  child: child,
                );
              },
              child: _BottomNavBar(
                items: _bottomNavItems,
                currentIndex: _navIndexForCurrent(),
                onTap: _switchToTab,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 素白外观下底部导航使用黑色图标：文件名在 .png 前加「1」
/// （如 my.png → my1.png、my_selected.png → my_selected1.png）。
String navIconAsset(String base) => AppPalette.instance.isPlain
    ? base.replaceAll('.png', '1.png')
    : base;

/// X 风格毛玻璃底部导航栏：始终悬浮在内容之上，内容从下方滚过时呈磨砂效果。
class _BottomNavBar extends StatelessWidget {
  final List<BottomNavigationBarItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _BottomNavBar({
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  /// 图标区高度（不含底部安全区）。
  static double heightOnly(BuildContext context) {
    final media = MediaQuery.of(context);
    final large = media.size.height >= 820 || media.size.width >= 430;
    return large ? 51.0 : 45.9;
  }

  @override
  Widget build(BuildContext context) {
    final base = heightOnly(context);

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            color: AppPalette.p.card.withValues(alpha: 0.4),
            border: Border(
              top: BorderSide(color: AppPalette.p.borderSoft, width: 0.8),
            ),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: base,
              child: Row(
                children: List.generate(items.length, (i) {
                  final selected = i == currentIndex;
                  final item = items[i];
                  final Widget icon = selected ? item.activeIcon : item.icon;
                  return Expanded(
                    child: InkWell(
                      onTap: () => onTap(i),
                      borderRadius: BorderRadius.circular(10),
                      child: Center(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: Center(child: icon),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部「通知」标签图标：右上角显示未读角标（Badge）。
/// - 圆形（1~9）/ 胶囊形（>9），背景 #70867A，白字，圆角 999，超出图标边界。
/// - 收到新通知时 Scale 0→1.15→1 弹性动画，数字平滑递增；
///   全部已读后淡出并缩小消失。
class _StudyTabIcon extends StatelessWidget {
  final bool active;
  const _StudyTabIcon({required this.active});

  @override
  Widget build(BuildContext context) {
    // 修学广场有新帖未查看时（顶部「显示X帖子」提醒可见），右上角显示 70867A 小圆点。
    return ValueListenableBuilder<int>(
      valueListenable: StudyHubPageState.newPostBadge,
      builder: (context, count, _) {
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Image.asset(
              navIconAsset(active
                  ? 'assets/images/study_selected.png'
                  : 'assets/images/study.png'),
              width: 24,
              height: 24,
            ),
            if (count > 0)
              Positioned(
                top: -2,
                right: -4,
                child: IgnorePointer(
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF70867A),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _NotificationTabIcon extends StatefulWidget {
  final bool active;
  const _NotificationTabIcon({required this.active});

  @override
  State<_NotificationTabIcon> createState() => _NotificationTabIconState();
}

class _NotificationTabIconState extends State<_NotificationTabIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  int _prev = 0;

  @override
  void initState() {
    super.initState();
    NotificationCenter.instance.unread.addListener(_onUnread);
    _prev = NotificationCenter.instance.unread.value;
  }

  @override
  void dispose() {
    NotificationCenter.instance.unread.removeListener(_onUnread);
    _pop.dispose();
    super.dispose();
  }

  void _onUnread() {
    final n = NotificationCenter.instance.unread.value;
    if (n > 0 && n != _prev) {
      _pop.forward(from: 0);
    }
    _prev = n;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final count = NotificationCenter.instance.unread.value;
    final visible = count > 0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Image.asset(
          navIconAsset(widget.active
              ? 'assets/images/chat_selected.png'
              : 'assets/images/chat.png'),
          width: 23,
          height: 23,
        ),
        Positioned(
          top: -6,
          right: -6,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: AnimatedScale(
                scale: visible ? 1 : 0.5,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: AnimatedBuilder(
                  animation: _pop,
                  builder: (context, child) {
                    final t = _pop.value;
                    double s = 1;
                    if (t > 0 && t < 0.6) {
                      s = (t / 0.6) * 1.15;
                    } else if (t >= 0.6) {
                      s = 1.15 - ((t - 0.6) / 0.4) * 0.15;
                    }
                    return Transform.scale(scale: s, child: child);
                  },
                  child: count > 0
                      ? _NotificationBadgePill(count: count)
                      : const SizedBox(width: 16, height: 16),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Badge 本体：圆形（1~9）或胶囊形（>9），数字 >99 显示「99+」。
class _NotificationBadgePill extends StatelessWidget {
  final int count;
  const _NotificationBadgePill({required this.count});

  @override
  Widget build(BuildContext context) {
    final text = count > 99 ? '99+' : '$count';
    final capsule = count > 9;
    return Container(
      height: 16,
      constraints: BoxConstraints(minWidth: 16),
      padding: EdgeInsets.symmetric(horizontal: capsule ? 5 : 0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF70867A),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: child),
        child: Text(
          text,
          key: ValueKey(text),
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

/// 底部「助手」标签页：DeepSeek 对话 WebView。
class _AssistantTabPage extends StatelessWidget {
  const _AssistantTabPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.p.bg,
      appBar: AppBar(
        backgroundColor: AppPalette.p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: IconThemeData(color: AppPalette.p.primary),
        title: Row(
          children: [
            Text(
              '助手',
              style: TextStyle(
                color: AppPalette.p.primary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(width: 6),
            Text(
              '·',
              style: TextStyle(
                color: Color(0xFF9E9588),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: 6),
            Flexible(
              child: Text(
                '诸行无常，一切皆苦；诸法无我，寂灭为乐。',
                style: TextStyle(
                  color: Color(0xFF9E9588),
                  fontSize: 10.5,
                ),
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      // WebView 底部让出菜单高度，避免 DeepSeek 的输入框被悬浮菜单遮挡。
      // 键盘弹出时取消让位：避免输入法上方露出页面底色的色块。
      body: SafeArea(
        top: false,
        bottom: MediaQuery.viewInsetsOf(context).bottom == 0,
        child: const DiscussionPage(surface: AssistantSurface.tab),
      ),
    );
  }
}

/// 全局 AI 助手面板：常驻在 Navigator 之上，WebView 不销毁。
/// 从底部向上滑出，顶部停在 AppBar 之下；展开时右下角显示收起按钮。
class _AssistantPanelOverlay extends StatefulWidget {
  const _AssistantPanelOverlay();

  @override
  State<_AssistantPanelOverlay> createState() => _AssistantPanelOverlayState();
}

class _AssistantPanelOverlayState extends State<_AssistantPanelOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    assistantVisible.addListener(_onVisible);
  }

  void _onVisible() {
    if (!mounted) return;
    if (assistantVisible.value) {
      // 展开：把共享 WebView 挂到上滑面板表面（首次打开才真正创建）。
      AssistantSession.instance.claim(AssistantSurface.panel);
      _ctrl.forward();
    } else {
      // 收起动画结束后才让出 WebView；若动画中途被取消（用户立刻重开），
      // 仍处于打开态则不让出。
      _ctrl.reverse().whenCompleteOrCancel(() {
        if (!mounted || assistantVisible.value) return;
        AssistantSession.instance.release(AssistantSurface.panel);
      });
    }
  }

  @override
  void dispose() {
    assistantVisible.removeListener(_onVisible);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top + kToolbarHeight;
    return SizedBox.expand(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, child) {
          final t = Curves.easeInOutCubic.transform(_ctrl.value);
          final full = MediaQuery.of(context).size.height - topInset;
          // 键盘弹出高度：输入框激活时 WebView 底部让出，输入框保持在键盘上方。
          final keyboard = MediaQuery.viewInsetsOf(context).bottom;
          return Stack(
            children: [
              // 面板：从底部升起，顶部边缘滑到 AppBar 之下。
              Positioned(
                left: 0,
                right: 0,
                top: topInset + full * (1 - t),
                bottom: 0,
                child: Padding(
                  padding: EdgeInsets.only(bottom: keyboard),
                  child: child!,
                ),
              ),
              // 展开时右下角的收起按钮（与阅读页 AI 按钮同位）。
              if (t > 0.5)
                Positioned(
                  right: 16,
                  bottom: 111,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: FloatingActionButton(
                      heroTag: 'sutra_ai_assistant_overlay',
                      onPressed: () => assistantVisible.value = false,
                      backgroundColor: const Color(0xFFf7f7f7),
                      elevation: 8,
                      highlightElevation: 12,
                      shape: const CircleBorder(),
                      child: Text(
                        'AI',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.p.primary,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
        child: const DiscussionPage(surface: AssistantSurface.panel),
      ),
    );
  }
}

/// 经藏页右上角「助手」圆形展开面板：
/// 从右上角一个点以圆形伸展为全屏 DeepSeek 页面，关闭时按原路径缩回。
class _AssistantRevealOverlay extends StatefulWidget {
  const _AssistantRevealOverlay();

  @override
  State<_AssistantRevealOverlay> createState() =>
      _AssistantRevealOverlayState();
}

class _AssistantRevealOverlayState extends State<_AssistantRevealOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    assistantReveal.addListener(_onVisible);
  }

  void _onVisible() {
    if (!mounted) return;
    if (assistantReveal.value) {
      // 展开：把共享 WebView 挂到圆形展开表面（首次打开才真正创建）。
      AssistantSession.instance.claim(AssistantSurface.reveal);
      _ctrl.forward();
    } else {
      // 收起动画结束后才让出 WebView；若动画中途被取消（用户立刻重开），
      // 仍处于打开态则不让出。
      _ctrl.reverse().whenCompleteOrCancel(() {
        if (!mounted || assistantReveal.value) return;
        AssistantSession.instance.release(AssistantSurface.reveal);
      });
    }
  }

  @override
  void dispose() {
    assistantReveal.removeListener(_onVisible);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, child) {
          final t = Curves.easeInOutCubic.transform(_ctrl.value);
          final size = MediaQuery.of(context).size;
          // 键盘弹出高度：输入框激活时 WebView 底部让出，输入框保持在键盘上方。
          final keyboard = MediaQuery.viewInsetsOf(context).bottom;
          // 圆心取屏幕右上角，半径需覆盖整屏（对角线）。
          final center = Offset(size.width, 0);
          final maxRadius = Offset(size.width, size.height).distance;
          // 完全收起时不拦截任何点击；开始展开即可交互。
          return IgnorePointer(
            ignoring: t == 0,
            child: ClipPath(
              clipper: _CircleRevealClipper(
                progress: t,
                center: center,
                maxRadius: maxRadius,
              ),
              child: SafeArea(
                // 顶部避开状态栏，底部避开手势条，避免遮挡 DeepSeek 页面的内容。
                child: Padding(
                  padding: EdgeInsets.only(bottom: keyboard),
                  child: Stack(
                    children: [
                      // 背景 + DeepSeek 页面。
                      ColoredBox(color: AppPalette.p.bg, child: child),
                      // 右上角收起按钮。
                      if (t > 0.6)
                        Positioned(
                          top: 10,
                          right: 12,
                          child: Material(
                            color: Colors.white,
                            shape: const CircleBorder(),
                            elevation: 4,
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => assistantReveal.value = false,
                              child: Padding(
                                padding: EdgeInsets.all(8),
                                child: Icon(
                                  Icons.close,
                                  size: 20,
                                  color: AppPalette.p.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
        child: const DiscussionPage(surface: AssistantSurface.reveal),
      ),
    );
  }
}

/// 圆形展开裁剪器：以右上角为圆心，半径随 progress 从 0 增长到全屏对角线。
class _CircleRevealClipper extends CustomClipper<Path> {
  final double progress;
  final Offset center;
  final double maxRadius;

  const _CircleRevealClipper({
    required this.progress,
    required this.center,
    required this.maxRadius,
  });

  @override
  Path getClip(Size size) {
    return Path()
      ..addOval(
        Rect.fromCircle(center: center, radius: maxRadius * progress),
      );
  }

  @override
  bool shouldReclip(_CircleRevealClipper oldClipper) {
    return oldClipper.progress != progress ||
        oldClipper.center != center ||
        oldClipper.maxRadius != maxRadius;
  }
}
