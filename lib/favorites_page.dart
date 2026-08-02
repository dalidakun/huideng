import 'package:flutter/material.dart';

import 'favorite_notes_page.dart';
import 'favorite_sutras_page.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);

/// 「我的收藏」入口：经书收藏 + 笔记收藏 两个标签页。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 10, 20, 6),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back_ios_new, color: _text, size: 20),
                        ),
                        const SizedBox(width: 4),
                        const Text('我的收藏', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
                      ],
                    ),
                  ),
                  TabBar(
                    controller: _tab,
                    indicatorColor: _gold,
                    labelColor: _text,
                    unselectedLabelColor: _textSec,
                    labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    unselectedLabelStyle: const TextStyle(fontSize: 15),
                    tabs: const [
                      Tab(text: '经书'),
                      Tab(text: '笔记'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: const [
                FavoriteSutrasPage(embedded: true),
                FavoriteNotesPage(embedded: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
