import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 外观模式：
/// warm  = 暖黄经典（米黄底 + 金棕点缀，原版配色）
/// plain = 素白简洁（纯白底 + 黑灰点缀）
enum AppearanceMode { warm, plain }

extension AppearanceModeLabel on AppearanceMode {
  String get label => this == AppearanceMode.warm ? '暖黄经典' : '素白清新';

  String get desc =>
      this == AppearanceMode.warm ? '米黄底 · 青绿点缀' : '纯白底 · 绿色点缀';
}

/// 一套完整的界面调色板。
/// 各页面原先散落的 `_primary/_gold/_bg/...` 常量统一收敛到这里的槽位。
class PaletteData {
  final Color primary;
  final Color accent;
  final Color accentDeep;
  final Color bg;
  final Color card;
  final Color text;
  final Color textSec;
  final Color textHint;
  final Color border;
  final Color divider;
  final Color borderSoft;
  final Color tintBg;
  final Color muted;
  final Color gradTop;
  final Color gradBot;
  /// 阅藏页面强调色：素白外观用绿色，暖黄外观用主色。
  final Color readingAccent;

  const PaletteData({
    required this.primary,
    required this.accent,
    required this.accentDeep,
    required this.bg,
    required this.card,
    required this.text,
    required this.textSec,
    required this.textHint,
    required this.border,
    required this.divider,
    required this.borderSoft,
    required this.tintBg,
    required this.muted,
    required this.gradTop,
    required this.gradBot,
    this.readingAccent = const Color(0xFF5B7D5A),
  });
}

class AppPalette extends ChangeNotifier {
  AppPalette._();

  static final AppPalette instance = AppPalette._();

  static const _prefKey = 'appearance_mode';

  /// 当前生效的调色板。页面代码用 `AppPalette.p.xxx` 取色。
  static PaletteData _current = warm;

  static PaletteData get p => _current;

  AppearanceMode _mode = AppearanceMode.warm;

  AppearanceMode get mode => _mode;

  bool get isPlain => _mode == AppearanceMode.plain;

  /// 暖黄经典：与重构前各页面硬编码值完全一致，视觉零变化。
  static const warm = PaletteData(
    primary: Color(0xFF5C4033),
    accent: Color(0xFFD4A06A),
    accentDeep: Color(0xFF9A6B3F),
    bg: Color(0xFFF5EDE3),
    card: Color(0xFFFFFAF5),
    text: Color(0xFF3E2723),
    textSec: Color(0xFF8B6B5A),
    textHint: Color(0xFFC4B5A8),
    border: Color(0xFFEBE1D6),
    divider: Color(0xFFE6DAC8),
    borderSoft: Color(0xFFEFE6DB),
    tintBg: Color(0xFFFFF3E0),
    muted: Color(0xFFD2C5B3),
    gradTop: Color(0xFFF3E8DB),
    gradBot: Color(0xFFF9F1E7),
    readingAccent: Color(0xFF5C4033),
  );

  /// 素白清新：白底配绿色点缀。
  static const plain = PaletteData(
    primary: Color(0xFF1A1A1A),
    accent: Color(0xFF5D7C5A),
    accentDeep: Color(0xFF3D5C3A),
    bg: Color(0xFFFBFBFB),
    card: Color(0xFFFFFFFF),
    text: Color(0xFF1C1C1C),
    textSec: Color(0xFF666666),
    textHint: Color(0xFFABABAB),
    border: Color(0xFFE8E8E8),
    // 分割线：与边框同档浅灰，白底上只留一道极淡的分隔（帖子流/个人主页等列表用）。
    divider: Color(0xFFE8E8E8),
    borderSoft: Color(0xFFEFEFEF),
    tintBg: Color(0xFFF2F2F2),
    muted: Color(0xFFD6D6D6),
    gradTop: Color(0xFFFFFFFF),
    gradBot: Color(0xFFF2F2F2),
    readingAccent: Color(0xFF5B7D5A),
  );

  /// 启动时读取用户保存的外观偏好（main 里 runApp 前调用）。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _apply(prefs.getString(_prefKey) == 'plain'
        ? AppearanceMode.plain
        : AppearanceMode.warm);
  }

  /// 切换外观：持久化 + 同步系统栏 + 通知全局刷新（即时生效，无需重启）。
  Future<void> setMode(AppearanceMode m) async {
    if (m == _mode) return;
    _apply(m);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefKey, m == AppearanceMode.warm ? 'warm' : 'plain');
    notifyListeners();
  }

  void _apply(AppearanceMode m) {
    _mode = m;
    _current = m == AppearanceMode.warm ? warm : plain;
    _syncSystemChrome();
  }

  /// 系统状态栏 / 底部导航栏颜色跟随外观。
  void _syncSystemChrome() {
    final bar = isPlain ? const Color(0xFFFBFBFB) : const Color(0xFFededed);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: bar,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: bar,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));
  }
}
