import 'package:flutter/material.dart';

import 'favorite_sutras_page.dart';

const Color _bg = Color(0xFFF5EDE3);
const Color _text = Color(0xFF3E2723);

/// 「收藏」：仅展示收藏的经书（笔记收藏不再显示）。
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
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFF3E8DB), Color(0xFFF9F1E7)],
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
                      icon: const Icon(Icons.arrow_back_ios_new, color: _text, size: 20),
                    ),
                    const SizedBox(width: 4),
                    const Text('收藏', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
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
