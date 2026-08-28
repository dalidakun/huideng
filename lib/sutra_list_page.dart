import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/foundation.dart'
    show kIsWeb, ValueListenable;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'reading_page.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'sutra_asset_path.dart';
import 'sutra_downloader.dart';
import 'sutra_favorites.dart';
import 'sutra_read_later.dart';
import 'favorite_sutras_page.dart';
import 'popular_sutras_page.dart';
import 'hot_ranking_page.dart';
import 'note_sutra_links.dart';

import 'app_palette.dart';

/// 用于监听路由返回（例如从阅读页 pop 回来时刷新“最近阅读”）。
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

class Sutra {
  final String title;
  final String size;
  final int charCount;
  final bool isPinned;
  final bool isRead;
  final bool isFavorite;
  final bool isReadLater;
  final String? filePath;
  final String? folder;
  final DateTime? favoriteTime; // 收藏时间
  final DateTime? readTime; // 标记已读时间
  final DateTime? readLaterTime; // 标记稍后阅读时间

  Sutra(this.title, this.size, {this.charCount = 0, this.isPinned = false, this.isRead = false, this.isFavorite = false, this.isReadLater = false, this.filePath, this.folder, this.favoriteTime, this.readTime, this.readLaterTime});

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'size': size,
      'charCount': charCount,
      'isPinned': isPinned,
      'isRead': isRead,
      'isFavorite': isFavorite,
      'isReadLater': isReadLater,
      'filePath': filePath,
      'folder': folder,
      'favoriteTime': favoriteTime?.toIso8601String(),
      'readTime': readTime?.toIso8601String(),
      'readLaterTime': readLaterTime?.toIso8601String(),
    };
  }

  factory Sutra.fromJson(Map<String, dynamic> json) {
    return Sutra(
      json['title'] as String,
      json['size'] as String,
      charCount: json['charCount'] as int? ?? 0,
      isPinned: json['isPinned'] as bool? ?? false,
      isRead: json['isRead'] as bool? ?? false,
      isFavorite: json['isFavorite'] as bool? ?? false,
      isReadLater: json['isReadLater'] as bool? ?? false,
      filePath: json['filePath'] as String?,
      folder: json['folder'] as String?,
      favoriteTime: json['favoriteTime'] != null ? DateTime.parse(json['favoriteTime'] as String) : null,
      readTime: json['readTime'] != null ? DateTime.parse(json['readTime'] as String) : null,
      readLaterTime: json['readLaterTime'] != null ? DateTime.parse(json['readLaterTime'] as String) : null,
    );
  }
}

/// 经名末尾的 CBETA 编号，如「中阿含经T01n0026_005」中的 `T01n0026_005`。
final RegExp _sutraIdSuffixRe = RegExp(r'T\d+n[0-9A-Za-z]+_\d+$');
final RegExp _sutraVolumeRe = RegExp(r'T\d+n[0-9A-Za-z]+_(\d+)$');

/// 提取 CBETA 卷次编号（如「中阿含经T01n0026_005」-> 5），无卷次返回 0。
int _sutraVolumeOf(String title) {
  final m = _sutraVolumeRe.firstMatch(title);
  return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
}

/// [ _sutraVolumeOf ] 的公开版本：提取经名末尾 CBETA 卷次编号，无卷次返回 0。
int sutraVolumeOf(String title) => _sutraVolumeOf(title);

/// 数字转中文卷名：实现见 [sutraVolumeLabel]（note_sutra_links.dart）。
String _volumeLabel(int n) => sutraVolumeLabel(n);

/// 中文卷标解析为阿拉伯数字：「卷十一」->11、「卷一百零五」->105、
/// 「卷四百零三」->403、「卷六百」->600；也接受纯数字（「11」->11）。
/// 无法解析返回 0。
int parseChineseVolumeNumber(String label) {
  var s = label.trim();
  if (s.startsWith('卷')) s = s.substring(1);
  if (s.isEmpty) return 0;
  final asInt = int.tryParse(s);
  if (asInt != null) return asInt;
  const digits = {
    '零': 0,
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  var total = 0;
  var num = 0;
  for (final ch in s.split('')) {
    final d = digits[ch];
    if (d != null) {
      num = d;
    } else if (ch == '十') {
      total += (num == 0 ? 1 : num) * 10;
      num = 0;
    } else if (ch == '百') {
      total += (num == 0 ? 1 : num) * 100;
      num = 0;
    } else if (ch == '千') {
      total += (num == 0 ? 1 : num) * 1000;
      num = 0;
    } else {
      return 0;
    }
  }
  return total + num;
}

/// 经名末尾的中文卷标（如「地藏菩萨本愿经卷一」中的「卷一」）。
final RegExp chineseVolumeSuffixRe = RegExp(r'卷[零一二三四五六七八九十百千]+$');

/// 中文卷标前缀匹配（用于在正文中识别紧跟经名的「卷X」，无结尾锚定）。
final RegExp chineseVolumePrefixRe = RegExp(r'卷[零一二三四五六七八九十百千]+');

/// 基础经名：去掉经名末尾的 CBETA 编号（如「地藏菩萨本愿经T13n0412_001」->「地藏菩萨本愿经」）。
String sutraBaseTitle(String title) =>
    title.replaceAll(_sutraIdSuffixRe, '').trim();

/// 历史脏数据：早期目录曾把空的卷号占位「第卷」写进多卷经书经名
/// （如「大般若波罗蜜多经第卷第卷T05n0220_001」）。合法经名不含「第卷」
/// （「第」后必跟数字），可安全移除。
final RegExp _legacyTitleGarbageRe = RegExp(r'(第卷)+');

/// 移除经名中的历史「第卷」占位脏字符；无脏数据时原样返回。
String repairLegacySutraTitle(String title) =>
    title.contains('第卷') ? title.replaceAll(_legacyTitleGarbageRe, '') : title;

/// 修复列表中历史遗留的「第卷」脏标题；修复后若与已有条目重复
/// （如 APK 更新时已补入干净条目），合并双方状态（已读/收藏/置顶取并集），
/// 保持原有顺序。无脏数据时原样返回 [sutras]。
List<Sutra> repairLegacySutraList(List<Sutra> sutras) {
  var changed = false;
  final indexByTitle = <String, int>{};
  final result = <Sutra>[];
  for (final s in sutras) {
    final t = repairLegacySutraTitle(s.title);
    if (t != s.title) changed = true;
    final exist = indexByTitle[t];
    if (exist != null) {
      changed = true;
      final e = result[exist];
      result[exist] = Sutra(
        t,
        e.size,
        charCount: e.charCount > 0 ? e.charCount : s.charCount,
        isPinned: e.isPinned || s.isPinned,
        isRead: e.isRead || s.isRead,
        isFavorite: e.isFavorite || s.isFavorite,
        isReadLater: e.isReadLater || s.isReadLater,
        filePath: e.filePath ?? s.filePath,
        folder: e.folder ?? s.folder,
        favoriteTime: e.favoriteTime ?? s.favoriteTime,
        readTime: e.readTime ?? s.readTime,
        readLaterTime: e.readLaterTime ?? s.readLaterTime,
      );
      continue;
    }
    indexByTitle[t] = result.length;
    result.add(t == s.title
        ? s
        : Sutra(
            t,
            s.size,
            charCount: s.charCount,
            isPinned: s.isPinned,
            isRead: s.isRead,
            isFavorite: s.isFavorite,
            isReadLater: s.isReadLater,
            filePath: s.filePath,
            folder: s.folder,
            favoriteTime: s.favoriteTime,
            readTime: s.readTime,
            readLaterTime: s.readLaterTime,
          ));
  }
  return changed ? result : sutras;
}

/// 归一化热门经文名称：先去掉 CBETA 编号后缀，再去掉末尾中文卷标，
/// 得到基础经名（「地藏菩萨本愿经卷一」/「地藏菩萨本愿经T13n0412_001」->「地藏菩萨本愿经」），
/// 使带卷标与不带卷标的引用能归并到同一条目。
String normalizeHotSutraName(String name) => name
    .replaceAll(_sutraIdSuffixRe, '')
    .replaceAll(chineseVolumeSuffixRe, '')
    .trim();

/// 将热门经文名解析为「目录真实经名 + 卷号」。
///
/// 云端按 `$`/`@` 标记贪心提取经名，名字可能粘连尾部正文
/// （如「$金刚经真好」提取出「金刚经真好」）。先去掉 CBETA 编号后缀，
/// 按目录做最长前缀匹配得到真实基础经名；经名后紧跟的中文卷标
/// （「$地藏菩萨本愿经卷二」「$地藏菩萨本愿经卷二真好」）解析为卷号，
/// 无卷标返回 0。无法归一到目录经名返回 null（调用方应丢弃）——与讨论页
/// 筛选相关帖子的口径保持一致，保证榜单「讨论X个」与点进去看到的条数一致。
(String, int)? resolveHotSutraBaseAndVolume(
    String name, Set<String> catalogNames) {
  final s = name.replaceAll(_sutraIdSuffixRe, '').trim();
  if (s.isEmpty) return null;
  String? base;
  for (final c in catalogNames) {
    if (s.startsWith(c) && (base == null || c.length > base.length)) base = c;
  }
  if (base == null) return null;
  final remainder = s.substring(base.length);
  final vm = chineseVolumePrefixRe.matchAsPrefix(remainder);
  final volume = vm == null ? 0 : parseChineseVolumeNumber(vm.group(0)!);
  return (base, volume);
}

/// 将热门经文名解析为目录中的真实经名（基础经名，不含卷号）。
/// 见 [resolveHotSutraBaseAndVolume]；无法归一返回 null。
String? resolveHotSutraName(String name, Set<String> catalogNames) =>
    resolveHotSutraBaseAndVolume(name, catalogNames)?.$1;

/// 拆分热门经文名为「基础经名 + 卷号」：末尾带中文卷标（「地藏菩萨本愿经卷二」）
/// 时解析出卷号，否则卷号为 0。用于从榜单条目定位到具体卷的讨论页/正文路径。
(String, int) splitHotSutraName(String name) {
  final m = chineseVolumeSuffixRe.firstMatch(name);
  if (m == null || m.start == 0) return (name, 0);
  final base = name.substring(0, m.start).trim();
  if (base.isEmpty) return (name, 0);
  return (base, parseChineseVolumeNumber(m.group(0)!));
}

/// 热门榜单条目（可能为「基础经名」或「基础经名+卷X」）对应的打开目标：
/// 返回基础经名与该卷正文路径。多卷经书的具体卷优先取该卷路径，
/// 无对应卷或单卷时回退到目录里该经的首卷路径。
(String, String) resolveHotSutraTarget(String name) {
  final (base, volume) = splitHotSutraName(name);
  final entry = NoteSutraCatalog.cachedTitleMap?[base];
  final path =
      (volume > 0 ? NoteSutraCatalog.cachedVolumePath(base, volume) : null) ??
          entry?.filePath ??
          '';
  return (base, path);
}

/// 归并热门经文条目。
///
/// 默认（不传 [multiVolumeBases]）按基础经名归并：「XX经卷一」与「XX经」合并为
/// 一条（posts/score 累加），多卷经书在榜上只出现一次——用于按整部经书排行的场景。
///
/// 传入 [multiVolumeBases]（多卷经书基础经名集合）时按卷拆分：多卷经书每一卷单独
/// 一条（「XX经卷一」「XX经卷二」），卷拆分之前的历史讨论与不带卷标的引用并入卷一，
/// 使榜单「讨论X个」与点进对应卷讨论页看到的条数一致。单卷经书仍按基础经名归并。
///
/// 传入 [catalogNames]（经书目录经名集合）时额外做目录归一：云端贪心提取的
/// 「经名+粘连文字」按最长前缀归一到真实经名，无法归一的条目丢弃。
List<HotDiscussionItem> mergeHotSutraItems(List<HotDiscussionItem> items,
    {Set<String>? catalogNames, Set<String>? multiVolumeBases}) {
  final byKey = <String, HotDiscussionItem>{};
  void add(String key, HotDiscussionItem it) {
    final cur = byKey[key];
    byKey[key] = cur == null
        ? HotDiscussionItem(name: key, posts: it.posts, score: it.score)
        : HotDiscussionItem(
            name: key,
            posts: cur.posts + it.posts,
            score: cur.score + it.score);
  }

  for (final it in items) {
    if (catalogNames == null) {
      final base = normalizeHotSutraName(it.name);
      if (base.isEmpty) continue;
      add(base, it);
      continue;
    }
    final resolved = resolveHotSutraBaseAndVolume(it.name, catalogNames);
    if (resolved == null) continue;
    final (base, volume) = resolved;
    if (multiVolumeBases != null && multiVolumeBases.contains(base)) {
      // 多卷经书按卷拆分；不带卷标的历史讨论/引用并入卷一（与讨论页口径一致）。
      add('$base${_volumeLabel(volume > 0 ? volume : 1)}', it);
    } else {
      add(base, it);
    }
  }
  return byKey.values.toList();
}

/// 统计同名（基础经名）出现多次的集合，即多卷经书的基础经名。
Set<String> collectMultiVolumeBases(Iterable<Sutra> sutras) {
  final counts = <String, int>{};
  for (final s in sutras) {
    final base = s.title.replaceAll(_sutraIdSuffixRe, '').trim();
    if (base.isEmpty) continue;
    counts[base] = (counts[base] ?? 0) + 1;
  }
  return {
    for (final e in counts.entries)
      if (e.value > 1) e.key,
  };
}

/// 经书展示名：单卷经书只显示经名；多卷经书显示「经名 + 卷X」。
/// [multiVolumeBases] 为空（或未提供）时表示无法判断多卷，只显示经名。
String sutraDisplayTitle(String title, {Set<String>? multiVolumeBases}) {
  final base = title.replaceAll(_sutraIdSuffixRe, '').trim();
  if (multiVolumeBases == null || !multiVolumeBases.contains(base)) return base;
  final volume = _sutraVolumeOf(title);
  return volume <= 0 ? base : '$base${_volumeLabel(volume)}';
}

/// 转换经名为显示格式。
/// 当 [multiVolumeBases] 非空时，仅多卷经书显示卷标（如「高僧传卷五」），
/// 单卷经书直接显示基础名（如「金刚经」）。
/// 当 [multiVolumeBases] 为 null 时，只要有卷号后缀就显示卷标。
String sutraDisplayNameWithVolume(String title,
    {Set<String>? multiVolumeBases}) {
  final base = title.replaceAll(_sutraIdSuffixRe, '').trim();
  final volume = _sutraVolumeOf(title);
  if (volume <= 0) return base;
  // 有卷号后缀但未传 multiVolumeBases 时，默认显示卷标。
  if (multiVolumeBases == null) return '$base${_volumeLabel(volume)}';
  // 传了 multiVolumeBases 时，仅多卷经书才显示卷标。
  return multiVolumeBases.contains(base)
      ? '$base${_volumeLabel(volume)}'
      : base;
}

/// 「标题 + 可选路径」条目的展示名：标题本身不带卷号后缀时（如从 $引用、
/// 讨论页跳转进入，标题只有基础经名），尝试从 [filePath] 中提取规范 ID
/// 补齐卷号，保证卷标与实际打开的卷一致。
String sutraDisplayTitleWithPath(String title,
    {String? filePath, Set<String>? multiVolumeBases}) {
  var t = title;
  if (_sutraVolumeOf(t) <= 0) {
    final id = SutraDownloader.extractId(null, filePath);
    if (id != null) t = '$t$id';
  }
  return sutraDisplayNameWithVolume(t, multiVolumeBases: multiVolumeBases);
}

/// 聚合场景（经书讨论页、热门榜等）的展示名：标题带卷号后缀时显示具体卷标；
/// 仅有基础经名且为多卷经书时统一补「卷一」卷标（按基础经名聚合、无具体卷信息）。
String sutraAggregatedDisplayName(String title,
    {required Set<String> multiVolumeBases}) {
  final display =
      sutraDisplayNameWithVolume(title, multiVolumeBases: multiVolumeBases);
  if (_sutraVolumeOf(title) <= 0 && multiVolumeBases.contains(display)) {
    return '$display卷一';
  }
  return display;
}

/// 经书讨论页等「按基础经名聚合、但可能带具体卷路径」场景的展示名：
/// 标题本身无卷号后缀时，优先从 [filePath] 提取卷号显示具体卷标
/// （如从「$高僧传卷十一」链接进入时显示「高僧传卷十一」而非「卷一」）；
/// 无法定位具体卷时按聚合规则（多卷经书补「卷一」）。
String sutraDiscussionDisplayName(String title,
    {String? filePath, required Set<String> multiVolumeBases}) {
  if (_sutraVolumeOf(title) <= 0 && filePath != null && filePath.isNotEmpty) {
    final id = SutraDownloader.extractId(null, filePath);
    if (id != null) {
      final withId = '$title$id';
      if (_sutraVolumeOf(withId) > 0) {
        return sutraDisplayNameWithVolume(withId,
            multiVolumeBases: multiVolumeBases);
      }
    }
  }
  return sutraAggregatedDisplayName(title, multiVolumeBases: multiVolumeBases);
}

/// 判断正文是否引用了 [baseTitle] 经书的第 [volume] 卷
/// （供按卷拆分的经书讨论页筛选相关帖子）。
/// 带中文卷标的引用（「$高僧传卷十一」）卷号相等才匹配；
/// 只写基础经名的引用（「$高僧传」）按约定视为卷一，仅 [volume] == 1 时匹配；
/// 旧式 [@经名](路径) 同样视为不带卷标的引用。
bool referencesSutraVolume(String text, String baseTitle, int volume) {
  if (baseTitle.isEmpty || volume <= 0) return false;
  final t = RegExp.escape(baseTitle);
  // 更旧式 [@经名](路径)：排除 user: 用户提及，视为不带卷标的引用（卷一）。
  if (volume == 1 &&
      RegExp(r'\[@' + t + r'\]\((?![^)]*user:)[^)]+\)').hasMatch(text)) {
    return true;
  }
  final re = RegExp(r'[@$]' + t);
  for (final m in re.allMatches(text)) {
    final before = m.start > 0 ? text[m.start - 1] : '';
    if (RegExp(r'[0-9A-Za-z\u4e00-\u9fa5]').hasMatch(before)) continue;
    final afterIdx = m.start + m.group(0)!.length;
    if (text.startsWith('](user:', afterIdx)) continue;
    final vm = chineseVolumePrefixRe.matchAsPrefix(text, afterIdx);
    final refVolume = vm == null ? 1 : parseChineseVolumeNumber(vm.group(0)!);
    if (refVolume == volume) return true;
  }
  return false;
}

/// 从本地 sutras_list.json 加载多卷经书的基础经名集合。
Future<Set<String>> loadLocalMultiVolumeBases() async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final file =
        File('${docs.path}${Platform.pathSeparator}sutras_list.json');
    if (!await file.exists()) return const {};
    final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
    return collectMultiVolumeBases(
        decoded.map((e) => Sutra.fromJson(e as Map<String, dynamic>)));
  } catch (_) {
    return const {};
  }
}

/// 为热门经文列表构建经名显示映射表：从本地 sutras_list.json 查找 CBETA 完整标题，
/// 将云端返回的基础经名（如「高僧传」）映射到带卷标的显示名。
/// 热门榜按基础经名聚合、无具体卷信息，多卷经书统一取第一卷卷标（如「高僧传卷一」）。
/// 单卷经书（如「金刚经」）映射为自身，不加卷标。
/// 仅对 [isSutra] 为 true 时构建映射，话题列表返回空映射。
/// 返回的 Map key 为 HotDiscussionItem.name（基础经名，用于导航），
/// value 为应显示的名称（含卷标），UI 层用此 map 替换显示文本。
Future<Map<String, String>> buildSutraDisplayNameMap(
  List<HotDiscussionItem> items, {
  required bool isSutra,
}) async {
  if (!isSutra || items.isEmpty) return const {};
  try {
    final docs = await getApplicationDocumentsDirectory();
    final file =
        File('${docs.path}${Platform.pathSeparator}sutras_list.json');
    if (!await file.exists()) return const {};
    final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
    final sutras =
        decoded.map((e) => Sutra.fromJson(e as Map<String, dynamic>)).toList();
    final mvBases = collectMultiVolumeBases(sutras);
    // 基础经名 → CBETA 完整标题（含卷号后缀）
    final titleLookup = <String, String>{};
    for (final s in sutras) {
      final base = s.title.replaceAll(_sutraIdSuffixRe, '').trim();
      if (base.isNotEmpty && !titleLookup.containsKey(base)) {
        titleLookup[base] = s.title;
      }
    }
    final result = <String, String>{};
    for (final it in items) {
      final fullTitle = titleLookup[it.name];
      if (fullTitle == null) continue;
      final displayName =
          sutraDisplayNameWithVolume(fullTitle, multiVolumeBases: mvBases);
      if (displayName != it.name) {
        result[it.name] = displayName;
      }
    }
    return result;
  } catch (_) {
    return const {};
  }
}

class SutraListPage extends StatefulWidget {
  /// 底部 Tab 索引变化通知。当切换回经藏页（索引值变化）时刷新"最近阅读"。
  final ValueListenable<int>? activeTab;

  /// 右上角「助手」入口点击回调。
  final VoidCallback? onOpenAssistant;

  /// 阅读统计入口点击回调。
  final VoidCallback? onOpenReadingStats;

  /// 阅读记录入口点击回调。
  final VoidCallback? onOpenReadingHistory;

  const SutraListPage({
    super.key,
    this.activeTab,
    this.onOpenAssistant,
    this.onOpenReadingStats,
    this.onOpenReadingHistory,
  });

  @override
  State<SutraListPage> createState() => SutraListPageState();
}

class SutraListPageState extends State<SutraListPage>
    with SingleTickerProviderStateMixin, RouteAware {
  static const MethodChannel _appChannel = MethodChannel('app_channel');
  static const String _kApkLastUpdateTimeKey = 'apk_last_update_time';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  /// 主页内容滚动控制器：双击顶部 AppBar 时回到顶部。
  final ScrollController _scrollController = ScrollController();
  bool _drawerOpen = false;
  late final AnimationController _drawerController;
  late final Animation<Offset> _drawerSlide;
  late final Animation<double> _overlayOpacity;
  String? _lastReadTitle;
  String? _lastReadFilePath;
  double _lastReadProgress = 0.0;
  List<Map<String, String>> _recentSutras = [];

  /// 随缘读经预览用的随机经书（保持稳定，避免每次重建都换）。
  Sutra? _randomSutra;

  /// 从全部经书中随机抽取一部。
  Sutra? _rollRandomSutra() {
    if (_allSutras.isEmpty) return null;
    return _allSutras[Random().nextInt(_allSutras.length)];
  }

  /// 「换一部」轮换选中的部类（保持稳定，避免每次重建都换）。
  String? _randomFolder;

  /// 随机经部区块的 GlobalKey，用于测量其滚动位置以决定「回到经部」按钮的显隐与目标偏移。
  final GlobalKey _randomFolderKey = GlobalKey();
  /// 「回到经部」浮动按钮是否显示：仅当随机经部上方内容全部滚出视口后才显示。
  bool _showScrollToFolderButton = false;

  /// 从全部部类（56 部）中随机抽取一部，尽量不与当前重复。
  String? _rollRandomFolder() {
    if (_folders.isEmpty) return null;
    final candidates = (_folders.length > 1 && _randomFolder != null)
        ? _folders.where((f) => f != _randomFolder).toList()
        : _folders;
    return candidates[Random().nextInt(candidates.length)];
  }

  Set<String>? _assetKeys;
  // Cache: resolved asset key -> exists?
  final Map<String, bool> _resolvedPathExistsCache = {};
  // Cache: sutra title -> best existing asset key (null means none found)
  final Map<String, String?> _bestAssetPathByTitleCache = {};
  Future<AssetManifest>? _manifestFuture;
  Set<String> _missingSutraTitles = {};
  bool _missingComputed = false;

  String _normalizeAssetKey(String p) => p.replaceAll('\\', '/').trim();

  List<String> _candidateAssetPathsForSutra(Sutra sutra) {
    final out = <String>{};
    final fp = sutra.filePath;
    if (fp != null && fp.startsWith('assets/')) {
      out.add(_normalizeAssetKey(fp));
    }
    // ASCII-mapped path (preferred when packaged).
    out.add(_normalizeAssetKey(_resolveSutraPath(sutra)));
    return out.toList();
  }

  String? _bestExistingAssetPathForSutra(Sutra sutra) {
    final keys = _assetKeys;
    if (keys == null) return null;

    final cached = _bestAssetPathByTitleCache[sutra.title];
    if (_bestAssetPathByTitleCache.containsKey(sutra.title)) return cached;

    for (final c in _candidateAssetPathsForSutra(sutra)) {
      if (keys.contains(c)) {
        _bestAssetPathByTitleCache[sutra.title] = c;
        return c;
      }
    }
    _bestAssetPathByTitleCache[sutra.title] = null;
    return null;
  }

  String _filePathForReading(Sutra sutra) {
    final fp = sutra.filePath;
    if (fp != null && !fp.startsWith('assets/')) return fp;

    final best = _bestExistingAssetPathForSutra(sutra);
    return best ?? _normalizeAssetKey(_resolveSutraPath(sutra));
  }

  Future<void> _loadAssetManifest() async {
    try {
      _manifestFuture ??= AssetManifest.loadFromAssetBundle(rootBundle);
      final manifest = await _manifestFuture!;
      final assets = manifest.listAssets();
      if (!mounted) return;
      setState(() {
        // Normalize keys to forward-slash to avoid platform-specific separators.
        _assetKeys = assets.map(_normalizeAssetKey).toSet();
        _resolvedPathExistsCache.clear();
        _bestAssetPathByTitleCache.clear();
      });
      _recomputeMissingSutrasIfReady();
    } catch (_) {
      // If manifest can't be read for some reason, don't block the UI.
      if (!mounted) return;
      setState(() {
        _assetKeys = null;
        _resolvedPathExistsCache.clear();
        _bestAssetPathByTitleCache.clear();
        _missingSutraTitles = {};
        _missingComputed = false;
      });
    }
  }

  void _recomputeMissingSutrasIfReady() {
    final keys = _assetKeys;
    if (keys == null) return;
    if (_allSutras.isEmpty) return;

    // Avoid repeated full scans; we recompute only when assets are loaded and sutras list is ready.
    if (_missingComputed) return;

    final missing = <String>{};
    for (final sutra in _allSutras) {
      final fp = sutra.filePath;
      final isAssetLike = fp == null || fp.startsWith('assets/');
      if (!isAssetLike) {
        if (!kIsWeb) {
          try {
            if (!File(fp).existsSync()) {
              missing.add(sutra.title);
            }
          } catch (_) {
            missing.add(sutra.title);
          }
        }
        continue;
      }

      // For asset-backed sutras, consider multiple candidate paths (ascii-mapped + legacy).
      final best = _bestExistingAssetPathForSutra(sutra);
      if (best == null) {
        missing.add(sutra.title);
      }
    }

    if (!mounted) return;
    setState(() {
      _missingSutraTitles = missing;
      _missingComputed = true;
    });
  }

  bool _isSutraContentMissing(Sutra sutra) {
    if (_missingComputed) {
      return _missingSutraTitles.contains(sutra.title);
    }

    // Not ready yet: don't mark anything until we have the manifest.
    final keys = _assetKeys;
    if (keys == null) return false;

    // If this sutra comes from a user-picked local file, validate file existence.
    final fp = sutra.filePath;
    final isAssetLike = fp == null || fp.startsWith('assets/');
    if (!isAssetLike) {
      if (kIsWeb) return false;
      try {
        return !File(fp).existsSync();
      } catch (_) {
        return true;
      }
    }

    // Otherwise validate packaged asset existence using resolved ASCII asset path.
    // We cache by the (normalized) resolved key, but still accept legacy key if present.
    final resolved = _normalizeAssetKey(_resolveSutraPath(sutra));
    final cached = _resolvedPathExistsCache[resolved];
    if (cached != null) return !cached;

    final best = _bestExistingAssetPathForSutra(sutra);
    final exists = best != null;
    _resolvedPathExistsCache[resolved] = exists;
    return !exists;
  }

  void _dismissKeyboard() {
    // 关键：TextField 仍处于 focus 时（即使用户手动收起了输入法），后续 setState / 弹窗
    // 可能会重新建立输入连接导致键盘再次弹出。这里统一释放焦点，保证只有再次点搜索框才弹键盘。
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// 「经典入口」右侧搜索框：进入搜索激活状态，弹出搜索框并拉起键盘。
  void activateSearch() {
    if (!mounted) return;
    if (_drawerOpen) _closeDrawer();
    setState(() {
      _searchActive = true;
      _showScrollToFolderButton = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  /// 处于搜索模式时退出搜索并返回 true（侧滑返回手势/切换菜单前调用）。
  bool exitSearchIfActive() {
    if (!mounted || !_searchActive) return false;
    _exitSearch();
    return true;
  }

  /// 底部菜单切换：退出搜索激活状态。
  void deactivateSearch() {
    if (!mounted) return;
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _searchActive = false;
    });
    _dismissKeyboard();
    // 退出搜索后滚动视图重建、位置归零，需重新评估按钮显隐。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateScrollToFolderButton();
    });
  }

  /// 页内清空按钮：退出搜索激活状态。
  void _exitSearch() {
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _searchActive = false;
    });
    _dismissKeyboard();
    // 退出搜索后滚动视图重建、位置归零，需重新评估按钮显隐。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateScrollToFolderButton();
    });
  }

  String _resolveSutraPath(Sutra sutra) {
    return SutraAssetPath.resolve(
      title: sutra.title,
      filePath: sutra.filePath,
    );
  }

  Future<void> _loadDownloadedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_kDownloadedIdsKey) ?? const [];
    // 兼容历史下载：扫描本地文件补齐，确保已下载的经文也显示「下载完成」对号。
    final diskIds = await SutraDownloader.listDownloadedIds();
    final merged = <String>{...ids, ...diskIds};
    // 无条件持久化合并结果（之前只在 diskIds 有新增时才写），
    // 防止内存中临时空集被刷回 prefs 把已有记录写空。
    if (merged.length != ids.length || !merged.containsAll(ids.toSet())) {
      await prefs.setStringList(_kDownloadedIdsKey, merged.toList());
    }
    if (!mounted) return;
    setState(() {
      _downloadedIds
        ..clear()
        ..addAll(merged);
    });
    _sutraDataVersion.value++;
  }

  /// 重新扫描本地下载目录，把缺失的状态补齐（阅读页等直接下载的经书也能显示对号）。
  Future<void> syncDownloadedIdsFromDisk() async {
    final diskIds = await SutraDownloader.listDownloadedIds();
    if (!mounted) return;
    var changed = false;
    setState(() {
      for (final id in diskIds) {
        if (_downloadedIds.add(id)) changed = true;
      }
    });
    if (changed) {
      await _persistDownloadedIds();
      _sutraDataVersion.value++;
    }
  }

  Future<void> _persistDownloadedIds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kDownloadedIdsKey, _downloadedIds.toList());
  }

  void _markDownloaded(String id) {
    if (!mounted) return;
    setState(() {
      _downloadedIds.add(id);
      _downloadProgress.remove(id);
    });
    _sutraDataVersion.value++;
  }

  Future<void> _downloadSingle(Sutra sutra, String id) async {
    // 本地已有完整文件时直接标记为已下载并打开，不重新下载。
    // 这是防止「已下载经文被误判为未下载而反复重下」的关键兜底：
    // 即使上游 _canOpenSutra / _downloadedIds 因任何原因误判，
    // 这里也能确保已有文件不被无谓地重新下载。
    if (await SutraDownloader.isDownloaded(id)) {
      _markDownloaded(id);
      await _persistDownloadedIds();
      if (!mounted) return;
      _openReading(sutra);
      return;
    }
    setState(() {
      _downloadProgress[id] = 0;
    });
    try {
      await SutraDownloader.download(id, onProgress: (received, total) {
        if (!mounted) return;
        final p = total > 0 ? received / total : 0.0;
        final prev = _downloadProgress[id] ?? 0;
        if (p < 1.0 && (p - prev).abs() < 0.02) return;
        setState(() {
          _downloadProgress[id] = p;
        });
        _sutraDataVersion.value++;
      });
      _markDownloaded(id);
      await _persistDownloadedIds();
      if (!mounted) return;
      final shouldRead = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('下载完成'),
          content: Text('《${_displayTitle(sutra.title)}》已下载完成，是否现在阅读？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppPalette.p.accent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('阅读'),
            ),
          ],
        ),
      );
      if (shouldRead == true && mounted) {
        _openReading(sutra);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloadProgress.remove(id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$e')),
      );
    }
  }

  Future<void> _downloadFolder(String folderName) async {
    final targets = <Sutra>[];
    for (final s in _getAllSutrasInFolder(folderName)) {
      final id = SutraDownloader.extractId(s.title, s.filePath);
      // 同时检查内存集合和磁盘文件，避免已下载的经文被重复下载。
      if (id != null &&
          !_downloadedIds.contains(id) &&
          !await SutraDownloader.isDownloaded(id)) {
        targets.add(s);
      }
    }
    if (targets.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本卷经文已全部下载')),
      );
      return;
    }
    setState(() {
      _folderDownloadDone[folderName] = 0;
      _folderDownloadTotal[folderName] = targets.length;
    });
    for (var i = 0; i < targets.length; i++) {
      final s = targets[i];
      final id = SutraDownloader.extractId(s.title, s.filePath)!;
      // 再次确认磁盘上没有该文件（可能在批量下载过程中已被其他路径下载）。
      if (await SutraDownloader.isDownloaded(id)) {
        _markDownloaded(id);
        if (mounted) {
          setState(() {
            _folderDownloadDone[folderName] = i + 1;
          });
          _sutraDataVersion.value++;
        }
        continue;
      }
      setState(() {
        _downloadProgress[id] = 0;
      });
      try {
        await SutraDownloader.download(id, onProgress: (received, total) {
          if (!mounted) return;
          final p = total > 0 ? received / total : 0.0;
          final prev = _downloadProgress[id] ?? 0;
          if (p < 1.0 && (p - prev).abs() < 0.02) return;
          setState(() {
            _downloadProgress[id] = p;
          });
        });
        _markDownloaded(id);
      } catch (_) {
        // 单本失败不中断整卷下载。
      }
      if (mounted) {
        setState(() {
          _folderDownloadDone[folderName] = i + 1;
        });
        _sutraDataVersion.value++;
      }
    }
    await _persistDownloadedIds();
    if (!mounted) return;
    setState(() {
      _folderDownloadDone.remove(folderName);
      _folderDownloadTotal.remove(folderName);
    });
    _sutraDataVersion.value++;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('《${_folderDisplayNames[folderName] ?? folderName}》下载完成')),
    );
  }

  Widget _buildDownloadTrailing(Sutra sutra) {
    final id = SutraDownloader.extractId(sutra.title, sutra.filePath);
    if (id == null || kIsWeb) return const SizedBox(width: 28);
    final progress = _downloadProgress[id];
    if (progress != null) {
      return SizedBox(
        width: 34,
        height: 30,
        child: Center(
          child: progress >= 1.0
              ? const Icon(Icons.check_circle, size: 15, color: Color(0xFF8FBC8F))
              : SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: progress > 0 ? progress : null,
                    color: const Color(0xFF71867A),
                  ),
                ),
        ),
      );
    }
    // memory hit → 绿色对勾
    if (_downloadedIds.contains(id)) {
      return const SizedBox(
        width: 34,
        height: 30,
        child: Center(
          child: Icon(Icons.check_circle, size: 15, color: Color(0xFF8FBC8F)),
        ),
      );
    }
    // memory miss → 异步查磁盘：文件存在就显示对勾（防止冷启动竞态窗口内
    // 全显示下载按钮），查到后补进 _downloadedIds 供后续同步命中。
    return SizedBox(
      width: 34,
      height: 30,
      child: FutureBuilder<bool>(
        future: SutraDownloader.isDownloaded(id),
        builder: (context, snapshot) {
          if (snapshot.data == true) {
            // 补进内存集合 + prefs，让后续不再走 FutureBuilder
            if (_downloadedIds.add(id)) {
              _persistDownloadedIds();
              _sutraDataVersion.value++;
            }
            return const Center(
              child: Icon(Icons.check_circle,
                  size: 15, color: Color(0xFF8FBC8F)),
            );
          }
          return IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            iconSize: 17,
            tooltip: '下载',
            icon: const Icon(Icons.download, color: Color(0xFF71867A)),
            onPressed: () => _downloadSingle(sutra, id),
          );
        },
      ),
    );
  }

  void _showMissingSutrasSheet() {
    if (!_missingComputed) return;
    if (_missingSutraTitles.isEmpty) return;

    final titles = _missingSutraTitles.toList()..sort();
    final fullText = titles.join('\n');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (ctx) {
        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.85,
            minChildSize: 0.35,
            maxChildSize: 0.95,
            builder: (ctx, controller) {
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Text(
                          '缺失经文 (${titles.length})',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF212121),
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: fullText));
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制缺失经文列表')),
                            );
                          },
                          child: const Text('复制全部'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      controller: controller,
                      itemCount: titles.length,
                      itemBuilder: (ctx, i) {
                        final t = titles[i];
                        return ListTile(
                          dense: true,
                          visualDensity: const VisualDensity(horizontal: 0, vertical: -3),
                          title: Text(
                            t,
                            style: const TextStyle(color: Colors.red, fontSize: 14),
                          ),
                          trailing: IconButton(
                            tooltip: '复制',
                            icon: const Icon(Icons.copy, size: 18, color: Color(0xFF616161)),
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: t));
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已复制')),
                              );
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
    }

  List<Sutra> _defaultSutras = [];
  List<Sutra> _allSutras = [];

  /// 多卷经书的基础经名集合（用于显示「卷X」卷标）。
  Set<String> _multiVolumeBases = const {};
  List<Sutra> _filteredSutras = [];
  List<File> txtFiles = [];

  bool _isReadExpanded = false;
  bool _isFavoriteExpanded = false;

  /// 是否处于搜索激活状态（「经典入口」右侧搜索框进入，页内清空退出）。
  bool _searchActive = false;

  static const String _kDownloadedIdsKey = 'downloaded_sutra_ids';
  /// 数据版本号：下载进度/经书状态变化时递增，供子页面（分部详情页）监听刷新。
  final ValueNotifier<int> _sutraDataVersion = ValueNotifier<int>(0);
  final Set<String> _downloadedIds = {};
  final Map<String, double> _downloadProgress = {};
  final Map<String, int> _folderDownloadDone = {};
  final Map<String, int> _folderDownloadTotal = {};

  // 文件夹名称映射
  final Map<String, String> _folderDisplayNames = {
    'T01阿含部类': 'T01阿含部类',
    'T02阿含部类': 'T02阿含部类',
    'T03本缘部': 'T03本缘部',
    'T04本缘部': 'T04本缘部',
    'T05般若部': 'T05般若部',
    'T06般若部': 'T06般若部',
    'T07般若部': 'T07般若部',
    'T08般若部': 'T08般若部',
    'T09法华部·华严部': 'T09法华部·华严部',
    'T10法华部·华严部': 'T10法华部·华严部',
    'T11宝积部·涅槃部': 'T11宝积部·涅槃部',
    'T12宝积部·涅槃部': 'T12宝积部·涅槃部',
    'T13大集部': 'T13大集部',
    'T14经集部': 'T14经集部',
    'T15经集部': 'T15经集部',
    'T16经集部': 'T16经集部',
    'T17经集部': 'T17经集部',
    'T18密教部': 'T18密教部',
    'T19密教部': 'T19密教部',
    'T20密教部': 'T20密教部',
    'T21密教部': 'T21密教部',
    'T22律部': 'T22律部',
    'T23律部': 'T23律部',
    'T24律部': 'T24律部',
    'T25释经论部·毗昙部': 'T25释经论部·毗昙部',
    'T26释经论部·毗昙部': 'T26释经论部·毗昙部',
    'T27释经论部·毗昙部': 'T27释经论部·毗昙部',
    'T28释经论部·毗昙部': 'T28释经论部·毗昙部',
    'T29释经论部·毗昙部': 'T29释经论部·毗昙部',
    'T30中观部·瑜伽部': 'T30中观部·瑜伽部',
    'T31中观部·瑜伽部': 'T31中观部·瑜伽部',
    'T32论集部': 'T32论集部',
    'T33经疏部': 'T33经疏部',
    'T34经疏部': 'T34经疏部',
    'T35经疏部': 'T35经疏部',
    'T36经疏部': 'T36经疏部',
    'T37经疏部': 'T37经疏部',
    'T38经疏部': 'T38经疏部',
    'T39经疏部': 'T39经疏部',
    'T40律疏部·论疏部': 'T40律疏部·论疏部',
    'T41律疏部·论疏部': 'T41律疏部·论疏部',
    'T42律疏部·论疏部': 'T42律疏部·论疏部',
    'T43律疏部·论疏部': 'T43律疏部·论疏部',
    'T44律疏部·论疏部': 'T44律疏部·论疏部',
    'T45诸宗部': 'T45诸宗部',
    'T46诸宗部': 'T46诸宗部',
    'T47诸宗部': 'T47诸宗部',
    'T48诸宗部': 'T48诸宗部',
    'T49史传部': 'T49史传部',
    'T50史传部': 'T50史传部',
    'T51史传部': 'T51史传部',
    'T52史传部': 'T52史传部',
    'T53事汇部·外教部·目录部': 'T53事汇部·外教部·目录部',
    'T54事汇部·外教部·目录部': 'T54事汇部·外教部·目录部',
    'T55事汇部·外教部·目录部': 'T55事汇部·外教部·目录部',
    'T85图象部': 'T85图象部',
  };

  @override
  void initState() {
    super.initState();
    _initFolders();
    // 默认显示最后一个部类（最近的部类）
    if (_folders.isNotEmpty) {
      _randomFolder = _folders.last;
    }
    _loadSutras();
    _loadLastRead();
    _loadReadingStats();
    _loadRecentSutras();
    _loadAssetManifest();
    _loadDownloadedIds();
    AuthService.instance.currentUser.addListener(_onAuthChanged);
    widget.activeTab?.addListener(_onActiveTabChanged);    _searchController.addListener(_filterSutras);
    _scrollController.addListener(_onScroll);
    _drawerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    final drawerCurve = CurvedAnimation(
      parent: _drawerController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _drawerSlide =
        Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero).animate(drawerCurve);
    _overlayOpacity = Tween<double>(begin: 0, end: 1).animate(drawerCurve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  /// 从阅读页等路由返回时刷新“最近阅读”与收藏状态，保证卡片始终是最新的。
  @override
  void didPopNext() {
    reload();
  }

  void _onActiveTabChanged() {
    _loadLastRead();
  }

  /// 登录/登出后会话状态变化时，从 prefs + 磁盘重新合并下载 ID 列表，
  /// 确保已下载的经文不会因重新登录/掉线恢复而被误判为「未下载」。
  void _onAuthChanged() {
    // 无论登录还是登出都重新加载：登出不清空状态，登录后从磁盘补齐。
    _loadDownloadedIds();
  }

  /// 滚动监听：根据随机经部区块相对视口的位置，决定「回到经部」按钮的显隐。
  void _onScroll() {
    _updateScrollToFolderButton();
  }

  /// 重新计算「回到经部」按钮是否应显示。
  /// 仅当随机经部区块顶部已滚出视口（上方内容全部被遮盖）时才显示。
  void _updateScrollToFolderButton() {
    if (!_scrollController.hasClients) {
      if (_showScrollToFolderButton) {
        setState(() => _showScrollToFolderButton = false);
      }
      return;
    }
    if (_randomFolder == null) {
      if (_showScrollToFolderButton) {
        setState(() => _showScrollToFolderButton = false);
      }
      return;
    }
    final ctx = _randomFolderKey.currentContext;
    if (ctx == null) return;
    final renderObject = ctx.findRenderObject();
    if (renderObject == null) return;
    final viewport = RenderAbstractViewport.of(renderObject);
    final targetOffset = viewport.getOffsetToReveal(renderObject, 0.0).offset;
    final shouldShow = _scrollController.offset >= targetOffset - 1.0;
    if (shouldShow != _showScrollToFolderButton) {
      setState(() => _showScrollToFolderButton = shouldShow);
    }
  }

  /// 点击「回到经部」按钮：平滑滚动到随机经部区块顶部。
  void _scrollToRandomFolder() {
    if (!_scrollController.hasClients) return;
    final ctx = _randomFolderKey.currentContext;
    if (ctx == null) return;
    final renderObject = ctx.findRenderObject();
    if (renderObject == null) return;
    final viewport = RenderAbstractViewport.of(renderObject);
    final targetOffset = viewport.getOffsetToReveal(renderObject, 0.0).offset;
    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
    );
  }

  /// 「回到经部」浮动按钮：圆形底色 + 上箭头，与页面暖色调协调。
  Widget _buildScrollToFolderButton() {
    return Material(
      color: AppPalette.p.accent,
      shape: const CircleBorder(),
      elevation: 3,
      shadowColor: AppPalette.p.primary.withValues(alpha: 0.3),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _scrollToRandomFolder,
        child: const SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            Icons.keyboard_arrow_up,
            color: Colors.white,
            size: 26,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.activeTab?.removeListener(_onActiveTabChanged);
    AuthService.instance.currentUser.removeListener(_onAuthChanged);
    routeObserver.unsubscribe(this);
    _drawerController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _sutraDataVersion.dispose();
    super.dispose();
  }

  List<String> _folders = [];

  void _initFolders() {
    _folders = _folderDisplayNames.values.toList();
  }

  Future<void> _loadSutras() async {
    // 1) 优先读本地 JSON 文件（快速，避免大键塞进 SharedPreferences 拖慢启动）。
    final file = await _sutraListFile();
    try {
      if (await file.exists()) {
        final loaded = await _parseSutraListFile(file);
        if (loaded.isNotEmpty) {
          final repaired = repairLegacySutraList(loaded);
          if (!identical(repaired, loaded)) {
            await _writeSutraListFile(repaired);
            await _repairLegacyTitlePrefs();
          }
          _applySutraList(repaired);
          await _enrichCharCounts();
          await _maybeRestoreDefaultsAfterApkUpdate();
          await _applyRestoredSutraStates();
          return;
        }
      }
    } catch (_) {
      // 文件损坏则回退到 prefs / 打包目录。
    }

    // 2) 从旧版 SharedPreferences 迁移（首次升级后执行一次）。
    final prefs = await SharedPreferences.getInstance();
    final sutraJsonList = prefs.getStringList('sutras');
    if (sutraJsonList != null && sutraJsonList.isNotEmpty) {
      final loaded = repairLegacySutraList(sutraJsonList
          .map((jsonStr) => Sutra.fromJson(jsonDecode(jsonStr)))
          .toList());
      await _writeSutraListFile(loaded);
      await prefs.remove('sutras');
      await _repairLegacyTitlePrefs();
      _applySutraList(loaded);
      await _enrichCharCounts();
      await _maybeRestoreDefaultsAfterApkUpdate();
      await _applyRestoredSutraStates();
      return;
    }

    // 3) 首次启动：从打包的目录 JSON 加载。
    final catalog = await _loadCatalogFromAsset();
    _applySutraList(catalog);
    await _writeSutraListFile(catalog);
    // 初始化安装标记（避免第一次启动就触发“恢复默认”）。
    await _shouldRestoreDefaultsAfterApkUpdate(prefs);
    await _applyRestoredSutraStates();
  }

  /// 一次性修复 SharedPreferences 中历史遗留的「第卷」脏经名：
  /// current_sutra_title / last_read_title / recent_sutras /
  /// sutra_states / daily_sutra_history，与经书列表修复保持一致。
  Future<void> _repairLegacyTitlePrefs() async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in const ['current_sutra_title', 'last_read_title']) {
        final v = prefs.getString(key);
        if (v != null && v.contains('第卷')) {
          await prefs.setString(key, repairLegacySutraTitle(v));
        }
      }
      final recent = prefs.getStringList('recent_sutras');
      if (recent != null && recent.any((e) => e.contains('第卷'))) {
        await prefs.setStringList(
            'recent_sutras',
            recent.map((e) {
              final i = e.indexOf('|||');
              if (i < 0) return repairLegacySutraTitle(e);
              return '${repairLegacySutraTitle(e.substring(0, i))}${e.substring(i)}';
            }).toList());
      }
      final rawStates = prefs.getString('sutra_states');
      if (rawStates != null && rawStates.contains('第卷')) {
        final states = jsonDecode(rawStates);
        if (states is Map && states.isNotEmpty) {
          final fixed = <String, dynamic>{};
          states.forEach((k, v) {
            fixed.putIfAbsent(repairLegacySutraTitle(k.toString()), () => v);
          });
          await prefs.setString('sutra_states', jsonEncode(fixed));
        }
      }
      final rawHistory = prefs.getString('daily_sutra_history');
      if (rawHistory != null && rawHistory.contains('第卷')) {
        final history = jsonDecode(rawHistory);
        if (history is Map) {
          history.forEach((_, dayList) {
            if (dayList is! List) return;
            for (final e in dayList) {
              if (e is Map && e['title'] is String) {
                e['title'] = repairLegacySutraTitle(e['title'] as String);
              }
            }
          });
          await prefs.setString('daily_sutra_history', jsonEncode(history));
        }
      }
    } catch (_) {
      // 修复失败不影响正常加载。
    }
  }

  /// 将云端同步下来的经书状态（已读/收藏/置顶/时间）合并进本地列表。
  /// 以标题匹配，采用并集（OR）语义：本地缺失的状态补上，已有状态绝不覆盖。
  /// 幂等：重复合并不会产生副作用。
  Future<void> _applyRestoredSutraStates() async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('sutra_states');
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded.isEmpty) return;
      // 云端可能仍存着历史脏经名（「第卷」占位），归一化后再匹配。
      final states = raw.contains('第卷')
          ? <String, dynamic>{
              for (final e in decoded.entries)
                repairLegacySutraTitle(e.key.toString()): e.value,
            }
          : decoded;

      var changed = false;
      final list = List<Sutra>.from(_allSutras);
      for (var i = 0; i < list.length; i++) {
        final st = states[list[i].title];
        if (st is! Map) continue;
        final s = list[i];
        final r = st['r'] == true;
        final f = st['f'] == true;
        final p = st['p'] == true;
        final rl = st['rl'] == true;
        final rt = st['rt']?.toString();
        final ft = st['ft']?.toString();
        final rlt = st['rlt']?.toString();
        if (!r && !f && !p && !rl && rt == null && ft == null && rlt == null) continue;
        final timeSame =
            (rt == null || s.readTime?.toIso8601String() == rt) &&
                (ft == null || s.favoriteTime?.toIso8601String() == ft) &&
                (rlt == null || s.readLaterTime?.toIso8601String() == rlt);
        if (r == s.isRead && f == s.isFavorite && p == s.isPinned && rl == s.isReadLater && timeSame) {
          continue;
        }
        list[i] = Sutra(
          s.title,
          s.size,
          charCount: s.charCount,
          isPinned: s.isPinned || p,
          isRead: s.isRead || r,
          isFavorite: s.isFavorite || f,
          isReadLater: s.isReadLater || rl,
          filePath: s.filePath,
          folder: s.folder,
          favoriteTime:
              (s.favoriteTime != null || ft == null) ? s.favoriteTime : DateTime.tryParse(ft),
          readTime: (s.readTime != null || rt == null) ? s.readTime : DateTime.tryParse(rt),
          readLaterTime: (s.readLaterTime != null || rlt == null) ? s.readLaterTime : DateTime.tryParse(rlt),
        );
        changed = true;
      }
      if (changed) {
        _applySutraList(list);
        await _writeSutraListFile(list);
      }
    } catch (_) {
      // 状态合并失败不影响列表加载。
    }
  }

  void _applySutraList(List<Sutra> list) {
    setState(() {
      _allSutras = List.from(list);
      _multiVolumeBases = collectMultiVolumeBases(_allSutras);
      // 搜索激活时保持过滤（reload 会重置 _filteredSutras 为全量，
      // 若不重新过滤，搜索结果会和搜索框字符不一致）。
      _filteredSutras = _searchActive
          ? _filterListBySearch(List.from(list))
          : List.from(list);
    });
    _randomSutra ??= _rollRandomSutra();
    unawaited(_ensureRandomFolder());
    _bestAssetPathByTitleCache.clear();
    _missingComputed = false;
    _recomputeMissingSutrasIfReady();
  }

  /// 按当前搜索框内容过滤 [list]，空查询返回全量。
  /// 结果按匹配度排序：完全相同 > 书名开头匹配 > 书名包含（位置越靠前越优先）
  /// > 仅部类名匹配；同一档位内置顶优先，其余保持原列表顺序。
  List<Sutra> _filterListBySearch(List<Sutra> list) {
    final q = _searchController.text.trim();
    if (q.isEmpty) return list;
    final hits = <(int, int, int, int, Sutra)>[];
    for (var i = 0; i < list.length; i++) {
      final s = list[i];
      final idx = s.title.indexOf(q);
      final folderHit = (_folderDisplayNames[s.folder] ?? '').contains(q);
      if (idx < 0 && !folderHit) continue;
      final int rank;
      if (idx < 0) {
        rank = 3;
      } else if (s.title == q) {
        rank = 0;
      } else if (idx == 0) {
        rank = 1;
      } else {
        rank = 2;
      }
      hits.add((rank, s.isPinned ? 0 : 1, idx < 0 ? 0 : idx, i, s));
    }
    hits.sort((a, b) {
      if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      if (a.$3 != b.$3) return a.$3.compareTo(b.$3);
      return a.$4.compareTo(b.$4);
    });
    return [for (final h in hits) h.$5];
  }

  /// 默认在「全部经典」下方随机展示一部（与随缘读经一致），优先恢复上次展示的部类。
  Future<void> _ensureRandomFolder() async {
    if (_randomFolder != null) return;
    String? restored;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('last_random_folder');
      if (saved != null && saved.isNotEmpty && _folders.contains(saved)) {
        restored = saved;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _randomFolder = restored ?? _rollRandomFolder();
    });
    if (restored == null) {
      await _persistRandomFolder();
    }
  }

  /// 记录当前展示的部类，便于下次打开恢复。
  Future<void> _persistRandomFolder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_random_folder', _randomFolder ?? '');
    } catch (_) {}
  }

  /// 云端同步拉取后刷新经书列表与最近阅读。
  Future<void> reload() async {
    await _loadSutras();
    await _loadLastRead();
    await _loadReadingStats();
    await _loadRecentSutras();
    // 同步刷新下载标记：reload 之前不调这一步，导致云同步后 _downloadedIds
    // 反映的还是旧的内存状态，已下载的经文被误显示为未下载。
    await _loadDownloadedIds();
  }

  Future<File> _sutraListFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}${Platform.pathSeparator}sutras_list.json');
  }

  Future<List<Sutra>> _parseSutraListFile(File file) async {
    final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
    return decoded.map((e) => Sutra.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> _writeSutraListFile(List<Sutra> list) async {
    if (kIsWeb) return;
    try {
      final file = await _sutraListFile();
      // 原子写：先写临时文件再改名替换，避免并发读取读到写到一半的损坏文件。
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(list.map((s) => s.toJson()).toList()),
        flush: true,
      );
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
    } catch (_) {
      // 写入失败不影响内存中的列表。
    }
  }

  Future<List<Sutra>> _loadCatalogFromAsset() async {
    if (_defaultSutras.isNotEmpty) return List.from(_defaultSutras);
    try {
      final raw = await rootBundle.loadString('assets/sutras_catalog.json');
      final decoded = jsonDecode(raw) as List<dynamic>;
      final list = decoded.map((e) {
        final m = e as Map<String, dynamic>;
        return Sutra(
          repairLegacySutraTitle(m['t'] as String),
          m['s'] as String,
          charCount: m['c'] as int? ?? 0,
          folder: m['f'] as String?,
        );
      }).toList();
      _defaultSutras = list;
      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _maybeRestoreDefaultsAfterApkUpdate() async {
    if (kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    final shouldRestore = await _shouldRestoreDefaultsAfterApkUpdate(prefs);
    if (!shouldRestore) return;
    await _loadCatalogFromAsset();
    if (_defaultSutras.isEmpty) return;
    final restored = _mergeMissingDefaultSutras(_allSutras);
    _applySutraList(restored);
    await _writeSutraListFile(restored);
  }

  Future<bool> _shouldRestoreDefaultsAfterApkUpdate(SharedPreferences prefs) async {
    if (kIsWeb) return false;
    if (!Platform.isAndroid) return false;
    try {
      final current = await _appChannel.invokeMethod<int>('getLastUpdateTime');
      if (current == null) return false;
      final last = prefs.getInt(_kApkLastUpdateTimeKey);
      if (last == null) {
        await prefs.setInt(_kApkLastUpdateTimeKey, current);
        return false;
      }
      if (last != current) {
        await prefs.setInt(_kApkLastUpdateTimeKey, current);
        return true;
      }
    } catch (_) {
      // ignore
    }
    return false;
  }

  List<Sutra> _mergeMissingDefaultSutras(List<Sutra> current) {
    // 用标题作为唯一键（目录 JSON 中默认经书没有 filePath）。
    final existingTitles = <String>{};
    for (final s in current) {
      existingTitles.add(s.title);
    }

    final merged = List<Sutra>.from(current);
    for (final d in _defaultSutras) {
      if (!existingTitles.contains(d.title)) {
        merged.add(d);
      }
    }
    return merged;
  }

  Future<void> _saveSutras() async {
    await _writeSutraListFile(_allSutras);
    _sutraDataVersion.value++;
  }

  void _filterSutras() {
    setState(() {
      _filteredSutras = _filterListBySearch(List.from(_allSutras));
    });
  }

  void _showBottomSheet(BuildContext context, Sutra sutra, {bool showPin = false}) {
    _dismissKeyboard();
    // 传入对象可能是旧引用（如随缘读经的随机经书），按标题解析到当前列表对象，
    // 保证菜单文案与操作都基于最新状态。
    final index = _allSutras.indexWhere((s) => s.title == sutra.title);
    if (index < 0) return;
    final current = _allSutras[index];
    // 点击时重新解析索引，避免弹窗打开期间列表被重载/重排导致误操作其他经书。
    int resolveIndex() =>
        _allSutras.indexWhere((s) => s.title == current.title);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildMenuItem(
                icon: current.isFavorite ? Icons.favorite : Icons.favorite_border,
                title: current.isFavorite ? '取消收藏' : '收藏',
                onTap: () async {
                  final idx = resolveIndex();
                  String? msg;
                  if (idx >= 0) {
                    final wasFav = _allSutras[idx].isFavorite;
                    await _toggleFavorite(idx);
                    msg = wasFav ? '已取消收藏' : '已收藏';
                  }
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  if (msg != null) _showToast(msg);
                },
              ),
              _buildMenuItem(
                icon: current.isReadLater ? Icons.bookmark : Icons.bookmark_border,
                title: current.isReadLater ? '取消稍后阅读' : '稍后阅读',
                onTap: () async {
                  final idx = resolveIndex();
                  String? msg;
                  if (idx >= 0) {
                    final wasRL = _allSutras[idx].isReadLater;
                    await _toggleReadLater(idx);
                    msg = wasRL ? '已取消稍后阅读' : '已标记稍后阅读';
                  }
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  if (msg != null) _showToast(msg);
                },
              ),
              if (showPin)
                _buildMenuItem(
                  icon: current.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  title: current.isPinned ? '取消置顶' : '置顶',
                  onTap: () async {
                    final idx = resolveIndex();
                    String? msg;
                    if (idx >= 0) {
                      final wasPinned = _allSutras[idx].isPinned;
                      await _togglePin(idx);
                      msg = wasPinned ? '已取消置顶' : '已置顶';
                    }
                    if (!context.mounted) return;
                    Navigator.pop(context);
                    if (msg != null) _showToast(msg);
                  },
                ),
              _buildMenuItem(
                icon: current.isRead ? Icons.mark_chat_unread : Icons.mark_chat_read,
                title: current.isRead ? '取消完成阅读' : '标记完成阅读',
                onTap: () async {
                  final idx = resolveIndex();
                  String? msg;
                  if (idx >= 0) {
                    final wasRead = _allSutras[idx].isRead;
                    await _toggleRead(idx);
                    msg = wasRead ? '已取消完成阅读标记' : '已标记完成阅读';
                  }
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  if (msg != null) _showToast(msg);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// 显示轻提示（收藏/标记等操作反馈）。
  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// 供子页面（收藏页等）复用：弹出经书长按菜单。
  void showSutraMenu(BuildContext context, Sutra sutra, {bool showPin = false}) {
    _showBottomSheet(context, sutra, showPin: showPin);
  }

  /// 供子页面监听的经书数据版本号。
  ValueListenable<int> get sutraDataVersion => _sutraDataVersion;

  /// 供子页面读取收藏列表（置顶优先）。
  List<Sutra> getFavoriteSutras() => _getFavoriteSutras();

  /// 供子页面读取全部经书列表。
  List<Sutra> get allSutras => List.unmodifiable(_allSutras);

  /// 供子页面读取部类显示名映射。
  Map<String, String> get folderDisplayNames => _folderDisplayNames;

  /// 供子页面查询某本经书当前的下载进度（null 表示未在下载）。
  double? downloadProgressOf(String id) => _downloadProgress[id];

  /// 供子页面判断某本经书是否已下载到本地。
  bool isSutraDownloaded(String id) => _downloadedIds.contains(id);

  /// 供子页面打开经书：复用经藏页的下载进度小圆圈与「下载完成」提示。
  Future<void> openSutraFromChild(Sutra sutra) => _openSutra(sutra);

  Widget _buildMenuItem({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF212121), size: 24),
            const SizedBox(width: 16),
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFF212121),
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _togglePin(int index) async {
    setState(() {
      _allSutras[index] = Sutra(
        _allSutras[index].title,
        _allSutras[index].size,
        charCount: _allSutras[index].charCount,
        isPinned: !_allSutras[index].isPinned,
        isRead: _allSutras[index].isRead,
        isFavorite: _allSutras[index].isFavorite,
        isReadLater: _allSutras[index].isReadLater,
        filePath: _allSutras[index].filePath,
        folder: _allSutras[index].folder,
        readLaterTime: _allSutras[index].readLaterTime,
      );
      _filterSutras();
    });
    await _saveSutras();
    await SutraFavorites.syncStatePref(_allSutras[index].title);
  }

  Future<void> _toggleFavorite(int index) async {
    setState(() {
      _allSutras[index] = Sutra(
        _allSutras[index].title,
        _allSutras[index].size,
        charCount: _allSutras[index].charCount,
        isPinned: _allSutras[index].isPinned,
        isRead: _allSutras[index].isRead,
        isFavorite: !_allSutras[index].isFavorite,
        isReadLater: _allSutras[index].isReadLater,
        filePath: _allSutras[index].filePath,
        folder: _allSutras[index].folder,
        favoriteTime: !_allSutras[index].isFavorite ? DateTime.now() : null,
        readTime: _allSutras[index].readTime,
        readLaterTime: _allSutras[index].readLaterTime,
      );
      _filterSutras();
    });
    await _saveSutras();
    await SutraFavorites.syncStatePref(_allSutras[index].title);
  }

  Future<void> _toggleRead(int index) async {
    setState(() {
      _allSutras[index] = Sutra(
        _allSutras[index].title,
        _allSutras[index].size,
        charCount: _allSutras[index].charCount,
        isPinned: _allSutras[index].isPinned,
        isRead: !_allSutras[index].isRead,
        isFavorite: _allSutras[index].isFavorite,
        isReadLater: _allSutras[index].isReadLater,
        filePath: _allSutras[index].filePath,
        folder: _allSutras[index].folder,
        favoriteTime: _allSutras[index].favoriteTime,
        readTime: !_allSutras[index].isRead ? DateTime.now() : null,
        readLaterTime: _allSutras[index].readLaterTime,
      );
      _filterSutras();
    });
    await _saveSutras();
    await SutraFavorites.syncStatePref(_allSutras[index].title);
  }

  Future<void> _toggleReadLater(int index) async {
    setState(() {
      _allSutras[index] = Sutra(
        _allSutras[index].title,
        _allSutras[index].size,
        charCount: _allSutras[index].charCount,
        isPinned: _allSutras[index].isPinned,
        isRead: _allSutras[index].isRead,
        isFavorite: _allSutras[index].isFavorite,
        isReadLater: !_allSutras[index].isReadLater,
        filePath: _allSutras[index].filePath,
        folder: _allSutras[index].folder,
        favoriteTime: _allSutras[index].favoriteTime,
        readTime: _allSutras[index].readTime,
        readLaterTime: !_allSutras[index].isReadLater ? DateTime.now() : null,
      );
      _filterSutras();
    });
    await _saveSutras();
    await SutraReadLater.syncStatePref(_allSutras[index].title);
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      setState(() {
        for (var file in result.files) {
          if (file.path != null) {
            String fileName = file.path!;
            if (fileName.toLowerCase().endsWith('.txt')) {
              File f = File(file.path!);
              txtFiles.add(f);
              String name = fileName.split('/').last.split('\\').last.replaceAll('.txt', '');
              int size = f.lengthSync();
              String sizeStr = size < 1024 ? '${size}B' : size < 1024 * 1024 ? '${(size / 1024).toStringAsFixed(1)}k' : '${(size / (1024 * 1024)).toStringAsFixed(1)}M';
              _allSutras.add(Sutra(name, sizeStr, filePath: file.path, folder: 'T01'));
              print('Added sutra: $name, path: ${file.path}');
            }
          }
        }
        _filteredSutras = List.from(_allSutras);
      });
      _saveSutras();
    }
  }

  List<Sutra> _getReadSutras() {
    List<Sutra> readSutras = _filteredSutras.where((sutra) => sutra.isRead).toList();
    readSutras.sort((a, b) {
      if (a.readTime == null && b.readTime == null) return 0;
      if (a.readTime == null) return 1;
      if (b.readTime == null) return -1;
      return b.readTime!.compareTo(a.readTime!);
    });
    return readSutras;
  }

  /// 某部分类下的全部经书（含已读）。
  List<Sutra> _getAllSutrasInFolder(String folder) {
    return _allSutras.where((s) => s.folder == folder).toList();
  }

  /// 我的收藏：置顶优先，其余按收藏时间倒序。
  List<Sutra> _getFavoriteSutras() {
    final list = _allSutras.where((s) => s.isFavorite).toList();
    list.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      if (a.favoriteTime == null && b.favoriteTime == null) return 0;
      if (a.favoriteTime == null) return 1;
      if (b.favoriteTime == null) return -1;
      return b.favoriteTime!.compareTo(a.favoriteTime!);
    });
    return list;
  }

  Future<void> _loadLastRead() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString('last_read_title');
    final fp = prefs.getString('last_read_filePath');
    var progress = 0.0;
    if (fp != null) {
      // 兼容旧版本用本机绝对路径命名的 progress_ 键，取所有形式的最大值。
      final variants =
          await SutraDownloader.pathKeyVariants(fp, title: t);
      for (final v in variants) {
        final p = prefs.getDouble('progress_$v') ?? 0.0;
        if (p > progress) progress = p;
      }
    }
    if (!mounted) return;
    setState(() {
      _lastReadTitle = t;
      _lastReadFilePath = fp;
      _lastReadProgress = progress;
    });
  }

  /// 阅读统计：已读天数与今日已读册数（依据每日诵经历史）。
  Future<void> _loadReadingStats() async {}

  /// 最近阅读记录（来自 recent_sutras）。
  Future<void> _loadRecentSutras() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('recent_sutras') ?? [];
    final list = raw.map((e) {
      final parts = e.split('|||');
      return {'title': parts[0], 'filePath': parts.length > 1 ? parts[1] : ''};
    }).toList();
    if (!mounted) return;
    setState(() {
      _recentSutras = list;
    });
  }

  String _displayTitle(String title, {String? filePath}) =>
      sutraDisplayTitleWithPath(title,
          filePath: filePath, multiVolumeBases: _multiVolumeBases);

  /// 供子页面（收藏/最近阅读/功课等）复用统一的经名展示逻辑。
  /// 标题不带 CBETA 编号时（如从笔记链接进入阅读后记录的经名），
  /// 可传 [filePath] 从路径补齐卷号，保证多卷经书显示「卷X」。
  String displayTitle(String title, {String? filePath}) =>
      _displayTitle(title, filePath: filePath);

  Sutra? _findSutra(String title) {
    for (final s in _allSutras) {
      if (s.title == title) return s;
    }
    return null;
  }

  /// 按标题精确查找；标题只有基础经名（如从笔记链接进入阅读后记录的经名）时，
  /// 用标题或路径里的 CBETA 编号回退匹配，保证能定位到具体卷。
  Sutra? _resolveSutraByTitleOrPath(String title, String? filePath) {
    final byTitle = _findSutra(title);
    if (byTitle != null) return byTitle;
    final id = SutraDownloader.extractId(title, filePath);
    if (id == null) return null;
    for (final s in _allSutras) {
      if (s.title.contains(id)) return s;
    }
    return null;
  }

  /// 供子页面（最近阅读页等）按标题查找经书。
  Sutra? findSutra(String title) => _findSutra(title);

  /// 供子页面读取最近阅读记录。
  List<Map<String, String>> getRecentSutras() =>
      List<Map<String, String>>.from(_recentSutras);

  /// 供子页面刷新最近阅读记录。
  Future<void> reloadRecentSutras() => _loadRecentSutras();

  Future<bool> _canOpenSutra(Sutra sutra) async {
    final fp = sutra.filePath;
    final isAssetLike = fp == null || fp.startsWith('assets/');
    // 无论路径形式，先按规范 ID 检查本地下载目录：云端同步恢复的路径
    // 可能是旧设备的本机绝对路径，在本机不存在但文件已在下载目录里，
    // 此时应直接打开，而不是误判「未下载」提示重新下载。
    final id = SutraDownloader.extractId(sutra.title, sutra.filePath);
    if (id != null) {
      if (_downloadedIds.contains(id)) return true;
      if (await SutraDownloader.isDownloaded(id)) return true;
    }
    if (isAssetLike) return false;
    return !_isSutraContentMissing(sutra);
  }

  void _openReading(Sutra sutra) {
    _dismissKeyboard();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReadingPage(
          title: sutra.title,
          filePath: _filePathForReading(sutra),
        ),
      ),
    );
  }

  Future<void> _openSutra(Sutra sutra) async {
    _dismissKeyboard();
    if (await _canOpenSutra(sutra)) {
      _openReading(sutra);
      return;
    }
    final id = SutraDownloader.extractId(sutra.title, sutra.filePath);
    if (id == null) {
      _openReading(sutra);
      return;
    }
    // 该经书正在下载中时，避免重复启动下载。
    final inFlight = _downloadProgress[id];
    if (inFlight != null && inFlight < 1.0) return;
    await _downloadSingle(sutra, id);
  }

  Widget _buildContinueReadingCard() {
    final title = _lastReadTitle;
    if (title == null) return const SizedBox.shrink();
    final pct = (_lastReadProgress * 100).clamp(0.0, 100.0);
    final sutra = _resolveSutraByTitleOrPath(title, _lastReadFilePath);
    final isRead = sutra?.isRead == true;
    final folderName = sutra != null
        ? (_folderDisplayNames[sutra.folder] ?? sutra.folder)
        : null;
    final meta = [
      if (folderName != null && folderName.isNotEmpty) folderName,
      if (sutra != null && sutra.charCount > 0) '${sutra.charCount} 字',
    ].join(' · ');
    final isPlain = AppPalette.instance.isPlain;
    final accentColor = AppPalette.p.readingAccent;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: AppPalette.p.card,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _openLastRead,
          onLongPress: () {
            final sutra = _resolveSutraByTitleOrPath(title, _lastReadFilePath);
            if (sutra != null) {
              _showBottomSheet(context, sutra);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: isPlain
                  ? null
                  : Border.all(color: AppPalette.p.borderSoft, width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 书籍图标
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.menu_book_rounded, color: accentColor, size: 26),
                    ),
                    const SizedBox(width: 12),
                    // 标题
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '最近阅读',
                            style: TextStyle(
                              color: AppPalette.p.textSec,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _displayTitle(title, filePath: _lastReadFilePath),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isRead ? const Color(0xFFcf9e66) : AppPalette.p.text,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 继续阅读按钮
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _openLastRead,
                      child: Container(
                        padding: isPlain
                            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 5)
                            : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isPlain
                              ? accentColor.withValues(alpha: 0.12)
                              : accentColor,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '继续阅读',
                              style: TextStyle(
                                color: isPlain ? accentColor : Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(Icons.arrow_forward,
                                color: isPlain ? accentColor : Colors.white, size: 12),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 进度条
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: _lastReadProgress.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: accentColor.withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                  ),
                ),
                const SizedBox(height: 6),
                // 元信息（左侧）和进度百分比（右侧）
                Row(
                  children: [
                    if (meta.isNotEmpty)
                      Expanded(
                        child: Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppPalette.p.textSec,
                            fontSize: 12,
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    Text(
                      '已读 ${pct.toStringAsFixed(1)}%',
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openLastRead() {
    final title = _lastReadTitle;
    if (title == null) return;
    openRecentSutra(title, _lastReadFilePath);
  }

  /// 打开一部经书：优先走本地列表（保持已读/收藏等状态），否则直接进入阅读页。
  void openRecentSutra(String title, String? filePath) {
    _dismissKeyboard();
    final sutra = _findSutra(title);
    if (sutra != null) {
      _openSutra(sutra);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ReadingPage(title: title, filePath: filePath),
        ),
      );
    }
  }

  Widget _buildSearchBar() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.p.borderSoft, width: 0.8),
      ),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          hintText: '搜索经文 · 支持书名与部类',
          hintStyle: const TextStyle(color: Color(0xFFB8B8B8), fontSize: 13),
          prefixIcon: const Padding(
            padding: EdgeInsets.only(left: 8, right: 4),
            child: Icon(Icons.search, color: Color(0xFF616161), size: 18),
          ),
          suffixIcon: GestureDetector(
            onTap: _exitSearch,
            child: const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.close, color: Color(0xFFB8B8B8), size: 18),
            ),
          ),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        style: const TextStyle(color: Color(0xFF212121), fontSize: 14),
        onSubmitted: (_) => _dismissKeyboard(),
      ),
    );
  }

  /// 搜索入口栏：横跨标题下方全部空间，圆角搜索框样式。
  Widget _buildSearchEntryField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: AppPalette.p.bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: activateSearch,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppPalette.p.border, width: 0.8),
            ),
            child: Row(
              children: [
                Icon(Icons.search, color: AppPalette.p.textHint, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '搜索经文',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppPalette.p.textHint,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressCard() {
    final total = _allSutras.length;
    final read = _allSutras.where((s) => s.isRead).length;
    final totalChars = _allSutras.fold<int>(0, (sum, s) => sum + s.charCount);
    final readChars = _allSutras.where((s) => s.isRead).fold<int>(0, (sum, s) => sum + s.charCount);
    final pct = total == 0 ? 0.0 : read / total * 100;
    if (pct >= 100) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _maybeShowCompletionDialog(),
      );
    }
    const milestones = [25, 50, 75, 100];
    final isPlain = AppPalette.instance.isPlain;
    final accentColor = AppPalette.p.readingAccent;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: AppPalette.p.card,
        borderRadius: BorderRadius.circular(12),
        border: isPlain
            ? null
            : Border.all(color: AppPalette.p.borderSoft, width: 0.8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_stories, color: accentColor, size: 18),
              const SizedBox(width: 6),
              Text('阅读进度',
                  style: TextStyle(
                      color: AppPalette.p.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                '${pct.toStringAsFixed(2)}%',
                style: TextStyle(
                  color: accentColor,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              return SizedBox(
                width: constraints.maxWidth,
                height: 6,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    if (pct >= 1)
                      FractionallySizedBox(
                        widthFactor: pct / 100,
                        child: Container(
                          height: 6,
                          decoration: BoxDecoration(
                            color: accentColor,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    // 25%/50%/75% 竖杠刻度
                    for (final m in [25, 50, 75])
                      Positioned(
                        left: constraints.maxWidth * m / 100 - 0.75,
                        top: 0,
                        bottom: 0,
                        child: Container(
                          width: 1.5,
                          color: accentColor.withValues(alpha: 0.45),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              return SizedBox(
                width: constraints.maxWidth,
                height: 16,
                child: ClipRect(
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        top: 1,
                        child: Text(
                          '0%',
                          style: TextStyle(
                            color: AppPalette.p.textHint,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      for (final m in milestones)
                        if (m == 100)
                          Positioned(
                            right: 0,
                            top: 1,
                            child: Text(
                              '100%',
                              style: TextStyle(
                                color: pct >= m ? accentColor : AppPalette.p.textHint,
                                fontSize: 11,
                                fontWeight: pct >= m
                                    ? FontWeight.w700
                                    : FontWeight.normal,
                              ),
                            ),
                          )
                        else
                          Positioned(
                            left: constraints.maxWidth * m / 100,
                            top: 1,
                            child: FractionalTranslation(
                              translation: const Offset(-0.5, 0),
                              child: Text(
                                '$m%',
                                style: TextStyle(
                                  color: pct >= m ? accentColor : AppPalette.p.textHint,
                                  fontSize: 11,
                                  fontWeight: pct >= m
                                      ? FontWeight.w700
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '已完成 $read / $total 册',
                style: TextStyle(color: AppPalette.p.textSec, fontSize: 12),
              ),
              const Spacer(),
              Text(
                '已阅读 ${_formatCharCount(readChars)} / ${_formatCharCount(totalChars)}',
                style: TextStyle(color: AppPalette.p.textSec, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 从目录补充 charCount（本地持久化文件可能不含此字段）。
  Future<void> _enrichCharCounts() async {
    try {
      final raw = await rootBundle.loadString('assets/sutras_catalog.json');
      final decoded = jsonDecode(raw) as List<dynamic>;
      final map = <String, int>{};
      for (final e in decoded) {
        final m = e as Map<String, dynamic>;
        map[m['t'] as String] = m['c'] as int? ?? 0;
      }
      var changed = false;
      for (var i = 0; i < _allSutras.length; i++) {
        final s = _allSutras[i];
        final cc = map[s.title];
        if (cc != null && cc != s.charCount) {
          _allSutras[i] = Sutra(s.title, s.size,
              charCount: cc, isPinned: s.isPinned, isRead: s.isRead,
              isFavorite: s.isFavorite, isReadLater: s.isReadLater,
              filePath: s.filePath, folder: s.folder,
              favoriteTime: s.favoriteTime, readTime: s.readTime,
              readLaterTime: s.readLaterTime);
          changed = true;
        }
      }
      if (changed && mounted) setState(() {});
    } catch (_) {}
  }

  /// 格式化字数为万字单位，如 12345 → "1.23万字"，800 → "0.08万字"，50 → "0万字"。
  String _formatCharCount(int chars) {
    final wan = chars / 10000;
    if (wan >= 10) return '${wan.toStringAsFixed(0)}万字';
    if (wan >= 1) return '${wan.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')}万字';
    if (wan >= 0.01) return '${wan.toStringAsFixed(2)}万字';
    return '0万字';
  }

  bool _completionDialogShown = false;

  /// 阅藏进度达到 100% 时，在页面中间弹出一次「阅藏圆满」庆祝弹窗（终生仅一次）。
  Future<void> _maybeShowCompletionDialog() async {
    if (_completionDialogShown) return;
    _completionDialogShown = true;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('sutra_reading_complete_shown') ?? false) return;
    await prefs.setBool('sutra_reading_complete_shown', true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppPalette.p.primary, Color(0xFF7a5c4e)],
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.emoji_events_rounded,
                  color: AppPalette.p.accent, size: 56),
              const SizedBox(height: 12),
              const Text(
                '阅藏圆满',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '功德无量',
                style: TextStyle(
                  color: AppPalette.p.accent,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '你已读完所有经文，随喜赞叹！',
                style: TextStyle(color: Color(0xFFE8D9C4), fontSize: 13),
              ),
              const SizedBox(height: 18),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppPalette.p.accent,
                  foregroundColor: AppPalette.p.primary,
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  '随喜赞叹',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickAccessRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: _buildQuickAccessTile(
              icon: Icons.people_outline,
              title: '大家都在学',
              onTap: () {
                _dismissKeyboard();
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => PopularSutrasPage(parent: this)),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildQuickAccessTile(
              icon: Icons.leaderboard_outlined,
              title: '热门榜单',
              onTap: () {
                _dismissKeyboard();
                _openHotDiscussionList();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildQuickAccessTile(
              icon: Icons.favorite_border,
              title: '我的收藏',
              iconImage: 'assets/images/like.png',
              onTap: () {
                _dismissKeyboard();
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => FavoriteSutrasPage(parent: this)),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildQuickAccessTile(
              icon: Icons.bookmark_border,
              title: '稍后阅读',
              onTap: widget.onOpenReadingHistory,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openHotDiscussionList() async {
    try {
      await NoteSutraCatalog.load();
      final (_, sutras) = await CloudNotesService.instance.getHotDiscussions();
      final titleMap = NoteSutraCatalog.cachedTitleMap ?? const {};
      final validSutras = mergeHotSutraItems(sutras,
              catalogNames: titleMap.keys.toSet())
          .where((s) => titleMap.containsKey(s.name))
          .toList()
        ..sort((a, b) => b.posts.compareTo(a.posts));
      final displayNames =
          await buildSutraDisplayNameMap(validSutras, isSutra: true);
      final subtitles = <String, String>{};
      for (final it in validSutras) {
        final link = titleMap[it.name];
        if (link == null) continue;
        final parts = <String>[];
        final dept = link.folder.replaceAll(RegExp(r'^T\d+'), '').trim();
        if (dept.isNotEmpty) parts.add(dept);
        final vols = NoteSutraCatalog.cachedVolumeCount(it.name);
        if (vols > 1) parts.add('共$vols卷');
        // 全书总字数（多卷经书为各卷之和），如「大集部 · 共2卷 · 12345字」。
        final chars = NoteSutraCatalog.cachedCharCount(it.name);
        if (chars > 0) parts.add('$chars字');
        if (parts.isNotEmpty) subtitles[it.name] = parts.join(' · ');
      }
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => HotRankingPage(
            items: validSutras,
            displayNames: displayNames,
            subtitles: subtitles,
          ),
        ),
      );
    } catch (_) {}
  }

  Widget _buildQuickAccessTile({
    required IconData icon,
    required String title,
    required VoidCallback? onTap,
    String? iconImage,
  }) {
    final accentColor = AppPalette.p.readingAccent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: iconImage != null
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: Image.asset(
                        iconImage,
                        color: accentColor,
                        width: 24,
                        height: 24,
                      ),
                    )
                  : Icon(icon, color: accentColor, size: 24),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                color: AppPalette.p.text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickGrid() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              AppPalette.instance.isPlain ? 20 : 14, 24, 14, 12),
          child: Row(
            children: [
              Icon(
                Icons.grid_view_rounded,
                color: AppPalette.instance.isPlain
                    ? const Color(0xFF1A1A1A)
                    : const Color(0xFFba8e82),
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(
                '经典入口',
                style: TextStyle(
                  color: AppPalette.p.primary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            height: 132,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _buildRecentTile()),
                      const SizedBox(height: 10),
                      Expanded(child: _buildFavoriteTile()),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: _buildRandomTile()),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(child: _buildAllSutrasBar()),
              const SizedBox(width: 8),
              _buildChangeFolderButton(),
            ],
          ),
        ),
        if (_randomFolder != null) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _buildRandomFolderSection(),
          ),
        ],
      ],
    );
  }

  Widget _buildFavoriteTile() {
    return Material(
      color: AppPalette.p.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _dismissKeyboard();
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => FavoriteSutrasPage(parent: this)),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: AppPalette.instance.isPlain
                ? null
                : Border.all(color: AppPalette.p.borderSoft, width: 0.8),
          ),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: AppPalette.p.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(Icons.star_rounded, size: 14, color: AppPalette.p.accent),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '我的收藏',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppPalette.p.primary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: AppPalette.p.textHint, size: 14),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentTile() {
    return Material(
      color: AppPalette.p.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _dismissKeyboard();
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => PopularSutrasPage(parent: this)),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: AppPalette.instance.isPlain
                ? null
                : Border.all(color: AppPalette.p.borderSoft, width: 0.8),
          ),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: AppPalette.p.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(Icons.trending_up_rounded, size: 14, color: AppPalette.p.accent),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '大家都在学',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppPalette.p.primary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: AppPalette.p.textHint, size: 14),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRandomTile() {
    var sutra = _randomSutra;
    if (sutra != null) {
      final st = sutra;
      final idx = _allSutras.indexWhere((s) => s.title == st.title);
      if (idx >= 0) sutra = _allSutras[idx];
    }
    final folderName = sutra != null
        ? (_folderDisplayNames[sutra.folder] ?? sutra.folder)
        : null;
    final info = [
      if (folderName != null && folderName.isNotEmpty) folderName,
      if (sutra?.size != null && sutra!.size.isNotEmpty) sutra.size,
    ].join(' · ');
    return Material(
      color: AppPalette.p.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _dismissKeyboard();
          if (_randomSutra != null) _openSutra(_randomSutra!);
        },
        onLongPress: () {
          _dismissKeyboard();
          final s = _randomSutra;
          if (s != null) _showBottomSheet(context, s);
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: AppPalette.instance.isPlain
                ? null
                : Border.all(color: AppPalette.p.borderSoft, width: 0.8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: const Color(0xFF71867A).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Icon(
                      Icons.casino_rounded,
                      size: 14,
                      color: AppPalette.instance.isPlain
                          ? const Color(0xFF1A1A1A)
                          : const Color(0xFF71867A),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '随缘读经',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppPalette.p.primary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      setState(() {
                        _randomSutra = _rollRandomSutra();
                      });
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.autorenew, color: Color(0xFF71867A), size: 13),
                          SizedBox(width: 2),
                          Text(
                            '换一本',
                            style: TextStyle(
                              color: Color(0xFF71867A),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                sutra != null ? _displayTitle(sutra.title) : '随机一部经书',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: sutra != null && sutra.isRead
                      ? const Color(0xFFcf9e66)
                      : AppPalette.p.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
              if (info.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  info,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppPalette.p.textSec,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                  ),
                ),
              ],
              const Spacer(),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (sutra != null) _buildRandomDownloadIndicator(sutra),
                    const SizedBox(width: 6),
                    Text(
                      '开始阅读 →',
                      style: TextStyle(
                        color: AppPalette.instance.isPlain
                            ? const Color(0xFF1A1A1A)
                            : const Color(0xFFE5A12E),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChangeFolderButton() {
    return Material(
      color: AppPalette.p.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _dismissKeyboard();
          setState(() {
            _randomFolder = _rollRandomFolder();
          });
        },
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: AppPalette.instance.isPlain
                ? null
                : Border.all(color: AppPalette.p.borderSoft, width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.autorenew, color: Color(0xFF71867A), size: 14),
              const SizedBox(width: 3),
              const Text(
                '换一部',
                style: TextStyle(
                  color: Color(0xFF71867A),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRandomDownloadIndicator(Sutra sutra) {
    final id = SutraDownloader.extractId(sutra.title, sutra.filePath);
    if (id == null) return const SizedBox.shrink();
    final p = _downloadProgress[id];
    if (p != null && p < 1.0) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          value: p > 0 ? p : null,
          strokeWidth: 2,
          color: const Color(0xFF71867A),
        ),
      );
    }
    if (_downloadedIds.contains(id)) {
      return const Icon(Icons.download_done_rounded, size: 14, color: Color(0xFF71867A));
    }
    return const SizedBox.shrink();
  }

  /// 全部经典通栏窄条：点击展开全部部类浏览。
  Widget _buildAllSutrasBar() {
    final accentColor = AppPalette.p.readingAccent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: AppPalette.p.card,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  _dismissKeyboard();
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => AllSutrasPage(parent: this)),
                  );
                },
                child: Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: AppPalette.instance.isPlain
                        ? null
                        : Border.all(color: AppPalette.p.borderSoft, width: 0.8),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: accentColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.menu_book_rounded, size: 16, color: accentColor),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '全部经典',
                          style: TextStyle(
                            color: AppPalette.p.primary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        '${_folders.length} 个部类',
                        style: const TextStyle(color: Color(0xFF999999), fontSize: 11),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, color: AppPalette.p.textHint, size: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: AppPalette.p.card,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                _dismissKeyboard();
                setState(() {
                  _randomFolder = _rollRandomFolder();
                });
              },
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: AppPalette.instance.isPlain
                      ? null
                      : Border.all(color: AppPalette.p.borderSoft, width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.autorenew, color: Color(0xFF71867A), size: 14),
                    const SizedBox(width: 3),
                    const Text(
                      '换一部',
                      style: TextStyle(
                        color: Color(0xFF71867A),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 随机选中部类的全部经书列表：展示在该部类下全部经书，供逐一阅读。
  Widget _buildRandomFolderSection() {
    final folder = _randomFolder;
    if (folder == null) return const SizedBox.shrink();
    final sutras = _getAllSutrasInFolder(folder);
    final name = _folderDisplayNames[folder] ?? folder;
    return Container(
      key: _randomFolderKey,
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      decoration: BoxDecoration(
        color: AppPalette.p.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppPalette.p.primary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '共 ${sutras.length} 册',
                  style: const TextStyle(color: Color(0xFF999999), fontSize: 11),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 0.6, color: AppPalette.p.borderSoft),
          if (sutras.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  '暂无内容',
                  style: TextStyle(color: Color(0xFF999999), fontSize: 12),
                ),
              ),
            )
          else
            ...sutras.map((s) => _buildSutraTile(context, s)),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildRandomSection() {
    var sutra = _randomSutra;
    if (sutra != null) {
      final st = sutra;
      final idx = _allSutras.indexWhere((s) => s.title == st.title);
      if (idx >= 0) sutra = _allSutras[idx];
    }
    final folderName = sutra != null
        ? (_folderDisplayNames[sutra.folder] ?? sutra.folder)
        : null;
    final info = [
      if (folderName != null && folderName.isNotEmpty) folderName,
      if (sutra != null && sutra.charCount > 0) '${sutra.charCount} 字',
    ].join(' · ');
    final isPlain = AppPalette.instance.isPlain;
    final accentColor = AppPalette.p.readingAccent;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Material(
        color: AppPalette.p.card,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            _dismissKeyboard();
            if (_randomSutra != null) _openSutra(_randomSutra!);
          },
          onLongPress: () {
            _dismissKeyboard();
            final s = _randomSutra;
            if (s != null) _showBottomSheet(context, s);
          },
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: isPlain
                  ? null
                  : Border.all(color: AppPalette.p.borderSoft, width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Image.asset(
                      'assets/images/leaf-sharp.png',
                      width: 18,
                      height: 18,
                      color: accentColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '随缘读经',
                        style: TextStyle(
                          color: AppPalette.p.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _randomSutra = _rollRandomSutra();
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.autorenew, color: accentColor, size: 14),
                            const SizedBox(width: 2),
                            Text(
                              '换一册',
                              style: TextStyle(
                                color: accentColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '随机选择，一切皆是因缘',
                    style: TextStyle(
                      color: AppPalette.p.textHint,
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  sutra != null ? _displayTitle(sutra.title) : '随机一部经典',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: sutra != null && sutra.isRead
                        ? const Color(0xFFcf9e66)
                        : AppPalette.p.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                  ),
                ),
                if (info.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    info,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppPalette.p.textSec,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (sutra != null) _buildRandomDownloadIndicator(sutra),
                      const SizedBox(width: 6),
                      Container(
                        padding: isPlain
                            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 5)
                            : const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: isPlain
                              ? accentColor.withValues(alpha: 0.12)
                              : accentColor,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '开始阅读',
                              style: TextStyle(
                                color: isPlain ? accentColor : Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(Icons.arrow_forward,
                                color: isPlain ? accentColor : Colors.white, size: 12),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFolderCard(String folder) {
    final list = _getAllSutrasInFolder(folder);
    final total = list.length;
    final read = list.where((s) => s.isRead).length;
    final pct = total == 0 ? 0.0 : read / total * 100;
    final name = _folderDisplayNames[folder] ?? folder;
    // 全部经典页部类卡：素白外观强调色改为 5d7c5a，米黄外观保持原样。
    final isPlain = AppPalette.instance.isPlain;
    final folderAccent =
        isPlain ? const Color(0xFF5d7c5a) : AppPalette.p.accent;
    return Material(
      color: AppPalette.p.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _dismissKeyboard();
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SutraFolderPage(
                parent: this,
                folderName: folder,
                displayName: name,
              ),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: AppPalette.instance.isPlain
                ? null
                : Border.all(color: AppPalette.p.borderSoft, width: 0.8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.menu_book,
                    color: isPlain
                        ? const Color(0xFF5d7c5a)
                        : const Color(0xFFba8e82),
                    size: 15,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppPalette.p.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '已读 ${pct.toStringAsFixed(0)}%',
                    style: TextStyle(
                      color: folderAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: total == 0 ? 0 : read / total,
                  minHeight: 8,
                  backgroundColor: isPlain
                      ? folderAccent.withValues(alpha: 0.12)
                      : AppPalette.p.tintBg,
                  color: folderAccent,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '共 $total 册 · 已阅 $read 册',
                style: TextStyle(color: AppPalette.p.textSec, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_searchController.text.trim().isEmpty) {
      return const Center(
        child: Text(
          '输入书名或部类，开始搜索经文',
          style: TextStyle(color: Color(0xFF999999), fontSize: 13),
        ),
      );
    }
    if (_filteredSutras.isEmpty) {
      return const Center(
        child: Text('未找到相关经文', style: TextStyle(color: Color(0xFF999999), fontSize: 13)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 40),
      itemCount: _filteredSutras.length,
      itemBuilder: (ctx, i) => _buildSutraTile(ctx, _filteredSutras[i], showFolder: true),
    );
  }

  Widget _buildSutraTile(BuildContext ctx, Sutra sutra, {bool showFolder = false}) {
    final folderName = _folderDisplayNames[sutra.folder] ?? sutra.folder;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: AppPalette.p.card,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        dense: true,
        minVerticalPadding: 4,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        title: Text(
          _displayTitle(sutra.title),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: sutra.isRead ? const Color(0xFFcf9e66) : AppPalette.p.primary,
            fontSize: 14.5,
            fontWeight: sutra.isRead ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        subtitle: showFolder && folderName != null
            ? Text(folderName, style: const TextStyle(color: Color(0xFF999999), fontSize: 11))
            : null,
        trailing: _buildDownloadTrailing(sutra),
        onTap: () => _openSutra(sutra),
        onLongPress: () => _showBottomSheet(ctx, sutra),
      ),
    );
  }

  Widget _buildFolder({
    required String title,
    required List<Sutra> sutras,
    required bool isExpanded,
    required VoidCallback onToggle,
    required IconData icon,
    required bool showPin,
  }) {
    return Column(
      children: [
        GestureDetector(
          onTap: onToggle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: const Color(0xFFcec6c3),
            child: Row(
              children: [
                Icon(icon, color: AppPalette.p.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  '$title (${sutras.length})',
                  style: TextStyle(
                    color: AppPalette.p.primary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Icon(
                  isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  color: const Color(0xFF999999),
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        if (isExpanded && sutras.isNotEmpty)
          Container(
            padding: const EdgeInsets.only(left: 8, right: 8, top: 0, bottom: 20),
            child: Column(
              children: sutras.map((sutra) {
                return Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  height: 38,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Center(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                      minVerticalPadding: 0,
                      dense: true,
                      title: Text(
                        sutra.title,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.2,
                          color: sutra.isRead
                              ? const Color(0xFFcf9e66)
                              : const Color(0xFF616161),
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      onTap: () {
                        _openSutra(sutra);
                      },
                      onLongPress: () => _showBottomSheet(context, sutra, showPin: showPin),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        if (isExpanded && sutras.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text(
                '暂无内容',
                style: TextStyle(
                  color: const Color(0xFF999999),
                  fontSize: 12,
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final drawerWidth = MediaQuery.of(context).size.width * 0.82;
    return Stack(
      children: [
        Scaffold(
          backgroundColor: AppPalette.p.bg,
          appBar: AppBar(
            backgroundColor: AppPalette.p.bg,
            elevation: 0,
            shadowColor: Colors.transparent,
            iconTheme: const IconThemeData(color: Color(0xFF212121)),
            title: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () {
                if (_scrollController.hasClients) {
                  _scrollController.animateTo(
                    0,
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                  );
                }
              },
              child: Row(
              children: [
                Text(
                  _searchActive ? '搜索' : '经藏',
                  style: TextStyle(
                    color: AppPalette.p.primary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  '·',
                  style: TextStyle(
                    color: Color(0xFF9E9588),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _searchActive ? '谛听，谛听，善思念之。' : '诸行无常，一切皆苦；诸法无我，寂灭为乐。',
                    style: const TextStyle(
                      color: Color(0xFF9E9588),
                      fontSize: 12,
                    ),
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              ),
            ),
            actions: [
              // 搜索激活时隐藏右上角「助手」入口。
              if (!_searchActive)
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: IconButton(
                    tooltip: '助手',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Image.asset(
                      AppPalette.instance.isPlain
                          ? 'assets/images/assistant.png'
                          : 'assets/images/assistant000.png',
                      width: 18,
                      height: 18,
                    ),
                    onPressed: widget.onOpenAssistant,
                  ),
                ),
            ],
          ),
          body: Column(
            children: [
              if (_searchActive) _buildSearchBar(),
              Expanded(
                child: _searchActive
                    ? _buildSearchResults()
                    : SingleChildScrollView(
                        controller: _scrollController,
                        padding: const EdgeInsets.only(bottom: 40),
                        child: Column(
                          children: [
                            _buildSearchEntryField(),
                            _buildProgressCard(),
                            _buildContinueReadingCard(),
                            if (AppPalette.instance.isPlain) ...[
                              _buildQuickAccessRow(),
                              _buildRandomSection(),
                              _buildAllSutrasBar(),
                              if (_randomFolder != null) ...[
                                _buildRandomFolderSection(),
                              ],
                            ] else ...[
                              _buildQuickGrid(),
                            ],
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
        // 「回到经部」浮动按钮：随机经部上方内容全部滚出视口后显示。
        if (_showScrollToFolderButton && !_searchActive && !_drawerOpen)
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 16,
            right: 16,
            child: _buildScrollToFolderButton(),
          ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_drawerOpen,
            child: FadeTransition(
              opacity: _overlayOpacity,
              child: GestureDetector(
                onTap: _closeDrawer,
                child: const ColoredBox(color: Colors.black38),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          width: drawerWidth,
          child: SlideTransition(
            position: _drawerSlide,
            child: _buildDrawerPanel(),
          ),
        ),
      ],
    );
  }

  void _toggleDrawer() {
    if (_drawerOpen) {
      _closeDrawer();
    } else {
      _openDrawer();
    }
  }

  void _openDrawer() {
    exitSearchIfActive();
    setState(() {
      _drawerOpen = true;
    });
    _drawerController.forward();
  }

  void _closeDrawer() {
    FocusScope.of(context).unfocus();
    _drawerController.reverse();
    setState(() {
      _drawerOpen = false;
      _isReadExpanded = false;
    });
  }

  Widget _buildDrawerPanel() {
    return Material(
      color: Colors.white,
      elevation: 16,
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Text(
                    '经藏',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppPalette.p.primary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF616161), size: 20),
                    tooltip: '关闭',
                    onPressed: _closeDrawer,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _buildFolder(
                    title: '已阅经文',
                    sutras: _getReadSutras(),
                    isExpanded: _isReadExpanded,
                    onToggle: () {
                      setState(() {
                        _isReadExpanded = !_isReadExpanded;
                      });
                    },
                    icon: Icons.check_circle,
                    showPin: false,
                  ),
                  _buildFolder(
                    title: '我的收藏',
                    sutras: _getFavoriteSutras(),
                    isExpanded: _isFavoriteExpanded,
                    onToggle: () {
                      setState(() {
                        _isFavoriteExpanded = !_isFavoriteExpanded;
                      });
                    },
                    icon: Icons.star,
                    showPin: true,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(Icons.upload_file, color: AppPalette.p.primary, size: 20),
                    title: Text(
                      '导入经书（TXT）',
                      style: TextStyle(
                        color: AppPalette.p.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    onTap: () {
                      _closeDrawer();
                      _pickFile();
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.error_outline, color: AppPalette.p.primary, size: 20),
                    title: Text(
                      '缺失经文',
                      style: TextStyle(
                        color: AppPalette.p.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    onTap: () {
                      _closeDrawer();
                      if (!_missingComputed || _missingSutraTitles.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('暂无缺失经文')),
                        );
                        return;
                      }
                      _showMissingSutrasSheet();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分部详情页：展示某一部类下的全部经书与阅读进度。
class SutraFolderPage extends StatefulWidget {
  final SutraListPageState parent;
  final String folderName;
  final String displayName;

  const SutraFolderPage({
    super.key,
    required this.parent,
    required this.folderName,
    required this.displayName,
  });

  @override
  State<SutraFolderPage> createState() => _SutraFolderPageState();
}

class _SutraFolderPageState extends State<SutraFolderPage> {
  List<Sutra> get _sutras =>
      widget.parent._getAllSutrasInFolder(widget.folderName);

  @override
  void initState() {
    super.initState();
    widget.parent._sutraDataVersion.addListener(_onParentChanged);
  }

  @override
  void dispose() {
    widget.parent._sutraDataVersion.removeListener(_onParentChanged);
    super.dispose();
  }

  void _onParentChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final total = _sutras.length;
    final read = _sutras.where((s) => s.isRead).length;
    final downloading = widget.parent._folderDownloadTotal[widget.folderName] != null;
    final isPlain = AppPalette.instance.isPlain;
    return Scaffold(
      backgroundColor: AppPalette.p.bg,
      appBar: AppBar(
        backgroundColor: AppPalette.p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: IconThemeData(color: AppPalette.p.primary),
        actionsPadding: const EdgeInsets.only(right: 24),
        title: Row(
          children: [
            Flexible(
              child: Text(
                widget.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppPalette.p.primary,
                  fontSize: 16.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '已读 $read/$total 册',
              style: TextStyle(
                color: isPlain
                    ? const Color(0xFF5d7c5a)
                    : const Color(0xFFba8e82),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        actions: [
          if (downloading)
            Center(
              child: Text(
                '${widget.parent._folderDownloadDone[widget.folderName] ?? 0}/${widget.parent._folderDownloadTotal[widget.folderName]}',
                style: const TextStyle(
                  color: Color(0xFFba8e82),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            SizedBox(
              width: 34,
              height: 30,
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: 17,
                tooltip: '下载本卷全部经文',
                icon: const Icon(Icons.download_for_offline_outlined, color: Color(0xFF71867A)),
                onPressed: () => widget.parent._downloadFolder(widget.folderName),
              ),
            ),
        ],
      ),
      body: total == 0
          ? const Center(
              child: Text('暂无经文', style: TextStyle(color: Color(0xFF999999), fontSize: 13)),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: total,
              itemBuilder: (ctx, i) => widget.parent._buildSutraTile(ctx, _sutras[i]),
            ),
    );
  }
}

/// 全部经典页：按部类浏览全部经书。
class AllSutrasPage extends StatefulWidget {
  final SutraListPageState parent;

  const AllSutrasPage({super.key, required this.parent});

  @override
  State<AllSutrasPage> createState() => _AllSutrasPageState();
}

class _AllSutrasPageState extends State<AllSutrasPage> {
  @override
  void initState() {
    super.initState();
    widget.parent._sutraDataVersion.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.parent._sutraDataVersion.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final folders = widget.parent._folders;
    final isPlain = AppPalette.instance.isPlain;
    return Scaffold(
      backgroundColor: AppPalette.p.bg,
      appBar: AppBar(
        backgroundColor: AppPalette.p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: IconThemeData(color: AppPalette.p.primary),
        title: Row(
          children: [
            Text(
              '全部经典',
              style: TextStyle(
                color: AppPalette.p.primary,
                fontSize: 16.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${folders.length} 个部类',
              style: TextStyle(
                color: isPlain
                    ? const Color(0xFF5d7c5a)
                    : const Color(0xFFba8e82),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.6,
        ),
        itemCount: folders.length,
        itemBuilder: (ctx, i) => widget.parent._buildFolderCard(folders[i]),
      ),
    );
  }
}
