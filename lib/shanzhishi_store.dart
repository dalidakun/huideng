import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_sutra_links.dart';

/// 善知识名号：用户自行录入到球面上的一位佛菩萨，附带它的关联经文（存展示名）
/// 与用户手写的引用段落。
class ShanyishiEntry {
  final String name;
  final List<String> sutras;

  /// 引用段落：与这位佛菩萨关联的经文段落（用户手写，一段一条）。
  /// 为空时展示层退回「按名号在各部经文里自动识别」。
  final List<String> paragraphs;

  /// 旧版按经书存的引用段落（经名 -> 段落）。新版统一收进 [paragraphs]，
  /// 读旧档时自动拍平迁移，展示层仍认这个字段兜底。
  final Map<String, List<String>> quotes;

  final int createdAt;

  const ShanyishiEntry({
    required this.name,
    required this.sutras,
    this.paragraphs = const [],
    this.quotes = const {},
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'sutras': sutras,
        'paragraphs': paragraphs,
        'quotes': quotes,
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
    final quotes = <String, List<String>>{};
    final rawQuotes = e['quotes'];
    if (rawQuotes is Map) {
      rawQuotes.forEach((key, value) {
        final sutra = key.toString().trim();
        if (sutra.isEmpty || value is! List) return;
        final texts = <String>[];
        for (final t in value) {
          final s = t.toString().trim();
          if (s.isNotEmpty && !texts.contains(s)) texts.add(s);
        }
        if (texts.isNotEmpty) quotes[sutra] = texts;
      });
    }
    final paragraphs = <String>[];
    final rawParagraphs = e['paragraphs'];
    if (rawParagraphs is List) {
      for (final t in rawParagraphs) {
        final s = t.toString().trim();
        if (s.isNotEmpty && !paragraphs.contains(s)) paragraphs.add(s);
      }
    }
    // 旧数据迁移：以前段落是按经书存的，读的时候拍平进段落池，避免丢内容。
    if (paragraphs.isEmpty && quotes.isNotEmpty) {
      for (final sutra in sutras) {
        for (final t in quotes[sutra] ?? const <String>[]) {
          if (!paragraphs.contains(t)) paragraphs.add(t);
        }
      }
      for (final list in quotes.values) {
        for (final t in list) {
          if (!paragraphs.contains(t)) paragraphs.add(t);
        }
      }
      quotes.clear();
    }
    final createdAt = e['createdAt'];
    return ShanyishiEntry(
      name: name,
      sutras: sutras,
      paragraphs: paragraphs,
      quotes: quotes,
      createdAt: createdAt is int
          ? createdAt
          : int.tryParse('$createdAt') ?? 0,
    );
  }

  ShanyishiEntry copyWith({
    String? name,
    List<String>? sutras,
    List<String>? paragraphs,
    Map<String, List<String>>? quotes,
  }) =>
      ShanyishiEntry(
        name: name ?? this.name,
        sutras: sutras ?? this.sutras,
        paragraphs: paragraphs ?? this.paragraphs,
        quotes: quotes ?? this.quotes,
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

  /// 编辑前快照（一步撤销）的落盘键：createdAt -> 该名号上一版。
  static const String _undoKey = 'shanzhishi_undo';

  /// createdAt -> 编辑前的一份快照，供面板上的「恢复」使用。
  final Map<int, ShanyishiEntry> _undo = {};

  /// 预置种子的版本：版本升级时把「还没出现过的种子名号」补进现有名单，
  /// 不覆盖用户已录入的数据，也不会让用户删掉的名号复活。
  static const String _seedVersionKey = 'shanzhishi_seed_version';
  static const int _seedVersion = 3;

  /// 首次安装预置的名号（名字 + 出现的经文），避免空球起手。
  /// 第一段：《地藏菩萨本愿经》里出现的佛菩萨名号；用户删掉后不再回来。
  /// 第二段：常见佛菩萨名号汇编（关联经文留空，用户可后补）。
  static const List<List<String>> _seeds = [
    ['地藏菩萨', '地藏菩萨本愿经'],
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
    // 常见佛菩萨名号汇编（关联经文留空）。
    ['阿弥陀佛'],
    ['药师琉璃光如来'],
    ['毗卢遮那佛'],
    ['卢舍那佛'],
    ['阿閦佛'],
    ['宝生佛'],
    ['不空成就佛'],
    ['燃灯佛'],
    ['弥勒佛'],
    ['多宝佛'],
    ['尸弃佛'],
    ['毗舍浮佛'],
    ['拘那含牟尼佛'],
    ['迦叶佛'],
    ['善名称吉祥王如来'],
    ['宝月智严光音自在王如来'],
    ['金色宝光妙行成就如来'],
    ['无忧最胜吉祥如来'],
    ['法海雷音如来'],
    ['法海胜慧游戏神通如来'],
    ['无量寿佛'],
    ['无量光佛'],
    ['日月灯明佛'],
    ['大通智胜佛'],
    ['威音王佛'],
    ['大势至菩萨'],
    ['金刚手菩萨'],
    ['除盖障菩萨'],
    ['日光遍照菩萨'],
    ['月光遍照菩萨'],
    ['药王菩萨'],
    ['药上菩萨'],
    ['宝檀华菩萨'],
    ['准提菩萨'],
    ['贤护菩萨'],
    ['常精进菩萨'],
    ['不休息菩萨'],
    ['法慧菩萨'],
    ['功德林菩萨'],
    ['金刚藏菩萨'],
    ['解脱月菩萨'],
    ['观自在菩萨'],
    ['正法明如来'],
    ['绿度母'],
    ['白度母'],
    ['摩利支天菩萨'],
    ['大吉祥天女'],
    ['辩才天女'],
    ['常啼菩萨'],
    ['法上菩萨'],
    ['宝月菩萨'],
    ['星宿菩萨'],
    ['香象菩萨'],
    ['龙树菩萨'],
    ['马鸣菩萨'],
    ['维摩诘菩萨'],
    ['善财童子'],
    ['常不轻菩萨'],
    ['妙音菩萨'],
    ['普门菩萨'],
    ['海会菩萨'],
    ['金刚拳菩萨'],
    ['才发心转法轮菩萨'],
    ['虚空库菩萨'],
    ['摧一切魔菩萨'],
    ['救脱菩萨'],
    ['坚勇菩萨'],
    ['地藏王菩萨'],
    ['大悲观世音菩萨'],
    ['大智文殊师利菩萨'],
    ['大行普贤菩萨'],
    ['大愿地藏菩萨'],
    ['慈氏菩萨'],
    ['虚空藏菩萨摩诃萨'],
    ['金刚手菩萨摩诃萨'],
    ['除盖障菩萨摩诃萨'],
    ['无尽意菩萨摩诃萨'],
    ['宝檀华菩萨摩诃萨'],
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
    // 读回编辑前快照（一步撤销），跨重启也能恢复。
    _undo.clear();
    final rawUndo = prefs.getString(_undoKey);
    if (rawUndo != null && rawUndo.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawUndo) as List<dynamic>;
        for (final e in decoded) {
          if (e is! Map) continue;
          final entry =
              ShanyishiEntry.fromJson(Map<String, dynamic>.from(e));
          if (entry != null) _undo[entry.createdAt] = entry;
        }
      } catch (_) {
        // 快照坏了就当作没有，不影响主数据。
      }
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefKey,
      jsonEncode([for (final e in _entries) e.toJson()]),
    );
  }

  /// 记录一份编辑前的快照，供「恢复」一步撤销。
  ///
  /// 同一名号只保留**最早**那份（也就是这次连续编辑开始前的版本），
  /// 这样连改几次再点恢复，能整体退回到动手之前，而不是只退一步。
  void _rememberUndo(ShanyishiEntry old) {
    _undo.putIfAbsent(old.createdAt, () => old);
  }

  Future<void> _persistUndo() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _undoKey,
      jsonEncode([for (final e in _undo.values) e.toJson()]),
    );
  }

  /// 这一位有没有可恢复的「编辑前版本」。
  bool canRestore(ShanyishiEntry entry) => _undo.containsKey(entry.createdAt);

  /// 恢复到这一位最近一次编辑前的状态（一步撤销）。
  ///
  /// 恢复后快照即被消费，返回是否真的恢复了（没有快照返回 false）。
  Future<bool> restoreLast(int index) async {
    if (index < 0 || index >= _entries.length) return false;
    final current = _entries[index];
    final backup = _undo.remove(current.createdAt);
    if (backup == null) return false;
    _entries[index] = backup;
    await _persist();
    await _persistUndo();
    notifyListeners();
    return true;
  }

  /// 新增一位名号，返回它的位次（追加到末尾，球面转到它）。
  ///
  /// 默认同名不重复录入：定位到已有的那一位，把经文与引用段落并进去。
  /// [allowDuplicate] 为 true 时即使同名也另起一位（用户明确选了「添加新的」）。
  Future<int> add(
    String name,
    List<String> sutras, {
    Map<String, List<String>> quotes = const {},
    List<String> paragraphs = const [],
    bool allowDuplicate = false,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return -1;
    // 同名不重复录入：定位到已有的那一位，把经文与引用段落并进去。
    final existing = allowDuplicate
        ? -1
        : _entries.indexWhere((e) => e.name == trimmed);
    if (existing >= 0) {
      return mergeInto(
        existing,
        sutras: sutras,
        quotes: quotes,
        paragraphs: paragraphs,
      );
    }
    final cleanedSutras = _cleanSutras(sutras);
    final cleanedQuotes = _cleanQuotes(quotes);
    _entries.add(ShanyishiEntry(
      name: trimmed,
      sutras: cleanedSutras,
      paragraphs: _cleanTexts(paragraphs),
      quotes: _pruneQuotes(cleanedQuotes, cleanedSutras),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await _persist();
    notifyListeners();
    return _entries.length - 1;
  }

  /// 把 [sutras] / [quotes] / [paragraphs] 并进已有的第 [index] 位
  /// （名号保持原样），返回该位次。
  ///
  /// 用户选择「合并」时调用：经文取并集、引用段落去重合并，
  /// 已有数据一处不丢。
  Future<int> mergeInto(
    int index, {
    List<String> sutras = const [],
    Map<String, List<String>> quotes = const {},
    List<String> paragraphs = const [],
  }) async {
    if (index < 0 || index >= _entries.length) return -1;
    final old = _entries[index];
    final mergedSutras = _cleanSutras([...old.sutras, ...sutras]);
    final mergedQuotes = <String, List<String>>{
      for (final e in old.quotes.entries) e.key: List.of(e.value),
    };
    _cleanQuotes(quotes).forEach((sutra, texts) {
      mergedQuotes[sutra] = _cleanTexts([...?mergedQuotes[sutra], ...texts]);
    });
    final pruned = _pruneQuotes(mergedQuotes, mergedSutras);
    final mergedParagraphs = _cleanTexts([...old.paragraphs, ...paragraphs]);
    if (mergedSutras.length != old.sutras.length ||
        !_sameQuotes(pruned, old.quotes) ||
        mergedParagraphs.length != old.paragraphs.length) {
      _rememberUndo(old);
      _entries[index] = old.copyWith(
        sutras: mergedSutras,
        quotes: pruned,
        paragraphs: mergedParagraphs,
      );
      await _persist();
      await _persistUndo();
      notifyListeners();
    }
    return index;
  }

  /// 名号相似度：字符重合比例（重复字按出现次数计），分母取较长的一边。
  /// 例：「地藏菩萨」vs「地藏王菩萨」= 4 / 5 = 0.8。
  static double nameSimilarity(String a, String b) {
    final x = a.trim();
    final y = b.trim();
    if (x.isEmpty || y.isEmpty) return 0;
    if (x == y) return 1;
    final counts = <int, int>{};
    for (final r in x.runes) {
      counts[r] = (counts[r] ?? 0) + 1;
    }
    var common = 0;
    for (final r in y.runes) {
      final n = counts[r] ?? 0;
      if (n <= 0) continue;
      counts[r] = n - 1;
      common++;
    }
    final len = math.max(x.runes.length, y.runes.length);
    return len == 0 ? 0 : common / len;
  }

  /// 找出与 [name] 相同、或字符重合 ≥ [threshold]（默认 80%）的已有名号位次；
  /// 没有相似项时返回 -1。多条命中时取相似度最高的那一位。
  /// [skip] 用于编辑场景：跳过自己那一位。
  int findSimilarIndex(
    String name, {
    double threshold = 0.8,
    int? skip,
  }) {
    final target = name.trim();
    if (target.isEmpty) return -1;
    var best = -1;
    var bestScore = 0.0;
    for (var i = 0; i < _entries.length; i++) {
      if (i == skip) continue;
      final score = nameSimilarity(target, _entries[i].name);
      if (score < threshold || score <= bestScore) continue;
      bestScore = score;
      best = i;
    }
    return best;
  }

  /// 把第 [from] 位整体并进第 [into] 位，然后删掉 [from]（编辑改名撞车时用）。
  ///
  /// 返回合并后目标的新位次（from < into 时会前移一位）；失败返回 -1。
  Future<int> mergeAndRemove(int from, int into) async {
    if (from == into) return into;
    if (from < 0 || from >= _entries.length) return -1;
    if (into < 0 || into >= _entries.length) return -1;
    final src = _entries[from];
    await mergeInto(
      into,
      sutras: src.sutras,
      paragraphs: src.paragraphs,
      quotes: src.quotes,
    );
    _entries.removeAt(from);
    _undo.remove(src.createdAt);
    final result = from < into ? into - 1 : into;
    await _persist();
    await _persistUndo();
    notifyListeners();
    return result;
  }

  /// 改名 / 增删经文 / 维护引用段落。
  ///
  /// [quotes] / [paragraphs] 传值即整体覆盖，传 null 表示保持原样。
  /// 已不在关联经文列表里的旧版按经书段落会被一并清掉。
  Future<void> update(
    int index, {
    String? name,
    List<String>? sutras,
    Map<String, List<String>>? quotes,
    List<String>? paragraphs,
  }) async {
    if (index < 0 || index >= _entries.length) return;
    final old = _entries[index];
    final newName = (name ?? old.name).trim();
    if (newName.isEmpty) return;
    final newSutras = sutras != null ? _cleanSutras(sutras) : old.sutras;
    final newQuotes = quotes != null
        ? _pruneQuotes(_cleanQuotes(quotes), newSutras)
        : _pruneQuotes(old.quotes, newSutras);
    final newParagraphs =
        paragraphs != null ? _cleanTexts(paragraphs) : old.paragraphs;
    _rememberUndo(old);
    _entries[index] = ShanyishiEntry(
      name: newName,
      sutras: newSutras,
      paragraphs: newParagraphs,
      quotes: newQuotes,
      createdAt: old.createdAt,
    );
    await _persist();
    await _persistUndo();
    notifyListeners();
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _entries.length) return;
    final removed = _entries.removeAt(index);
    _undo.remove(removed.createdAt);
    await _persist();
    await _persistUndo();
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

  /// 段落文本去空、去重（保持原有顺序）。
  static List<String> _cleanTexts(Iterable<String> raw) {
    final out = <String>[];
    for (final s in raw) {
      final t = s.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  /// 规范化引用段落：经名去空、段落去空去重，空列表不落库。
  static Map<String, List<String>> _cleanQuotes(
    Map<String, List<String>> raw,
  ) {
    final out = <String, List<String>>{};
    raw.forEach((sutra, texts) {
      final key = sutra.trim();
      if (key.isEmpty) return;
      final list = _cleanTexts(texts);
      if (list.isNotEmpty) out[key] = list;
    });
    return out;
  }

  /// 只保留仍挂在 [sutras] 里的经文段落（删经书时一并清掉它的引用）。
  static Map<String, List<String>> _pruneQuotes(
    Map<String, List<String>> quotes,
    List<String> sutras,
  ) {
    if (quotes.isEmpty) return const <String, List<String>>{};
    final keep = sutras.toSet();
    final out = <String, List<String>>{};
    quotes.forEach((sutra, texts) {
      if (keep.contains(sutra)) out[sutra] = texts;
    });
    return out;
  }

  static bool _sameQuotes(
    Map<String, List<String>> a,
    Map<String, List<String>> b,
  ) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final other = b[e.key];
      if (other == null || other.length != e.value.length) return false;
      for (var i = 0; i < e.value.length; i++) {
        if (other[i] != e.value[i]) return false;
      }
    }
    return true;
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
    _undo.clear();
    _loaded = false;
  }
}
