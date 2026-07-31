import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFFededed),
      primaryColor: const Color(0xFF5D4037),
      
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF5D4037),
        primary: const Color(0xFF5D4037),
        surface: const Color(0xFFFFFFFF),
        onSurface: const Color(0xFF212121),
        brightness: Brightness.light,
      ),
      
      textTheme: TextTheme(
        bodyLarge: const TextStyle(
          color: Color(0xFF212121),
          fontSize: 16,
        ),
        bodyMedium: const TextStyle(
          color: Color(0xFF212121),
          fontSize: 14,
        ),
        titleMedium: const TextStyle(
          color: Color(0xFF212121),
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFededed),
        foregroundColor: Color(0xFF212121),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Color(0xFF212121),
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(
          color: Color(0xFF212121),
        ),
      ),
      
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFFf7f7f7),
        selectedItemColor: Color(0xFF5D4037),
        unselectedItemColor: Color(0xFF424242),
        selectedLabelStyle: TextStyle(
          fontWeight: FontWeight.bold,
        ),
        showUnselectedLabels: true,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
      ),
      
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 1.5,
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      
      dividerTheme: const DividerThemeData(
        color: Color(0xFFBDBDBD),
        thickness: 0.5,
        space: 1,
      ),
      
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.all(16),
        titleTextStyle: TextStyle(
          color: Color(0xFF212121),
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        subtitleTextStyle: TextStyle(
          color: Color(0xFF424242),
          fontSize: 14,
        ),
      ),
      
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
    );
  }
}
