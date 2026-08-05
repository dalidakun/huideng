import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 经书收藏读写工具：与 `sutras_list.json`（经藏页持久化文件）保持一致。
/// 阅读页 / 学习中心等页面用它切换收藏，改动会立刻出现在「我的收藏」。
class SutraFavorites {
  SutraFavorites._();

  static Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}${Platform.pathSeparator}sutras_list.json');
  }

  static Future<List<Map<String, dynamic>>> _readList() async {
    final f = await _file();
    if (!await f.exists()) return [];
    try {
      final decoded = jsonDecode(await f.readAsString()) as List<dynamic>;
      return decoded.map((e) => (e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static int _indexOf(
      List<Map<String, dynamic>> list, String title, String? filePath) {
    if (title.isNotEmpty) {
      final byTitle = list.indexWhere((e) => e['title'] == title);
      if (byTitle >= 0) return byTitle;
    }
    if (filePath != null && filePath.isNotEmpty) {
      final byPath = list.indexWhere((e) => e['filePath'] == filePath);
      if (byPath >= 0) return byPath;
    }
    return -1;
  }

  static Future<bool> isFavorite(String title, [String? filePath]) async {
    final list = await _readList();
    final idx = _indexOf(list, title, filePath);
    return idx >= 0 && list[idx]['isFavorite'] == true;
  }

  /// 切换收藏状态，返回切换后的状态（true=已收藏）。
  static Future<bool> toggle(String title, [String? filePath]) async {
    final f = await _file();
    var list = await _readList();
    final idx = _indexOf(list, title, filePath);
    bool newState;
    if (idx >= 0) {
      final wasFav = list[idx]['isFavorite'] == true;
      newState = !wasFav;
      list[idx]['isFavorite'] = newState;
      list[idx]['favoriteTime'] =
          newState ? DateTime.now().toIso8601String() : null;
    } else {
      // 不在经书列表中（如导入/直开文本），新增一条，保证能出现在「我的收藏」。
      newState = true;
      list.add({
        'title': title,
        'size': '',
        'isPinned': false,
        'isRead': false,
        'isFavorite': true,
        'filePath': filePath,
        'folder': null,
        'favoriteTime': DateTime.now().toIso8601String(),
        'readTime': null,
      });
    }
    // 原子写：先写临时文件再改名替换，避免并发读取读到写到一半的损坏文件。
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(list), flush: true);
    if (await f.exists()) {
      await f.delete();
    }
    await tmp.rename(f.path);
    await syncStatePref(title);
    return newState;
  }

  /// 将某本经书在 `sutras_list.json` 中的最新状态同步进 `sutra_states` pref。
  ///
  /// 经藏页在每次加载时会把 pref 里的云端状态 OR 合并回列表（见
  /// `SutraListPage._applyRestoredSutraStates`），若不更新 pref，
  /// 已取消的收藏 / 已撤销的已读会被旧状态“复活”并重新写回文件。
  /// 此方法按 `_collectSutraStates` 的格式重建该经书条目。
  static Future<void> syncStatePref(String title) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('sutra_states');
      if (raw == null || raw.isEmpty) return;
      final states = jsonDecode(raw);
      if (states is! Map) return;

      final list = await _readList();
      final idx = _indexOf(list, title, null);
      final s = idx >= 0 ? list[idx] : null;
      final r = s?['isRead'] == true;
      final f = s?['isFavorite'] == true;
      final p = s?['isPinned'] == true;
      final rt = s?['readTime']?.toString() ?? '';
      final ft = s?['favoriteTime']?.toString() ?? '';
      final hasRt = rt.isNotEmpty;
      final hasFt = ft.isNotEmpty;

      final rebuilt = <String, dynamic>{
        if (r) 'r': true,
        if (f) 'f': true,
        if (p) 'p': true,
        if (hasRt) 'rt': rt,
        if (hasFt) 'ft': ft,
      };
      if (rebuilt.isEmpty) {
        states.remove(title);
      } else {
        states[title] = rebuilt;
      }
      await prefs.setString('sutra_states', jsonEncode(states));
    } catch (_) {
      // 同步失败不影响收藏本身。
    }
  }
}
