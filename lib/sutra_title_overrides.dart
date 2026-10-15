import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_notes_service.dart';
import 'sutra_downloader.dart';

/// 管理员「编辑经文」订正过的经名覆盖表（CBETA 编号 → 标题）。
///
/// 云端 [CloudNotesService.getSutraEditTitles] 批量下发，本地 prefs 缓存一份，
/// 供搜索/列表/最近阅读/阅读页同步取用（显示名覆盖，存储键仍是原经名/编号，
/// 不影响笔记、收藏、已读等按经名存储的数据）。
///
/// 取用方在渲染显示名前调用 [forTitle]，命中则直接用覆盖标题。
class SutraTitleOverrides {
  SutraTitleOverrides._();

  static const String _prefKey = 'sutra_title_overrides';

  static Map<String, String> _byId = const {};

  /// 是否已从本地缓存/云端初始化过（未初始化时 [forTitle] 恒返回 null）。
  static bool _loaded = false;

  static bool get isLoaded => _loaded;

  /// 按 CBETA 编号取覆盖标题；无覆盖返回 null。
  static String? forId(String? id) {
    if (id == null || id.isEmpty) return null;
    final v = _byId[id];
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 按经名（可带 CBETA 编号）取覆盖标题；无覆盖返回 null。
  static String? forTitle(String? title) {
    if (title == null || title.isEmpty) return null;
    return forId(SutraDownloader.extractId(title, null));
  }

  /// 确保已装载本地缓存（幂等，首次调用同步读 prefs）。
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _byId = {
            for (final e in decoded.entries)
              e.key.toString(): e.value.toString(),
          };
        }
      }
    } catch (_) {
      // 缓存损坏：保持空表，等待云端刷新。
    }
  }

  /// 从云端刷新覆盖表并写入本地缓存；失败时保留既有缓存。
  static Future<void> refresh() async {
    try {
      final map = await CloudNotesService.instance.getSutraEditTitles();
      _byId = map;
      _loaded = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(map));
    } catch (_) {
      // 静默降级：使用本地缓存/空表。
    }
  }

  /// 管理员本地保存后立即生效（并写入缓存），供界面即时反映。
  /// [title] 为空表示清除该经的覆盖。
  static Future<void> setLocal(String id, String? title) async {
    final next = Map<String, String>.from(_byId);
    final clean = title?.trim() ?? '';
    if (clean.isEmpty) {
      next.remove(id);
    } else {
      next[id] = clean;
    }
    _byId = next;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(next));
    } catch (_) {
      // 缓存写入失败不影响本次会话内的内存生效。
    }
  }
}
