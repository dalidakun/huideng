import 'cloud_notes_service.dart';

/// 空白字符：对齐要在整篇段落上反复去空白，统一复用同一次编译的正则。
final RegExp _whitespaceRe = RegExp(r'\s');

String _normalize(String s) => s.replaceAll(_whitespaceRe, '');

/// 段落列表的去空白版本：对齐时按列表缓存一次，避免「每条备注 × 每个段落」
/// 都把整篇经文重新 replaceAll 一遍。
List<String> _normalized(List<String> paragraphs) =>
    [for (final p in paragraphs) _normalize(p)];

/// 排版变化后，把「按下标存储」的段落备注/画线/完成态重新对齐到新段号的结果。
class ParagraphAlignment {
  final Map<int, List<ParaNote>> notes;
  final Map<int, List<Map<String, int>>> underlines;
  final Map<int, bool> done;

  /// 新版里找不到原文字、只能保留下标的旧下标（页面据此提示「未能重新定位」）。
  final Set<int> unmigratedOld;

  const ParagraphAlignment({
    required this.notes,
    required this.underlines,
    required this.done,
    required this.unmigratedOld,
  });
}

/// 互相包含判断：等价于 `a.contains(b) || b.contains(a)`，但先按长度选方向，
/// 省掉一次方向必然失败的整串查找。
bool _mutuallyContains(String a, String b) =>
    a.length >= b.length ? a.contains(b) : b.contains(a);

/// 在 [paragraphs] 里定位旧段 [oldText]（旧下标 [oldIdx]）对应的新下标，找不到返回 -1。
///
/// 选取规则：优先「文字完全相同」的段；其次取互相包含的段（原段被拆分 / 合并的
/// 过渡态），同一档里取离旧下标最近的一段，避免「就近第一处命中」把备注绑到
/// 并不相干的那段上。
///
/// [normalizedParagraphs] 为 [paragraphs] 已去空白的版本：调用方有多条旧段
/// 要对齐时应先算好传进来，避免每条都把整篇经文重新归一化一遍。
int matchParagraphIndex(List<String> paragraphs, String oldText, int oldIdx,
    {List<String>? normalizedParagraphs}) {
  final norms = normalizedParagraphs ?? _normalized(paragraphs);
  final normalized = _normalize(oldText);
  if (normalized.isEmpty) return -1;
  var bestIdx = -1, bestRank = 2, bestDist = 0;
  for (var j = 0; j < norms.length; j++) {
    final cand = norms[j];
    if (cand.isEmpty) continue;
    final rank = cand == normalized
        ? 0
        : _mutuallyContains(cand, normalized)
            ? 1
            : 2;
    if (rank == 2) continue;
    final dist = (j - oldIdx).abs();
    if (bestIdx < 0 || rank < bestRank || (rank == bestRank && dist < bestDist)) {
      bestIdx = j;
      bestRank = rank;
      bestDist = dist;
    }
  }
  return bestIdx;
}

/// 在 [paragraphs] 里定位 [quoted]（某条备注针对的选中文字）所在的新段下标，
/// 找不到返回 -1。忽略空白匹配；多处命中时取离旧下标 [oldIdx] 最近的一段。
///
/// 用于「原段被拆成多段」时把每条备注精确落到它针对文字所在的那一段，
/// 而不是把所有备注都塞进离旧下标最近的那一段。
///
/// [normalizedParagraphs] 同 [matchParagraphIndex]。
int matchQuotedIndex(List<String> paragraphs, String quoted, int oldIdx,
    {List<String>? normalizedParagraphs}) {
  final norms = normalizedParagraphs ?? _normalized(paragraphs);
  final q = _normalize(quoted);
  if (q.isEmpty) return -1;
  var best = -1, bestDist = 0;
  for (var j = 0; j < norms.length; j++) {
    final cand = norms[j];
    if (cand.isEmpty || !cand.contains(q)) continue;
    final dist = (j - oldIdx).abs();
    if (best < 0 || dist < bestDist) {
      best = j;
      bestDist = dist;
    }
  }
  return best;
}

/// 按原文把 [oldParagraphs] 下标上的备注/画线/完成态迁移到 [paragraphs] 的新下标。
///
/// 备注优先按其针对的选中文字（[ParaNote.quoted]）精确定位到新段——原段被拆成
/// 多段时，各条备注会分别落到各自针对文字所在的那一段；选中文字缺失或在任何
/// 新段中都找不到时，回退到「按整段原文匹配」的结果。
/// 多个旧段落落回同一新段（段落被合并）时合并而不是互相覆盖；
/// 新版找不到原文字时保留下标并记入 [ParagraphAlignment.unmigratedOld]。
ParagraphAlignment alignParagraphAnnotations({
  required List<String> oldParagraphs,
  required List<String> paragraphs,
  required Map<int, List<ParaNote>> notes,
  required Map<int, List<Map<String, int>>> underlines,
  required Map<int, bool> done,
}) {
  final migratedNotes = <int, List<ParaNote>>{};
  final migratedUnderlines = <int, List<Map<String, int>>>{};
  final migratedDone = <int, bool>{};
  final unmigratedOld = <int>{};

  final affectedOld = <int>{
    ...notes.keys,
    ...underlines.keys,
    ...done.keys,
  };
  // 整篇新段落只归一化一次：原先每条旧段都要把全部段落重新 replaceAll。
  final normalizedNew = _normalized(paragraphs);
  for (final oldIdx in affectedOld) {
    final oldText =
        oldIdx >= 0 && oldIdx < oldParagraphs.length ? oldParagraphs[oldIdx] : '';
    final newIdx = matchParagraphIndex(paragraphs, oldText, oldIdx,
        normalizedParagraphs: normalizedNew);
    if (newIdx < 0) {
      // 新版找不到原文字：若原下标仍在新段范围内则保留原位置并标记，避免丢数据。
      if (oldIdx < 0 || oldIdx >= paragraphs.length) continue; // 完全越界
      unmigratedOld.add(oldIdx);
    }
    final target = newIdx < 0 ? oldIdx : newIdx;
    if (notes.containsKey(oldIdx)) {
      for (final n in notes[oldIdx]!) {
        // 有选中文字的备注：优先按选中文字精确定位到新段，支持原段被拆分。
        final quote = n.quoted.trim();
        final quoteIdx = quote.isEmpty
            ? -1
            : matchQuotedIndex(paragraphs, quote, oldIdx,
                normalizedParagraphs: normalizedNew);
        final noteTarget = quoteIdx >= 0 ? quoteIdx : target;
        migratedNotes[noteTarget] = [
          ...?migratedNotes[noteTarget],
          n,
        ];
      }
    }
    if (underlines.containsKey(oldIdx)) {
      migratedUnderlines[target] = [
        ...?migratedUnderlines[target],
        ...underlines[oldIdx]!,
      ];
    }
    if (done.containsKey(oldIdx)) {
      migratedDone[target] = (migratedDone[target] ?? false) || done[oldIdx]!;
    }
  }

  return ParagraphAlignment(
    notes: migratedNotes,
    underlines: migratedUnderlines,
    done: migratedDone,
    unmigratedOld: unmigratedOld,
  );
}
