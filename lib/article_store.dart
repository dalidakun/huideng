import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 文章列表地址：留空则只用 App 内置 + 本机添加的文章。
///
/// 建议放在国内可访问的静态地址（例如你自己站点上的 `articles.json`），
/// 这样没有网络加速的用户也能拉到最新文章。格式：
/// ```json
/// { "articles": [ { "title": "...", "url": "https://mp.weixin.qq.com/s/...", "source": "微信公众号", "date": "2026-10-29" } ] }
/// ```
const String kArticleListUrl = '';

/// 一篇文章：只需要标题和链接，点击后 App 内 WebView 打开。
class ArticleItem {
  final String title;
  final String url;

  /// 来源标签：微信公众号 / 知乎 / 其他。
  final String source;
  final String date;

  const ArticleItem({
    required this.title,
    required this.url,
    this.source = '',
    this.date = '',
  });

  factory ArticleItem.fromJson(Map<String, dynamic> json) => ArticleItem(
        title: (json['title'] ?? '').toString().trim(),
        url: (json['url'] ?? '').toString().trim(),
        source: (json['source'] ?? '').toString().trim(),
        date: (json['date'] ?? '').toString().trim(),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        if (source.isNotEmpty) 'source': source,
        if (date.isNotEmpty) 'date': date,
      };
}

/// 文章仓库：内置文章 + 云端 articles.json + 本机手动添加，三者合并。
class ArticleStore extends ChangeNotifier {
  ArticleStore._();

  static final ArticleStore instance = ArticleStore._();

  static const String _cacheKey = 'article_list_v1';
  static const String _localKey = 'article_list_local_v1';

  List<ArticleItem> _items = const [];
  bool _loaded = false;
  Future<void>? _pending;

  List<ArticleItem> get items => _items;

  bool get loaded => _loaded;

  bool get hasItems => _items.isNotEmpty;

  Future<void> load({bool force = false}) {
    final pending = _pending;
    if (pending != null) return pending;
    final future = _load(force).whenComplete(() => _pending = null);
    _pending = future;
    return future;
  }

  Future<void> _load(bool force) async {
    final prefs = await SharedPreferences.getInstance();
    final merged = <ArticleItem>[];

    // 1) 云端缓存 / 云端
    final cached = prefs.getString(_cacheKey);
    if (cached != null && cached.trim().isNotEmpty) {
      merged.addAll(_parse(cached));
    }
    if (kArticleListUrl.isNotEmpty) {
      try {
        final resp = await http
            .get(Uri.parse(kArticleListUrl))
            .timeout(const Duration(seconds: 5));
        if (resp.statusCode == 200) {
          final body = utf8.decode(resp.bodyBytes);
          final remote = _parse(body);
          if (remote.isNotEmpty) {
            merged
              ..removeWhere((a) => remote.any((r) => r.url == a.url))
              ..addAll(remote);
            await prefs.setString(_cacheKey, body);
          }
        }
      } catch (_) {
        // 云端拉不到就用缓存 / 本地。
      }
    }

    // 2) 本机手动添加
    final local = prefs.getStringList(_localKey) ?? const [];
    for (final raw in local) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final item = ArticleItem.fromJson(Map<String, dynamic>.from(decoded));
          if (item.url.isNotEmpty &&
              !merged.any((a) => a.url == item.url)) {
            merged.add(item);
          }
        }
      } catch (_) {}
    }

    // 3) 内置兜底
    for (final item in kDefaultArticles) {
      if (!merged.any((a) => a.url == item.url)) merged.add(item);
    }

    _items = List.unmodifiable(merged);
    _loaded = true;
    notifyListeners();
  }

  /// 本机添加一篇（用于测试 / 个人收藏）。
  Future<void> add(ArticleItem item) async {
    if (item.url.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final local = prefs.getStringList(_localKey) ?? <String>[];
    final encoded = jsonEncode(item.toJson());
    local.removeWhere((raw) {
      try {
        final m = jsonDecode(raw);
        return m is Map && m['url'] == item.url;
      } catch (_) {
        return false;
      }
    });
    local.insert(0, encoded);
    await prefs.setStringList(_localKey, local);
    if (!_items.any((a) => a.url == item.url)) {
      _items = List.unmodifiable([item, ..._items]);
      notifyListeners();
    }
  }

  Future<void> remove(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final local = prefs.getStringList(_localKey) ?? <String>[];
    local.removeWhere((raw) {
      try {
        final m = jsonDecode(raw);
        return m is Map && m['url'] == url;
      } catch (_) {
        return false;
      }
    });
    await prefs.setStringList(_localKey, local);
    _items = List.unmodifiable(_items.where((a) => a.url != url));
    notifyListeners();
  }

  List<ArticleItem> _parse(String text) {
    try {
      final decoded = jsonDecode(text);
      final raw = decoded is Map ? decoded['articles'] : decoded;
      if (raw is! List) return const [];
      final out = <ArticleItem>[];
      for (final a in raw) {
        if (a is Map) {
          final item = ArticleItem.fromJson(Map<String, dynamic>.from(a));
          if (item.url.isNotEmpty) out.add(item);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}

/// 内置文章（没有云端清单时至少有几篇可看）。
const List<ArticleItem> kDefaultArticles = [];

/// 从链接猜一个来源标签，列表里显示「微信公众号 / 知乎 / 网页」。
String articleSourceOf(String url) {
  final u = url.toLowerCase();
  if (u.contains('mp.weixin.qq.com')) return '微信公众号';
  if (u.contains('zhihu.com')) return '知乎';
  if (u.contains('bilibili.com')) return 'B站';
  if (u.contains('xiaohongshu.com')) return '小红书';
  return '网页';
}
