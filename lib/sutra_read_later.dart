import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 经书「稍后阅读」读写工具：与 `sutras_list.json`（经藏页持久化文件）保持一致。
/// 阅读页 / 学习中心 / 经藏页等页面用它切换稍后阅读状态。
class SutraReadLater {
  SutraReadLater._();

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

  static Future<bool> isReadLater(String title, [String? filePath]) async {
    final list = await _readList();
    final idx = _indexOf(list, title, filePath);
    return idx >= 0 && list[idx]['isReadLater'] == true;
  }

  /// 切换稍后阅读状态，返回切换后的状态（true=已标记）。
  static Future<bool> toggle(String title, [String? filePath]) async {
    final f = await _file();
    var list = await _readList();
    final idx = _indexOf(list, title, filePath);
    bool newState;
    if (idx >= 0) {
      final wasRL = list[idx]['isReadLater'] == true;
      newState = !wasRL;
      list[idx]['isReadLater'] = newState;
      list[idx]['readLaterTime'] =
          newState ? DateTime.now().toIso8601String() : null;
    } else {
      newState = true;
      list.add({
        'title': title,
        'size': '',
        'isPinned': false,
        'isRead': false,
        'isFavorite': false,
        'isReadLater': true,
        'filePath': filePath,
        'folder': null,
        'favoriteTime': null,
        'readTime': null,
        'readLaterTime': DateTime.now().toIso8601String(),
      });
    }
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(list), flush: true);
    if (await f.exists()) {
      await f.delete();
    }
    await tmp.rename(f.path);
    await syncStatePref(title);
    return newState;
  }

  /// 同步状态到 SharedPreferences（与 SutraFavorites 相同格式）。
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
      final rl = s?['isReadLater'] == true;
      final rt = s?['readTime']?.toString() ?? '';
      final ft = s?['favoriteTime']?.toString() ?? '';
      final rlt = s?['readLaterTime']?.toString() ?? '';
      final hasRt = rt.isNotEmpty;
      final hasFt = ft.isNotEmpty;
      final hasRlt = rlt.isNotEmpty;

      final rebuilt = <String, dynamic>{
        if (r) 'r': true,
        if (f) 'f': true,
        if (p) 'p': true,
        if (rl) 'rl': true,
        if (hasRt) 'rt': rt,
        if (hasFt) 'ft': ft,
        if (hasRlt) 'rlt': rlt,
      };
      if (rebuilt.isEmpty) {
        states.remove(title);
      } else {
        states[title] = rebuilt;
      }
      await prefs.setString('sutra_states', jsonEncode(states));
    } catch (_) {
      // 同步失败不影响稍后阅读本身。
    }
  }
}
