import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';

/// 记录类型：画线 / 感想 / 笔记。
enum RecordType { highlight, thought, note }

/// 一条记录（时间线上的一个条目）。
///
/// 记录来源有三处，全部在「用户产生动作的那一刻」落到本地索引：
///   - 画线 / 感想：读经页 [_saveParagraphNote] 保存成功后（云端一条记录
///     同时含 note 与 underlines，且只给一个 updatedAt，因此必须本地记时间，
///     否则同段落内画线与感想的先后永久丢失）。
///   - 笔记：读经页 / 笔记编辑页写入 SharedPreferences `notes` 之后。
class RecordItem {
  const RecordItem({
    required this.id,
    required this.type,
    required this.sutraKeys,
    required this.para,
    required this.text,
    required this.paraText,
    required this.createdAt,
    required this.updatedAt,
    this.shared = false,
    this.backfilled = false,
  });

  /// 画线：`h|经名|段下标|start|end`；感想：`t|经名|段下标`；笔记：`n|<笔记id>`。
  final String id;

  final RecordType type;

  /// 关联经名（一律用读经页的 sutraKey 形态：经名，可能带「卷X」）。
  /// 笔记可同时引用多部经，这里全部保留，筛选时任一命中即算命中。
  final List<String> sutraKeys;

  /// 段落下标；笔记为 -1。
  final int para;

  /// 画线 = 画线文字片段；感想 / 笔记 = 用户正文。
  final String text;

  /// 段落原文快照（仅感想，用于卡片展示「经文」引用块）。
  final String paraText;

  /// 动作发生时刻（毫秒）。
  final int createdAt;

  final int updatedAt;

  /// 笔记是否已分享到菩提空间。
  final bool shared;

  /// 由云端回填而来（缺段落原文 / 画线文字时按紧凑样式展示）。
  final bool backfilled;

  /// 主经名（列表展示用）。
  String get sutraKey => sutraKeys.isEmpty ? '' : sutraKeys.first;

  Map<String, dynamic> toJson() => {
        'i': id,
        't': type.index,
        'k': sutraKeys,
        'p': para,
        'x': text,
        'q': paraText,
        'c': createdAt,
        'u': updatedAt,
        's': shared ? 1 : 0,
        'b': backfilled ? 1 : 0,
      };

  static RecordItem? fromJson(Map<String, dynamic> j) {
    final id = (j['i'] ?? '').toString();
    if (id.isEmpty) return null;
    final t = (j['t'] as num?)?.toInt();
    if (t == null || t < 0 || t >= RecordType.values.length) return null;
    final keys = <String>[];
    final rawKeys = j['k'];
    if (rawKeys is List) {
      for (final k in rawKeys) {
        final s = k.toString();
        if (s.isNotEmpty && !keys.contains(s)) keys.add(s);
      }
    } else {
      final s = (rawKeys ?? '').toString();
      if (s.isNotEmpty) keys.add(s);
    }
    final created = (j['c'] as num?)?.toInt() ?? 0;
    return RecordItem(
      id: id,
      type: RecordType.values[t],
      sutraKeys: keys,
      para: (j['p'] as num?)?.toInt() ?? -1,
      text: (j['x'] ?? '').toString(),
      paraText: (j['q'] ?? '').toString(),
      createdAt: created,
      updatedAt: (j['u'] as num?)?.toInt() ?? created,
      shared: (j['s'] as num?)?.toInt() == 1,
      backfilled: (j['b'] as num?)?.toInt() == 1,
    );
  }
}

/// 本地「记录索引」：时间线页的唯一数据源。
///
/// 存应用文档目录 `record_index.json`（原子写），不进云端同步：
/// 单 key 体积上限 2MB，且索引可由「笔记本地全量 + 云端回填」重建。
class RecordIndex {
  static final RecordIndex instance = RecordIndex._();

  RecordIndex._();

  static const String fileName = 'record_index.json';

  /// 保存过记录 / 回填过的经名，回填时无需遍历整个经藏列表。
  static const String prefSutraKeys = 'record_sutra_keys';

  /// 索引条数上限，超出丢弃最旧的记录，避免文件无限增长。
  static const int maxItems = 5000;

  /// 索引变更版本号：写入方自增，时间线页监听后静默刷新。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final List<RecordItem> _items = [];
  final Map<String, int> _pos = {};

  bool _loaded = false;
  Future<void>? _loading;
  Timer? _debounce;
  Future<void> _writeChain = Future.value();

  bool get isLoaded => _loaded;

  /// 全部记录（按创建时间正序，便于裁剪最旧）。
  List<RecordItem> get items => List<RecordItem>.unmodifiable(_items);

  // ── 读取 ────────────────────────────────────────────────

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    final pending = _loading;
    if (pending != null) return pending;
    final f = _loading = _readFromDisk();
    await f;
    _loading = null;
  }

  Future<void> _readFromDisk() async {
    final list = <RecordItem>[];
    try {
      final file = await _resolveFile();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          for (final it in decoded) {
            if (it is Map) {
              final item = RecordItem.fromJson(it.cast<String, dynamic>());
              if (item != null) list.add(item);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[record-index] 读取失败：$e');
    }
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _items
      ..clear()
      ..addAll(list);
    _reindex();
    _loaded = true;
    revision.value++;
  }

  Future<File> _resolveFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}${Platform.pathSeparator}$fileName');
  }

  // ── 写入（读经页钩子） ────────────────────────────────────

  /// 把某一段的最终状态同步进索引：新增 / 修改 / 删除画线与感想一次搞定。
  ///
  /// [underlines] 传该段保存后的**完整**画线区间列表（与云端一致），
  /// 索引按区间 id 做差集，因此擦除某条画线会自动移除对应条目。
  Future<void> syncParagraph({
    required String sutraKey,
    required int para,
    required String paraText,
    required String thought,
    required List<({int start, int end})> underlines,
  }) async {
    await load();
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;

    // 感想：空文本视为删除。
    final thoughtId = 't|$sutraKey|$para';
    final thoughtPos = _pos[thoughtId];
    if (thought.trim().isEmpty) {
      if (thoughtPos != null) {
        _removeAt(thoughtPos);
        changed = true;
      }
    } else {
      changed |= _upsert(RecordItem(
        id: thoughtId,
        type: RecordType.thought,
        sutraKeys: [sutraKey],
        para: para,
        text: thought.trim(),
        paraText: paraText,
        createdAt: thoughtPos == null ? now : _items[thoughtPos].createdAt,
        updatedAt: now,
      ));
    }

    // 画线：按区间 id 差集同步。
    final ranges = underlines.where((u) => u.end > u.start).toList();
    final wanted = <String>{
      for (final r in ranges) 'h|$sutraKey|$para|${r.start}|${r.end}',
    };
    final stale = _items
        .where((i) =>
            i.type == RecordType.highlight &&
            i.sutraKey == sutraKey &&
            i.para == para &&
            !wanted.contains(i.id))
        .toList();
    for (final it in stale) {
      _remove(it.id);
      changed = true;
    }
    for (final r in ranges) {
      final id = 'h|$sutraKey|$para|${r.start}|${r.end}';
      if (_pos.containsKey(id)) continue;
      final snippet = _slice(paraText, r.start, r.end);
      if (snippet.isEmpty) continue;
      changed |= _upsert(RecordItem(
        id: id,
        type: RecordType.highlight,
        sutraKeys: [sutraKey],
        para: para,
        text: snippet,
        paraText: '',
        createdAt: now,
        updatedAt: now,
      ));
    }

    unawaited(_rememberSutraKey(sutraKey));
    if (changed) _touch();
  }

  /// 经文重排版（段落序号整体变化）后调用：按新的段号重建本经的画线/感想条目。
  ///
  /// 段号变了，旧 id 会在时间线上留下「幽灵」条目，因此这里先清空本经的
  /// 非笔记条目再重建；时间戳按 id 继承旧值，未变化的动作不会重排。
  /// 笔记（note）不属于经文段落数据，不受影响。
  Future<void> resyncSutra({
    required String sutraKey,
    required List<String> paragraphs,
    required Map<int, String> notes,
    required Map<int, List<Map<String, int>>> underlines,
  }) async {
    await load();
    final now = DateTime.now().millisecondsSinceEpoch;
    final prev = <String, int>{
      for (final i in _items)
        if (i.type != RecordType.note && i.sutraKey == sutraKey)
          i.id: i.createdAt,
    };
    var changed = false;
    for (final id in _items
        .where((i) => i.type != RecordType.note && i.sutraKey == sutraKey)
        .map((i) => i.id)
        .toList()) {
      _remove(id);
      changed = true;
    }

    String paraOf(int idx) =>
        idx >= 0 && idx < paragraphs.length ? paragraphs[idx] : '';

    for (final entry in notes.entries) {
      final text = entry.value.trim();
      if (text.isEmpty) continue;
      final id = 't|$sutraKey|${entry.key}';
      changed |= _upsert(RecordItem(
        id: id,
        type: RecordType.thought,
        sutraKeys: [sutraKey],
        para: entry.key,
        text: text,
        paraText: paraOf(entry.key),
        createdAt: prev[id] ?? now,
        updatedAt: now,
      ));
    }

    for (final entry in underlines.entries) {
      for (final u in entry.value) {
        final start = u['start'] ?? 0;
        final end = u['end'] ?? 0;
        if (end <= start) continue;
        final id = 'h|$sutraKey|${entry.key}|$start|$end';
        changed |= _upsert(RecordItem(
          id: id,
          type: RecordType.highlight,
          sutraKeys: [sutraKey],
          para: entry.key,
          text: _slice(paraOf(entry.key), start, end),
          paraText: paraOf(entry.key),
          createdAt: prev[id] ?? now,
          updatedAt: now,
        ));
      }
    }

    if (changed) _touch();
  }

  /// 读经页拉取本经段落笔记后调用：为回填记录补上段落原文 / 画线文字。
  /// 只填空字段，不改动任何时间戳。
  Future<void> enrichParagraphs({
    required String sutraKey,
    required List<String> paragraphs,
    required List<Map<String, dynamic>> rows,
  }) async {
    await load();
    var changed = false;
    for (final row in rows) {
      final idx = (row['index'] as num?)?.toInt() ?? -1;
      if (idx < 0) continue;
      final paraText = idx < paragraphs.length ? paragraphs[idx] : '';
      if (paraText.isEmpty) continue;

      final note = (row['note'] ?? '').toString().trim();
      if (note.isNotEmpty) {
        final pos = _pos['t|$sutraKey|$idx'];
        if (pos != null && _items[pos].paraText.isEmpty) {
          _items[pos] = RecordItem(
            id: _items[pos].id,
            type: _items[pos].type,
            sutraKeys: _items[pos].sutraKeys,
            para: _items[pos].para,
            text: _items[pos].text,
            paraText: paraText,
            createdAt: _items[pos].createdAt,
            updatedAt: _items[pos].updatedAt,
            shared: _items[pos].shared,
          );
          changed = true;
        }
      }

      final raw = row['underlines'];
      if (raw is! List) continue;
      for (final u in raw) {
        if (u is! Map) continue;
        final start = (u['start'] as num?)?.toInt() ?? 0;
        final end = (u['end'] as num?)?.toInt() ?? 0;
        if (end <= start) continue;
        final id = 'h|$sutraKey|$idx|$start|$end';
        final pos = _pos[id];
        if (pos == null || _items[pos].text.isNotEmpty) continue;
        final snippet = _slice(paraText, start, end);
        if (snippet.isEmpty) continue;
        final old = _items[pos];
        _items[pos] = RecordItem(
          id: old.id,
          type: old.type,
          sutraKeys: old.sutraKeys,
          para: old.para,
          text: snippet,
          paraText: '',
          createdAt: old.createdAt,
          updatedAt: old.updatedAt,
          shared: old.shared,
          backfilled: old.backfilled,
        );
        changed = true;
      }
    }
    if (changed) _touch();
  }

  // ── 笔记：以 SharedPreferences `notes` 为准，全量对账 ──────

  /// 用本地 `notes` 全量对账笔记条目：新增 / 更新已存在的，删除已不存在的。
  /// 因此笔记的保存、删除、回收站恢复都无需改动各自页面。
  Future<void> syncNotesFromPrefs() async {
    await load();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('notes') ?? '[]';
    List<dynamic> notes;
    try {
      final decoded = jsonDecode(raw);
      notes = decoded is List ? decoded : const [];
    } catch (_) {
      return;
    }
    final liveIds = <String>{};
    var changed = false;
    for (final it in notes) {
      if (it is! Map) continue;
      final map = it.cast<String, dynamic>();
      final id = (map['id'] ?? '').toString();
      if (id.isEmpty) continue;
      liveIds.add('n|$id');
      final content = (map['content'] ?? '').toString();
      if (content.trim().isEmpty) {
        // 正文被清空：视为删除，避免时间线留下空条目。
        if (_pos.containsKey('n|$id')) {
          _remove('n|$id');
          changed = true;
        }
        continue;
      }
      changed |= _upsertNote(id, content, (map['updatedAt'] ?? '').toString(),
          map['shared'] == true);
    }
    final gone = _items
        .where((i) => i.type == RecordType.note && !liveIds.contains(i.id))
        .map((i) => i.id)
        .toList();
    for (final id in gone) {
      _remove(id);
      changed = true;
    }
    if (changed) _touch();
  }

  bool _upsertNote(
      String noteId, String content, String updatedAtRaw, bool shared) {
    final id = 'n|$noteId';
    final ts = DateTime.tryParse(updatedAtRaw)?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
    final keys = extractSutraTitles(content);
    final body = stripSutraTags(content);
    if (body.trim().isEmpty && keys.isEmpty) return false;
    final pos = _pos[id];
    return _upsert(RecordItem(
      id: id,
      type: RecordType.note,
      sutraKeys: keys,
      para: -1,
      text: body.trim().isEmpty ? content.trim() : body,
      paraText: '',
      createdAt: pos == null ? ts : _items[pos].createdAt,
      updatedAt: ts,
      shared: shared,
    ));
  }

  // ── 云端回填（手动） ──────────────────────────────────────

  /// 扫描云端，把索引里还没有的画线 / 感想补进来。
  ///
  /// 云端接口按 sutraKey 查询（getParagraphNotes 强制要经名），且一条记录
  /// 只有一个 updatedAt、也不返回段落原文，因此回填项标记 [RecordItem.backfilled]，
  /// 卡片按紧凑样式展示；等用户再次打开该经，读经页会自动补齐原文与画线文字。
  Future<int> backfillFromCloud({
    void Function(int done, int total)? onProgress,
  }) async {
    if (!AuthService.instance.isLoggedIn) return 0;
    await load();
    final keys = <String>{};
    for (final k in await _knownSutraKeys()) {
      keys.add(k);
    }
    for (final it in _items) {
      if (it.type != RecordType.note) keys.add(it.sutraKey);
    }
    keys.removeWhere((k) => k.isEmpty);

    var added = 0;
    var done = 0;
    for (final key in keys) {
      try {
        final rows = await CloudNotesService.instance.getParagraphNotes(key);
        added += _absorbRows(key, rows);
      } catch (_) {}
      done++;
      onProgress?.call(done, keys.length);
    }
    if (added > 0) _touch();
    return added;
  }

  /// 吸收某经的云端段落记录，只补索引里没有的条目。
  int _absorbRows(String sutraKey, List<Map<String, dynamic>> rows) {
    var added = 0;
    for (final row in rows) {
      final idx = (row['index'] as num?)?.toInt() ?? -1;
      if (idx < 0) continue;
      final ts = (row['updatedAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
      final note = (row['note'] ?? '').toString().trim();
      if (note.isNotEmpty) {
        final id = 't|$sutraKey|$idx';
        if (!_pos.containsKey(id)) {
          if (_upsert(RecordItem(
            id: id,
            type: RecordType.thought,
            sutraKeys: [sutraKey],
            para: idx,
            text: note,
            paraText: '',
            createdAt: ts,
            updatedAt: ts,
            backfilled: true,
          ))) {
            added++;
          }
        }
      }
      final raw = row['underlines'];
      if (raw is! List) continue;
      for (final u in raw) {
        if (u is! Map) continue;
        final start = (u['start'] as num?)?.toInt() ?? 0;
        final end = (u['end'] as num?)?.toInt() ?? 0;
        if (end <= start) continue;
        final id = 'h|$sutraKey|$idx|$start|$end';
        if (_pos.containsKey(id)) continue;
        if (_upsert(RecordItem(
          id: id,
          type: RecordType.highlight,
          sutraKeys: [sutraKey],
          para: idx,
          text: '',
          paraText: '',
          createdAt: ts,
          updatedAt: ts,
          backfilled: true,
        ))) {
          added++;
        }
      }
    }
    return added;
  }

  /// 回填用的经名候选：本地经藏列表 + 记录过画线/感想的经名。
  Future<Set<String>> _knownSutraKeys() async {
    final out = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(prefSutraKeys);
      if (saved != null && saved.isNotEmpty) {
        for (final k in jsonDecode(saved)) {
          final s = k.toString();
          if (s.isNotEmpty) out.add(s);
        }
      }
    } catch (_) {}
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) {
              final t = (e['title'] ?? '').toString();
              if (t.isNotEmpty) out.add(t);
            }
          }
        }
      }
    } catch (_) {}
    return out;
  }

  Future<void> _rememberSutraKey(String sutraKey) async {
    if (sutraKey.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = <String>[];
      final saved = prefs.getString(prefSutraKeys);
      if (saved != null && saved.isNotEmpty) {
        final decoded = jsonDecode(saved);
        if (decoded is List) {
          for (final k in decoded) {
            final s = k.toString();
            if (s.isNotEmpty) list.add(s);
          }
        }
      }
      if (list.contains(sutraKey)) return;
      list.add(sutraKey);
      if (list.length > 400) {
        list.removeRange(0, list.length - 400);
      }
      await prefs.setString(prefSutraKeys, jsonEncode(list));
    } catch (_) {}
  }

  // ── 内部集合操作 ────────────────────────────────────────

  bool _upsert(RecordItem item) {
    final pos = _pos[item.id];
    if (pos == null) {
      _items.add(item);
      _reindex();
      return true;
    }
    if (_sameAs(pos, item)) return false;
    _items[pos] = item;
    return true;
  }

  bool _sameAs(int pos, RecordItem item) {
    final old = _items[pos];
    return old.text == item.text &&
        old.paraText == item.paraText &&
        old.sutraKeys.join('\u0001') == item.sutraKeys.join('\u0001') &&
        old.shared == item.shared &&
        old.backfilled == item.backfilled;
  }

  void _remove(String id) {
    final pos = _pos[id];
    if (pos == null) return;
    _removeAt(pos);
  }

  void _removeAt(int pos) {
    _items.removeAt(pos);
    _reindex();
  }

  void _reindex() {
    _pos
      ..clear()
      ..addEntries(
          _items.asMap().entries.map((e) => MapEntry(e.value.id, e.key)));
  }

  // ── 落盘 ───────────────────────────────────────────────

  void _touch() {
    revision.value++;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _persist);
  }

  Future<void> _persist() async {
    _debounce = null;
    _writeChain = _writeChain.then((_) => _writeNow());
    return _writeChain;
  }

  Future<void> _writeNow() async {
    try {
      if (_items.length > maxItems) {
        _items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _items.removeRange(0, _items.length - maxItems);
        _reindex();
      }
      final file = await _resolveFile();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
          jsonEncode([for (final it in _items) it.toJson()]),
          flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[record-index] 写入失败：$e');
    }
  }

  // ── 文本工具 ────────────────────────────────────────────

  /// 正文中的 `$经名` 引用：以汉字开头、不含句读与空白（与应用内分享帖
  /// 对「合法 $经名」的判定一致）。
  static final RegExp _sutraTagRe =
      RegExp(r'\$([\u4e00-\u9fff][^\n\u3000\s，。！？；：、,;:!?．]*)');

  static List<String> extractSutraTitles(String content) {
    final out = <String>[];
    for (final m in _sutraTagRe.allMatches(content)) {
      final t = m.group(1)?.trim() ?? '';
      if (t.isEmpty) continue;
      if (!out.contains(t)) out.add(t);
    }
    return out;
  }

  /// 去掉正文里的 `$经名` 引用行，只留用户写的部分。
  static String stripSutraTags(String content) {
    return content
        .replaceAll(_sutraTagRe, '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// 按 [start,end) 从段落原文切出画线片段（越界自动收敛）。
  static String _slice(String text, int start, int end) {
    if (text.isEmpty) return '';
    final s = start.clamp(0, text.length);
    final e = end.clamp(s, text.length);
    return text.substring(s, e).trim();
  }
}
