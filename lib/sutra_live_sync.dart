import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'note_sutra_links.dart';
import 'sutra_asset_path.dart';
import 'sutra_downloader.dart';
import 'sutra_edit_page.dart' show editedSutraFilePath;

/// 菩提空间分享帖「画线 / 感想」页的实时数据同步工具。
///
/// 分享到菩提空间时正文里存的是分享那一刻的快照；当用户后来在画线 / 感想页
/// 新增或删除，快照页就过时了。这里按与读经页一致的加载顺序解析经书段落，
/// 再结合云端当前段落笔记，重建最新画线 / 感想数据，让分享出去的页面与用户
/// 当前的画线 / 感想页保持一致。

/// 实时重建的有界上限：任何规模的云端数据都只产生有限输出，
/// 从根上杜绝大幅合并/巨量画线造成的 UI 阻塞。
const int kLiveMaxItems = 2000;
const int kLiveMaxRangesPerPara = 5000;
const int kLiveMaxCharsPerItem = 100000;
const int kLiveMaxNotes = 3000;

/// 一条实时画线项内的一段画线：段落下标 + 该段内 [start,end) 区间。
typedef LiveHighlightSegment = ({int para, int start, int end});

/// 一条实时画线项：合并后的展示文字 + 组成它的各段画线（多段时可跨 `。。。///` 连段）。
typedef LiveHighlightItem = ({String text, List<LiveHighlightSegment> segments});

/// 一条实时感想项：经文 + 感想 + 所属段落下标。
typedef LiveThoughtItem = ({String paragraph, String note, int para});

/// 拆段逻辑与读经页 `_parseParagraphs` 一致（剔除 `。。。`、`///` 等分段标记），
/// 并额外返回「紧密连段」段落下标集合：`tight.contains(j)` 表示段落 j 与 j+1 之间无间隔。
({List<String> paragraphs, Set<int> tight}) parseSutraTight(String content) {
  final out = <String>[];
  final tight = <int>{};
  final lines = content.split('\n');
  const hideMark = '。。。';
  const tightUnits = ['///', '／／／'];
  for (final line in lines) {
    var text = line.trim();
    if (text.isEmpty) continue;
    var isTight = false;
    // 尾部标记：正文。。。  或  正文。。。/// / 正文///。。。
    for (final u in tightUnits) {
      if (text.endsWith(hideMark + u)) {
        text = text.substring(0, text.length - hideMark.length - u.length);
        isTight = true;
        break;
      }
      if (text.endsWith(u + hideMark)) {
        text = text.substring(0, text.length - u.length - hideMark.length);
        isTight = true;
        break;
      }
    }
    if (!isTight && text.endsWith(hideMark)) {
      text = text.substring(0, text.length - hideMark.length);
    }
    // 头部标记：。。。正文  或   。。。///正文 / ///。。。正文
    for (final u in tightUnits) {
      if (text.startsWith(hideMark + u)) {
        text = text.substring(hideMark.length + u.length);
        isTight = true;
        break;
      }
      if (text.startsWith(u + hideMark)) {
        text = text.substring(u.length + hideMark.length);
        isTight = true;
        break;
      }
    }
    if (!isTight && text.startsWith(hideMark)) {
      text = text.substring(hideMark.length);
    }
    text = text.trim();
    if (text.isEmpty) continue;
    if (isTight) tight.add(out.length);
    out.add(text);
  }
  return (paragraphs: out, tight: tight);
}

/// 拆段逻辑与读经页 `_parseParagraphs` 一致（剔除 `。。。`、`///` 等分段标记）。
List<String> parseSutraParagraphs(String content) =>
    parseSutraTight(content).paragraphs;

/// 由段落下标 [index] 向两边扩展，找到与其用 `。。。///` 连成一体的整簇下标列表。
/// `tight.contains(j)` 表示段落 j 与 j+1 之间无间隔。
List<int> tightClusterOf(int index, Set<int> tight, int length) {
  if (length <= 1) return [index.clamp(0, length - 1)];
  var lo = index;
  var hi = index;
  while (lo > 0 && tight.contains(lo - 1)) lo--;
  while (hi < length - 1 && tight.contains(hi)) hi++;
  return [for (var k = lo; k <= hi; k++) k];
}

/// 把连续段落下标按 `。。。///` 紧密连段切成多个「渲染簇」：
/// 每簇内相邻段落两两相连（无间隔），对外表现为一段。
List<List<int>> tightClusterGroups(List<int> indices, Set<int> tight) {
  final groups = <List<int>>[];
  var cur = <int>[];
  for (var i = 0; i < indices.length; i++) {
    final idx = indices[i];
    cur.add(idx);
    final nextIdx = i + 1 < indices.length ? indices[i + 1] : -1;
    if (nextIdx != idx + 1 || !tight.contains(idx)) {
      groups.add(cur);
      cur = <int>[];
    }
  }
  if (cur.isNotEmpty) groups.add(cur);
  return groups;
}

/// 一簇的合并文本：段落间用 `\n` 连接（与编辑器的「不分段」视觉一致）。
String tightClusterText(List<String> paragraphs, List<int> cluster) =>
    [for (final k in cluster) paragraphs[k]].join('\n');

/// 某段所属整簇的合并文本：非连段时就是该段本身。
String tightClusterTextFor(
    List<String> paragraphs, Set<int> tight, int index) {
  if (index < 0 || index >= paragraphs.length) return '';
  final cluster = tightClusterOf(index, tight, paragraphs.length);
  return tightClusterText(paragraphs, cluster);
}

/// 按与读经页一致的优先级加载经书各段原文 + 紧密连段标记：
/// 已编辑副本 → 本地下载副本 → 打包资源 → 原文件 → 按需自动下载。
/// 失败返回 null。
Future<({List<String> paragraphs, Set<int> tight})?> loadSutraTight({
  required String title,
  required String filePath,
}) async {
  String? content;
  // 1. 已编辑副本（读经页里编辑经文后保存的本地文件）。
  try {
    final editedPath = await editedSutraFilePath(filePath);
    final f = File(editedPath);
    if (await f.exists()) {
      content = await f.readAsString();
      debugPrint('[loadTight] 1/编辑副本命中: ${editedPath.length > 80 ? editedPath.substring(editedPath.length - 80) : editedPath}');
    }
  } catch (_) {}
  // 2. 本地已下载副本。
  if (content == null) {
    try {
      File? local;
      if (filePath.startsWith('assets/sutras_ascii/')) {
        local = await SutraDownloader.localFileForAssetPath(filePath);
      }
      if (local == null) {
        final id = SutraDownloader.extractId(title, filePath);
        if (id != null &&
            id.isNotEmpty &&
            await SutraDownloader.isDownloaded(id)) {
          local = await SutraDownloader.localFile(id);
        }
      }
      if (local != null) {
        content = await local.readAsString();
        debugPrint('[loadTight] 2/本地下载副本命中');
      }
    } catch (_) {}
  }
  // 3. 打包资源。
  if (content == null && filePath.startsWith('assets/')) {
    try {
      content = await rootBundle.loadString(filePath);
      debugPrint('[loadTight] 3/打包资源命中');
    } catch (_) {}
  }
  // 4. 原文件。
  if (content == null) {
    try {
      final f = File(filePath);
      if (await f.exists()) {
        content = await f.readAsString();
        debugPrint('[loadTight] 4/原文件命中');
      }
    } catch (_) {}
  }
  // 5. 本地与打包都没有正文时，按需自动下载（优先管理员编辑版，回退原始版）：
  //    与读经页无正文时的自动下载一致，保证分享帖的实时重建能取到经书正文，
  //    避免重装/换机后因正文缺失而回退到分享快照。
  if (content == null) {
    // 从路径或标题提取经书 ID；取不到时再按规范化路径解析一次，
    // 兜底「标题不带编号、路径又退化」导致无法下载的情况。
    var id = SutraDownloader.extractId(title, filePath);
    if (id == null || id.isEmpty) {
      try {
        id = SutraDownloader.extractId(
            null, SutraAssetPath.resolve(title: title, filePath: filePath));
      } catch (_) {}
    }
    if (id == null || id.isEmpty) {
      debugPrint('[loadTight] 5/自动下载跳过：未能提取经书ID, title=$title, filePath=$filePath');
    } else {
      try {
        final f = await SutraDownloader.download(id, preferEdited: true);
        content = await f.readAsString();
        debugPrint('[loadTight] 5/自动下载成功: $id');
      } catch (e) {
        debugPrint('[loadTight] 5/自动下载正文失败: $id $e');
      }
    }
  }
  if (content == null) {
    debugPrint('[loadTight] 定位正文失败: title=$title, filePath=$filePath');
    return null;
  }
  return parseSutraTight(content);
}

/// 按与读经页一致的优先级加载经书各段原文。失败返回 null。
Future<List<String>?> loadSutraParagraphs({
  required String title,
  required String filePath,
}) async {
  final r = await loadSutraTight(title: title, filePath: filePath);
  return r?.paragraphs;
}

/// 仅凭经书名加载段落原文：优先使用调用方已知的 [filePath]（如分享帖里记录的原路径），
/// 否则按经书目录解析正文路径（不影响调用方传入的 `sutraLibrary` 快照是否为空），
/// 再交回 [loadSutraParagraphs]。找不到经文返回 null。
Future<List<String>?> loadSutraParagraphsByTitle(
  String title, {
  String? filePath,
}) async {
  final r = await loadSutraTightByTitle(title, filePath: filePath);
  return r?.paragraphs;
}

/// 同 [loadSutraParagraphsByTitle]，额外返回紧密连段标记。
/// 优先使用调用方已知的 [filePath]；若该路径已失效（例如来自历史分享帖、或
/// 管理员改排版后本地路径与帖子记录不一致），自动按经书名重新解析正文路径
/// 再试一次，兜底「本地明明有这部经却定位不到」的橙色提示问题。
/// 返回值额外带 [filePath]：实际命中正文的路径（已解析到 CBETA 编号），
/// 供调用方推导「读经页存笔记用的完整 key」。
Future<({List<String> paragraphs, Set<int> tight, String filePath})?>
    loadSutraTightByTitle(
  String title, {
  String? filePath,
}) async {
  var path = (filePath ?? '').trim();
  if (path.isNotEmpty) {
    final r = await loadSutraTight(title: title, filePath: path);
    if (r != null) {
      debugPrint('[loadTight] 用已存路径命中: ${path.length > 60 ? path.substring(0, 60) + '…' : path}');
      return (paragraphs: r.paragraphs, tight: r.tight, filePath: path);
    }
    debugPrint('[loadTight] 已存路径未命中: $path');
  }
  // 按经书名兜底解析：目录中的官方路径 → 资产路径。
  String resolved = '';
  try {
    final lib = await NoteSutraCatalog.titleMap();
    resolved = (lib[title]?.filePath ?? '').trim();
    if (resolved.isEmpty) {
      // 多卷经书帖子的标题可能带「卷X」后缀（如「地藏菩萨本愿经卷一」），
      // 去掉卷标后按基础经名再查一次目录。
      final vol = _volumeOf(title);
      if (vol > 0) {
        final base = _stripVolumeSuffix(title);
        final entry = lib[base];
        if (entry != null) {
          resolved = NoteSutraCatalog.cachedVolumePath(base, vol) ??
              entry.filePath;
          debugPrint('[loadTight] 按卷标${vol}解析: $resolved');
        }
      }
      if (resolved.isEmpty) {
        debugPrint('[loadTight] 目录未命中标题, 尝试子串回退: $title');
        // 目录键与帖子标题不是逐字一致时（如空格/用词差异），取「标题包含目录键
        // 或目录键包含标题」中最长的一条，保证仍能解析到带编号的正文路径。
        String? bestKey;
        String? bestPath;
        for (final e in lib.entries) {
          if (title.contains(e.key) || e.key.contains(title)) {
            if (bestKey == null || e.key.length > bestKey.length) {
              bestKey = e.key;
              bestPath = e.value.filePath;
            }
          }
        }
        if (bestKey != null) {
          resolved = bestPath!;
          debugPrint('[loadTight] 子串回退命中: $bestKey -> $resolved');
        }
      }
    } else {
      debugPrint('[loadTight] 目录精确命中: $resolved');
    }
  } catch (e) {
    debugPrint('[loadTight] 目录加载失败: $e');
  }
  if (resolved.isEmpty) {
    resolved = SutraAssetPath.resolve(title: title).trim();
  }
  debugPrint('[loadTight] 按书名兜底最终路径: $resolved');
  if (resolved.isEmpty) return null;
  final r = await loadSutraTight(title: title, filePath: resolved);
  if (r == null) return null;
  return (paragraphs: r.paragraphs, tight: r.tight, filePath: resolved);
}

/// 中文卷标提取：`卷一`→1、`卷六百零五`→605；无卷标返回 0。
int _volumeOf(String title) {
  final m = RegExp(r'卷(.+)$').firstMatch(title);
  if (m == null) return 0;
  const digits = '零一二三四五六七八九';
  final Map<String, int> map = {for (var i = 0; i < digits.length; i++) digits[i]: i};
  var n = 0;
  for (final ch in m.group(1)!.split('')) {
    final d = map[ch];
    if (d == null) return 0;
    n = n * 10 + d;
  }
  return n;
}

/// 去掉尾部「卷X」卷标，返回基础经名。
String _stripVolumeSuffix(String title) {
  final m = RegExp(r'^(.+?)卷(.+)$').firstMatch(title);
  return m == null ? title : m.group(1)!.trimRight();
}

/// 去掉 CBETA 编号与「卷X」卷标后缀，返回基础经名
/// （读经页 widget.title 可能是「基础经名T编号」或「基础经名卷X」）。
String _sutraBaseTitle(String title) => _stripVolumeSuffix(
    title.replaceAll(RegExp(r'T\d+n[0-9A-Za-z]+_\d+$'), '').trim());

/// 同一部经的段落笔记可能因入口不同而存到不同 key 下：
///   - 读经页以「当前经名」为 key（可能是基础经名，也可能带 CBETA 编号
///     /「卷X」卷标，具体看用户从哪个入口打开）；
///   - 菩提空间分享帖标题是展示名（基础经名 或 基础经名+卷X），
///     未必与读经页的笔记 key 逐字相等。
/// 若只按帖子标题去查，作者明明有画线却会查到空 → 实时重建走空分支，
/// 误报「作者已删除全部画线 / 感想」。这里生成候选 key 分别拉取作者当前笔记，
/// 按段合并后返回；同时给出「实际命中笔记的 key」，供本页实时删除写回同一位置。
/// [filePath] 为实时重建定位到的正文路径（已解析出 CBETA 编号），
/// 用于补出带编号的候选 key。
Future<({List<Map<String, dynamic>> items, String key})>
    fetchParagraphNotesUnion(
  String title,
  String userId, {
  String? filePath,
}) async {
  final base = _sutraBaseTitle(title);
  final id = SutraDownloader.extractId(null, filePath ?? '') ??
      SutraDownloader.extractId(title);
  final candidates = <String>{
    title,
    if (base.isNotEmpty) base,
    if (base.isNotEmpty && id != null && id.isNotEmpty) '$base$id',
  };
  final results = <String, List<Map<String, dynamic>>>{};
  for (final key in candidates) {
    try {
      results[key] = await CloudNotesService.instance
          .getParagraphNotes(key, userId: userId);
      debugPrint('[notes-union] key=$key items=${results[key]!.length}');
    } catch (_) {
      // 某个候选 key 拉取失败（网络/云端异常）不影响其它候选继续尝试。
      debugPrint('[notes-union] key=$key 拉取失败');
    }
  }
  final out = mergeParagraphNotes(results, defaultKey: title);
  debugPrint('[notes-union] primary=${out.key} merged=${out.items.length}');
  return out;
}

Map<String, dynamic> _normalizedNoteEntry(Map<String, dynamic> it) => {
      'index': it['index'],
      'text': it['text'],
      'note': it['note'],
      'shared': it['shared'],
      'cloudId': it['cloudId'],
      if (it['underlines'] is List)
        'underlines': [
          for (final u in it['underlines'] as List)
            if (u is Map) {...u},
        ]
    };

/// 纯合并：把「候选 key → 原始笔记」合成为按段合并的作者笔记。
/// 同一段来自多个 key 时：画线区间按 start-end 去重合并，感想取首个非空。
/// 返回合并后的条目 + 命中笔记最多的主 key（供实时删除写回同一位置）；
/// 所有候选都拉取失败时返回空条目，主 key 取 [defaultKey]。
({List<Map<String, dynamic>> items, String key}) mergeParagraphNotes(
  Map<String, List<Map<String, dynamic>>> results, {
  required String defaultKey,
}) {
  final byIndex = <int, Map<String, dynamic>>{};
  // 主 key = 首选「确实命中笔记」的候选（按候选顺序取第一个非空）：
  // 作者某部经的笔记通常只存于一个 key 下，哪个候选先命中就写回哪个，
  // 保证页内实时删除能改到与读取相同的位置。
  var primary = defaultKey;
  var foundPrimary = false;
  results.forEach((key, rawItems) {
    if (!foundPrimary && rawItems.isNotEmpty) {
      primary = key;
      foundPrimary = true;
    }
    for (final it in rawItems) {
      final idx = it['index'];
      if (idx is! int) continue;
      final prev = byIndex[idx];
      if (prev == null) {
        byIndex[idx] = _normalizedNoteEntry(it);
        continue;
      }
      final seen = <String>{
        for (final u in (prev['underlines'] as List? ?? []))
          if (u is Map) '${u['start']}-${u['end']}',
      };
      final merged = [...(prev['underlines'] as List? ?? [])];
      for (final u in (it['underlines'] as List? ?? [])) {
        if (u is! Map) continue;
        if (seen.add('${u['start']}-${u['end']}')) merged.add({...u});
      }
      prev['underlines'] = merged;
      if ((prev['note'] ?? '').toString().trim().isEmpty &&
          (it['note'] ?? '').toString().trim().isNotEmpty) {
        prev['note'] = it['note'];
        prev['text'] = it['text'];
      }
    }
  });
  final items = byIndex.values.toList()
    ..sort((a, b) => ((a['index'] is int) ? a['index'] as int : 0)
        .compareTo((b['index'] is int) ? b['index'] as int : 0));
  return (items: items, key: primary);
}

/// 由「段落原文 + 紧密连段标记 + 云端段落笔记」重建当前全部画线项。
/// 同一 `。。。///` 连段簇内的画线合并为一条展示（段间 `\n`），每段区间单独记录，
/// 便于删除时逐段落地。与读经页打开画线归集页时的组装逻辑一致。
List<LiveHighlightItem> buildLiveHighlights(
  List<String> paragraphs,
  Set<int> tight,
  List<Map<String, dynamic>> items,
) {
  final underlinesByIndex = <int, List<Map<String, int>>>{};
  for (final it in items) {
    final idx = it['index'];
    if (idx is! int) continue;
    if (it['underlines'] is! List) continue;
    try {
      underlinesByIndex[idx] = (it['underlines'] as List)
          .whereType<Map>()
          .map((u) => {
                'start': (u['start'] is int)
                    ? u['start'] as int
                    : int.tryParse('${u['start']}') ?? 0,
                'end': (u['end'] is int)
                    ? u['end'] as int
                    : int.tryParse('${u['end']}') ?? 0,
              })
          .where((u) =>
              (u['start'] ?? 0) >= 0 && (u['end'] ?? 0) >= (u['start'] ?? 0))
          .toList();
    } catch (_) {
      underlinesByIndex[idx] = const [];
    }
  }

  // 每簇内的画线区间（段落下标, start, end）按段序展开为合并画线。
  final out = <LiveHighlightItem>[];
  final groups = tightClusterGroups(
      [for (var i = 0; i < paragraphs.length; i++) i], tight);
  for (final group in groups) {
    if (out.length >= kLiveMaxItems) break;
    final textParts = <String>[];
    final segs = <LiveHighlightSegment>[];
    var textLen = 0;
    for (final i in group) {
      final raw = underlinesByIndex[i] ?? const <Map<String, int>>[];
      if (raw.isEmpty) continue;
      final text = paragraphs[i];
      final len = text.length;
      final merged = <(int, int)>[];
      var count = 0;
      for (final u in raw) {
        if (count++ >= kLiveMaxRangesPerPara) break;
        final s = (u['start'] ?? 0).clamp(0, len);
        final e = (u['end'] ?? 0).clamp(0, len);
        if (e > s) merged.add((s, e));
      }
      merged.sort((a, b) => a.$1.compareTo(b.$1));
      final consolidated = <(int, int)>[];
      for (final r in merged) {
        if (consolidated.isNotEmpty && r.$1 <= consolidated.last.$2) {
          final last = consolidated.removeLast();
          consolidated.add((last.$1, r.$2 > last.$2 ? r.$2 : last.$2));
        } else {
          consolidated.add(r);
        }
      }
      for (final r in consolidated) {
        if (textLen >= kLiveMaxCharsPerItem) break;
        final s = r.$1.clamp(0, len);
        final e = r.$2.clamp(0, len);
        if (e > s) {
          textParts.add(text.substring(s, e));
          textLen += e - s;
          segs.add((para: i, start: s, end: e));
        }
      }
    }
    if (textParts.isEmpty) continue;
    var joined = textParts.join('\n');
    if (joined.length > kLiveMaxCharsPerItem) {
      joined = joined.substring(0, kLiveMaxCharsPerItem) + '……';
    }
    out.add((text: joined, segments: segs));
  }
  return out;
}

/// 由「段落原文 + 紧密连段标记 + 云端段落笔记」重建当前全部感想项（过滤空感想）。
/// 感想所属段落若位于 `。。。///` 连段簇内，则用整簇合并文本作为经文展示。
List<LiveThoughtItem> buildLiveThoughts(
  List<String> paragraphs,
  Set<int> tight,
  List<Map<String, dynamic>> items,
) {
  final notesByIndex = <int, String>{};
  for (final it in items) {
    final idx = it['index'];
    if (idx is! int) continue;
    final note = (it['note'] ?? '').toString().trim();
    if (note.isNotEmpty) notesByIndex[idx] = note;
  }
  final out = <LiveThoughtItem>[];
  final idxs = notesByIndex.keys.toList()..sort();
  for (final i in idxs) {
    if (out.length >= kLiveMaxNotes) break;
    if (i < 0 || i >= paragraphs.length) continue;
    out.add((
      paragraph: tightClusterTextFor(paragraphs, tight, i),
      note: notesByIndex[i]!,
      para: i,
    ));
  }
  return out;
}

/// 删除若干段 [start,end) 区间内的全部画线（用于分享帖页面的实时删除）。
/// 依据云端当前数据更新，保留各段感想；返回是否真正删除了内容。
/// [segments] 为空或删除后没有任何段落有实际变化时返回 false。
Future<bool> deleteLiveUnderline({
  required String sutraKey,
  required List<String> paragraphs,
  required List<LiveHighlightSegment> segments,
}) async {
  if (segments.isEmpty) return false;
  if (!AuthService.instance.isLoggedIn) return false;
  try {
    final items = await CloudNotesService.instance.getParagraphNotes(sutraKey);
    var changed = false;
    final byIndex = <int, Map<String, dynamic>>{};
    for (final x in items) {
      if (x['index'] is int) byIndex[x['index'] as int] = x;
    }
    for (final seg in segments) {
      final index = seg.para;
      if (index < 0 || index >= paragraphs.length) continue;
      final it = byIndex[index];
      if (it == null || it['underlines'] is! List) continue;
      final current = (it['underlines'] as List)
          .whereType<Map>()
          .map((u) => {
                'start': (u['start'] is int)
                    ? u['start'] as int
                    : int.tryParse('${u['start']}') ?? 0,
                'end': (u['end'] is int)
                    ? u['end'] as int
                    : int.tryParse('${u['end']}') ?? 0,
              })
          .where((u) =>
              (u['start'] ?? 0) >= 0 && (u['end'] ?? 0) >= (u['start'] ?? 0))
          .toList();
      final next = current.where((u) {
        final us = u['start'] ?? 0;
        final ue = u['end'] ?? 0;
        // 移除此区间相交的所有画线（渲染端合并出的整块都消失）。
        return !(ue > seg.start && us < seg.end);
      }).toList();
      if (next.length == current.length) continue;
      changed = true;
      await CloudNotesService.instance.saveParagraphNote(
        sutraKey: sutraKey,
        index: index,
        text: paragraphs[index],
        note: (it['note'] ?? '').toString(),
        shared: it['shared'] == true,
        cloudId: (it['cloudId'] ?? '').toString(),
        underlines: next,
      );
    }
    return changed;
  } catch (_) {
    return false;
  }
}

/// 删除某段感想（用于分享帖页面的实时删除）。保留该段画线；返回是否真正删除了内容。
Future<bool> deleteLiveNote({
  required String sutraKey,
  required List<String> paragraphs,
  required int index,
}) async {
  if (index < 0 || index >= paragraphs.length) return false;
  if (!AuthService.instance.isLoggedIn) return false;
  try {
    final items = await CloudNotesService.instance.getParagraphNotes(sutraKey);
    Map<String, dynamic> it = const {};
    for (final x in items) {
      if (x['index'] == index) {
        it = x;
        break;
      }
    }
    if (it.isEmpty) return false;
    final note = (it['note'] ?? '').toString().trim();
    if (note.isEmpty) return false;
    List<Map<String, int>> underlines = const [];
    if (it['underlines'] is List) {
      underlines = (it['underlines'] as List)
          .whereType<Map>()
          .map((u) => {
                'start': (u['start'] is int)
                    ? u['start'] as int
                    : int.tryParse('${u['start']}') ?? 0,
                'end': (u['end'] is int)
                    ? u['end'] as int
                    : int.tryParse('${u['end']}') ?? 0,
              })
          .where((u) =>
              (u['start'] ?? 0) >= 0 && (u['end'] ?? 0) >= (u['start'] ?? 0))
          .toList();
    }
    await CloudNotesService.instance.saveParagraphNote(
      sutraKey: sutraKey,
      index: index,
      text: paragraphs[index],
      note: '',
      shared: false,
      cloudId: '',
      underlines: underlines,
    );
    return true;
  } catch (_) {
    return false;
  }
}
