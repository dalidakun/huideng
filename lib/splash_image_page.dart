import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  static const _overlayStyle = SystemUiOverlayStyle(
    statusBarColor: Color(0xFFededed),
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFFededed),
    systemNavigationBarIconBrightness: Brightness.dark,
  );

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, () {
      if (!mounted || _done) return;
      _done = true;
      widget.onFinished();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _overlayStyle,
      child: Scaffold(
        backgroundColor: const Color(0xFFededed),
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


