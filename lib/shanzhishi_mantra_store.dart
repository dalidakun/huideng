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

/// 一条用户自建密咒的稳定身份：名字可以重、可以改，条目靠 [id] 区分。
class _AddedMantra {
  _AddedMantra({required this.id, required this.name});

  final String id;
  String name;
}

/// 展示/编辑时的一条密咒：内部键 + 显示名（同名条目也各有各的键）。
class _MantraEntry {
  const _MantraEntry({
    required this.key,
    required this.name,
    required this.builtin,
    this.original,
  });

  final String key;
  final String name;
  final bool builtin;

  /// 内置条目的原名（用户改过名时与 [name] 不同）；用户自建为 null。
  final String? original;
}

/// 神咒原文上的一条批注：作用于 [start,end) 这段文字。
/// [ruby] 是注音（显示在文字上方），[note] 是备注（显示在文字下方）。
@immutable
class MantraAnnotation {
  const MantraAnnotation({
    required this.start,
    required this.end,
    this.ruby = '',
    this.note = '',
  });

  final int start;
  final int end;
  final String ruby;
  final String note;

  bool get hasRuby => ruby.trim().isNotEmpty;

  bool get hasNote => note.trim().isNotEmpty;

  bool get isValid => end > start && (hasRuby || hasNote);

  MantraAnnotation copyWith({
    int? start,
    int? end,
    String? ruby,
    String? note,
  }) {
    return MantraAnnotation(
      start: start ?? this.start,
      end: end ?? this.end,
      ruby: ruby ?? this.ruby,
      note: note ?? this.note,
    );
  }

  Map<String, Object> toJson() => {
        's': start,
        'e': end,
        if (hasRuby) 'r': ruby,
        if (hasNote) 'n': note,
      };

  /// 本地/云端旧数据里可能缺字段或越界，交给调用方再按原文长度夹一次。
  static MantraAnnotation? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final start = int.tryParse(raw['s']?.toString() ?? '');
    final end = int.tryParse(raw['e']?.toString() ?? '');
    if (start == null || end == null) return null;
    final ann = MantraAnnotation(
      start: start,
      end: end,
      ruby: (raw['r'] ?? '').toString(),
      note: (raw['n'] ?? '').toString(),
    );
    return ann.isValid ? ann : null;
  }
}

/// 密咒名号数据：内置名单 + 用户自建（本地持久化），与佛号名号同模式。
///
/// 用户自建条目按稳定 id 存，名字允许重复（「保存两者」时两条同名密咒
/// 各有一份出处/原文/人天利益）；内置条目按原名存，只维护改名与隐藏。
class ShanZhiShiMantraStore extends ChangeNotifier {
  ShanZhiShiMantraStore._();

  static final ShanZhiShiMantraStore instance = ShanZhiShiMantraStore._();

  static const _prefKey = 'shanzhishi_mantra_added';
  static const _entriesKey = 'shanzhishi_mantra_entries';
  static const _detailKey = 'shanzhishi_mantra_details';
  static const _renameKey = 'shanzhishi_mantra_renames';
  static const _hiddenKey = 'shanzhishi_mantra_hidden';

  /// 用户自建的密咒（新添加的排最前，像佛号页那样新的先看到）。
  final List<_AddedMantra> _added = [];

  /// 内置密咒的改名记录：内置原名 → 用户改成的名字（改回原名则删掉该项）。
  final Map<String, String> _renames = {};

  /// 被用户删掉的内置密咒原名（名单是常量删不动，展示时跳过）。
  Set<String> _hidden = {};

  /// 详情：内部键（`a:id` / `b:内置原名`）→
  /// (关联经文, 原文, 人天利益段落（平铺），按经文分组的人天利益, 原文批注)。
  final Map<
      String,
      ({
        List<String> sources,
        String source,
        String text,
        List<String> benefit,
        Map<String, List<String>> benefitBySutra,
        List<MantraAnnotation> annotations,
      })> _details = {};

  var _seq = 0;

  bool loaded = false;

  String _addedKey(_AddedMantra m) => 'a:${m.id}';

  String _builtinKey(String original) => 'b:$original';

  String _newId() {
    _seq++;
    return '${DateTime.now().microsecondsSinceEpoch}_$_seq';
  }

  /// 当前完整名单：用户自建在前、内置名单在后；同名条目各算一条。
  List<_MantraEntry> get _items {
    final out = <_MantraEntry>[
      for (final m in _added)
        _MantraEntry(
          key: _addedKey(m),
          name: m.name,
          builtin: false,
        ),
      for (final b in kBuiltInMantras)
        if (!_hidden.contains(b))
          _MantraEntry(
            key: _builtinKey(b),
            name: _renames[b] ?? b,
            builtin: true,
            original: b,
          ),
    ];
    return out;
  }

  /// 当前完整名单的显示名（同名条目会各出现一次）。
  List<String> get mantras => [for (final e in _items) e.name];

  int get length => _items.length;

  /// 第 [index] 条密咒的显示名。
  String? nameAt(int index) {
    final items = _items;
    return index >= 0 && index < items.length ? items[index].name : null;
  }

  /// 第 [index] 条密咒的内部键（同名条目靠它区分）。
  String? keyAt(int index) {
    final items = _items;
    return index >= 0 && index < items.length ? items[index].key : null;
  }

  /// 内部键对应的显示名。
  String? nameOfKey(String key) {
    for (final e in _items) {
      if (e.key == key) return e.name;
    }
    return null;
  }

  _MantraEntry? _resolve(String name, [String? key]) {
    final items = _items;
    if (key != null) {
      for (final e in items) {
        if (e.key == key) return e;
      }
      return null;
    }
    final trimmed = name.trim();
    for (final e in items) {
      if (e.name == trimmed) return e;
    }
    return null;
  }

  /// 某条密咒的关联经文（内置或未填写时为空表）。
  List<String> sourcesOf(String name) => sourcesOfKey(_resolve(name)?.key);

  /// 某条密咒的经文出处（内置或未填写时为空串）。多部经用「 / 」接成一串。
  String sourceOf(String name) => sourceOfKey(_resolve(name)?.key);

  /// 某条密咒的神咒原文（内置或未填写时为空串）。
  String textOf(String name) => textOfKey(_resolve(name)?.key);

  /// 某条密咒的人天利益段落（内置或未填写时为空表，平铺）。
  List<String> benefitOf(String name) => benefitOfKey(_resolve(name)?.key);

  /// 某条密咒按经文分组的人天利益。
  Map<String, List<String>> benefitBySutraOf(String name) =>
      benefitBySutraOfKey(_resolve(name)?.key);

  /// 某条密咒的神咒原文批注（未填写时为空表）。
  List<MantraAnnotation> annotationsOf(String name) =>
      annotationsOfKey(_resolve(name)?.key);

  /// 按内部键取出的关联经文。
  List<String> sourcesOfKey(String? key) {
    final d = _details[key];
    if (d == null) return const [];
    if (d.sources.isNotEmpty) return d.sources;
    if (d.source.isNotEmpty) return [d.source];
    return const [];
  }

  /// 按内部键取出的经文出处：多部经用「 / 」接成一串（没有则退回首条）。
  String sourceOfKey(String? key) {
    final list = sourcesOfKey(key);
    if (list.isNotEmpty) return list.join(' / ');
    return _details[key]?.source ?? '';
  }

  /// 按内部键取出的神咒原文。
  String textOfKey(String? key) => _details[key]?.text ?? '';

  /// 按内部键取出的人天利益段落（平铺）。
  List<String> benefitOfKey(String? key) => _details[key]?.benefit ?? const [];

  /// 按内部键取出按经文分组的人天利益。
  Map<String, List<String>> benefitBySutraOfKey(String? key) =>
      _details[key]?.benefitBySutra ?? const {};

  /// 按内部键取出的神咒原文批注。
  List<MantraAnnotation> annotationsOfKey(String? key) =>
      _details[key]?.annotations ?? const [];

  /// 从本地恢复用户自建的密咒及其详情。
  Future<void> load({bool force = false}) async {
    if (loaded && !force) return;
    if (force) {
      _added.clear();
      _renames.clear();
      _hidden.clear();
      _details.clear();
      _newFormat = false;
    }
    loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
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
      await _loadEntries(prefs);
      await _loadDetails(prefs);
    } catch (_) {
      _added.clear();
      _renames.clear();
      _hidden.clear();
      _details.clear();
    }
    notifyListeners();
  }

  /// 云端恢复后强制重读，避免页面停留在同步前的旧名单。
  Future<void> reload() => load(force: true);

  bool _newFormat = false;

  Future<void> _loadEntries(SharedPreferences prefs) async {
    final raw = prefs.getString(_entriesKey);
    if (raw != null && raw.isNotEmpty) {
      _newFormat = true;
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final e in decoded) {
          if (e is! Map) continue;
          final id = (e['id'] ?? '').toString().trim();
          final name = (e['name'] ?? '').toString().trim();
          if (id.isEmpty || name.isEmpty) continue;
          _added.add(_AddedMantra(id: id, name: name));
        }
      }
      return;
    }
    // 旧版：只有名字列表。逐条补一个稳定 id，详情加载时再按名字认领。
    final names = prefs.getStringList(_prefKey) ?? const <String>[];
    for (var i = 0; i < names.length; i++) {
      final name = names[i].trim();
      if (name.isEmpty) continue;
      _added.add(_AddedMantra(id: 'legacy_$i', name: name));
    }
  }

  Future<void> _loadDetails(SharedPreferences prefs) async {
    final raw = prefs.getString(_detailKey);
    if (raw == null || raw.isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    for (final e in decoded.entries) {
      final v = e.value;
      if (v is! List || v.length < 2) continue;
      final benefit = <String>[];
      if (v.length >= 3 && v[2] is List) {
        for (final t in v[2] as List) {
          final s = t.toString().trim();
          if (s.isNotEmpty && !benefit.contains(s)) benefit.add(s);
        }
      }
      final detail = (
        sources: () {
          if (v.length >= 5 && v[4] is List) {
            final list = <String>[];
            for (final t in v[4] as List) {
              final s = t.toString().trim();
              if (s.isNotEmpty && !list.contains(s)) list.add(s);
            }
            if (list.isNotEmpty) return list;
          }
          final src = v[0].toString().trim();
          return src.isEmpty ? const <String>[] : [src];
        }(),
        source: v[0].toString(),
        text: v[1].toString(),
        benefit: benefit,
        benefitBySutra: () {
          if (v.length >= 6 && v[5] is Map) {
            final map = <String, List<String>>{};
            for (final e in (v[5] as Map).entries) {
              final key = e.key.toString().trim();
              if (key.isEmpty || e.value is! List) continue;
              final list = <String>[];
              for (final t in e.value as List) {
                final s = t.toString().trim();
                if (s.isNotEmpty && !list.contains(s)) list.add(s);
              }
              if (list.isNotEmpty) map[key] = list;
            }
            return map;
          }
          return const <String, List<String>>{};
        }(),
        annotations: _parseAnnotations(v.length >= 4 ? v[3] : null),
      );
      final rawKey = e.key.toString();
      if (_newFormat) {
        _details[rawKey] = detail;
      } else {
        // 旧版的键是显示名：用户条目归到它的新键，内置条目归到原名键。
        final added = _firstAddedNamed(rawKey);
        if (added != null) {
          _details[_addedKey(added)] = detail;
          continue;
        }
        final builtin = _builtinOriginalOf(rawKey);
        if (builtin != null) _details[_builtinKey(builtin)] = detail;
      }
    }
  }

  _AddedMantra? _firstAddedNamed(String name) {
    for (final m in _added) {
      if (m.name == name) return m;
    }
    return null;
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

  /// 新增一条用户密咒；不允许重名时撞名返回 false。
  /// [allowDuplicate] 为 true 时（用户选了「保存两者」）同名也另起一条。
  Future<bool> add(
    String name, {
    String source = '',
    List<String>? sources,
    String text = '',
    List<String> benefit = const [],
    Map<String, List<String>>? benefitBySutra,
    List<MantraAnnotation> annotations = const [],
    bool allowDuplicate = false,
  }) async {
    final key = name.trim();
    if (key.isEmpty) return false;
    if (!allowDuplicate && mantras.contains(key)) return false;
    final entry = _AddedMantra(id: _newId(), name: key);
    _added.insert(0, entry);
    final trimmedText = text.trim();
    final benefitList = _cleanTexts(benefit);
    final srcList = _cleanTexts(sources ?? (source.trim().isEmpty ? const [] : [source.trim()]));
    final benefitBy = _cleanBenefitBySutra(benefitBySutra ?? const {});
    _details[_addedKey(entry)] = (
      sources: srcList,
      source: srcList.join(' / '),
      text: trimmedText,
      benefit: benefitList,
      benefitBySutra: benefitBy,
      annotations: _fitAnnotations(annotations, text),
    );
    await _persist();
    notifyListeners();
    return true;
  }

  /// 编辑一条密咒：出处、原文、人天利益随时可改，名称也能改。
  /// [entryKey] 指定具体条目（同名条目时用它区分）；不传则按名字找第一条。
  /// 新名与现有名单撞名时返回 false，[allowDuplicate] 为 true 则允许。
  Future<bool> update(
    String oldName, {
    String? newName,
    String? entryKey,
    String source = '',
    List<String>? sources,
    String text = '',
    List<String> benefit = const [],
    Map<String, List<String>>? benefitBySutra,
    List<MantraAnnotation> annotations = const [],
    bool allowDuplicate = false,
  }) async {
    final target = _resolve(oldName, entryKey);
    if (target == null) return false;
    final newKey = (newName ?? target.name).trim();
    if (newKey.isEmpty) return false;
    if (newKey != target.name &&
        !allowDuplicate &&
        _items.any((e) => e.name == newKey && e.key != target.key)) {
      return false;
    }
    if (target.builtin) {
      final original = target.original!;
      if (newKey == original) {
        _renames.remove(original);
      } else {
        _renames[original] = newKey;
      }
    } else {
      final entry = _firstAddedByKey(target.key);
      if (entry != null) entry.name = newKey;
    }
    final srcList = _cleanTexts(sources ?? (source.trim().isEmpty ? const [] : [source.trim()]));
    final benefitBy = _cleanBenefitBySutra(benefitBySutra ?? const {});
    _details[target.key] = (
      sources: srcList,
      source: srcList.join(' / '),
      text: text.trim(),
      benefit: _cleanTexts(benefit),
      benefitBySutra: benefitBy,
      annotations: _fitAnnotations(annotations, text),
    );
    await _persist();
    notifyListeners();
    return true;
  }

  _AddedMantra? _firstAddedByKey(String key) {
    for (final m in _added) {
      if (_addedKey(m) == key) return m;
    }
    return null;
  }

  /// 保存前的查重名单：与 [name] 完全同名、或摘掉通用尊称（口径与佛号查重
  /// 一致，见 [ShanZhiShiStore.genericNameTerms]）后仍有 ≥2 个相同字符的
  /// 现有密咒；完全同名排最前。[skip] 是编辑场景里自己的原名，
  /// [skipKey] 是编辑场景里自己那条的内部键（同名条目时用它精确跳过）。
  List<String> findSimilarEntries(
    String name, {
    String? skip,
    String? skipKey,
  }) {
    final target = name.trim();
    if (target.isEmpty) return const [];
    final targetDistinct = ShanZhiShiStore.distinctName(target);
    final hits = <(int, String)>[]; // (相同字符数, 名字)
    final seen = <String>{};
    for (final e in _items) {
      final other = e.name.trim();
      if (other.isEmpty) continue;
      if (skipKey != null) {
        if (e.key == skipKey) continue;
      } else if (other == (skip ?? '').trim()) {
        continue;
      }
      // 同名条目只提示一次。
      if (!seen.add(other)) continue;
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

  /// 把刚填写的 [source] / [text] / [benefit] 并进现有密咒 [name]
  /// （名字不变），两条并成一条：原有内容一处不丢。返回是否成功。
  /// [entryKey] 指定具体条目（同名条目时用它区分）。
  Future<bool> mergeInto(
    String name, {
    String? entryKey,
    String source = '',
    List<String>? sources,
    String text = '',
    List<String> benefit = const [],
    Map<String, List<String>>? benefitBySutra,
    List<MantraAnnotation> annotations = const [],
  }) async {
    final target = _resolve(name, entryKey);
    if (target == null) return false;
    final old = _details[target.key] ??
        (
          sources: const <String>[],
          source: '',
          text: '',
          benefit: const <String>[],
          benefitBySutra: const <String, List<String>>{},
          annotations: const <MantraAnnotation>[],
        );
    final newText = text.trim();
    final mergedSources = _joinSources(
      old.sources,
      sources ?? (source.trim().isEmpty ? const [] : [source.trim()]),
    );
    _details[target.key] = (
      sources: mergedSources,
      source: mergedSources.join(' / '),
      text: _joinText(old.text, newText),
      benefit: _joinBenefits(old.benefit, benefit),
      benefitBySutra: _joinBenefitBySutra(old.benefitBySutra, benefitBySutra),
      annotations: _joinAnnotations(
        old.text,
        old.annotations,
        newText,
        _cleanAnnotations(annotations, newText.length),
      ),
    );
    await _persist();
    notifyListeners();
    return true;
  }

  /// 把 [drop] 这条的内容并进 [keep]，然后删掉 [drop]：两条并成一条。
  /// 保留刚输入的名字时用（[keep] 是刚存下的那条）。返回是否成功。
  /// [keepKey] / [dropKey] 用于在同名条目里精确指定。
  Future<bool> mergeAndRemove(
    String keep,
    String drop, {
    String? keepKey,
    String? dropKey,
  }) async {
    final k = _resolve(keep, keepKey);
    final d = _resolve(drop, dropKey);
    if (k == null || d == null || k.key == d.key) return false;
    final moved = _details[d.key];
    if (moved != null) {
      final old = _details[k.key] ??
          (
            sources: const <String>[],
            source: '',
            text: '',
            benefit: const <String>[],
            benefitBySutra: const <String, List<String>>{},
            annotations: const <MantraAnnotation>[],
          );
      final mergedSources = _joinSources(old.sources, moved.sources);
      _details[k.key] = (
        sources: mergedSources,
        source: mergedSources.join(' / '),
        text: _joinText(old.text, moved.text),
        benefit: _joinBenefits(old.benefit, moved.benefit),
        benefitBySutra: _joinBenefitBySutra(old.benefitBySutra, moved.benefitBySutra),
        annotations: _joinAnnotations(
          old.text,
          old.annotations,
          moved.text,
          moved.annotations,
        ),
      );
    }
    return remove(d.name, entryKey: d.key);
  }

  /// 原文合并：新的非空优先；两条不同且都有值时空行接上（两段都留着）。
  static String _joinText(String a, String b) {
    if (b.isEmpty) return a;
    if (a.isEmpty || a == b) return b;
    return '$a\n\n$b';
  }

  /// 人天利益段落合并：两条的段落去空去重、按原顺序接上。
  static List<String> _joinBenefits(List<String> a, List<String> b) =>
      _cleanTexts([...a, ...b]);

  /// 关联经文合并：两条的经名去空去重、按原顺序接上。
  static List<String> _joinSources(List<String>? a, List<String>? b) =>
      _cleanTexts([...?a, ...?b]);

  /// 清理「按经文分组的人天利益」：经名去空、段落去空去重，空组丢掉，
  /// 保持原有顺序。
  static Map<String, List<String>> _cleanBenefitBySutra(
    Map<String, List<String>> raw,
  ) {
    final out = <String, List<String>>{};
    for (final e in raw.entries) {
      final k = e.key.trim();
      if (k.isEmpty) continue;
      final cleaned = _cleanTexts(e.value);
      if (cleaned.isEmpty) continue;
      out[k] = cleaned;
    }
    return out;
  }

  /// 按经文分组的人天利益合并：同一部经的段落去空去重接上，
  /// 其余经名整体带上；保持 [a] 里已有经名的顺序，新经名按 [b] 顺序追加。
  static Map<String, List<String>> _joinBenefitBySutra(
    Map<String, List<String>> a,
    Map<String, List<String>>? b,
  ) {
    final out = <String, List<String>>{};
    for (final e in a.entries) {
      out[e.key] = _cleanTexts(e.value);
    }
    for (final e in (b ?? const <String, List<String>>{}).entries) {
      final k = e.key.trim();
      if (k.isEmpty) continue;
      out[k] = _cleanTexts([...?out[k], ...e.value]);
    }
    out.removeWhere((_, v) => v.isEmpty);
    return out;
  }

  /// 原文批注合并：[bText] 接在 [aText] 后面时，其批注整体后移，
  /// 落在新原文的对应位置上。
  static List<MantraAnnotation> _joinAnnotations(
    String aText,
    List<MantraAnnotation> a,
    String bText,
    List<MantraAnnotation> b,
  ) {
    final out = <MantraAnnotation>[...a];
    if (bText.isEmpty) return out;
    final offset = aText.isEmpty || aText == bText ? 0 : aText.length + 2;
    for (final ann in b) {
      out.add(ann.copyWith(
        start: ann.start + offset,
        end: ann.end + offset,
      ));
    }
    return out;
  }

  /// 原文保存时会去掉首尾空白；批注的下标基于输入框里的原文，
  /// 这里按被去掉的头部空白整体左移，再按新长度夹紧。
  ///
  /// 关键：落在被去掉的「尾部空白」上的批注不能直接丢掉——用户可能是
  /// 在最后一行/末尾空白上写的备注，保存后原文被 trim 掉，若直接丢弃
  /// 会造成「前面的备注不见了」。这类批注收缩到「最后一个保留字符」上。
  static List<MantraAnnotation> _fitAnnotations(
    List<MantraAnnotation> raw,
    String rawText,
  ) {
    if (raw.isEmpty) return const [];
    final trimmed = rawText.trim();
    final lead = rawText.length - rawText.trimLeft().length;
    final len = trimmed.length;
    final out = <MantraAnnotation>[];
    for (final a in raw) {
      var s = a.start - lead;
      var e = a.end - lead;
      if (e <= 0) continue; // 完全落在被 trim 的头部空白里：无对应文字。
      // 终点越过保留区的，收到保留区末尾。
      if (s >= len) {
        // 起点也在保留区之外（落在被 trim 的尾部空白上）：
        // 收缩到最后一个保留字符，保住这条备注。
        if (len == 0 || !a.isValid) continue;
        s = len - 1;
        e = len;
      } else {
        if (s < 0) s = 0;
        if (e > len) e = len;
        if (e <= s) continue;
      }
      final fit = a.copyWith(start: s, end: e);
      if (!fit.isValid) continue;
      out.add(fit);
    }
    out.sort((x, y) => x.start != y.start
        ? x.start - y.start
        : x.end - y.end);
    return out;
  }

  /// 批注按原文长度夹紧、去掉无效项（越界/空内容），并按起点排序。
  static List<MantraAnnotation> _cleanAnnotations(
    Iterable<MantraAnnotation> raw,
    int textLength,
  ) {
    final out = <MantraAnnotation>[];
    for (final a in raw) {
      final s = a.start.clamp(0, textLength);
      final e = a.end.clamp(0, textLength);
      if (e <= s || !a.isValid) continue;
      out.add(a.copyWith(start: s, end: e));
    }
    out.sort((x, y) => x.start != y.start
        ? x.start - y.start
        : x.end - y.end);
    return out;
  }

  /// 从本地详情里解析批注列表（旧数据没有这一项）。
  static List<MantraAnnotation> _parseAnnotations(Object? raw) {
    if (raw is! List) return const [];
    final out = <MantraAnnotation>[];
    for (final item in raw) {
      final ann = MantraAnnotation.fromJson(item);
      if (ann != null) out.add(ann);
    }
    return out;
  }

  /// 段落文本去空、去重（保持原有顺序）。
  static List<String> _cleanTexts(Iterable<String> raw) {
    final out = <String>[];
    for (final s in raw) {
      final t = s.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  /// 只更新某条密咒的原文批注（注音 / 备注）：原文与其他内容原样保留。
  Future<void> saveAnnotationsKey(
    String? key,
    List<MantraAnnotation> annotations,
  ) async {
    if (key == null) return;
    final d = _details[key];
    if (d == null) return;
    _details[key] = (
      sources: d.sources,
      source: d.source,
      text: d.text,
      benefit: d.benefit,
      benefitBySutra: d.benefitBySutra,
      annotations: _cleanAnnotations(annotations, d.text.length),
    );
    await _persist();
    notifyListeners();
  }

  /// 删除一条密咒：自建的从名单移除，内置的记进隐藏名单；详情一并清掉。
  /// [entryKey] 指定具体条目（同名条目时用它区分）。
  Future<bool> remove(String name, {String? entryKey}) async {
    final target = _resolve(name, entryKey);
    if (target == null) return false;
    if (target.builtin) {
      final original = target.original!;
      _hidden.add(original);
      _renames.remove(original);
    } else {
      _added.removeWhere((m) => _addedKey(m) == target.key);
    }
    _details.remove(target.key);
    await _persist();
    notifyListeners();
    return true;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _entriesKey,
        jsonEncode([
          for (final m in _added) {'id': m.id, 'name': m.name},
        ]),
      );
      // 旧键继续写一份名字列表：旧版本读到的仍是同名单（同名会合并展示）。
      await prefs.setStringList(_prefKey, [for (final m in _added) m.name]);
      await prefs.setStringList(_hiddenKey, _hidden.toList());
      await prefs.setString(_renameKey, jsonEncode(_renames));
      await prefs.setString(
          _detailKey,
          jsonEncode({
            for (final e in _details.entries)
              e.key: [
                e.value.source,
                e.value.text,
                e.value.benefit,
                [for (final a in e.value.annotations) a.toJson()],
              ],
          }));
    } catch (_) {}
  }

  /// 测试用：清空用户自建记录（只动内存，供单测隔离）。
  void resetForTest() {
    _added.clear();
    _renames.clear();
    _hidden.clear();
    _details.clear();
    _newFormat = false;
    _seq = 0;
    loaded = false;
    notifyListeners();
  }
}
