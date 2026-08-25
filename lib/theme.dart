import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 应用基线主题。页面级配色直接取 [AppPalette.p]；
/// 这里的 ThemeData 主要作用于对话框、按钮、输入框等 Material 组件。
class AppTheme {
  AppTheme._();

  static ThemeData get lightTheme {
    final p = AppPalette.p;
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: p.bg,
      primaryColor: p.primary,

      colorScheme: ColorScheme.fromSeed(
        seedColor: p.primary,
        primary: p.primary,
        surface: p.card,
        onSurface: p.text,
        brightness: Brightness.light,
      ),

      textTheme: TextTheme(
        bodyLarge: TextStyle(
          color: p.text,
          fontSize: 16,
        ),
        bodyMedium: TextStyle(
          color: p.text,
          fontSize: 14,
        ),
        titleMedium: TextStyle(
          color: p.text,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        foregroundColor: p.text,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: p.text,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(
          color: p.text,
        ),
      ),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: p.card,
        selectedItemColor: p.accent,
        unselectedItemColor: p.textSec,
        selectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.bold,
        ),
        showUnselectedLabels: true,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
      ),

      cardTheme: CardThemeData(
        color: p.card,
        elevation: 1.5,
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: p.divider,
        thickness: 0.5,
        space: 1,
      ),

      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.all(16),
        titleTextStyle: TextStyle(
          color: p.text,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        subtitleTextStyle: TextStyle(
          color: p.textSec,
          fontSize: 14,
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: p.card,
        titleTextStyle: TextStyle(
          color: p.text,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),

      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
    );
  }
}
