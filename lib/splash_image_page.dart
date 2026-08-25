import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_palette.dart';

/// 启动时展示一张全屏图片一小段时间，然后进入主页。
///
/// 说明：
/// - 这是 Flutter 首帧后的"应用内启动页"，不受 Android 12 系统 Splash 图标尺寸限制
/// - 适合覆盖 Flutter 初始化/数据加载阶段可能出现的白屏/卡顿
class SplashImagePage extends StatefulWidget {
  const SplashImagePage({
    super.key,
    required this.onFinished,
    this.duration = const Duration(seconds: 2),
    this.assetPath = 'assets/images/splash.png',
  });

  final VoidCallback onFinished;
  final Duration duration;
  final String assetPath;

  @override
  State<SplashImagePage> createState() => _SplashImagePageState();
}

class _SplashImagePageState extends State<SplashImagePage> {
  Timer? _timer;
  bool _done = false;

  /// 状态栏/底部导航栏底色跟随外观：素白用近白，米黄保持原浅灰。
  Color get _barColor =>
      AppPalette.instance.isPlain ? const Color(0xFFFBFBFB) : const Color(0xFFededed);

  @override
  void initState() {
    super.initState();
    // 启动图全屏展示：隐藏状态栏（时间/信号/WiFi）与底部导航栏，
    // 整块屏幕只显示启动图。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _timer = Timer(widget.duration, () {
      if (!mounted || _done) return;
      _done = true;
      widget.onFinished();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    // 启动图结束，恢复状态栏/导航栏显示。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: _barColor,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: _barColor,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: _barColor,
        body: SizedBox.expand(
          child: Image.asset(
            widget.assetPath,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
          ),
        ),
      ),
    );
  }
}


