import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'sutra_asset_path.dart';
import 'app_palette.dart';

/// 一部可被 @ 引用的经书。title 为展示名，filePath 为打包的 ASCII 路径。
class NoteSutraLink {
  final String title;
  final String size;
  final String folder;
  final String filePath;

  const NoteSutraLink({
    required this.title,
    required this.filePath,
    this.size = '',
    this.folder = '',
  });
}

/// 数字转中文卷名：1->「卷一」、10->「卷十」、21->「卷二十一」、
/// 105->「卷一百零五」、110->「卷一百一十」、600->「卷六百」。
String sutraVolumeLabel(int n) {
  const digits = '零一二三四五六七八九';
  if (n <= 0) return '';
  if (n <= 10) return '卷${n == 10 ? '十' : digits[n]}';
  if (n < 20) return '卷十${digits[n - 10]}';
  if (n < 100) {
    final tens = n ~/ 10;
    final ones = n % 10;
    return '卷${digits[tens]}十${ones == 0 ? '' : digits[ones]}';
  }
  if (n < 1000) {
    final hundreds = n ~/ 100;
    final rest = n % 100;
    final head = '卷${digits[hundreds]}百';
    if (rest == 0) return head;
    if (rest < 10) return '$head零${digits[rest]}';
    final tens = rest ~/ 10;
    final ones = rest % 10;
    return '$head${digits[tens]}十${ones == 0 ? '' : digits[ones]}';
  }
  return '卷$n';
}

/// 经书目录加载与检索（@经书 功能）。
///
/// 目录来源与经藏页一致：assets/sutras_catalog.json（约九千部）。
class NoteSutraCatalog {
  NoteSutraCatalog._();

  static List<NoteSutraLink>? _cache;

  /// 多卷经书的基础经名集合（目录中出现多次的基础经名），与目录同生命周期缓存。
  static Set<String>? _multiVolumeBases;

  /// 基础经名 ->（卷号 -> 该卷正文路径）：供带卷标的 $引用定位到具体卷。
  static Map<String, Map<int, String>>? _volumePaths;

  /// 基础经名 -> 全书总字数（多卷经书为各卷之和），与目录同生命周期缓存。
  static Map<String, int>? _charCounts;

  static final RegExp _idSuffixRe = RegExp(r'T\d+n[0-9A-Za-z]+_\d+$');
  static final RegExp _volumeOfRe = RegExp(r'T\d+n[0-9A-Za-z]+_(\d+)$');

  /// 历史脏数据防御：早期目录曾把空的「第卷」占位写进经名。
  static final RegExp _legacyGarbageRe = RegExp(r'(第卷)+');

  static Future<List<NoteSutraLink>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString('assets/sutras_catalog.json');
    final decoded = jsonDecode(raw) as List<dynamic>;
    final byTitle = <String, NoteSutraLink>{};
    final counts = <String, int>{};
    final volumePaths = <String, Map<int, String>>{};
    final charCounts = <String, int>{};
    for (final e in decoded) {
      final m = e as Map<String, dynamic>;
      final rawTitle =
          ((m['t'] as String?) ?? '').replaceAll(_legacyGarbageRe, '');
      final title = rawTitle.replaceAll(_idSuffixRe, '');
      if (title.isEmpty) continue;
      counts[title] = (counts[title] ?? 0) + 1;
      // 字数按基础经名累加：多卷经书得到全书总字数。
      charCounts[title] =
          (charCounts[title] ?? 0) + ((m['c'] as num?)?.toInt() ?? 0);
      final path = SutraAssetPath.resolve(title: rawTitle);
      if (!path.startsWith('assets/')) continue;
      final vm = _volumeOfRe.firstMatch(rawTitle);
      if (vm != null) {
        final vol = int.tryParse(vm.group(1)!) ?? 0;
        if (vol > 0) (volumePaths[title] ??= {})[vol] = path;
      }
      if (byTitle.containsKey(title)) continue; // 多卷经书只保留第一部
      byTitle[title] = NoteSutraLink(
        title: title,
        size: (m['s'] as String?) ?? '',
        folder: (m['f'] as String?) ?? '',
        filePath: path,
      );
    }
    final list = byTitle.values.toList();
    _cache = list;
    _volumePaths = volumePaths;
    _charCounts = charCounts;
    _multiVolumeBases = {
      for (final e in counts.entries)
        if (e.value > 1) e.key,
    };
    return list;
  }

  /// 检索以 query 开头的经书；结果不足时补充包含匹配。最多返回 30 部。
  /// 多卷经书按卷展开检索（「地藏菩萨本愿经卷一」「卷二」各成一条），
  /// 选中后插入带卷标的引用，与讨论页/热度榜的卷标口径一致。
  static Future<List<NoteSutraLink>> search(String query) async {
    final all = await _loadExpanded();
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final prefix = <NoteSutraLink>[];
    final contains = <NoteSutraLink>[];
    for (final s in all) {
      final t = s.title.toLowerCase();
      if (t.startsWith(q)) {
        prefix.add(s);
      } else if (t.contains(q)) {
        contains.add(s);
      }
    }
    return [...prefix, ...contains].take(30).toList();
  }

  /// 多卷经书按卷展开后的目录（$ 引用面板检索用）：
  /// 「地藏菩萨本愿经」展开为「地藏菩萨本愿经卷一」「卷二」…独立条目，
  /// 路径指向各卷正文；单卷经书保持基础经名原样。与目录同生命周期缓存。
  static List<NoteSutraLink>? _expandedCache;

  static Future<List<NoteSutraLink>> _loadExpanded() async {
    final cached = _expandedCache;
    if (cached != null) return cached;
    final all = await _load();
    final expanded = <NoteSutraLink>[];
    for (final s in all) {
      final volumes = _volumePaths?[s.title];
      if (volumes == null || volumes.length <= 1) {
        expanded.add(s);
        continue;
      }
      final vols = volumes.keys.toList()..sort();
      for (final v in vols) {
        expanded.add(NoteSutraLink(
          title: '${s.title}${sutraVolumeLabel(v)}',
          size: s.size,
          folder: s.folder,
          filePath: volumes[v] ?? s.filePath,
        ));
      }
    }
    _expandedCache = expanded;
    return expanded;
  }

  /// 加载全部经书（已按经书去重），带缓存。
  static Future<List<NoteSutraLink>> load() => _load();

  /// 目录已加载时，返回「经书名 -> 经书」的同步映射；未加载时返回 null（适合列表卡片快速提取）。
  static Map<String, NoteSutraLink>? get cachedTitleMap {
    final c = _cache;
    if (c == null) return null;
    return {for (final s in c) s.title: s};
  }

  /// 目录已加载时，返回多卷经书的基础经名集合（用于给 $引用/热门榜补「卷X」卷标）；
  /// 未加载时返回空集合。
  static Set<String> get cachedMultiVolumeBases =>
      _multiVolumeBases ?? const {};

  /// 目录已加载时，返回基础经名 [base] 第 [volume] 卷的正文路径；
  /// 未加载或无对应卷时返回 null（调用方回退到第一部路径）。
  static String? cachedVolumePath(String base, int volume) {
    if (volume <= 0) return null;
    return _volumePaths?[base]?[volume];
  }

  /// 目录已加载时，返回基础经名 [base] 的总卷数；未加载或无记录返回 0。
  static int cachedVolumeCount(String base) =>
      _volumePaths?[base]?.length ?? 0;

  /// 目录已加载时，返回基础经名 [base] 的总字数（多卷经书为各卷之和）；
  /// 未加载或无记录返回 0。
  static int cachedCharCount(String base) => _charCounts?[base] ?? 0;

  /// 经书名 -> 经书的映射，用于点击 @经书 时定位正文路径。
  static Future<Map<String, NoteSutraLink>> titleMap() async {
    final all = await _load();
    return {for (final s in all) s.title: s};
  }
}

/// 笔记正文中的 @经书 标记的编码与渲染。
///
/// 新格式为纯经书名：@地藏菩萨本愿经（不带路径）。
/// 为兼容旧保存的数据，仍会识别旧式的 `[@经名](assets/...路径)` 标记。
class NoteSutraLinks {
  NoteSutraLinks._();

  static final RegExp _legacyTokenRe = RegExp(r'\[@([^\]]+)\]\(([^)]+)\)');

  /// 生成可在正文中保存的 @经书 标记（纯经书名，不带路径）。
  static String encode(String title) => '@$title';

  /// 将正文中的 @经书 标记转成纯文本（@经书名），用于列表摘要等。
  static String plainText(String text) =>
      text.replaceAllMapped(_legacyTokenRe, (m) => '@${m.group(1)}');

  /// 提取正文中引用的经书（旧式 [@经名](路径) 和新式 @经书名 均支持）。
  /// 目录对应路径来自 [NoteSutraCatalog] 的缓存；若目录未加载，新式标记暂时退化为不可提取。
  static List<(String, String)> extract(String text) {
    final results = _legacyTokenRe
        .allMatches(text)
        .map((m) => (m.group(1)!, m.group(2)!))
        .toList();
    final lib = NoteSutraCatalog.cachedTitleMap;
    if (lib != null) {
      // 新式 @经书名：扫描全文，匹配已知经书名称（最长匹配优先）。
      var i = 0;
      while (i < text.length) {
        if (text[i] == '@' && i + 1 < text.length) {
          var best = '';
          for (final t in lib.keys) {
            if (t.length <= best.length) continue;
            if (text.startsWith('@$t', i)) best = t;
          }
          if (best.isNotEmpty) {
            final entry = lib[best]!;
            // 避免旧式已提过的重复
            final already = results.any((r) => r.$1 == best && r.$2 == entry.filePath);
            if (!already) results.add((best, entry.filePath));
            i += 1 + best.length;
            continue;
          }
        }
        i++;
      }
    }
    return results;
  }

  /// 判断正文是否引用了指定经书。
  ///
  /// 支持三种写法：`$经名`（编辑器插入的新格式）、`@经名`（旧式）、
  /// `[@经名](路径)`（更旧式）。`@账号` 用户提及（含 `[@账号](user:id)`）不算引用经书。
  static bool referencesSutra(String text, String title) {
    if (title.isEmpty) return false;
    final t = RegExp.escape(title);
    // 更旧式 [@经名](路径)：排除 user: 用户提及。
    if (RegExp(r'\[@' + t + r'\]\((?![^)]*user:)[^)]+\)').hasMatch(text)) {
      return true;
    }
    // $经名 / @经名：标记前不是汉字/字母/数字，避免长经名子串误报；
    // 若 `@经名` 后面紧跟 `](user:` 则是用户提及，跳过。
    final re = RegExp(r'[@$]' + t);
    for (final m in re.allMatches(text)) {
      final before = m.start > 0 ? text[m.start - 1] : '';
      if (RegExp(r'[0-9A-Za-z\u4e00-\u9fa5]').hasMatch(before)) continue;
      if (text.startsWith('](user:', m.start + m.group(0)!.length)) continue;
      return true;
    }
    return false;
  }

  /// 渲染正文，@经书名 标记显示为金色可点击链接。
  ///
  /// [library] 为「经书名 -> 经书」的映射，来自 [NoteSutraCatalog.titleMap]。
  /// 目录中不存在的 @文本 会按普通文字处理，不渲染成链接。
  static Widget buildRichText(
    String text, {
    required TextStyle style,
    required Map<String, NoteSutraLink> library,
    required void Function(String title, String filePath) onTap,
    Color? linkColor,
    int? maxLines,
    TextOverflow overflow = TextOverflow.clip,
  }) {
    WidgetSpan linkSpan(String title, String filePath) {
      final linkStyle = style.copyWith(
        color: linkColor ?? AppPalette.p.accent,
        fontWeight: FontWeight.w600,
      );
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTap(title, filePath),
          child: Text('@$title', style: linkStyle),
        ),
      );
    }

    // 在 [from]（text[from] == '@'）处解析 `@ + 经书名`，返回最长的已知经书名。
    String? titleAt(int from) {
      var best = '';
      for (final t in library.keys) {
        if (t.length <= best.length) continue;
        if (text.startsWith('@$t', from)) best = t;
      }
      return best.isEmpty ? null : best;
    }

    final spans = <InlineSpan>[];
    var i = 0;
    var litStart = 0;
    void flushLit() {
      if (litStart < i) spans.add(TextSpan(text: text.substring(litStart, i)));
    }

    while (i < text.length) {
      // 旧式标记：[@经名](路径)
      if (text[i] == '[' && i + 1 < text.length && text[i + 1] == '@') {
        final m = _legacyTokenRe.matchAsPrefix(text, i);
        if (m != null) {
          flushLit();
          spans.add(linkSpan(m.group(1)!, m.group(2)!));
          i = m.end;
          litStart = i;
          continue;
        }
      }
      // 新式标记：@经书名（需能在目录中解析）
      if (text[i] == '@' && i + 1 < text.length) {
        final t = titleAt(i);
        if (t != null) {
          flushLit();
          spans.add(linkSpan(t, library[t]!.filePath));
          i += 1 + t.length;
          litStart = i;
          continue;
        }
      }
      i++;
    }
    flushLit();

    return Text.rich(
      TextSpan(children: spans, style: style),
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
