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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

  final List<Widget> _pages = [
    const StudyHubPage(),
    const SutraListPage(),
    const DiscussionPage(),
  ];

  @override
  void initState() {
    super.initState();
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
    const BottomNavigationBarItem(
      icon: Icon(Icons.auto_stories_outlined),
      activeIcon: Icon(Icons.auto_stories),
      label: '修学',
    ),
    BottomNavigationBarItem(
      icon: Image.asset('assets/images/sutra_book.png', width: 18, height: 18),
      activeIcon: Image.asset('assets/images/sutra_book_selected.png', width: 18, height: 18),
      label: '经文',
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
  }

  void switchToTab(int index) {
    setState(() {
      _currentIndex = index;
    });
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
            Container(
              height: 1,
              color: const Color(0xFFF0F0F0),
            ),
            BottomNavigationBar(
              currentIndex: _currentIndex,
              onTap: _switchToTab,
              backgroundColor: const Color(0xFFf7f7f7),
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
