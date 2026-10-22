import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'note_sutra_links.dart';
import 'sutra_list_page.dart';

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
      createdAt: createdAt is int ? createdAt : int.tryParse('$createdAt') ?? 0,
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

  /// 首次启动写入预置种子时打标记；云端有真实名单时允许覆盖。
  static const String provisionalMarkerKey = '_provisional_shanzhishi_names';

  /// 用户最后点选的名号：下次打开善知识页时球心默认对准它。
  static const String _lastTappedKey = 'shanzhishi_last_tapped';

  /// 编辑前快照（一步撤销）的落盘键：createdAt -> 该名号上一版。
  static const String _undoKey = 'shanzhishi_undo';

  /// createdAt -> 编辑前的一份快照，供面板上的「恢复」使用。
  final Map<int, ShanyishiEntry> _undo = {};

  /// 预置种子的版本：版本升级时把「还没出现过的种子名号」补进现有名单，
  /// 不覆盖用户已录入的数据，也不会让用户删掉的名号复活。
  static const String _seedVersionKey = 'shanzhishi_seed_version';
  static const int _seedVersion = 5;

  static const String _baifoBenefit =
      '若有一心受持读诵，忆念不忘此佛名者，所生贪欲、瞋恚、愚痴、诸怖畏等，即得除灭，未生贪欲、瞋恚、愚痴、诸怖畏者，能令不生。';

  /// 分卷经书的「合并名」：这类经在经藏里是好几卷，只写合并名点不开对的那一卷
  /// （永远落到卷一），关联经文必须写带卷标的名字（「…卷一」「…卷二」）。
  ///
  /// 这里只挡**精确等于**合并名的条目，带卷标的照旧保留：
  /// 「地藏菩萨本愿经卷一」「地藏菩萨本愿经卷二」都是好名字。
  static const Set<String> mergedSutraNames = {'地藏菩萨本愿经'};

  /// 首次安装预置的名号（名字 + 出现的经文），避免空球起手。
  /// 第一段：《地藏菩萨本愿经》里出现的佛菩萨名号；用户删掉后不再回来。
  /// 第二段：常见佛菩萨名号汇编（关联经文留空，用户可后补）。
  ///
  /// 第一段不预置关联经文：《地藏菩萨本愿经》在经藏里是卷一、卷二两卷
  /// （T13n0412_001／T13n0412_002），关联经文只写合并名点不开对的那一卷
  /// （永远落到卷一），要哪一卷由用户在编辑面板里从经藏按卷选。
  static const List<List<String>> _seeds = [
    ['地藏菩萨'],
    // 称佛名号品第九明确列举的佛名（共 19 尊）。
    ['无边身如来'],
    ['宝性如来'],
    ['波头摩胜如来'],
    ['师子吼如来'],
    ['拘留孙佛'],
    ['毗婆尸佛'],
    ['宝胜如来'],
    ['宝相如来'],
    ['袈裟幢如来'],
    ['大通山王如来'],
    ['净月佛'],
    ['山王佛'],
    ['智胜佛'],
    ['净名王佛'],
    ['智成就佛'],
    ['无上佛'],
    ['妙声佛'],
    ['满月佛'],
    ['月面佛'],
    // 其他品中出现的佛名。
    ['释迦牟尼佛'],
    ['师子奋迅具足万行如来'],
    ['觉华定自在王如来'],
    ['一切智成就如来'],
    ['清净莲华目如来'],
    // 菩萨名。
    ['文殊师利菩萨'],
    ['定自在王菩萨'],
    ['财首菩萨'],
    ['无尽意菩萨'],
    ['解脱菩萨'],
    ['普贤菩萨'],
    ['普广菩萨'],
    ['观世音菩萨'],
    ['虚空藏菩萨'],
    ['弥勒菩萨'],
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
    // 佛说百佛名经所列佛名（人天利益统一）
    ['月光佛', '佛说百佛名经'],
    ['阿閦佛', '佛说百佛名经'],
    ['大庄严佛', '佛说百佛名经'],
    ['多伽罗香佛', '佛说百佛名经'],
    ['常照曜佛', '佛说百佛名经'],
    ['栴檀德佛', '佛说百佛名经'],
    ['最上佛', '佛说百佛名经'],
    ['莲华幢佛', '佛说百佛名经'],
    ['莲华生佛', '佛说百佛名经'],
    ['宝聚佛', '佛说百佛名经'],
    ['阿伽楼香佛', '佛说百佛名经'],
    ['大精进佛', '佛说百佛名经'],
    ['娑伽罗佛', '佛说百佛名经'],
    ['巨海佛', '佛说百佛名经'],
    ['幢德佛', '佛说百佛名经'],
    ['梵德佛', '佛说百佛名经'],
    ['大香佛', '佛说百佛名经'],
    ['大生佛', '佛说百佛名经'],
    ['宝网佛', '佛说百佛名经'],
    ['阿弥陀佛', '佛说百佛名经'],
    ['大施德佛', '佛说百佛名经'],
    ['大金柱佛', '佛说百佛名经'],
    ['大念佛', '佛说百佛名经'],
    ['言无尽佛', '佛说百佛名经'],
    ['常散华佛', '佛说百佛名经'],
    ['大爱佛', '佛说百佛名经'],
    ['师子香胜佛', '佛说百佛名经'],
    ['养德佛', '佛说百佛名经'],
    ['帝释火焰佛', '佛说百佛名经'],
    ['常乐德佛', '佛说百佛名经'],
    ['师子华德佛', '佛说百佛名经'],
    ['寂灭幢佛', '佛说百佛名经'],
    ['戒王佛', '佛说百佛名经'],
    ['普德佛', '佛说百佛名经'],
    ['普德象佛', '佛说百佛名经'],
    ['无忧德佛', '佛说百佛名经'],
    ['优波罗香佛', '佛说百佛名经'],
    ['大地佛', '佛说百佛名经'],
    ['大龙德佛', '佛说百佛名经'],
    ['清净王佛', '佛说百佛名经'],
    ['莲华德佛', '佛说百佛名经'],
    ['舍华佛', '佛说百佛名经'],
    ['龙德佛', '佛说百佛名经'],
    ['华聚佛', '佛说百佛名经'],
    ['香象佛', '佛说百佛名经'],
    ['常观佛', '佛说百佛名经'],
    ['正作佛', '佛说百佛名经'],
    ['善住佛', '佛说百佛名经'],
    ['尼瞿嚧陀王佛', '佛说百佛名经'],
    ['无上王佛', '佛说百佛名经'],
    ['月德佛', '佛说百佛名经'],
    ['栴檀林佛', '佛说百佛名经'],
    ['日藏佛', '佛说百佛名经'],
    ['德藏佛', '佛说百佛名经'],
    ['须弥力佛', '佛说百佛名经'],
    ['摩尼藏佛', '佛说百佛名经'],
    ['金刚王佛', '佛说百佛名经'],
    ['威德佛', '佛说百佛名经'],
    ['无坏佛', '佛说百佛名经'],
    ['善见佛', '佛说百佛名经'],
    ['精进德佛', '佛说百佛名经'],
    ['大海佛', '佛说百佛名经'],
    ['覆婆罗树佛', '佛说百佛名经'],
    ['跋蹉德佛', '佛说百佛名经'],
    ['佛天佛', '佛说百佛名经'],
    ['师子幢佛', '佛说百佛名经'],
    ['毗头德佛', '佛说百佛名经'],
    ['无边德佛', '佛说百佛名经'],
    ['德智佛', '佛说百佛名经'],
    ['厚德佛', '佛说百佛名经'],
    ['华幢佛', '佛说百佛名经'],
    ['象德佛', '佛说百佛名经'],
    ['龙德佛', '佛说百佛名经'],
    ['德生佛', '佛说百佛名经'],
    ['德婆瑳子佛', '佛说百佛名经'],
    ['论议佛', '佛说百佛名经'],
    ['普见佛', '佛说百佛名经'],
    ['宝多罗佛', '佛说百佛名经'],
    ['普舍佛', '佛说百佛名经'],
    ['大供养德佛', '佛说百佛名经'],
    ['大网佛', '佛说百佛名经'],
    ['断一切众生疑王佛', '佛说百佛名经'],
    ['宝德佛', '佛说百佛名经'],
    ['普盖佛', '佛说百佛名经'],
    ['大盖佛', '佛说百佛名经'],
    ['胜德佛', '佛说百佛名经'],
    ['千供养佛', '佛说百佛名经'],
    ['宝莲华奋迅佛', '佛说百佛名经'],
    ['智幡佛', '佛说百佛名经'],
    ['宝月德佛', '佛说百佛名经'],
    ['尼瞿嚧陀婆瑳王佛', '佛说百佛名经'],
    ['常德佛', '佛说百佛名经'],
    ['普莲华佛', '佛说百佛名经'],
    ['平等德佛', '佛说百佛名经'],
    ['龙护救济佛', '佛说百佛名经'],
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

  /// 上次点选的名号（按名字记，位次会随增删变化）。
  String? _lastTappedName;

  bool get loaded => _loaded;

  int get length => _entries.length;

  List<ShanyishiEntry> get entries => List.unmodifiable(_entries);

  ShanyishiEntry? operator [](int index) =>
      (index >= 0 && index < _entries.length) ? _entries[index] : null;

  /// 上次点选的名号现在所在的位次；名号被删掉/改名找不到时返回 null
  /// （调用方退回「球心正前方那一位」）。
  int? get lastTappedIndex {
    final name = _lastTappedName;
    if (name == null || name.isEmpty) return null;
    final idx = _entries.indexWhere((e) => e.name == name);
    return idx < 0 ? null : idx;
  }

  /// 记住用户刚点选的名号（记名字不记位次），下次进页球心默认对准它。
  Future<void> rememberLastTapped(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _lastTappedName = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastTappedKey, trimmed);
  }

  /// 读本地数据；没存过时写入预置种子。幂等，可重复调用。
  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    if (force) _loaded = false;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    final seeded = raw == null || raw.isEmpty;
    final storedSeedVersion = prefs.getInt(_seedVersionKey) ?? 0;
    _lastTappedName = prefs.getString(_lastTappedKey);
    _entries.clear();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (seeded) {
      final seen = <String>{};
      for (var i = 0; i < _seeds.length; i++) {
        final seed = _seeds[i];
        final name = normalizeName(seed[0]);
        if (name.isEmpty || !seen.add(name)) continue;
        final sutras =
            seed.length > 1 ? _cleanSutras(seed.sublist(1)) : const <String>[];
        final paragraphs = sutras.contains('佛说百佛名经') ? [_baifoBenefit] : const <String>[];
        _entries.add(ShanyishiEntry(
          name: name,
          sutras: sutras,
          paragraphs: paragraphs,
          createdAt: now + i,
        ));
      }
    } else {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final e in decoded) {
          if (e is! Map) continue;
          final entry = ShanyishiEntry.fromJson(Map<String, dynamic>.from(e));
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
          final name = normalizeName(seed[0]);
          if (name.isEmpty || !existing.add(name)) {
            i++;
            continue;
          }
          final sutras = seed.length > 1 ? seed.sublist(1) : const <String>[];
          final paragraphs = sutras.contains('佛说百佛名经') ? [_baifoBenefit] : const <String>[];
          _entries.add(ShanyishiEntry(
            name: name,
            sutras: sutras,
            paragraphs: paragraphs,
            createdAt: now + i,
          ));
          i++;
        }
      }
    }
    // 分卷经书的「合并名」清一遍：老数据里可能还挂着「地藏菩萨本愿经」，
    // 点进去只会落到卷一；带卷标的（「…卷一」「…卷二」）照旧保留。
    for (var i = 0; i < _entries.length; i++) {
      final cleaned = _withoutMergedSutras(_entries[i]);
      if (!identical(cleaned, _entries[i])) _entries[i] = cleaned;
    }
    // 名号规范化：老数据里可能还带着「南无」前缀 /「摩诃萨」尾缀，
    // 统一去掉；因此撞名的两位合并成一位（经文与段落取并集）。
    _normalizeAllNames();
    _loaded = true;
    // seeded 时打上 provisional，云端有真实名单可覆盖；已有本地数据时
    // 传入 null，保留原有标记（上次种子尚未同步完成时不能丢标记）。
    await _persist(provisional: seeded ? true : null);
    await prefs.setInt(_seedVersionKey, _seedVersion);
    // 读回编辑前快照（一步撤销），跨重启也能恢复。
    _undo.clear();
    final rawUndo = prefs.getString(_undoKey);
    if (rawUndo != null && rawUndo.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawUndo) as List<dynamic>;
        for (final e in decoded) {
          if (e is! Map) continue;
          final entry = ShanyishiEntry.fromJson(Map<String, dynamic>.from(e));
          if (entry != null) _undo[entry.createdAt] = _withoutMergedSutras(entry);
        }
      } catch (_) {
        // 快照坏了就当作没有，不影响主数据。
      }
    }
    notifyListeners();
  }

  /// 云端恢复后强制重读本地数据，让页面立即反映同步结果。
  Future<void> reload() => load(force: true);

  /// [provisional] 为 true 时写入"首次启动种子"标记，false 时清除，
  /// null 表示保持原标记不变（加载已有数据时使用）。
  Future<void> _persist({bool? provisional = false}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefKey,
      jsonEncode([for (final e in _entries) e.toJson()]),
    );
    if (provisional == true) {
      await prefs.setBool(provisionalMarkerKey, true);
    } else if (provisional == false) {
      await prefs.remove(provisionalMarkerKey);
    }
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
  /// [allowDuplicate] 为 true 时即使同名也另起一位（用户明确选了「两个都留着」）。
  Future<int> add(
    String name,
    List<String> sutras, {
    Map<String, List<String>> quotes = const {},
    List<String> paragraphs = const [],
    bool allowDuplicate = false,
  }) async {
    final trimmed = normalizeName(name);
    if (trimmed.isEmpty) return -1;
    // 同名不重复录入：定位到已有的那一位，把经文与引用段落并进去。
    final existing =
        allowDuplicate ? -1 : _entries.indexWhere((e) => e.name == trimmed);
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
    var cleanedParagraphs = _cleanTexts(paragraphs);
    if (cleanedParagraphs.isEmpty && cleanedSutras.contains('佛说百佛名经')) {
      cleanedParagraphs = [_baifoBenefit];
    }
    _entries.add(ShanyishiEntry(
      name: trimmed,
      sutras: cleanedSutras,
      paragraphs: cleanedParagraphs,
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

  /// 通用尊称：名号里人人都有的字样，查重时不算「相同字符」。
  /// 「菩萨」这类通用称一旦计入，任何一位菩萨都会跟所有菩萨判成重复，故先摘掉。
  static const List<String> genericNameTerms = [
    '摩诃萨',
    '菩萨',
    '大士',
    '如来',
    '金刚',
    '明王',
    '上师',
    '大师',
    '尊者',
    '真言',
    '神咒',
    '心咒',
    '佛母',
    '佛',
    '咒',
    '母',
  ];

  /// 名号里真正有辨识度的部分：摘掉通用尊称后的字样。
  static String distinctName(String name) {
    var s = name.trim();
    for (final t in genericNameTerms) {
      s = s.replaceAll(t, '');
    }
    return s;
  }

  /// 两个名号之间有多少个相同字符（重复字按出现次数计）。
  /// 两个名号之间最长公共连续子串的长度。
  /// 必须是连着的相同字符序列才算相同（如「地藏菩萨」vs「地藏王菩萨」中的「地藏」）。
  static int nameCommonChars(String a, String b) {
    final xStr = a.trim();
    final yStr = b.trim();
    if (xStr.isEmpty || yStr.isEmpty) return 0;
    final x = xStr.runes.toList();
    final y = yStr.runes.toList();
    if (x.isEmpty || y.isEmpty) return 0;
    var maxLen = 0;
    final dp = List.generate(x.length + 1, (_) => List.filled(y.length + 1, 0));
    for (int i = 1; i <= x.length; i++) {
      for (int j = 1; j <= y.length; j++) {
        if (x[i - 1] == y[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
          if (dp[i][j] > maxLen) maxLen = dp[i][j];
        } else {
          dp[i][j] = 0;
        }
      }
    }
    return maxLen;
  }
  /// 保存前的查重名单：与 [name] 摘掉通用尊称（「菩萨 / 如来 / 佛 / 咒」等，
  /// 见 [genericNameTerms]）后还有 ≥ [minCommon] 个相同字符（默认 2 个）的
  /// 所有已有名号；完全同名必然命中。
  /// 按相同字符数从多到少排（同数按位次先后），[skip] 跳过自己那一位。
  List<(int, String)> findSimilarEntries(
    String name, {
    int minCommon = 2,
    int? skip,
  }) {
    final target = name.trim();
    if (target.isEmpty) return const [];
    final targetDistinct = distinctName(target);
    final hits = <(int, int)>[];
    for (var i = 0; i < _entries.length; i++) {
      if (i == skip) continue;
      final other = _entries[i].name;
      final n = other == target
          // 完全同名：不问长短，直接算命中（排最前）。
          ? target.runes.length + 1
          : nameCommonChars(targetDistinct, distinctName(other));
      if (n >= minCommon) hits.add((i, n));
    }
    hits.sort((a, b) => b.$2 != a.$2 ? b.$2 - a.$2 : a.$1 - b.$1);
    return [for (final h in hits) (h.$1, _entries[h.$1].name)];
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
    final newName = normalizeName(name ?? old.name);
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
      // 分卷经书的「合并名」不作为关联经文：点进去只会落到卷一。
      if (t.isEmpty || mergedSutraNames.contains(t)) continue;
      if (!out.contains(t)) out.add(t);
    }
    return out;
  }

  /// 去掉一位名号上挂着的「合并名」关联经文（带卷标的保留）。
  ///
  /// 老数据里可能还留着合并名（《地藏菩萨本愿经》），读档时顺手清掉。
  static ShanyishiEntry _withoutMergedSutras(ShanyishiEntry e) {
    final sutras = _cleanSutras(e.sutras);
    if (sutras.length == e.sutras.length) return e;
    return e.copyWith(sutras: sutras, quotes: _pruneQuotes(e.quotes, sutras));
  }

  /// 就地规范化所有名号：去「南无」前缀 /「摩诃萨」尾缀；规范化后撞名的
  /// 两位合并成一位（经文、引用段落取并集），保留最早出现的那一位。
  void _normalizeAllNames() {
    final merged = <String, int>{};
    final out = <ShanyishiEntry>[];
    for (final e in _entries) {
      final name = normalizeName(e.name);
      if (name.isEmpty) continue;
      final at = merged[name];
      if (at == null) {
        merged[name] = out.length;
        out.add(name == e.name ? e : e.copyWith(name: name));
        continue;
      }
      // 撞名：把这一位的经文/段落并进已保留的那一位。
      final keep = out[at];
      final sutras = _cleanSutras([...keep.sutras, ...e.sutras]);
      final paragraphs = _cleanTexts([...keep.paragraphs, ...e.paragraphs]);
      final quotes = <String, List<String>>{
        for (final q in keep.quotes.entries) q.key: List.of(q.value),
      };
      e.quotes.forEach((sutra, texts) {
        quotes[sutra] = _cleanTexts([...?quotes[sutra], ...texts]);
      });
      out[at] = keep.copyWith(
        sutras: sutras,
        paragraphs: paragraphs,
        quotes: _pruneQuotes(quotes, sutras),
      );
    }
    _entries
      ..clear()
      ..addAll(out);
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

  /// 名号规范化：去掉开头的「南无」三称前缀（「南无阿弥陀佛」→「阿弥陀佛」），
  /// 再去掉结尾的「摩诃萨」尊称尾缀（「虚空藏菩萨摩诃萨」→「虚空藏菩萨」）。
  /// 只处理整词前缀/后缀，名字中间的同字串不动。
  static String normalizeName(String name) {
    var s = name.trim();
    while (s.startsWith('南无')) {
      s = s.substring(2);
    }
    while (s.length > 3 && s.endsWith('摩诃萨')) {
      s = s.substring(0, s.length - 3);
    }
    return s.trim();
  }

  /// 把经文展示名解析成经藏条目（拿到可跳转的正文路径）。
  ///
  /// 目录未加载时返回 null（经文卡片退化为纯文本）。
  ///
  /// 解析顺序：
  ///  1. 精确匹配（展示名就是目录基础经名）；
  ///  2. 拆出「基础经名 + 卷号」→ 按卷取该卷正文路径（修掉「地藏菩萨本愿经
  ///     卷一」这类带卷标名以前解析不到的问题）；
  ///  3. 只有基础经名时取目录条目；
  ///  4. 「包含该名」的兜底**仅在唯一命中时**采用；命中多个即视为同名异本/
  ///     同名不同卷，返回 null，绝不猜测打开错译本。
  static NoteSutraLink? resolveSutra(String name) {
    final map = NoteSutraCatalog.cachedTitleMap;
    if (map == null || map.isEmpty) return null;
    final q = name.trim();
    if (q.isEmpty) return null;

    final exact = map[q];
    if (exact != null) return exact;

    var parsed = parseSutraTitleAndVolume(q);
    if (parsed.base.isNotEmpty && parsed.volume > 0) {
      final volPath =
          NoteSutraCatalog.cachedVolumePath(parsed.base, parsed.volume);
      if (volPath != null) {
        final base = map[parsed.base];
        return NoteSutraLink(
          title: q,
          filePath: volPath,
          size: base?.size ?? '',
          folder: base?.folder ?? '',
        );
      }
    }
    final baseLink = map[parsed.base.isEmpty ? q : parsed.base];
    if (baseLink != null) return baseLink;

    // 包含兜底：仅当全目录唯一命中时才认，多个候选一律不猜。
    NoteSutraLink? only;
    var hits = 0;
    for (final e in map.values) {
      if (e.title.contains(q)) {
        hits++;
        if (hits > 1) return null;
        only = e;
      }
    }
    return only;
  }

  /// 测试用：清空内存与标记，让下一次 load() 重新读。
  @visibleForTesting
  void resetForTest() {
    _entries.clear();
    _undo.clear();
    _lastTappedName = null;
    _loaded = false;
  }
}
