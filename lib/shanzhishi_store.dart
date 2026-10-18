import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_sutra_links.dart';

/// 善知识名号：用户自行录入到球面上的一位佛菩萨，附带它出现过的经文（存展示名）。
class ShanyishiEntry {
  final String name;
  final List<String> sutras;
  final int createdAt;

  const ShanyishiEntry({
    required this.name,
    required this.sutras,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'sutras': sutras,
        'createdAt': createdAt,
      };

  static ShanyishiEntry? fromJson(Map<String, dynamic> e) {
    final name = (e['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    final sutras = <String>[];
    final raw = e['sutras'];
    if (raw is List) {
      for (final s in raw) {
        final t = s.toString().trim();
        if (t.isNotEmpty && !sutras.contains(t)) sutras.add(t);
      }
    }
    final createdAt = e['createdAt'];
    return ShanyishiEntry(
      name: name,
      sutras: sutras,
      createdAt: createdAt is int
          ? createdAt
          : int.tryParse('$createdAt') ?? 0,
    );
  }

  ShanyishiEntry copyWith({String? name, List<String>? sutras}) =>
      ShanyishiEntry(
        name: name ?? this.name,
        sutras: sutras ?? this.sutras,
        createdAt: createdAt,
      );
}

/// 善知识名号数据：用户自建、本地持久化。
///
/// 球面按列表顺序铺排（顺序即录入顺序）；每次改动落盘并 notifyListeners，
/// 善知识页挂监听实时刷新球面与下方经文面板。
class ShanZhiShiStore extends ChangeNotifier {
  ShanZhiShiStore._();

  static final ShanZhiShiStore instance = ShanZhiShiStore._();

  static const String _prefKey = 'shanzhishi_names';

  /// 预置种子的版本：版本升级时把「还没出现过的种子名号」补进现有名单，
  /// 不覆盖用户已录入的数据，也不会让用户删掉的名号复活。
  static const String _seedVersionKey = 'shanzhishi_seed_version';
  static const int _seedVersion = 2;

  /// 首次安装预置的名号（名字 + 出现的经文），避免空球起手。
  /// 《地藏菩萨本愿经》里出现的佛菩萨名号；用户删掉后不再回来。
  static const List<List<String>> _seeds = [    ['地藏菩萨', '地藏菩萨本愿经'],
    // 称佛名号品第九明确列举的佛名（共 19 尊）。
    ['无边身如来', '地藏菩萨本愿经'],
    ['宝性如来', '地藏菩萨本愿经'],
    ['波头摩胜如来', '地藏菩萨本愿经'],
    ['师子吼如来', '地藏菩萨本愿经'],
    ['拘留孙佛', '地藏菩萨本愿经'],
    ['毗婆尸佛', '地藏菩萨本愿经'],
    ['宝胜如来', '地藏菩萨本愿经'],
    ['宝相如来', '地藏菩萨本愿经'],
    ['袈裟幢如来', '地藏菩萨本愿经'],
    ['大通山王如来', '地藏菩萨本愿经'],
    ['净月佛', '地藏菩萨本愿经'],
    ['山王佛', '地藏菩萨本愿经'],
    ['智胜佛', '地藏菩萨本愿经'],
    ['净名王佛', '地藏菩萨本愿经'],
    ['智成就佛', '地藏菩萨本愿经'],
    ['无上佛', '地藏菩萨本愿经'],
    ['妙声佛', '地藏菩萨本愿经'],
    ['满月佛', '地藏菩萨本愿经'],
    ['月面佛', '地藏菩萨本愿经'],
    // 其他品中出现的佛名。
    ['释迦牟尼佛', '地藏菩萨本愿经'],
    ['师子奋迅具足万行如来', '地藏菩萨本愿经'],
    ['觉华定自在王如来', '地藏菩萨本愿经'],
    ['一切智成就如来', '地藏菩萨本愿经'],
    ['清净莲华目如来', '地藏菩萨本愿经'],
    // 菩萨名。
    ['文殊师利菩萨', '地藏菩萨本愿经'],
    ['定自在王菩萨', '地藏菩萨本愿经'],
    ['财首菩萨', '地藏菩萨本愿经'],
    ['无尽意菩萨', '地藏菩萨本愿经'],
    ['解脱菩萨', '地藏菩萨本愿经'],
    ['普贤菩萨', '地藏菩萨本愿经'],
    ['普广菩萨', '地藏菩萨本愿经'],
    ['观世音菩萨', '地藏菩萨本愿经'],
    ['虚空藏菩萨', '地藏菩萨本愿经'],
    ['弥勒菩萨', '地藏菩萨本愿经'],
  ];

  /// 版本 1 及更早的旧版预置：升级到 [_seedVersion] 时，
  /// 若这些条目原样还在，先移除再补新种子，免得和新名单重复
  /// （如旧「地藏王菩萨」与新「地藏菩萨」）。用户改动过的不动。
  static const List<List<String>> _legacySeeds = [
    ['释迦牟尼佛', '佛说四十二章经'],
    ['阿弥陀佛', '佛说阿弥陀经'],
    ['药师佛', '药师琉璃光如来本愿功德经'],
    ['观世音菩萨', '妙法莲华经'],
    ['地藏王菩萨', '地藏菩萨本愿经'],
    ['文殊师利菩萨', '大方广佛华严经'],
    ['普贤菩萨', '大方广佛华严经'],
    ['弥勒菩萨', '佛说观弥勒菩萨上生兜率天经'],
  ];

  final List<ShanyishiEntry> _entries = [];

  bool _loaded = false;

  bool get loaded => _loaded;

  int get length => _entries.length;

  List<ShanyishiEntry> get entries => List.unmodifiable(_entries);

  ShanyishiEntry? operator [](int index) =>
      (index >= 0 && index < _entries.length) ? _entries[index] : null;

  /// 读本地数据；没存过时写入预置种子。幂等，可重复调用。
  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    final storedSeedVersion = prefs.getInt(_seedVersionKey) ?? 0;
    _entries.clear();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (raw == null || raw.isEmpty) {
      for (var i = 0; i < _seeds.length; i++) {
        _entries.add(ShanyishiEntry(
          name: _seeds[i][0],
          sutras: _seeds[i].length > 1 ? _seeds[i].skip(1).toList() : const [],
          createdAt: now + i,
        ));
      }
    } else {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final e in decoded) {
          if (e is! Map) continue;
          final entry =
              ShanyishiEntry.fromJson(Map<String, dynamic>.from(e));
          if (entry != null) _entries.add(entry);
        }
      } catch (_) {
        // 存坏了一律退回空列表，绝不抛。
      }
      // 种子版本升级：先清掉原样未改的旧版预置（避免重复），
      // 再把新增的种子名号补进现有名单（同名不重复）。
      if (storedSeedVersion < _seedVersion) {
        final legacyKeys = {
          for (final s in _legacySeeds) _seedKey(s[0], s.skip(1)),
        };
        _entries.removeWhere(
            (e) => legacyKeys.contains(_seedKey(e.name, e.sutras)));
        final existing = {for (final e in _entries) e.name};
        var i = 0;
        for (final seed in _seeds) {
          if (existing.add(seed[0])) {
            _entries.add(ShanyishiEntry(
              name: seed[0],
              sutras: seed.length > 1 ? seed.skip(1).toList() : const [],
              createdAt: now + i,
            ));
          }
          i++;
        }
      }
    }
    _loaded = true;
    await _persist();
    await prefs.setInt(_seedVersionKey, _seedVersion);
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefKey,
      jsonEncode([for (final e in _entries) e.toJson()]),
    );
  }

  /// 新增一位名号，返回它的位次（追加到末尾，球面转到它）。
  Future<int> add(String name, List<String> sutras) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return -1;
    final entry = ShanyishiEntry(
      name: trimmed,
      sutras: _cleanSutras(sutras),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    // 同名不重复录入：定位到已有的那一位。
    final existing = _entries.indexWhere((e) => e.name == trimmed);
    if (existing >= 0) {
      if (entry.sutras.isNotEmpty) {
        final merged = _cleanSutras([..._entries[existing].sutras, ...entry.sutras]);
        _entries[existing] = _entries[existing].copyWith(sutras: merged);
        await _persist();
        notifyListeners();
      }
      return existing;
    }
    _entries.add(entry);
    await _persist();
    notifyListeners();
    return _entries.length - 1;
  }

  /// 改名 / 增删经文。
  Future<void> update(
    int index, {
    String? name,
    List<String>? sutras,
  }) async {
    if (index < 0 || index >= _entries.length) return;
    final old = _entries[index];
    final newName = (name ?? old.name).trim();
    if (newName.isEmpty) return;
    _entries[index] = ShanyishiEntry(
      name: newName,
      sutras: sutras != null ? _cleanSutras(sutras) : old.sutras,
      createdAt: old.createdAt,
    );
    await _persist();
    notifyListeners();
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _entries.length) return;
    _entries.removeAt(index);
    await _persist();
    notifyListeners();
  }

  /// 随机抽取一位（排除当前位次；只有一位时不排除）。
  int randomIndex({int? exclude, math.Random? random}) {
    final n = _entries.length;
    if (n == 0) return -1;
    if (n == 1) return 0;
    final rng = random ?? math.Random();
    var i = rng.nextInt(n);
    if (exclude != null && i == exclude) i = (i + 1) % n;
    return i;
  }

  static List<String> _cleanSutras(List<String> raw) {
    final out = <String>[];
    for (final s in raw) {
      final t = s.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  /// 种子比对键：名号 + 经文，用于判断某条预置有没有被用户改过。
  static String _seedKey(String name, Iterable<String> sutras) =>
      '$name\u0000${sutras.join("\u0001")}';

  /// 把经文展示名解析成经藏条目（拿到可跳转的正文路径）。
  ///
  /// 目录未加载时返回 null（经文卡片退化为纯文本）；精确匹配优先，
  /// 其次取「包含该名字的最短经名」（用户常输入简称，如「地藏经」）。
  static NoteSutraLink? resolveSutra(String name) {
    final map = NoteSutraCatalog.cachedTitleMap;
    if (map == null || map.isEmpty) return null;
    final exact = map[name.trim()];
    if (exact != null) return exact;
    final q = name.trim();
    if (q.isEmpty) return null;
    NoteSutraLink? best;
    for (final e in map.values) {
      if (e.title.contains(q)) {
        if (best == null || e.title.length < best.title.length) best = e;
      }
    }
    return best;
  }

  /// 测试用：清空内存与标记，让下一次 load() 重新读。
  @visibleForTesting
  void resetForTest() {
    _entries.clear();
    _loaded = false;
  }
}
