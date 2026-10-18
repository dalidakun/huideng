import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'theme.dart';
import 'sutra_list_page.dart';
import 'discussion_page.dart';
import 'splash_image_page.dart';
import 'study_hub_page.dart';
import 'bodhi_space_page.dart';
import 'my_page.dart';
import 'message_page.dart';
import 'record_page.dart';
import 'shanzhishi_page.dart';
import 'home_side_menu.dart';
import 'certification_page.dart';
import 'user_list_page.dart';
import 'login_page.dart';
import 'app_state.dart';
import 'assistant_session.dart';
import 'auth_service.dart';
import 'sync_service.dart';
import 'notification_service.dart';
import 'notification_center.dart';
import 'user_avatar_cache.dart';
import 'update_service.dart';
import 'reading_badges.dart';
import 'recent_sutras_page.dart';
import 'reading_page.dart';
import 'note_edit_page.dart';
import 'sect_community_page.dart';
import 'sect_detail_page.dart';
import 'sect_page.dart';

import 'app_palette.dart';
import 'agreements.dart';
import 'ui_sound.dart';
import 'sutra_title_overrides.dart';
import 'shortcut_actions.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 桌面快捷方式（「继续阅读」/「新建笔记」）专用全屏遮盖层：位于 Navigator 之上，
/// 从冷/热启动到目标页就绪之前一直遮住主页，避免先闪一下主页。就绪后置为 false 移除遮盖。
final ValueNotifier<bool> readingShortcutCover = ValueNotifier<bool>(false);

/// 包一层目标页面（阅读页 / 新建笔记），在其首帧渲染完成后回调 [onFirstFrame]，
/// 用于「继续阅读」「新建笔记」快捷方式在目标页真正可见后再撤掉全屏遮盖层
/// （此前遮盖层一直挡着主页）。
class _ShortcutLaunch extends StatefulWidget {
  const _ShortcutLaunch({required this.child, required this.onFirstFrame});

  final Widget child;
  final VoidCallback onFirstFrame;

  @override
  State<_ShortcutLaunch> createState() => _ShortcutLaunchState();
}

class _ShortcutLaunchState extends State<_ShortcutLaunch> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onFirstFrame();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 「继续阅读」遮盖层内容：与 [SplashImagePage] 同图同底色，覆盖整屏。
class _ReadingShortcutCover extends StatelessWidget {
  const _ReadingShortcutCover();

  @override
  Widget build(BuildContext context) {
    final barColor = AppPalette.instance.isPlain
        ? const Color(0xFFFBFBFB)
        : const Color(0xFFededed);
    return ColoredBox(
      color: barColor,
      child: SizedBox.expand(
        child: Image.asset(
          AppPalette.instance.isPlain
              ? 'assets/images/splash.png'
              : 'assets/images/splash1.png',
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}

/// 右下角「继续阅读」按钮几何：与菩提空间右下角「新建笔记」按钮一致
/// （直径 42、右边距 16、圆底距菜单栏上缘 28）。
const double _readingFabSize = 42;
const double _readingFabRight = 16;
const double _readingFabGap = 28;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await StudyHubPageState.warmPrefs();
  // 先加载外观偏好（暖黄/素白），再启动应用，避免首帧闪错主题。
  await AppPalette.instance.load();
  // 预加载管理员订正的经名覆盖（纯本地缓存，无网络），保证首帧即显示订正名。
  await SutraTitleOverrides.ensureLoaded();
  // 预加载磁盘缓存的头像到内存（不阻塞启动，下次 request() 即可命中）。
  unawaited(UserAvatarCache.instance.loadFromDisk());
  // 隐私合规：先读本地协议同意状态（纯本地读取，无网络）。用户首次启动
  // 会看到《用户协议》/《隐私政策》弹窗；在同意之前不得发起任何联网采集，
  // 因此登录恢复、云同步、通知调度等服务统一延迟到 [startBackgroundServices]。
  final agreed = await PrivacyConsent.isAgreed();
  // 桌面长按图标的快捷方式：在 runApp 之前消费冷启动动作（此时原生通道已就绪），
  // 供 _AppEntry 在启动图阶段直接进入对应页面，避免先闪一下主页。
  final startupAction = await ShortcutActions.consumeLaunchAction();
  runApp(MyApp(privacyAgreed: agreed, startupAction: startupAction));
  // 预热底部菜单点击音（纯本地资源，无网络请求），保证首次点击立即发声。
  unawaited(UiSound.instance.warmup());
  if (!agreed) return;
  startBackgroundServices();
}

/// 启动全部后台服务（含联网请求）。必须且只能在用户同意《隐私政策》之后调用：
/// - 后台静默恢复登录会话（不阻塞启动，登录态通过 ValueNotifier 广播）；
/// - 本地数据云同步：监听登录态变化 + 定时推送 + 生命周期冲刷；
/// - 本地通知（打卡提醒）初始化与调度恢复；
/// - App 回到前台时重新挂起打卡提醒（国产 ROM 常在后台清掉闹钟任务），
///   并先续期登录会话：后台停留超过 2 小时（access token 有效期）回来后
///   token 已过期，先修复会话再让界面刷新，避免带着过期 token 的云调用
///   被网关 401 拦截导致帖子全部加载失败（本地兜底缺作者信息）。
void startBackgroundServices() {
  unawaited(AuthService.instance.restoreSession());
  SyncService.instance.init();
  // 拉取管理员订正的经名覆盖（联网），供全站搜索/列表/最近阅读统一套用。
  unawaited(SutraTitleOverrides.refresh());
  unawaited(NotificationService.instance.init());
  AppLifecycleListener(
    onResume: () {
      NotificationService.instance.onAppResumed();
      unawaited(AuthService.instance.ensureFreshSession());
    },
  );
}

class MyApp extends StatefulWidget {
  /// 用户是否已同意《用户协议》与《隐私政策》（启动时读自本地存储）。
  final bool privacyAgreed;

  /// 冷启动时的桌面快捷方式动作（continue_reading / quick_checkin），无则为 null。
  final String? startupAction;

  const MyApp({super.key, required this.privacyAgreed, this.startupAction});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late bool _agreed = widget.privacyAgreed;

  /// 主页状态引用：侧滑返回时检查经藏页是否处于搜索模式（先退出搜索）。
  final _mainPageKey = GlobalKey<_MainPageState>();

  // 监听外观切换：调色板变化时重建整棵树，所有页面即时换肤（无需重启）。
  void _onPaletteChanged() {
    if (mounted) setState(() {});
  }

  /// 首次启动用户在同意页点了「同意并继续」：记录状态并启动后台服务。
  void _onPrivacyAgreed() {
    if (!mounted) return;
    setState(() => _agreed = true);
    startBackgroundServices();
  }

  @override
  void initState() {
    super.initState();
    AppPalette.instance.addListener(_onPaletteChanged);
    // 冷启动「继续阅读」/「新建笔记」：立即盖上全屏遮盖层（覆盖主页首帧来源），
    // 待 _AppEntry 打开目标页并就绪后再移除。
    if (widget.privacyAgreed &&
        (widget.startupAction == ShortcutActions.continueReading ||
            widget.startupAction == ShortcutActions.newNote)) {
      readingShortcutCover.value = true;
    }
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
            if (child != null) _HomeRevealStage(child: child),
            const _AssistantPanelOverlay(),
            const _AssistantRevealOverlay(),
            // 快捷方式「继续阅读」遮盖层：置顶于 Navigator 之上，阅读页就绪前
            // 遮住主页（含热启动复用主页的情况），杜绝「主页一闪」。
            Positioned.fill(
              child: ValueListenableBuilder<bool>(
                valueListenable: readingShortcutCover,
                builder: (_, show, __) =>
                    show ? const _ReadingShortcutCover() : const SizedBox.shrink(),
              ),
            ),
          ],
        );
      },
      // 未同意协议前，根页面是隐私同意页（不进入应用、后台服务也未启动）。
      home: !_agreed
          ? PrivacyConsentPage(onAgreed: _onPrivacyAgreed)
          : PopScope(
              // 根路由不允许直接 pop（否则系统会直接退出应用）：所有返回意图都
              // 统一在 onPopInvokedWithResult 里处理（收起面板 → 依次返回 → 最小化）。
              // 不能用已废弃的 WillPopScope：Android 14+ 预测性返回（targetSdk 34+
              // 默认开启）下，系统侧滑返回手势不会触发 onWillPop，导致「侧滑无反应」。
              canPop: false,
              onPopInvokedWithResult: (didPop, _) async {
                if (didPop) return;
                // 下拉露出到一半还没松手/没收完：先把它收回，不再往下走
                if (homeRevealScrub.value > 0) {
                  homeRevealScrub.value = 0;
                  return;
                }
                // 主页下拉打开的 DeepSeek 页展开时，先收起它而不是退出应用
                if (homeReveal.value) {
                  homeReveal.value = false;
                  return;
                }
                // 圆形助手面板展开时，先收起它而不是退出应用
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
                // 经藏页底部「全部经典」面板展开时，侧滑返回先收起面板，
                // 而不是直接最小化应用。
                if (_mainPageKey.currentState?.collapseSutraShelfIfOpen() ??
                    false) {
                  return;
                }
                // 经藏页处于搜索模式时，侧滑返回先退出搜索、回到经藏页面，
                // 而不是直接最小化应用。
                if (_mainPageKey.currentState?.exitSutraSearchIfActive() ??
                    false) {
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
              child: _AppEntry(
                mainPageKey: _mainPageKey,
                startupAction: widget.startupAction,
              ),
            ),
    );
  }
}

class _AppEntry extends StatefulWidget {
  const _AppEntry({required this.mainPageKey, this.startupAction});

  /// 主页状态引用：供根路由侧滑返回时检查/退出经藏搜索模式。
  final GlobalKey<_MainPageState> mainPageKey;

  /// 冷启动快捷方式动作：continue_reading 时启动图结束后直接进入阅读页。
  final String? startupAction;

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  bool _showMain = false;

  /// 桌面「继续阅读」快捷方式：跳过计时启动图，首帧后直接打开阅读页。
  ///
  /// 说明：静态快捷方式（shortcuts.xml）启动时系统固定附加
  /// FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TASK，旧界面会被整个清掉、
  /// main() 必然重跑，因此这里只需处理冷启动路径。
  bool get _continueToReading =>
      widget.startupAction == ShortcutActions.continueReading;

  /// 桌面「新建笔记」快捷方式：跳过计时启动图，首帧后直接打开新建笔记输入框。
  bool get _continueToNote =>
      widget.startupAction == ShortcutActions.newNote;

  @override
  void initState() {
    super.initState();
    if (_continueToReading) {
      // 跳过 2 秒启动图：首帧渲染出静态启动图 cover 后立即解析并打开阅读页。
      WidgetsBinding.instance.addPostFrameCallback((_) => _openStartupReading());
    } else if (_continueToNote) {
      // 同理：首帧渲染出静态启动图 cover 后立即打开新建笔记输入框。
      WidgetsBinding.instance.addPostFrameCallback((_) => _openStartupNote());
    }
  }

  Future<void> _finishSplash() async {
    if (!mounted) return;
    setState(() => _showMain = true);
    _afterStartup();
  }

  /// 启动后静默检查更新（不阻塞使用，失败静默忽略）。
  void _afterStartup() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(UpdateService.checkAndPrompt(context));
    });
  }

  /// 读取最近阅读记录并直接打开阅读页。
  ///
  /// 全屏遮盖层 [readingShortcutCover] 位于 Navigator 之上，从启动到阅读页
  /// 就绪前一直遮住主页；阅读页（不透明）压到最上层后再移除遮盖层，用户全程
  /// 只看到「启动图 → 阅读页」，不会闪出主页。
  Future<void> _openStartupReading() async {
    final prefs = await SharedPreferences.getInstance();
    var t = prefs.getString('last_read_title');
    var fp = prefs.getString('last_read_filePath');
    if (t == null || t.isEmpty) {
      final raw = prefs.getStringList('recent_sutras');
      if (raw != null && raw.isNotEmpty) {
        final parts = raw.first.split('|||');
        if (parts.isNotEmpty && parts[0].isNotEmpty) {
          t = parts[0];
          fp = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
        }
      }
    }
    if (!mounted) return;
    final nav = navigatorKey.currentState;
    // 无阅读记录或导航未就绪：移除遮盖层，正常进入主页。
    if (t == null || t.isEmpty || nav == null) {
      readingShortcutCover.value = false;
      setState(() => _showMain = true);
      _afterStartup();
      return;
    }
    final title = t;
    // 无入场动画，瞬时把不透明的阅读页压到最上层（遮盖层仍在其上方）。
    // 阅读页首帧渲染完成后回调 _onReadingReady 再撤遮盖层，确保其时阅读页已
    // 完全盖住主页。用首帧回调而非等帧，避免无动画时帧不再调度导致长时间停留。
    unawaited(nav.push(PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, __, ___) => _ShortcutLaunch(
        onFirstFrame: _onReadingReady,
        child: ReadingPage(title: title, filePath: fp),
      ),
    )));
  }

  /// 首帧后直接打开「新建笔记」输入框（无首页闪现）。
  Future<void> _openStartupNote() async {
    if (!mounted) return;
    final nav = navigatorKey.currentState;
    // 导航未就绪：移除遮盖层，正常进入主页。
    if (nav == null) {
      readingShortcutCover.value = false;
      setState(() => _showMain = true);
      _afterStartup();
      return;
    }
    // 无入场动画，瞬时把新建笔记页压到最上层（遮盖层仍在其上方）；其首帧渲染
    // 完成后回调 _onNoteReady 再撤遮盖层，确保其时编辑器已完全盖住主页。
    unawaited(nav.push(PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, __, ___) => _ShortcutLaunch(
        onFirstFrame: _onNoteReady,
        child: const NoteEditPage(),
      ),
    )));
  }

  /// 阅读页首帧渲染完成：撤掉遮盖层，并把根部内容切成主页（主页在阅读页之下，
  /// 不可见），同时执行启动后检查。
  void _onReadingReady() {
    if (!mounted) return;
    if (!_showMain) setState(() => _showMain = true);
    readingShortcutCover.value = false;
    _afterStartup();
  }

  /// 新建笔记页首帧渲染完成：撤掉遮盖层，并把根部内容切成主页（在笔记页之下）。
  void _onNoteReady() {
    if (!mounted) return;
    if (!_showMain) setState(() => _showMain = true);
    readingShortcutCover.value = false;
    _afterStartup();
  }

  /// 静态启动图 cover：与 [SplashImagePage] 同图同底色，但不计时、不改系统 UI，
  /// 仅用于「继续阅读」「新建笔记」首帧遮盖，避免闪出主页或黑屏。
  Widget _splashCover() {
    final barColor = AppPalette.instance.isPlain
        ? const Color(0xFFFBFBFB)
        : const Color(0xFFededed);
    return Scaffold(
      backgroundColor: barColor,
      body: SizedBox.expand(
        child: Image.asset(
          AppPalette.instance.isPlain
              ? 'assets/images/splash.png'
              : 'assets/images/splash1.png',
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_showMain) {
      if (_continueToReading || _continueToNote) return _splashCover();
      // 启动图跟随外观：米黄（warm）用 splash1.png，素白（plain）用 splash.png。
      return SplashImagePage(
        onFinished: _finishSplash,
        assetPath: AppPalette.instance.isPlain
            ? 'assets/images/splash.png'
            : 'assets/images/splash1.png',
      );
    }
    return MainPage(key: widget.mainPageKey);
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage>
    with WidgetsBindingObserver, TickerProviderStateMixin, RouteAware {
  int _currentIndex = 0;
  final _studyHubKey = GlobalKey<StudyHubPageState>();
  final _bodhiKey = GlobalKey<BodhiSpacePageState>();
  final _myKey = GlobalKey<MyPageState>();
  final _sutraListKey = GlobalKey<SutraListPageState>();
  final _recordKey = GlobalKey<RecordPageState>();
  final _shanZhiShiKey = GlobalKey();
  String? _recentTitle;
  String? _recentFilePath;
  bool _recentLoaded = false;
  bool _mainPageSubscribed = false;
  late final ValueNotifier<int> _tabIndex;
  List<Widget> _pages = [];
  // 底部菜单自动隐藏动画：value 0=完全显示，1=完全隐藏。
  // 惰性初始化，避免热重载后旧实例字段未赋值导致红屏。
  late final AnimationController _navCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  // 上一帧滚动偏移与最近一次方向判定后的滚动方向（1=向下，-1=向上）。
  double _lastScrollPixels = 0;
  int _scrollDir = 0;
  // 菩提空间菜单图标最近一次点击时间戳：无新帖时用于判定双击回到顶部。
  int _lastBodhiTabTap = 0;
  // 左侧个人菜单（个人资料/记录/关注/设置/退出登录）滑出动画。
  // value 0=完全收起，1=完全展开。
  late final AnimationController _sideMenuCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  // 抽屉曲线常驻字段（而非每次 build 新建）：避免监听器泄漏，并让关闭走
  // 反向专用的对称缓动——否则关闭复用 easeOutCubic，会先猛冲到只剩一点，
  // 末尾长时间慢爬，视觉上就是「先收一大半、卡住、再收完」。
  late final CurvedAnimation _sideMenuSlide = CurvedAnimation(
    parent: _sideMenuCtrl,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInOutCubic,
  );
  late final CurvedAnimation _sideMenuFade = CurvedAnimation(
    parent: _sideMenuCtrl,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeInOut,
  );
  bool _sideMenuOpen = false;
  // 每晚 20:00 打卡提醒定时器。
  Timer? _checkInReminderTimer;
  bool _checkInReminderShownToday = false;
  String _lastReminderDate = '';

  @override
  void initState() {
    super.initState();
    _tabIndex = ValueNotifier<int>(0);
    WidgetsBinding.instance.addObserver(this);
    SyncService.instance.dataVersion.addListener(_onCloudDataChanged);
    // 外观切换时刷新底部导航图标（素白用黑色版本）。
    AppPalette.instance.addListener(_onPaletteChanged);
    // 消息中心未读数轮询（底部「通知」角标实时同步服务器）。
    NotificationCenter.instance.start();
    // 启动时清理应用目录里残留的旧头像/横幅文件（只保留当前使用的）。
    unawaited(_cleanupAvatarBannerFiles());
    // 最近阅读记录 → 右下角「继续阅读」按钮打开阅读页。
    unawaited(_loadRecentReading());
    // 桌面长按图标的快捷方式：注册热启动信号监听（冷启动动作已在 main() 消费）。
    ShortcutActions.listen(_handleShortcutAction);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForResult();
      // 启动时检查是否需要显示 20:00 打卡提醒（当天 20:00 后打开 App）。
      _checkDailyCheckInReminder();
    });
    _scheduleCheckInReminderTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 订阅主页所在路由：从任何页面（含全屏阅读页）返回主页时刷新最近阅读记录。
    final route = ModalRoute.of(context);
    if (route != null && !_mainPageSubscribed) {
      _mainPageSubscribed = true;
      routeObserver.subscribe(this, route);
    }
  }

  /// 回到主页：全屏阅读页可能读了新的经书/更新了进度。
  @override
  void didPopNext() {
    unawaited(_loadRecentReading());
  }

  @override
  void dispose() {
    if (_mainPageSubscribed) routeObserver.unsubscribe(this);
    ShortcutActions.dispose();
    _checkInReminderTimer?.cancel();
    SyncService.instance.dataVersion.removeListener(_onCloudDataChanged);
    AppPalette.instance.removeListener(_onPaletteChanged);
    NotificationCenter.instance.stop();
    WidgetsBinding.instance.removeObserver(this);
    _navCtrl.dispose();
    _sideMenuSlide.dispose();
    _sideMenuFade.dispose();
    _sideMenuCtrl.dispose();
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
    _bodhiKey.currentState?.reload();
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
        // 切离菩提空间时收起其自定义悬浮面板。
        if (_currentIndex == 1) _bodhiKey.currentState?.closeCustomPanel();
        setState(() {
          _currentIndex = 2;
        });
        prefs.setBool('switch_to_sutra', false);
      }

      final shouldSwitchToAssistant = prefs.getBool('switch_to_assistant');
      if (shouldSwitchToAssistant == true) {
        if (_currentIndex == 1) _bodhiKey.currentState?.closeCustomPanel();
        setState(() {
          _currentIndex = 3;
        });
        prefs.setBool('switch_to_assistant', false);
      }
      _syncAssistantTab();
    });
  }

  /// 助手 Tab 是否处于选中态，同步给共享 WebView 会话。
  void _syncAssistantTab() {
    AssistantSession.instance.setTabActive(_currentIndex == 3);
  }

  // ── 每晚 20:00 打卡提醒 ──────────────────────────────

  /// 安排每天 20:00 的打卡提醒定时器。
  void _scheduleCheckInReminderTimer() {
    _checkInReminderTimer?.cancel();
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, 20, 0);
    if (now.isAfter(target)) {
      // 已过 20:00，设为明天 20:00。
      target = target.add(const Duration(days: 1));
    }
    _checkInReminderTimer = Timer(target.difference(now), () {
      _checkDailyCheckInReminder();
      // 明天同一时间再检查。
      _scheduleCheckInReminderTimer();
    });
  }

  /// 检查今天是否有未完成的打卡，20:00 后弹窗提醒（每天只弹一次）。
  Future<void> _checkDailyCheckInReminder() async {
    final now = DateTime.now();
    final today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    // 跨天重置标记。
    if (_lastReminderDate != today) {
      _lastReminderDate = today;
      _checkInReminderShownToday = false;
    }
    if (_checkInReminderShownToday) return;
    if (now.hour < 20) return; // 未到 20:00 不弹。
    final prefs = await SharedPreferences.getInstance();
    // 从持久化存储中读取今天是否已弹过。
    final lastShownDate = prefs.getString('checkin_reminder_shown_date') ?? '';
    if (lastShownDate == today) {
      _checkInReminderShownToday = true;
      return;
    }
    // 加载配置的功课项目。
    final items = <Map<String, String>>[];
    _loadNamedItems(items, prefs, 'reading', '诵经');
    _loadNamedItems(items, prefs, 'buddha', '称名');
    _loadNamedItems(items, prefs, 'mantra', '持咒');
    _loadNamedItems(items, prefs, 'nianfo', '念佛');
    _loadStrItems(items, prefs, 'copying', '抄经');
    _loadStrItems(items, prefs, 'meditation', '静坐');
    if (items.isEmpty) return; // 未配置功课不弹。
    // 加载今日打卡记录。
    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> allRecords = jsonDecode(raw);
    final todayRecords = allRecords.where((r) => r['date'] == today).toList();
    // 检查是否有未完成项：按类别维度判断（与功课页「完成自动分享」口径一致——
    // 每天每个已配置类别至少打卡一次即算完成；日历回填的补卡记录不存 name 字段，
    // 故不按具体项目匹配，避免已完成仍被提醒）。
    final types = {for (final item in items) item['type']!};
    final todayTypes = {
      for (final r in todayRecords) (r['type'] ?? '').toString()
    };
    final allDone = types.every((t) => todayTypes.contains(t));
    if (allDone) return; // 全部完成不弹。
    if (!mounted) return;
    _checkInReminderShownToday = true;
    await prefs.setString('checkin_reminder_shown_date', today);
    _showCheckInReminderDialog();
  }

  void _loadNamedItems(List<Map<String, String>> items, SharedPreferences prefs,
      String type, String category) {
    final raw = prefs.getString('setting_${type}_items') ??
        prefs.getString('setting_${type}_titles');
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final e in list) {
        final name = e is Map ? (e['name'] ?? '').toString() : '';
        if (name.trim().isEmpty) continue;
        items.add({'type': type, 'name': name.trim()});
      }
    } catch (_) {}
  }

  void _loadStrItems(List<Map<String, String>> items, SharedPreferences prefs,
      String type, String category) {
    final raw = prefs.getString('setting_${type}_titles') ??
        prefs.getString('setting_${type}_minutes');
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final e in list) {
        final name = e.toString().trim();
        if (name.isEmpty) continue;
        items.add({'type': type, 'name': name});
      }
    } catch (_) {}
  }

  void _showCheckInReminderDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 图标
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFFF7C948).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.notifications_active,
                    size: 32, color: Color(0xFFF7C948)),
              ),
              const SizedBox(height: 20),
              Text(
                '今日功课尚未完成',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.instance.isPlain
                      ? const Color(0xFF1A1A1A)
                      : const Color(0xFF212121),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '今天的修行功课还没打卡哦，\n坚持就是精进。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.6,
                  color: AppPalette.instance.isPlain
                      ? const Color(0xFF666666)
                      : const Color(0xFF999999),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppPalette.instance.isPlain
                        ? const Color(0xFF1A1A1A)
                        : const Color(0xFF71867A),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22)),
                    elevation: 0,
                  ),
                  child: const Text('我知道了',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _checkForResult();
      // 桌面「一键打卡」在后台由原生写入打卡记录：回到前台重读并补发静默分享。
      unawaited(_studyHubKey.currentState?.checkShortcutCheckin() ??
          Future<void>.value());
      // 回到前台立即同步未读数，角标保持实时。
      NotificationCenter.instance.refreshUnread();
      // 回到前台检查 20:00 打卡提醒。
      _checkDailyCheckInReminder();
    }
  }

  /// 底部导航图标：素白外观用黑色版本（文件名 .png 前加「1」），
  /// 每次构建重新取值，外观切换后立即换图。
  List<BottomNavigationBarItem> get _bottomNavItems => [
        BottomNavigationBarItem(
          icon: Image.asset(navIconAsset('assets/images/study.png'),
              width: 22, height: 22),
          activeIcon: Image.asset(
              navIconAsset('assets/images/study_selected.png'),
              width: 22,
              height: 22),
          label: '',
        ),
        // 菩提空间（菜单第 2 位）。
        BottomNavigationBarItem(
          icon: _BodhiTabIcon(active: false),
          activeIcon: _BodhiTabIcon(active: true),
          label: '',
        ),
        BottomNavigationBarItem(
          icon: Image.asset(navIconAsset('assets/images/sutra_book.png'),
              width: 22, height: 22),
          activeIcon: Image.asset(
              navIconAsset('assets/images/sutra_book_selected.png'),
              width: 22,
              height: 22),
          label: '',
        ),
        // 善知识（菜单第 4 位，放在经藏和消息之间）。
        BottomNavigationBarItem(
          icon: Image.asset(
              AppPalette.instance.isPlain
                  ? 'assets/images/ss1.png'
                  : 'assets/images/ms1.png',
              width: 22,
              height: 22),
          activeIcon: Image.asset(
              AppPalette.instance.isPlain
                  ? 'assets/images/ss2.png'
                  : 'assets/images/ms2.png',
              width: 22,
              height: 22),
          label: '',
        ),
        BottomNavigationBarItem(
          icon: _NotificationTabIcon(active: false),
          activeIcon: _NotificationTabIcon(active: true),
          label: '',
        ),
      ];

  /// 当前页面索引 → 底部菜单索引（助手/记录/个人主页无菜单项，不高亮）。
  int _navIndexForCurrent() {
    switch (_currentIndex) {
      case 0: // 首页
        return 0;
      case 1: // 菩提空间（菜单第 2 位）
        return 1;
      case 2: // 经藏（菜单第 3 位）
        return 2;
      case 7: // 善知识（菜单第 4 位）
        return 3;
      case 3: // 助手（入口在经藏页右上角）
        return -1;
      case 4: // 消息（菜单第 5 位）
        return 4;
      case 5: // 我的（入口在左侧菜单）
        return -1;
      case 6: // 记录（入口在左侧菜单）
        return -1;
      default:
        return -1;
    }
  }

  /// 读取最近阅读记录（last_read_title / last_read_filePath），
  /// 回退到 recent_sutras 首条（格式 `title|||filePath`）。
  Future<void> _loadRecentReading() async {
    final prefs = await SharedPreferences.getInstance();
    var t = prefs.getString('last_read_title');
    var fp = prefs.getString('last_read_filePath');
    if (t == null || t.isEmpty) {
      final raw = prefs.getStringList('recent_sutras');
      if (raw != null && raw.isNotEmpty) {
        final parts = raw.first.split('|||');
        if (parts.isNotEmpty && parts[0].isNotEmpty) {
          t = parts[0];
          fp = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
        }
      }
    }
    if (t != null && t.isEmpty) t = null;
    if (!mounted) return;
    if (_recentLoaded && t == _recentTitle && fp == _recentFilePath) return;
    setState(() {
      _recentTitle = t;
      _recentFilePath = fp;
      _recentLoaded = true;
    });
  }

  /// 处理桌面长按图标的快捷方式动作。
  Future<void> _handleShortcutAction(String action) async {
    switch (action) {
      case ShortcutActions.continueReading:
        // 热启动（App 已在后台，某些 ROM 的快捷方式走 onNewIntent）：先用全屏
        // 遮盖层盖住当前主页，再把阅读页瞬时压到最上层，就绪后撤遮盖层，
        // 避免热启动复用主页时「主页一闪」。
        readingShortcutCover.value = true;
        await _loadRecentReading();
        if (!mounted) return;
        final title = _recentTitle;
        if (title == null) {
          readingShortcutCover.value = false;
          break;
        }
        final nav = navigatorKey.currentState;
        if (nav == null) {
          readingShortcutCover.value = false;
          break;
        }
        unawaited(nav.push(PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: const Duration(milliseconds: 220),
          pageBuilder: (_, __, ___) => _ShortcutLaunch(
            onFirstFrame: () => readingShortcutCover.value = false,
            child: ReadingPage(title: title, filePath: _recentFilePath),
          ),
        )));
        break;
      case ShortcutActions.newNote:
        // 热启动：先用全屏遮盖层盖住当前页面，再把新建笔记页瞬时压到最上层，
        // 其首帧就绪后撤遮盖层，直接进入输入框。
        readingShortcutCover.value = true;
        if (!mounted) return;
        final noteNav = navigatorKey.currentState;
        if (noteNav == null) {
          readingShortcutCover.value = false;
          break;
        }
        unawaited(noteNav.push(PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: const Duration(milliseconds: 220),
          pageBuilder: (_, __, ___) => _ShortcutLaunch(
            onFirstFrame: () => readingShortcutCover.value = false,
            child: const NoteEditPage(),
          ),
        )));
        break;
      case ShortcutActions.quickCheckIn:
        // 冷启动时登录会话可能仍在后台恢复，先确保完成再判定是否自动分享。
        await AuthService.instance.restoreSession();
        if (!mounted) return;
        // 收起可能残留的子页面，让用户直接看到首页已完成的打卡状态。
        navigatorKey.currentState?.popUntil((r) => r.isFirst);
        if (_currentIndex != 0) _switchToTab(0);
        await _studyHubKey.currentState?.quickCheckInAll();
        break;
    }
  }

  /// 经藏页处于搜索模式时退出搜索（根路由侧滑返回调用）。返回是否消费了本次返回。
  bool exitSutraSearchIfActive() {
    if (_currentIndex != 2) return false;
    return _sutraListKey.currentState?.exitSearchIfActive() ?? false;
  }

  /// 经藏页底部「全部经典」面板展开时收起它（根路由侧滑返回调用）。
  /// 返回是否消费了本次返回，避免侧滑直接最小化应用。
  bool collapseSutraShelfIfOpen() {
    if (_currentIndex != 2) return false;
    return _sutraListKey.currentState?.collapseShelfIfOpen() ?? false;
  }

  void _switchToTab(int index) {
    // 切页前重读最近阅读记录——离开期间可能已从全屏阅读页换了经书。
    unawaited(_loadRecentReading());
    // 已停留在经藏页再次点击经藏菜单图标：处于搜索模式则先退出搜索。
    // 注意：经藏仍是底部菜单第 3 格（nav 2），插入「善知识」只把「消息」挤到 nav 4。
    if (index == 2 && _currentIndex == 2) {
      _sutraListKey.currentState?.exitSearchIfActive();
      _tabIndex.value = 2;
      _syncAssistantTab();
      _revealNavBar();
      return;
    }
    // 离开经藏页时退出搜索模式，保证回来时是正常页面。
    if (_currentIndex == 2) {
      _sutraListKey.currentState?.deactivateSearch();
    }
    // 底部菜单索引 → 页面索引：善知识(nav3)→7，消息(nav4)→4，其他按顺序映射
    final pageIndex = switch (index) {
      2 => 2, // 经藏
      3 => 7, // 善知识
      4 => 4, // 消息
      _ => index,
    };
    // 已停留在首页再次点击首页菜单图标：刷新并回到顶部。
    if (pageIndex == 0 && _currentIndex == 0) {
      _studyHubKey.currentState?.reload();
      _studyHubKey.currentState?.scrollToTop();
      _tabIndex.value = 0;
      _syncAssistantTab();
      _revealNavBar();
      return;
    }
    // 已停留在菩提空间再次点击其菜单图标：
    // - 有新帖（角标 > 0）：保持原 reload 行为，刷出新帖。
    // - 无新帖：检测双击，第二次点击则回到页面最顶部。
    if (pageIndex == 1 && _currentIndex == 1) {
      if (BodhiSpacePageState.newPostBadge.value > 0) {
        _bodhiKey.currentState?.reload();
      } else {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastBodhiTabTap < 350) {
          _bodhiKey.currentState?.scrollToTop();
          _lastBodhiTabTap = 0;
        } else {
          _lastBodhiTabTap = now;
        }
      }
      _tabIndex.value = 1;
      _syncAssistantTab();
      _revealNavBar();
      return;
    }
    // 离开菩提空间时收起其自定义悬浮面板，避免面板残留在其他页面上方。
    if (_currentIndex == 1 && pageIndex != 1) {
      _bodhiKey.currentState?.closeCustomPanel();
    }
    _tabIndex.value = pageIndex;
    setState(() {
      _currentIndex = pageIndex;
    });
    _syncAssistantTab();
    _revealNavBar();
    if (pageIndex == 0) _studyHubKey.currentState?.reload();
    if (pageIndex == 1) _bodhiKey.currentState?.reload();
  }

  /// 经藏页右上角助手入口：以圆形展开/缩回动画开关全屏 DeepSeek 面板。
  void _openAssistantPage() {
    assistantReveal.value = !assistantReveal.value;
  }

  /// 修学页左上角头像入口：打开「我的」页面。
  void _openMyPage() {
    if (_currentIndex == 2) {
      _sutraListKey.currentState?.deactivateSearch();
    }
    _tabIndex.value = 5;
    setState(() {
      _currentIndex = 5;
    });
    _syncAssistantTab();
    _revealNavBar();
    _myKey.currentState?.reload();
  }

  /// 经藏页「宗派经典」入口：打开宗门/法门列表页（原底部菜单第 4 项，现作为经藏页
  /// 压栈子页，顶栏返回键 pop 回经藏）。可从前台其它页进入，先退出经藏页搜索模式。
  void _openSectPage() {
    if (_currentIndex == 2) {
      _sutraListKey.currentState?.deactivateSearch();
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SectPage(
          onOpen: _openSectDetail,
          onOpenCommunity: _openSectCommunityByKey,
        ),
      ),
    );
  }

  /// 各页面左上角头像入口：从左侧滑出个人菜单。
  void _openSideMenu() {
    if (_sideMenuOpen) return;
    setState(() {
      _sideMenuOpen = true;
    });
    _sideMenuCtrl.forward();
  }

  // 关闭去重：同一轮关闭里重复调用（遮罩连点等）不再重启 reverse——
  // 重启会按剩余距离重算时长，越点剩余时长越长，末尾看起来像卡住不动。
  Future<void>? _sideMenuClosing;

  Future<void> _closeSideMenu() {
    final existing = _sideMenuClosing;
    if (existing != null) return existing;
    if (!_sideMenuOpen) return Future<void>.value();
    final future = _sideMenuCtrl.reverse().whenComplete(() {
      _sideMenuClosing = null;
      if (mounted) setState(() => _sideMenuOpen = false);
    });
    _sideMenuClosing = future;
    return future;
  }

  /// 菜单跳转统一处理：先收起面板，再执行跳转（避免两个转场同时进行）。
  Future<void> _sideMenuGo(Future<void> Function() action) async {
    await _closeSideMenu();
    await action();
  }

  void _sideMenuOpenFollowing() {
    unawaited(_sideMenuGo(() => Navigator.of(context).push(
        slideInFromLeft(const UserListPage(mode: UserListMode.following)))));
  }

  void _sideMenuOpenSettings() {
    unawaited(_sideMenuGo(() =>
        Navigator.of(context).push(slideInFromLeft(const SettingsPage()))));
  }

  void _sideMenuOpenProfile() {
    unawaited(_sideMenuGo(() async => _openMyPage()));
  }

  /// 抽屉「记录」入口：进记录时间线（底部菜单无此页，底部不高亮）。
  void _sideMenuOpenRecord() {
    unawaited(_sideMenuGo(() async => _openRecordPage()));
  }

  /// 抽屉「书签」入口：进书签页（原本挂在个人资料页的标签栏，现移到这里）。
  void _sideMenuOpenBookmarks() {
    unawaited(_sideMenuGo(() =>
        Navigator.of(context).push(slideInFromLeft(const BookmarksPage()))));
  }

  /// 切到记录页：重读本地索引（读经页新写的画线/感想、笔记改动即时可见）。
  void _openRecordPage() {
    if (!mounted) return;
    if (_currentIndex == 2) _sutraListKey.currentState?.deactivateSearch();
    _tabIndex.value = 6;
    setState(() => _currentIndex = 6);
    _syncAssistantTab();
    _revealNavBar();
    unawaited(_recordKey.currentState?.reload());
  }

  /// 抽屉「获得认证」入口：收起面板后进实名认证页，返回时认证状态已写入本地。
  void _sideMenuCertify() {
    unawaited(_sideMenuGo(() => Navigator.of(context)
        .push(slideInFromLeft(const CertificationPage()))));
  }

  /// 抽屉「登录」入口（未登录时显示）：收起面板后进登录页。
  Future<void> _sideMenuLogin() async {
    await _closeSideMenu();
    if (!mounted) return;
    unawaited(Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const LoginPage())));
  }

  /// 退出登录：二次确认后清登录态。
  Future<void> _sideMenuLogout() async {
    if (!AuthService.instance.isLoggedIn) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppPalette.p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('退出登录',
            style: TextStyle(
                color: AppPalette.p.text,
                fontSize: 18,
                fontWeight: FontWeight.w600)),
        content: Text('退出后需重新登录才能管理云端笔记',
            style: TextStyle(color: AppPalette.p.textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: AppPalette.p.textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出',
                style:
                    TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _closeSideMenu();
    await AuthService.instance.logout();
  }

  /// 打开最近阅读页：与经藏页「继续阅读」走同一条路径
  /// （SutraListPage.openRecentSutra），保证和正常点经进入的阅读页完全一致。
  /// 路由是从右下角按钮圆心逐渐展开的圆形效果（同经藏页右上角 DeepSeek 按钮）。
  /// 没有阅读记录时不响应。
  void _openRecentReading() {
    final title = _recentTitle;
    if (title == null) return;
    final routeBuilder = _readingRevealRoute();
    final sutraState = _sutraListKey.currentState;
    if (sutraState != null) {
      sutraState.openRecentSutra(
        title,
        _recentFilePath,
        routeBuilder: routeBuilder,
      );
      return;
    }
    Navigator.push(
      context,
      routeBuilder(
        (context) => ReadingPage(title: title, filePath: _recentFilePath),
      ),
    );
  }

  /// 构造「从按钮圆心展开/收起」的阅读页路由：打开时圆从按钮铺满全屏，
  /// 返回时同圆收回按钮；时长与曲线同经藏页 DeepSeek 按钮（480ms easeInOutCubic）。
  ReadingRouteBuilder _readingRevealRoute() {
    final media = MediaQuery.of(context);
    final center = Offset(
      media.size.width - _readingFabRight - _readingFabSize / 2,
      media.size.height -
          media.padding.bottom -
          _BottomNavBar.heightOnly(context) -
          _readingFabGap -
          _readingFabSize / 2,
    );
    // 圆心在右下角，覆盖整屏只需到左上角的距离。
    return (builder) => _CircleRevealPageRoute(
          builder: builder,
          center: center,
          maxRadius: center.distance,
        );
  }

  /// 阅读统计入口：打开阅读统计页面。
  void _openReadingStats() {
    if (_currentIndex == 2) {
      _sutraListKey.currentState?.deactivateSearch();
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const BadgeDetailPage(),
      ),
    );
  }

  /// 稍后阅读入口：打开稍后阅读页面。
  void _openReadingHistory() {
    if (_currentIndex == 2) {
      _sutraListKey.currentState?.deactivateSearch();
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecentSutrasPage(parent: _sutraListKey.currentState),
      ),
    );
  }

  /// 宗门入口：打开该宗核心经典详情页，分卷正文复用经藏页的下载/阅读逻辑。
  /// 缠习社等自定义入口不走详情页，先进独立占位页。
  void _openSectDetail(SectInfo sect) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SectDetailPage(
          sect: sect,
          parent: _sutraListKey.currentState,
        ),
      ),
    );
  }

  /// 社区入口：顶部展示位点「进入社区」时按社区标记（`${栏目名}社区`）
  /// 反查栏目，再进该栏目的合并页并直接落在社区那一侧。
  /// 对不上（历史脏数据）直接忽略，不弹空页。
  void _openSectCommunityByKey(String community) {
    final sect = sectByCommunity(community);
    if (sect == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SectDetailPage(sect: sect, initialTab: 1)),
    );
  }

  /// 切页时立即弹回菜单并重置滚动方向跟踪。
  void _revealNavBar() {
    _scrollDir = 0;
    _lastScrollPixels = 0;
    _navCtrl.value = 0;
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
    // 外观切换时重建页面列表，确保各子页面的 build() 能读取最新的 AppPalette.p 值。
    _pages = [
      StudyHubPage(
        key: _studyHubKey,
        onOpenSideMenu: _openSideMenu,
        onSutraStateChanged: () =>
            unawaited(_sutraListKey.currentState?.reload()),
      ),
      BodhiSpacePage(
        key: _bodhiKey,
        onOpenMyPage: _openMyPage,
        onOpenSideMenu: _openSideMenu,
      ),
      SutraListPage(
        key: _sutraListKey,
        activeTab: _tabIndex,
        onOpenAssistant: _openAssistantPage,
        onOpenReadingStats: _openReadingStats,
        onOpenReadingHistory: _openReadingHistory,
        onOpenSect: _openSectPage,
      ),
      _AssistantTabPage(),
      MessagePage(onOpenSideMenu: _openSideMenu, activeTab: _tabIndex),
      MyPage(key: _myKey),
      RecordPage(key: _recordKey, onOpenSideMenu: _openSideMenu),
      ShanZhiShiPage(key: _shanZhiShiKey, activeTab: _tabIndex, tabIndex: 7),
    ];
    // 关闭键盘自适应压缩：WebView（助手/DeepSeek）在 adjustResize 下会被键盘
    // 压成小视口，页面在消息区与输入框之间露出大片空白遮挡内容。
    // 改为不压缩，由 DeepSeek 页面自身处理键盘重叠，输入框保持在键盘上方。
    final navBase = _BottomNavBar.heightOnly(context);
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
                        bottom: MediaQuery.of(context).padding.bottom + navBase,
                      ),
                  // Scaffold 的 FAB 定位读取的是 viewPadding，需同步加高，
                  // 否则右下角加号按钮会落到菜单栏上重叠。
                  viewPadding: MediaQuery.of(context)
                      .viewPadding
                      .copyWith(
                        bottom:
                            MediaQuery.of(context).viewPadding.bottom + navBase,
                      ),
                ),
                child: IndexedStack(
                  index: _currentIndex,
                  children: _pages,
                ),
              ),
            ),
          ),
          // 右下角「继续阅读」圆形按钮：仅首页(0)、消息(4) 两个菜单页
          // 显示，点击打开最近阅读的经书；没有阅读记录时不显示。
          if (_recentTitle != null &&
              (_currentIndex == 0 || _currentIndex == 4))
            Positioned(
              right: _readingFabRight,
              bottom: MediaQuery.of(context).padding.bottom +
                  navBase +
                  _readingFabGap,
              child: SizedBox(
                width: _readingFabSize,
                height: _readingFabSize,
                child: FloatingActionButton(
                  heroTag: 'continue_reading_fab',
                  onPressed: _openRecentReading,
                  // 与菩提空间「新建笔记」按钮同款：素白黑底、米黄绿底，白色图标。
                  backgroundColor: AppPalette.instance.isPlain
                      ? const Color(0xFF1A1A1A)
                      : const Color(0xFF71867A),
                  elevation: 8,
                  highlightElevation: 12,
                  shape: const CircleBorder(),
                  child: Image.asset(
                    'assets/images/yt.png',
                    width: 21,
                    height: 21,
                  ),
                ),
              ),
            ),
          // 悬浮菜单：不再随滚动变淡（变淡会让背后文字透出菜单）。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _BottomNavBar(
              items: _bottomNavItems,
              currentIndex: _navIndexForCurrent(),
              onTap: _switchToTab,
              // 仅「经藏」页（_currentIndex == 2）菜单用实底，其余保持毛玻璃。
              opaque: _currentIndex == 2,
            ),
          ),
          // 左侧个人菜单：约 2/3 屏宽，遮罩点击关闭，覆盖在底部菜单之上。
          if (_sideMenuOpen) ...[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeSideMenu,
                child: FadeTransition(
                  opacity:
                      Tween<double>(begin: 0, end: 0.35).animate(_sideMenuFade),
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: MediaQuery.of(context).size.width * 2 / 3,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(-1, 0),
                  end: Offset.zero,
                ).animate(_sideMenuSlide),
                child: HomeSideMenu(
                  onOpenProfile: _sideMenuOpenProfile,
                  onOpenRecord: _sideMenuOpenRecord,
                  onOpenBookmarks: _sideMenuOpenBookmarks,
                  onOpenFollowing: _sideMenuOpenFollowing,
                  onOpenSettings: _sideMenuOpenSettings,
                  onLogin: _sideMenuLogin,
                  onLogout: _sideMenuLogout,
                  onCertify: _sideMenuCertify,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 素白外观下底部导航使用黑色图标：文件名在 .png 前加「1」
/// （如 my.png → my1.png、my_selected.png → my_selected1.png）。
String navIconAsset(String base) =>
    AppPalette.instance.isPlain ? base.replaceAll('.png', '1.png') : base;

/// X 风格毛玻璃底部导航栏：始终悬浮在内容之上，内容从下方滚过时呈磨砂效果。
class _BottomNavBar extends StatelessWidget {
  final List<BottomNavigationBarItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// 是否使用不透明底色（不做毛玻璃）。
  /// 仅「经藏」页开启：该页底部有常驻「全部经典」面板，菜单透出正文会很乱；
  /// 其他菜单页保持原来的毛玻璃悬浮效果。
  final bool opaque;

  const _BottomNavBar({
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.opaque = false,
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

    final Widget bar = Container(
      decoration: BoxDecoration(
        color: opaque
            ? AppPalette.p.card
            : AppPalette.p.card.withValues(alpha: 0.4),
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
                      onTap: () {
                        // 点击菜单时播放清脆短暂的自带点击音效。
                        UiSound.instance.playClick();
                        onTap(i);
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Center(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 160),
                            reverseDuration: const Duration(milliseconds: 70),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, anim) => FadeTransition(
                              opacity: anim,
                              child: ScaleTransition(
                                scale: Tween<double>(begin: 0.88, end: 1)
                                    .animate(anim),
                                child: child,
                              ),
                            ),
                            child: KeyedSubtree(
                              key: ValueKey<bool>(selected),
                              child: Center(child: icon),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
      ),
    );

    // 经藏页：实底菜单，不叠毛玻璃，避免透出正文；其他页面维持原有的毛玻璃悬浮。
    if (opaque) {
      return ClipRect(child: bar);
    }
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: bar,
      ),
    );
  }
}

/// 底部「菩提空间」标签图标：米黄外观用 mi1/mi2，素白外观用 su1/su2；
/// 有新帖未查看时右上角显示 70867A 小圆点。
class _BodhiTabIcon extends StatelessWidget {
  final bool active;
  const _BodhiTabIcon({required this.active});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: BodhiSpacePageState.newPostBadge,
      builder: (context, count, _) {
        return Stack(
          clipBehavior: Clip.none,
          children: [
            // 新素材四周留白比同排图标多，23 号下仍显得比邻项小，
            // 故放到 25 号，视觉大小才与其它菜单项一致。
            Image.asset(
              AppPalette.instance.isPlain
                  ? (active ? 'assets/images/su2.png' : 'assets/images/su1.png')
                  : (active
                      ? 'assets/images/mi2.png'
                      : 'assets/images/mi1.png'),
              width: 25,
              height: 25,
            ),
            if (count > 0)
              Positioned(
                // 圆点尽量贴近图标右上角（图标素材自身带少量透明边距）。
                top: -1,
                right: -1,
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
          // 比同排 22 号略大一号：素材墨迹占比略小，23 号视觉才齐平。
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
              // 不在聊天页时显示返回按钮，回到聊天页后换回 AI 按钮。
              if (t > 0.5)
                Positioned(
                  right: 16,
                  bottom: 111,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: AssistantSession.instance.isOnChatPage,
                      builder: (context, onChat, _) {
                        return FloatingActionButton(
                          heroTag: 'sutra_ai_assistant_overlay',
                          onPressed: onChat
                              ? () => assistantVisible.value = false
                              : () => AssistantSession.instance.goBackToChat(),
                          backgroundColor: const Color(0xFFf7f7f7),
                          elevation: 8,
                          highlightElevation: 12,
                          shape: const CircleBorder(),
                          child: onChat
                              ? Text(
                                  'AI',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: AppPalette.p.primary,
                                  ),
                                )
                              : Icon(
                                  Icons.arrow_back,
                                  size: 18,
                                  color: AppPalette.p.primary,
                                ),
                        );
                      },
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
/// 深色的翻页式：从上方滑入显示 DeepSeek 聊天页，左上角叉号关闭
/// Circle-reveal overlay for the assistant button at the top-right of the
/// sutra library page. Unrelated to the home page pull-down reveal.
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
      AssistantSession.instance.claim(AssistantSurface.reveal);
      _ctrl.forward();
    } else {
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
          final keyboard = MediaQuery.viewInsetsOf(context).bottom;
          final center = Offset(size.width, 0);
          final maxRadius = Offset(size.width, size.height).distance;
          return IgnorePointer(
            ignoring: t == 0,
            child: ClipPath(
              clipper: _CircleRevealClipper(
                progress: t,
                center: center,
                maxRadius: maxRadius,
              ),
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(bottom: keyboard),
                  child: Stack(
                    children: [
                      ColoredBox(color: AppPalette.p.bg, child: child),
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

/// Home page pull-down reveal.
///
/// Wraps the whole app content ([child]). DeepSeek 页固定在主页身后；下拉时主页
/// 整体往下滑动（与手指 1:1：手指拖多少，主页就下移多少，见
/// PullRevealTracker.revealDistance），身后的 DeepSeek 页随之逐渐「漏出」
/// （上下两个页面互相推拉）：
/// - 顶部 DeepSeek 页区域先出现一个灰色圆点，随下拉逐渐「裂开」成三个并铺开
///   到临界位置（进度 [ _crit ] 处）；主页同时逐渐变模糊。
/// - 越过临界点后继续下拉，DeepSeek 页由朦胧转为清晰；松手时进度过半才自动
///   展开 DeepSeek，否则主页弹回原位。
/// 关闭时反向播放；DeepSeek 页顶部中央有一枚关闭 (X) 按钮。
class _HomeRevealStage extends StatefulWidget {
  const _HomeRevealStage({required this.child});

  final Widget child;

  @override
  State<_HomeRevealStage> createState() => _HomeRevealStageState();
}

class _HomeRevealStageState extends State<_HomeRevealStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  /// 是否正被下拉手势擦洗：此时显示值直接取手指进度，
  /// 曲线只用于开/收合的补间（避免跟手时进度被曲线二次加工）。
  bool _scrubbing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    homeReveal.addListener(_onVisible);
    homeRevealScrub.addListener(_onScrub);
  }

  /// 下拉跟手：进度 > 0 时按手指实时露出（并提前挂载 WebView，露出即可见），
  /// 归零（反向上拖到位 / 松手未过半）时按余下距离收合。
  void _onScrub() {
    if (!mounted || homeReveal.value) return;
    final v = homeRevealScrub.value;
    if (v > 0) {
      _scrubbing = true;
      AssistantSession.instance.claim(AssistantSurface.home);
      _ctrl.stop();
      _ctrl.value = v.clamp(_ctrl.lowerBound, _ctrl.upperBound);
    } else if (_scrubbing) {
      _scrubbing = false;
      _collapse();
    }
  }

  void _onVisible() {
    if (!mounted) return;
    if (homeReveal.value) {
      _scrubbing = false;
      AssistantSession.instance.claim(AssistantSurface.home);
      _ctrl.animateTo(1.0, curve: Curves.easeInOutCubic);
    } else {
      _scrubbing = false;
      _collapse();
    }
  }

  /// 从当前露出量收合到 0，收完才把 WebView 让给其他入口（否则露出中途会闪没）。
  void _collapse() {
    _ctrl.animateBack(0.0, curve: Curves.easeInOutCubic).whenCompleteOrCancel(() {
      if (!mounted || homeReveal.value || homeRevealScrub.value > 0) return;
      AssistantSession.instance.release(AssistantSurface.home);
    });
  }

  @override
  void dispose() {
    homeReveal.removeListener(_onVisible);
    homeRevealScrub.removeListener(_onScrub);
    _ctrl.dispose();
    super.dispose();
  }

  /// 临界点：三个圆点恰好展开到位的位置。越过它松手才会自动展开 DeepSeek，
  /// 否则弹回主页。与 [PullRevealTracker.commitProgress] 保持一致（0.5）。
  static const double _crit = 0.5;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        final height = MediaQuery.of(context).size.height;
        // 键盘弹出高度：输入框激活时 WebView 底部让出，输入框保持在键盘上方
        //（与经藏页右上角 DeepSeek 展开面板同一处理，否则输入法会盖住输入框）。
        final keyboard = MediaQuery.viewInsetsOf(context).bottom;

        // 圆点从主页开始下移、顶部露出 DeepSeek 区域时才出现（先是一个圆点），
        // 展开进度到临界点正好铺成三个。
        const double dotsStart = 0.1;
        final dotsT =
            ((t - dotsStart) / (_crit - dotsStart)).clamp(0.0, 1.0);
        final dotsIn = (dotsT * 4).clamp(0.0, 1.0);
        // 越过临界点后圆点淡出，让位给逐渐清晰的 DeepSeek 页。
        final dotsOpacity = t <= _crit
            ? dotsIn
            : (1.0 - (t - _crit) / (1 - _crit)).clamp(0.0, 1.0);

        // 主页跟手整体往下滑动：滑走多少，顶部的 DeepSeek 页就露出多少。
        final homeShift = height * t;
        // 淡出：整棵 App 子树做透明度合成已是全屏 saveLayer，成本不低。
        final homeOpacity = (1.0 - t * 0.35).clamp(0.0, 1.0);

        return Stack(
          children: [
            // DeepSeek 页：全屏浅色底上，把 DeepSeek 页硬裁剪到顶部 t·h 区域。
            // 主页下移多少，顶部这块就露出多少，两块面积一增一减。
            Positioned.fill(
              child: IgnorePointer(
                ignoring: t < 0.99,
                child: Material(
                  color: const Color(0xFFf0f3f8),
                  child: Stack(
                    children: [
                      // 硬裁剪：DeepSeek 页只在顶部 t·h 区域露出（与主页下移量同步），
                      // 于是主页下半块的半透明不再「透出整张 DeepSeek 页」。
                      // 内层 SizedBox 仍按全屏高度布局，WebView 不重排，只做裁剪。
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: ClipRect(
                          child: Align(
                            alignment: Alignment.topCenter,
                            heightFactor: t,
                            child: SizedBox(
                              width: double.infinity,
                              height: height,
                              child: SafeArea(
                                bottom: true,
                                child: Padding(
                                  padding: EdgeInsets.only(bottom: keyboard),
                                  child: const DiscussionPage(
                                    surface: AssistantSurface.home,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // 关闭按钮：DeepSeek 已基本漏出时才出现，避免与圆点挤在顶部。
                      if (t > 0.6)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Center(
                                child: Material(
                                  color: Colors.white,
                                  shape: const CircleBorder(),
                                  elevation: 3,
                                  child: InkWell(
                                    customBorder: const CircleBorder(),
                                    onTap: () => homeReveal.value = false,
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Icon(
                                        Icons.close,
                                        size: 20,
                                        color: AppPalette.p.primary,
                                      ),
                                    ),
                                  ),
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
            // 下拉指示：位于 DeepSeek 页顶部区域，随下拉逐渐展开成三个圆点。
            if (dotsOpacity > 0.01)
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: const Alignment(0, -0.76),
                    child: Opacity(
                      opacity: dotsOpacity,
                      child: _PullDots(t: dotsT),
                    ),
                  ),
                ),
              ),
            // 主页内容：整体下移 + 淡出，露出顶部的 DeepSeek 页。
            // 只做平移（Transform）与透明度，避免对整棵 App 子树做高斯模糊——
            // 全屏模糊每帧都要 saveLayer 重新栅格化，是掉帧的主因。
            // RepaintBoundary 缓存主页位图：露出期间主页被冻结、画面不变，
            // 每帧只需复用缓存再叠加透明度/平移，避免整棵 App 反复重绘。
            IgnorePointer(
              ignoring: t > 0.01,
              child: Opacity(
                opacity: homeOpacity,
                child: Transform.translate(
                  offset: Offset(0, homeShift),
                  child: RepaintBoundary(child: widget.child),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 下拉指示：一个灰色圆点随下拉逐渐「裂开」为三个圆点，并铺开到临界位置。
///
/// [t] 为 0 → 1 的展开进度：0 时外侧两点缩放为 0、间距为 0（看起来就是一个
/// 圆点）；1 时三点成型并分散到位（这一刻正是展开/回弹的临界点）。
class _PullDots extends StatelessWidget {
  const _PullDots({required this.t});

  final double t;

  static const double _dot = 10;
  static const double _maxGap = 14;

  @override
  Widget build(BuildContext context) {
    final gap = _maxGap * t;
    final outer = _dot * t;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _dotBox(outer),
        SizedBox(width: gap),
        _dotBox(_dot),
        SizedBox(width: gap),
        _dotBox(outer),
      ],
    );
  }

  Widget _dotBox(double size) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0xFFB4BCC4),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _CircleRevealPageRoute<T> extends PageRoute<T> {
  _CircleRevealPageRoute({
    required this.builder,
    required this.center,
    required this.maxRadius,
  });

  final WidgetBuilder builder;
  final Offset center;
  final double maxRadius;

  bool _revealStarted = false;
  bool _disposed = false;
  Timer? _fallbackTimer;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 480);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 480);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return NotificationListener<ReadingContentReadyNotification>(
      onNotification: (_) {
        _startReveal();
        return true;
      },
      child: ClipPath(
        clipper: _CircleRevealClipper(
          progress: Curves.easeInOutCubic.transform(animation.value),
          center: center,
          maxRadius: maxRadius,
        ),
        child: child,
      ),
    );
  }

  @override
  TickerFuture didPush() {
    // 先按默认流程压栈（请求焦点、注册），但立刻停住动画：保持半径 0。
    final future = super.didPush();
    controller!.stop();
    controller!.value = 0.0;
    // 兜底：正文迟迟不就绪（网络/异常）时也按时展开，显示加载态而非卡住。
    _fallbackTimer = Timer(const Duration(milliseconds: 1200), _startReveal);
    return future;
  }

  void _startReveal() {
    if (_revealStarted || _disposed) return;
    final ctrl = controller;
    if (ctrl == null || ctrl.isAnimating || ctrl.isCompleted) {
      _revealStarted = true;
      _fallbackTimer?.cancel();
      _fallbackTimer = null;
      return;
    }
    _revealStarted = true;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    ctrl.forward();
  }

  @override
  bool didPop(T? result) {
    // 返回时不再触发延迟展开；若已展开则按原路径缩回。
    _revealStarted = true;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    return super.didPop(result);
  }

  @override
  void dispose() {
    _disposed = true;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    super.dispose();
  }
}

/// 圆形展开裁剪器：以 center 为圆心，半径随 progress 从 0 增长到 maxRadius。
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