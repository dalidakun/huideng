import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'theme.dart';
import 'sutra_list_page.dart';
import 'discussion_page.dart';
import 'splash_image_page.dart';
import 'study_hub_page.dart';
import 'my_page.dart';
import 'message_page.dart';
import 'app_state.dart';
import 'auth_service.dart';
import 'sync_service.dart';
import 'notification_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

bool _errorDialogShown = false;

/// 捕获未处理异常并把堆栈弹窗展示，方便在手机上直接看到出错位置。
void _installErrorHandler() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _showErrorReport(details.exceptionAsString(), details.stack?.toString() ?? '');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _showErrorReport(error.toString(), stack.toString());
    return true;
  };
}

void _showErrorReport(String message, String stack) {
  if (_errorDialogShown) return;
  _errorDialogShown = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    nav.push(
      MaterialPageRoute(
        builder: (_) => _ErrorReportPage(message: message, stack: stack),
      ),
    );
  });
}

/// 展示错误详情（调试用）：消息 + 完整堆栈 + 复制按钮。
class _ErrorReportPage extends StatelessWidget {
  final String message;
  final String stack;
  const _ErrorReportPage({required this.message, required this.stack});

  @override
  Widget build(BuildContext context) {
    final full = 'ERROR: $message\n\n$stack';
    return Scaffold(
      appBar: AppBar(
        title: const Text('错误详情'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: full)),
          ),
        ],
      ),
      body: SelectableText(
        full,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
      ),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await StudyHubPageState.warmPrefs();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Color(0xFFededed),
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFFededed),
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  _installErrorHandler();
  runApp(const MyApp());
  // 后台静默恢复登录会话（不阻塞启动，登录态通过 ValueNotifier 广播）。
  unawaited(AuthService.instance.restoreSession());
  // 本地数据云同步：监听登录态变化 + 定时推送 + 生命周期冲刷。
  SyncService.instance.init();
  // 本地通知（打卡提醒）初始化与调度恢复。
  unawaited(NotificationService.instance.init());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

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
          ],
        );
      },
      home: WillPopScope(
        onWillPop: () async {
          // AI 面板展开时，先收起它而不是退出应用。
          if (assistantVisible.value) {
            assistantVisible.value = false;
            return false;
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
          return false;
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
  }

  @override
  Widget build(BuildContext context) {
    if (!_showMain) return SplashImagePage(onFinished: _finishSplash);
    return const MainPage();
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver {
  int _currentIndex = 0;
  final _studyHubKey = GlobalKey<StudyHubPageState>();
  final _myKey = GlobalKey<MyPageState>();
  final _sutraListKey = GlobalKey<SutraListPageState>();
  late final ValueNotifier<int> _tabIndex;
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _tabIndex = ValueNotifier<int>(0);
    _pages = [
      StudyHubPage(key: _studyHubKey),
      SutraListPage(key: _sutraListKey, activeTab: _tabIndex),
      const MessagePage(),
      MyPage(key: _myKey),
    ];
    WidgetsBinding.instance.addObserver(this);
    SyncService.instance.dataVersion.addListener(_onCloudDataChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForResult();
    });
  }

  @override
  void dispose() {
    SyncService.instance.dataVersion.removeListener(_onCloudDataChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 云端同步拉取完成后刷新各页面展示的数据。
  void _onCloudDataChanged() {
    if (!mounted) return;
    _studyHubKey.currentState?.reload();
    _myKey.currentState?.reload();
    unawaited(_sutraListKey.currentState?.reload());
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
          _currentIndex = 3;
        });
        prefs.setBool('switch_to_assistant', false);
      }
    });
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _checkForResult();
    }
  }

  final List<BottomNavigationBarItem> _bottomNavItems = [
    BottomNavigationBarItem(
      icon: Image.asset('assets/images/study.png', width: 18, height: 18),
      activeIcon: Image.asset('assets/images/study_selected.png', width: 18, height: 18),
      label: '修学',
    ),
    BottomNavigationBarItem(
      icon: Image.asset('assets/images/sutra_book.png', width: 18, height: 18),
      activeIcon: Image.asset('assets/images/sutra_book_selected.png', width: 18, height: 18),
      label: '经藏',
    ),
    BottomNavigationBarItem(
      icon: Image.asset('assets/images/chat.png', width: 18, height: 18),
      activeIcon: Image.asset('assets/images/chat_selected.png', width: 18, height: 18),
      label: '消息',
    ),
    BottomNavigationBarItem(
      icon: Image.asset('assets/images/my.png', width: 18, height: 18),
      activeIcon: Image.asset('assets/images/my_selected.png', width: 18, height: 18),
      label: '我的',
    ),
  ];

  void _switchToTab(int index) {
    _tabIndex.value = index;
    setState(() {
      _currentIndex = index;
    });
    if (index == 0) _studyHubKey.currentState?.reload();
    if (index == 3) _myKey.currentState?.reload();
  }

  void switchToTab(int index) {
    _tabIndex.value = index;
    setState(() {
      _currentIndex = index;
    });
    if (index == 0) _studyHubKey.currentState?.reload();
    if (index == 3) _myKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: _pages,
              ),
            ),
            _BottomNavBar(
              items: _bottomNavItems,
              currentIndex: _currentIndex,
              onTap: _switchToTab,
            ),
        ],
      ),
    );
  }
}

/// 自定义底部导航栏：按屏幕尺寸自适应高度，统一处理安全区并加分隔线/阴影。
class _BottomNavBar extends StatelessWidget {
  final List<BottomNavigationBarItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _BottomNavBar({
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // 大屏（高度 ≥ 820 或很宽）适当加高，避免与内容区比例失调。
    final large = media.size.height >= 820 || media.size.width >= 430;
    final base = large ? 62.0 : 54.0;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAF5),
        border: const Border(
          top: BorderSide(color: Color(0xFFE8E0D5), width: 0.8),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: base,
          child: Row(
            children: List.generate(items.length, (i) {
              final selected = i == currentIndex;
              final item = items[i];
              final Widget icon = selected
                  ? (item.activeIcon ?? item.icon)
                  : item.icon;
              return Expanded(
                child: InkWell(
                  onTap: () => onTap(i),
                  borderRadius: BorderRadius.circular(10),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(width: 24, height: 24, child: Center(child: icon)),
                      const SizedBox(height: 2),
                      Text(
                        item.label ?? '',
                        style: TextStyle(
                          fontSize: selected ? 11.5 : 11,
                          color: selected
                              ? const Color(0xFF5D4037)
                              : const Color(0xFF424242),
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
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
      _ctrl.forward();
    } else {
      _ctrl.reverse();
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
          return Stack(
            children: [
              // 面板：从底部升起，顶部边缘滑到 AppBar 之下。
              Positioned(
                left: 0,
                right: 0,
                top: topInset + full * (1 - t),
                bottom: 0,
                child: child!,
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
                      child: const Text(
                        'AI',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF5d4037),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
        child: const DiscussionPage(),
      ),
    );
  }
}
