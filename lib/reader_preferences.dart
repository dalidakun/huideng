import 'package:shared_preferences/shared_preferences.dart';

/// 阅读偏好统一存储。阅读页与设置页共用同一套键，保证设置即时生效。
class ReaderPreferences {
  static const String fontSizeKey = 'fontSize';
  static const String isDarkModeKey = 'isDarkMode';
  static const String lineHeightKey = 'reader_line_height';
  static const String pageModeKey = 'reader_page_mode';

  /// 翻页方式：0=纵向滚动，1=左右翻页。
  static const int pageModeScroll = 0;
  static const int pageModeFlip = 1;

  static Future<double> getFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.get(fontSizeKey);
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return 16.0;
  }

  static Future<void> setFontSize(double size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(fontSizeKey, size);
  }

  static Future<bool> isDarkMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(isDarkModeKey) ?? false;
  }

  static Future<void> setDarkMode(bool isDark) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(isDarkModeKey, isDark);
  }

  static Future<double> getLineHeight() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.get(lineHeightKey);
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return 1.8;
  }

  static Future<void> setLineHeight(double height) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(lineHeightKey, height);
  }

  static Future<int> getPageMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(pageModeKey) ?? pageModeScroll;
  }

  static Future<void> setPageMode(int mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(pageModeKey, mode);
  }
}
