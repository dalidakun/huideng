import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shanzhishi_store.dart';

/// 内置密咒名单（展示用起步名单；用户在「添加」里录的另存）。
const List<String> kBuiltInMantras = [
  '六字大明咒',
  '准提神咒',
  '大悲咒',
  '往生咒',
  '药师心咒',
  '文殊心咒',
  '金刚萨埵百字明咒',
  '绿度母心咒',
  '尊胜佛母心咒',
  '楞严咒',
  '黄财神心咒',
  '莲花生大士心咒',
  '白度母心咒',
  '不空绢索毗卢遮那佛大灌顶光真言',
  '金刚手菩萨心咒',
  '虚空藏菩萨真言',
  '地藏菩萨灭定业真言',
  '大白伞盖佛母心咒',
  '作明佛母心咒（咕噜咕列佛母心咒）',
  '秽迹金刚咒',
];

/// 密咒名号数据：内置名单 + 用户自建（本地持久化），与佛号名号同模式。
class ShanZhiShiMantraStore extends ChangeNotifier {
  ShanZhiShiMantraStore._();

  static final ShanZhiShiMantraStore instance = ShanZhiShiMantraStore._();

  static const _prefKey = 'shanzhishi_mantra_added';
  static const _detailKey = 'shanzhishi_mantra_details';
  static const _renameKey = 'shanzhishi_mantra_renames';
  static const _hiddenKey = 'shanzhishi_mantra_hidden';

  /// 用户自建的密咒（新添加的排最前，像佛号页那样新的先看到）。
  List<String> _added = [];

  /// 内置密咒的改名记录：内置原名 → 用户改成的名字（改回原名则删掉该项）。
  final Map<String, String> _renames = {};

  /// 被用户删掉的内置密咒原名（名单是常量删不动，展示时跳过）。
  Set<String> _hidden = {};

  /// 用户自建密咒的详情：经名 → (经文出处, 神咒原文)。
  final Map<String, ({String source, String text})> _details = {};

  bool loaded = false;

  /// 当前完整名单：用户自建在前、内置名单在后；重复名只保留一处。
  /// 内置条目显示的是用户改过的名字，被删掉的跳过。
  List<String> get mantras {
    final out = <String>[];
    final seen = <String>{};
    for (final m in [
      ..._added,
      ...kBuiltInMantras.where((b) => !_hidden.contains(b))
          .map((b) => _renames[b] ?? b),
    ]) {
      final key = m.trim();
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      out.add(m);
    }
    return out;
  }

  /// 这个显示名对应的内置原名（不是内置条目则返回 null）。
  String? _builtinOriginalOf(String displayName) {
    final shown = displayName.trim();
    if (kBuiltInMantras.contains(shown)) return shown;
    for (final e in _renames.entries) {
      if (e.value == shown) return e.key;
    }
    return null;
  }

  /// 某条密咒的经文出处（内置或未填写时为空串）。
  String sourceOf(String name) => _details[name.trim()]?.source ?? '';

  /// 某条密咒的神咒原文（内置或未填写时为空串）。
  String textOf(String name) => _details[name.trim()]?.text ?? '';

  /// 从本地恢复用户自建的密咒及其详情。
  Future<void> load() async {
    if (loaded) return;
    loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _added = prefs.getStringList(_prefKey) ?? const <String>[];
      _hidden = (prefs.getStringList(_hiddenKey) ?? const <String>[]).toSet();
      final renameRaw = prefs.getString(_renameKey);
      if (renameRaw != null && renameRaw.isNotEmpty) {
        final decoded = jsonDecode(renameRaw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            _renames[e.key.toString()] = e.value.toString();
          }
        }
      }
      final raw = prefs.getString(_detailKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            final v = e.value;
            if (v is List && v.length >= 2) {
              _details[e.key.toString()] = (
                source: v[0].toString(),
                text: v[1].toString(),
              );
            }
          }
        }
      }
    } catch (_) {
      _added = const <String>[];
      _renames.clear();
      _hidden.clear();
      _details.clear();
    }
    notifyListeners();
  }

  /// 新增一条用户密咒；与现有名单撞名返回 false，成功持久化后通知刷新。
  Future<bool> add(
    String name, {
    String source = '',
    String text = '',
  }) async {
    final key = name.trim();
    if (key.isEmpty || mantras.contains(key) || kBuiltInMantras.contains(key)) {
      return false;
    }
    _added = [key, ..._added];
    _details[key] = (source: source.trim(), text: text.trim());
    await _persist();
    notifyListeners();
    return true;
  }

  /// 编辑一条密咒：出处与原文随时可改，名称也能改（内置、自建都可改）。
  /// 新名与现有名单撞名（含别的内置原名）返回 false。
  Future<bool> update(
    String oldName, {
    String? newName,
    String source = '',
    String text = '',
  }) async {
    final oldKey = oldName.trim();
    final newKey = (newName ?? oldKey).trim();
    if (oldKey.isEmpty || newKey.isEmpty) return false;
    if (newKey != oldKey) {
      if (mantras.contains(newKey)) return false;
      final builtinOrig = _builtinOriginalOf(oldKey);
      // 自建条目不许改成某个内置的原名（即使那条内置已改过名）。
      if (builtinOrig == null &&
          (kBuiltInMantras.contains(newKey) || _renames.containsKey(newKey))) {
        return false;
      }
      // 内置条目只许改名到没被占用的名字，且不许挪用别的内置原名。
      if (builtinOrig != null &&
          kBuiltInMantras.contains(newKey) &&
          newKey != builtinOrig) {
        return false;
      }
    }
    final builtinOrig = _builtinOriginalOf(oldKey);
    if (newKey != oldKey) {
      if (builtinOrig != null) {
        // 内置条目改名：记住映射（改回原名则清掉），原名在名单里隐藏。
        if (newKey == builtinOrig) {
          _renames.remove(builtinOrig);
        } else {
          _renames[builtinOrig] = newKey;
        }
      } else {
        _added = [for (final m in _added) m == oldKey ? newKey : m];
      }
      if (_details.containsKey(oldKey)) {
        _details[newKey] = _details.remove(oldKey)!;
      }
    }
    _details[newKey] = (source: source.trim(), text: text.trim());
    await _persist();
    notifyListeners();
    return true;
  }

  /// 保存前的查重名单：与 [name] 完全同名、或摘掉通用尊称（口径与佛号查重
  /// 一致，见 [ShanZhiShiStore.genericNameTerms]）后仍有 ≥2 个相同字符的
  /// 现有密咒；完全同名排最前。[skip] 是编辑场景里自己的原名。
  List<String> findSimilarEntries(String name, {String? skip}) {
    final target = name.trim();
    if (target.isEmpty) return const [];
    final targetDistinct = ShanZhiShiStore.distinctName(target);
    final hits = <(int, String)>[]; // (相同字符数, 名字)
    final all = mantras;
    for (var i = 0; i < all.length; i++) {
      final other = all[i].trim();
      if (other.isEmpty || other == skip) continue;
      final n = other == target
          // 完全同名：不问长短，直接算命中（排最前）。
          ? target.runes.length + 1
          : ShanZhiShiStore.nameCommonChars(
              targetDistinct, ShanZhiShiStore.distinctName(other));
      if (n >= 2) hits.add((n, other));
    }
    hits.sort((a, b) => b.$1 != a.$1 ? b.$1 - a.$1 : 0);
    return [for (final h in hits) h.$2];
  }

  /// 把刚填写的 [source] / [text] 并进现有密咒 [name]（名字不变），
  /// 两条并成一条：出处/原文原有的内容一处不丢。返回是否成功。
  Future<bool> mergeInto(
    String name, {
    String source = '',
    String text = '',
  }) async {
    final key = name.trim();
    if (key.isEmpty || !mantras.contains(key)) return false;
    final old = _details[key] ?? (source: '', text: '');
    _details[key] = (
      source: _joinSource(old.source, source.trim()),
      text: _joinText(old.text, text.trim()),
    );
    await _persist();
    notifyListeners();
    return true;
  }

  /// 把 [drop] 这条的内容并进 [keep]，然后删掉 [drop]：两条并成一条。
  /// 保留刚输入的名字时用（[keep] 是刚存下的那条）。返回是否成功。
  Future<bool> mergeAndRemove(String keep, String drop) async {
    final k = keep.trim();
    final d = drop.trim();
    if (k.isEmpty || d.isEmpty || k == d) return false;
    if (!mantras.contains(k) || !mantras.contains(d)) return false;
    final moved = _details[d];
    if (moved != null) {
      final old = _details[k] ?? (source: '', text: '');
      _details[k] = (
        source: _joinSource(old.source, moved.source),
        text: _joinText(old.text, moved.text),
      );
    }
    return remove(d);
  }

  /// 出处合并：新的非空优先；两条不同且都有值时用「 / 」接上。
  static String _joinSource(String a, String b) {
    if (b.isEmpty) return a;
    if (a.isEmpty || a == b) return b;
    return '$a / $b';
  }

  /// 原文合并：新的非空优先；两条不同且都有值时空行接上（两段都留着）。
  static String _joinText(String a, String b) {
    if (b.isEmpty) return a;
    if (a.isEmpty || a == b) return b;
    return '$a\n\n$b';
  }

  /// 删除一条密咒：自建的从名单移除，内置的记进隐藏名单；详情一并清掉。
  Future<bool> remove(String name) async {
    final key = name.trim();
    if (key.isEmpty) return false;
    final builtinOrig = _builtinOriginalOf(key);
    if (builtinOrig != null) {
      _hidden.add(builtinOrig);
      _renames.remove(builtinOrig);
    } else if (_added.contains(key)) {
      _added = [for (final m in _added) if (m != key) m];
    } else {
      return false;
    }
    _details.remove(key);
    await _persist();
    notifyListeners();
    return true;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefKey, _added);
      await prefs.setStringList(_hiddenKey, _hidden.toList());
      await prefs.setString(_renameKey, jsonEncode(_renames));
      await prefs.setString(_detailKey, jsonEncode({
        for (final e in _details.entries) e.key: [e.value.source, e.value.text],
      }));
    } catch (_) {}
  }

  /// 测试用：清空用户自建记录（只动内存，供单测隔离）。
  void resetForTest() {
    _added = const <String>[];
    _renames.clear();
    _hidden.clear();
    _details.clear();
    loaded = false;
    notifyListeners();
  }
}
