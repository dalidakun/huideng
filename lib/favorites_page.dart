import 'package:flutter/material.dart';

import 'favorite_sutras_page.dart';

import 'app_palette.dart';
Color get _bg => AppPalette.p.bg;
Color get _text => AppPalette.p.text;
class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppPalette.p.gradTop, AppPalette.p.gradBot],
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 20, 18),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.arrow_back_ios_new, color: _text, size: 20),
                    ),
                    const SizedBox(width: 4),
                    Text('收藏', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
                  ],
                ),
              ),
            ),
          ),
          const Expanded(
            child: FavoriteSutrasPage(embedded: true),
          ),
        ],
      ),
    );
  }
}
