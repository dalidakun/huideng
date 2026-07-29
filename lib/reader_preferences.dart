import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReaderPreferences {
  static const String _fontSizeKey = 'reader_font_size';
  static const String _isNightModeKey = 'reader_night_mode';
  static const String _progressKeyPrefix = 'progress_';

  static Future<double> getFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_fontSizeKey) ?? 14.0;
  }

  static Future<void> setFontSize(double size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontSizeKey, size);
  }

  static Future<bool> isNightMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_isNightModeKey) ?? false;
  }

  static Future<void> setNightMode(bool isNight) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_isNightModeKey, isNight);
  }

  static Future<int?> getProgress(String title) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('$_progressKeyPrefix${title}');
  }

  static Future<void> setProgress(String title, int position) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_progressKeyPrefix${title}', position);
  }

  static Future<void> clearProgress(String title) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_progressKeyPrefix${title}');
  }
}
