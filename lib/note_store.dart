import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';

/// 私有笔记的唯一写入口：本地 SharedPreferences 缓存 + 云端 userNotes 同步。
///
/// 为什么要有这层：笔记原先散落在 9 个文件里各写各的 prefs 数组，改一条要
/// 把整份数组取出来、解码、改、再编码写回去，且完全没有云端副本的单独通道
/// （只能挤在 setUserData 的共享大包里，撞上体积上限就静默丢数据）。
/// 集中到这里之后：
///  - 时间戳换算只做一次（见 [_toMillis]，这是本文件最容易出错的地方）；
///  - 离线期间的改动进 [_dirty] 队列，联网后自动补传；
///  - 云端与本地合并时不会把「尚未上传的本地改动」覆盖掉。
///
/// 本地 prefs 保留为离线缓存：断网、卸载重装前的最后一次本地会话都要能读到。
class NoteStore {
  static const String _notesKey = 'notes';
  static const String _trashKey = 'trash_notes';
  static const String _dirtyKey = 'notes_dirty';
  static const int _batchSize = 500;

  /// 一次性把某条笔记写进本地并标记为待上传。
  /// [trash] 为 true 表示这条笔记当前在回收站。
  static Future<void> save(Map<String, dynamic> note, {bool trash = false}) async {
    final id = (note['id'] ?? '').toString();
    if (id.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final bucket = await _readBucket(prefs, trash);
    final idx = bucket.indexWhere((n) => (n['id'] ?? '').toString() == id);
    if (idx >= 0) {
      bucket[idx] = note;
    } else {
      bucket.add(note);
    }
    await _writeBucket(prefs, trash, bucket);
    // 笔记在 notes 与 trash_notes 之间搬家时，两边都不能留残影。
    if (trash) {
      await _removeFromBucket(prefs, _notesKey, id);
    } else {
      await _removeFromBucket(prefs, _trashKey, id);
    }
    await _markDirty(prefs, id);
  }

  /// 把笔记移入回收站（软删除）。云端通过 deletedAt > 0 表达，不另建集合。
  static Future<void> softDelete(Map<String, dynamic> note) async {
    final moved = Map<String, dynamic>.of(note);
    moved['deletedAt'] = DateTime.now().toIso8601String();
    final prefs = await SharedPreferences.getInstance();
    final trash = await _readBucket(prefs, true);
    final id = (note['id'] ?? '').toString();
    trash.removeWhere((n) => (n['id'] ?? '').toString() == id);
    trash.add(moved);
    await _writeBucket(prefs, true, trash);
    await _removeFromBucket(prefs, _notesKey, id);
    await _markDirty(prefs, id);
  }

  /// 从回收站还原。
  static Future<void> restore(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final trash = await _readBucket(prefs, true);
    final idx = trash.indexWhere((n) => (n['id'] ?? '').toString() == id);
    if (idx < 0) return;
    final note = Map<String, dynamic>.of(trash[idx]);
    note.remove('deletedAt');
    await save(note);
  }

  /// 彻底删除（回收站里清空 / 删掉单条）。
  ///
  /// 云端不能靠「content 为空 + deletedAt=0」判断删除：那和一篇真的空笔记
  /// 无法区分，会把空笔记也误删。所以推一条 deletedAt>0 的墓碑，云端看到
  /// 就把该文档真正移除（见云函数 upsertUserNotes 的 tombstone 分支）。
  /// 墓碑存在 [_tombstoneKey] 这个**列表**里——清空回收站一次会删几十条，
  /// 之前只存单个 id 会导致除最后一条外全部删不掉。
  static Future<void> purge(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await _removeFromBucket(prefs, _notesKey, id);
    await _removeFromBucket(prefs, _trashKey, id);
    if (id.isEmpty) return;
    final tombstones = await _readTombstones(prefs);
    if (tombstones.add(id)) {
      await prefs.setString(_tombstoneKey, jsonEncode(tombstones.toList()));
    }
    await _markDirty(prefs, id);
  }

  /// 彻底删除多条（清空回收站）。
  static Future<void> purgeAll(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final tombstones = await _readTombstones(prefs);
    final dirty = await _readDirty(prefs);
    for (final raw in ids) {
      final id = raw.toString();
      if (id.isEmpty) continue;
      await _removeFromBucket(prefs, _notesKey, id);
      await _removeFromBucket(prefs, _trashKey, id);
      tombstones.add(id);
      dirty.add(id);
    }
    await prefs.setString(_tombstoneKey, jsonEncode(tombstones.toList()));
    await prefs.setString(_dirtyKey, jsonEncode(dirty.toList()));
  }

  static const String _tombstoneKey = 'notes_tombstone';

  /// 尚未上云的墓碑 id 集合。
  static Future<Set<String>> _readTombstones(SharedPreferences prefs) async {
    final raw = prefs.getString(_tombstoneKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded.map((e) => e.toString()).where((e) => e.isNotEmpty).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  /// 读取本地笔记（不含回收站）。
  static Future<List<Map<String, dynamic>>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return _readBucket(prefs, false);
  }

  /// 读取回收站。
  static Future<List<Map<String, dynamic>>> loadTrash() async {
    final prefs = await SharedPreferences.getInstance();
    return _readBucket(prefs, true);
  }

  // ── 云端同步 ────────────────────────────────────────────────────

  /// 拉取云端笔记并与本地合并。
  ///
  /// 云端为准，但**本地有未上传改动的笔记例外**：那些 id 保留本地版本，
  /// 由 [flush] 负责推上去。否则一次 pull 就会把用户断网期间写的内容
  /// 悄悄改回旧版本——这正是「云同步后又变回旧内容」的典型原因。
  static Future<void> pull() async {
    if (!AuthService.instance.isLoggedIn) return;
    final prefs = await SharedPreferences.getInstance();
    final dirty = await _readDirty(prefs);
    final remote = <String, Map<String, dynamic>>{};
    UserNotesCursor? cursor;
    var guard = 0;
    do {
      final page = await CloudNotesService.instance.fetchUserNotes(
        pageSize: _batchSize,
        cursor: cursor,
      );
      for (final row in page.notes) {
        final id = (row['noteId'] ?? '').toString();
        if (id.isNotEmpty) remote[id] = row;
      }
      cursor = page.cursor;
      // 上限只是防呆：真有几万条笔记时也不该把云函数拉死。
      if (++guard > 200) break;
    } while (cursor != null);

    final tombstones = await _readTombstones(prefs);
    final notes = await _readBucket(prefs, false);
    final trash = await _readBucket(prefs, true);

    // 纯本地（云端还没有）且不脏的笔记直接丢掉：那些是已登录用户的孤儿数据，
    // 云端才是权威。脏的留下，等 flush 推上去。
    final mergedNotes = <Map<String, dynamic>>[];
    final mergedTrash = <Map<String, dynamic>>[];
    for (final local in [...notes, ...trash]) {
      final id = (local['id'] ?? '').toString();
      if (dirty.contains(id)) {
        (local['deletedAt'] == null ? mergedNotes : mergedTrash).add(local);
        continue;
      }
      final row = remote[id];
      if (row == null) continue; // 云端没有 → 已被别处删除，以云端为准
      final local2 = fromCloud(row);
      (local2['deletedAt'] == null ? mergedNotes : mergedTrash).add(local2);
    }
    // 云端有、本地完全没有的（换机 / 重装后恢复）也要补进来。
    final localIds = <String>{
      ...mergedNotes.map((n) => (n['id'] ?? '').toString()),
      ...mergedTrash.map((n) => (n['id'] ?? '').toString()),
    };
    for (final entry in remote.entries) {
      if (localIds.contains(entry.key)) continue;
      // 已在本机彻底删除的，别又从云端拉回来复活。
      if (tombstones.contains(entry.key)) continue;
      final row = fromCloud(entry.value);
      (row['deletedAt'] == null ? mergedNotes : mergedTrash).add(row);
    }

    mergedNotes.sort((a, b) => (b['updatedAt'] ?? '').toString().compareTo((a['updatedAt'] ?? '').toString()));
    mergedTrash.sort((a, b) => (b['deletedAt'] ?? '').toString().compareTo((a['deletedAt'] ?? '').toString()));
    await prefs.setString(_notesKey, jsonEncode(mergedNotes));
    await prefs.setString(_trashKey, jsonEncode(mergedTrash));
  }

  /// 把待上传队列推上云端。未登录时静默返回（本地仍然写好了）。
  static Future<void> flush() async {
    if (!AuthService.instance.isLoggedIn) return;
    final prefs = await SharedPreferences.getInstance();
    final dirty = await _readDirty(prefs);
    if (dirty.isEmpty) return;
    final notes = await _readBucket(prefs, false);
    final trash = await _readBucket(prefs, true);
    final tombstones = await _readTombstones(prefs);

    final byId = <String, Map<String, dynamic>>{};
    for (final n in [...notes, ...trash]) {
      final id = (n['id'] ?? '').toString();
      if (id.isNotEmpty) byId[id] = n;
    }

    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final nowIso = DateTime.fromMillisecondsSinceEpoch(nowMillis).toIso8601String();
    final payload = <Map<String, dynamic>>[];
    for (final id in dirty) {
      final n = byId[id];
      // 彻底删除，或本地已无此条（被打过墓碑）→ 推墓碑让云端真删文档。
      if (tombstones.contains(id) || n == null) {
        payload.add(toCloud(
          <String, dynamic>{'id': id, 'content': '', 'updatedAt': nowIso},
          trashed: true,
          deletedAtMillis: nowMillis,
        ));
        continue;
      }
      payload.add(toCloud(n, trashed: n['deletedAt'] != null));
    }

    try {
      for (var i = 0; i < payload.length; i += _batchSize) {
        final end = (i + _batchSize).clamp(0, payload.length);
        final slice = payload.sublist(i, end);
        final ids = slice
            .map((p) => (p['noteId'] ?? '').toString())
            .where((x) => x.isNotEmpty)
            .toList();
        await CloudNotesService.instance.upsertUserNotes(slice);
        // 只有云端确认写入成功，才清脏标记和墓碑。顺序不能反：
        // 先清本地状态再上传，一旦上传失败这条改动就彻底没人记得了。
        await _clearDirty(prefs, ids);
        tombstones.removeAll(ids);
      }
      if (tombstones.isEmpty) {
        await prefs.remove(_tombstoneKey);
      } else {
        await prefs.setString(_tombstoneKey, jsonEncode(tombstones.toList()));
      }
    } on CloudApiException catch (e) {
      debugPrint('[NoteStore] flush 失败（保留脏队列待重试）: ${e.message}');
    } catch (e) {
      debugPrint('[NoteStore] flush 异常（保留脏队列待重试）: $e');
    }
  }

  /// 登录后调一次：先补传本地未上传的改动，再拉云端覆盖本地。
  static Future<void> sync() async {
    if (!AuthService.instance.isLoggedIn) return;
    await flush();
    try {
      await pull();
    } on CloudApiException catch (e) {
      debugPrint('[NoteStore] pull 失败（保留本地）: ${e.message}');
    } catch (e) {
      debugPrint('[NoteStore] pull 异常（保留本地）: $e');
    }
  }

  // ── 内部工具 ────────────────────────────────────────────────────

  /// 本地 ISO8601 字符串 → 云端 epoch 毫秒。
  ///
  /// 这是本文件最关键的一处：本地笔记的 updatedAt 存的是
  /// DateTime.toIso8601String()，而云端排序/游标要的是数值。直接
  /// `Number("2026-09-28T10:00:00.000")` 得到的是 NaN，会被
  /// `|| 0` 兜成 0，于是所有笔记的 updatedAt 全变 0，游标分页立刻失效
  /// （排序乱、翻页重复或漏页）。所以必须在这里统一解析。
  @visibleForTesting
  static int toMillis(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    final s = (v ?? '').toString().trim();
    if (s.isEmpty) return 0;
    final asInt = int.tryParse(s);
    if (asInt != null) return asInt;
    final parsed = DateTime.tryParse(s);
    if (parsed == null) return 0;
    return parsed.millisecondsSinceEpoch;
  }

  /// 云端 epoch 毫秒 → 本地 ISO8601 字符串，保持 UI 层读到的形状不变。
  @visibleForTesting
  static String toIso(int millis) {
    if (millis <= 0) return '';
    return DateTime.fromMillisecondsSinceEpoch(millis).toIso8601String();
  }

  /// 从正文里的 `$经名` 标签提取经文 key。
  ///
  /// 本地笔记没有单独的 sutraKeys 字段，经文关联是写在正文里的
  /// （reading_sutra_notes_page 就是靠 content.contains('\$金剛經') 筛的）。
  /// 这里顺手抽出来存到云端，方便以后按经文反查笔记，不必再全表扫正文。
  @visibleForTesting
  static List<String> extractSutraKeys(String content) {
    final keys = <String>[];
    // 经名以书名号收尾（正文里就是「《$金剛經》」这种写法），所以排除
    // 一律要包含 CJK 收尾标点，否则会把「金剛經》有感」整段吃成经名，
    // 抽出来的 key 反查不到任何东西。开头同理排除《与空白。
    final re = RegExp(r'\$([^《》\s\$\n]{1,64})');
    for (final m in re.allMatches(content)) {
      final k = m.group(1);
      if (k != null && k.isNotEmpty && !keys.contains(k)) keys.add(k);
      if (keys.length >= 32) break;
    }
    return keys;
  }

  /// 本地笔记 → 云端 payload。
  @visibleForTesting
  static Map<String, dynamic> toCloud(
    Map<String, dynamic> n, {
    required bool trashed,
    int? deletedAtMillis,
  }) {
    final content = (n['content'] ?? '').toString();
    final updatedAt = toMillis(n['updatedAt']);
    // 本地笔记没有 createdAt，用 updatedAt 兜底；云端只在该 id 首次写入时
    // 采纳这个值，之后一律保留云端已有的，所以不会因重传而整体后移。
    final createdAt = toMillis(n['createdAt']) > 0
        ? toMillis(n['createdAt'])
        : updatedAt;
    return {
      'noteId': (n['id'] ?? '').toString(),
      'title': (n['title'] ?? '').toString(),
      'content': content,
      'createdAt': createdAt,
      'updatedAt': updatedAt > 0 ? updatedAt : DateTime.now().millisecondsSinceEpoch,
      'sutraKeys': extractSutraKeys(content),
      'shared': n['shared'] == true,
      'cloudId': (n['cloudId'] ?? '').toString(),
      'deletedAt': trashed ? (deletedAtMillis ?? toMillis(n['deletedAt'])) : 0,
    };
  }

  /// 云端行 → 本地笔记。
  @visibleForTesting
  static Map<String, dynamic> fromCloud(Map<String, dynamic> row) {
    final deletedAt = (row['deletedAt'] as num?)?.toInt() ?? 0;
    return {
      'id': (row['noteId'] ?? '').toString(),
      'title': (row['title'] ?? '').toString(),
      'content': (row['content'] ?? '').toString(),
      'createdAt': toIso((row['createdAt'] as num?)?.toInt() ?? 0),
      'updatedAt': toIso((row['updatedAt'] as num?)?.toInt() ?? 0),
      'shared': row['shared'] == true,
      'cloudId': (row['cloudId'] ?? '').toString(),
      if (deletedAt > 0) 'deletedAt': toIso(deletedAt),
    };
  }

  static Future<List<Map<String, dynamic>>> _readBucket(
    SharedPreferences prefs,
    bool trash,
  ) async {
    final raw = prefs.getString(trash ? _trashKey : _notesKey) ?? '[]';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writeBucket(
    SharedPreferences prefs,
    bool trash,
    List<Map<String, dynamic>> list,
  ) async {
    await prefs.setString(
      trash ? _trashKey : _notesKey,
      jsonEncode(list),
    );
  }

  static Future<void> _removeFromBucket(
    SharedPreferences prefs,
    String key,
    String id,
  ) async {
    final isTrash = key == _trashKey;
    final list = await _readBucket(prefs, isTrash);
    final before = list.length;
    list.removeWhere((n) => (n['id'] ?? '').toString() == id);
    if (list.length == before) return;
    await _writeBucket(prefs, isTrash, list);
  }

  static Future<Set<String>> _readDirty(SharedPreferences prefs) async {
    final raw = prefs.getString(_dirtyKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded.map((e) => e.toString()).where((e) => e.isNotEmpty).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> _markDirty(SharedPreferences prefs, String id) async {
    if (id.isEmpty) return;
    final dirty = await _readDirty(prefs);
    dirty.add(id);
    await prefs.setString(_dirtyKey, jsonEncode(dirty.toList()));
  }

  static Future<void> _clearDirty(
    SharedPreferences prefs,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return;
    final dirty = await _readDirty(prefs);
    dirty.removeAll(ids);
    if (dirty.isEmpty) {
      await prefs.remove(_dirtyKey);
    } else {
      await prefs.setString(_dirtyKey, jsonEncode(dirty.toList()));
    }
  }
}
