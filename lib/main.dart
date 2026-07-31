import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'theme.dart';
import 'sutra_list_page.dart';
import 'discussion_page.dart';
import 'splash_image_page.dart';
import 'study_hub_page.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

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
  runApp(const MyApp());
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
      home: WillPopScope(
        onWillPop: () async {
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
    if (_showMain) return const MainPage();
    return SplashImagePage(onFinished: _finishSplash);
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
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      StudyHubPage(key: _studyHubKey),
      const SutraListPage(),
      const DiscussionPage(),
    ];
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForResult();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
      label: '助手',
    ),
  ];

  void _switchToTab(int index) {
    setState(() {
      _currentIndex = index;
    });
    if (index == 0) _studyHubKey.currentState?.reload();
  }

  void switchToTab(int index) {
    setState(() {
      _currentIndex = index;
    });
    if (index == 0) _studyHubKey.currentState?.reload();
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
            BottomNavigationBar(
              currentIndex: _currentIndex,
              onTap: _switchToTab,
              backgroundColor: const Color(0xFFFFFAF5),
              selectedItemColor: const Color(0xFF5D4037),
              unselectedItemColor: const Color(0xFF424242),
              selectedLabelStyle: const TextStyle(
                fontSize: 11,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: 11,
              ),
              showUnselectedLabels: true,
              elevation: 0,
              type: BottomNavigationBarType.fixed,
              items: _bottomNavItems,
            ),
        ],
      ),
    );
  }
}
