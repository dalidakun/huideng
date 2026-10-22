import 'package:shared_preferences/shared_preferences.dart';

import 'sutra_downloader.dart';

/// 最近阅读记录（prefs 键 `recent_sutras`）的读写与去重。
///
/// 存储格式：`经名|||正文路径[|||时间戳]`（时间戳段为历史遗留，可缺省），
/// 列表按「新读在前」排列。
///
/// 同一部经在不同入口写入的经名写法不同（经藏目录原名「地藏菩萨本愿经T13n0412_001」、
/// 基础经名「地藏菩萨本愿经」、$引用面板的展示名「地藏菩萨本愿经卷一」），
/// 只按经名原文去重会漏掉同一部经，于是最近阅读里出现多条重复记录
/// （几天前打开过一遍、今天再打开又记一条）。这里统一按「同一部经」归一去重。

/// 最近阅读条目。
class RecentSutraEntry {
  /// 经名原文（同一部经可能有多种写法）。
  final String title;

  /// 正文路径（打包资产路径 / 本机绝对路径，可为空）。
  final String filePath;

  /// 原始存储串（写回时保持原样，不丢历史时间段）。
  final String raw;

  const RecentSutraEntry({
    required this.title,
    required this.filePath,
    required this.raw,
  });

  /// 解析一条记录；格式非法（缺经名或缺分隔符）时返回 null。
  static RecentSutraEntry? parse(String raw) {
    final i = raw.indexOf('|||');
    if (i <= 0) return null;
    final title = raw.substring(0, i);
    if (title.isEmpty) return null;
    final rest = raw.substring(i + 3);
    final j = rest.indexOf('|||');
    return RecentSutraEntry(
      title: title,
      filePath: j < 0 ? rest : rest.substring(0, j),
      raw: raw,
    );
  }
}

/// 同一部经的归一键：用于最近阅读去重。
///
/// 优先级：
///  1. CBETA 编号（正文路径或经名里的 `T13n0412_001`）：最可靠，同一部经的
///     各种经名写法、资产路径与本机绝对路径都能命中同一个编号；
///  2. 正文路径：用户自选导入的本地文件没有编号，用路径区分；
///  3. 经名原文：兜底。
String recentSutraIdentityKey(String title, {String? filePath}) {
  final t = title.trim();
  final path = (filePath ?? '').trim();
  final id = SutraDownloader.extractId(null, path.isEmpty ? null : path) ??
      SutraDownloader.extractId(t, null);
  if (id != null) return 'id:$id';
  if (path.isNotEmpty) return 'path:$path';
  return 'title:$t';
}

/// 一条记录的归一键；无法解析的条目按原始串单独成键（不会被误合并）。
String _recentEntryKey(String raw) {
  final entry = RecentSutraEntry.parse(raw);
  if (entry == null) return 'raw:$raw';
  return recentSutraIdentityKey(entry.title, filePath: entry.filePath);
}

/// 最近阅读列表去重：同一部经只保留最新的一条（列表按「新读在前」排列，
/// 保留首次出现的那条）。无法解析的条目原样保留。
List<String> dedupeRecentSutraEntries(List<String> raw) {
  final seen = <String>{};
  final out = <String>[];
  for (final e in raw) {
    if (!seen.add(_recentEntryKey(e))) continue;
    out.add(e);
  }
  return out;
}

/// 把一部经记入最近阅读：同一部经去重置顶，上限 [limit] 部。
///
/// 去重按「同一部经」判定（[recentSutraIdentityKey]），此前无论用过哪种
/// 经名写法写入过同一部经，都会被移除后重新置顶，避免出现重复条目。
Future<void> recordRecentSutra(
  SharedPreferences prefs,
  String title,
  String filePath, {
  int limit = 20,
}) async {
  final key = recentSutraIdentityKey(title, filePath: filePath);
  final raw = prefs.getStringList('recent_sutras') ?? [];
  final out = <String>[];
  for (final e in raw) {
    if (_recentEntryKey(e) == key) continue;
    out.add(e);
  }
  out.insert(0, '$title|||$filePath');
  if (out.length > limit) out.removeRange(limit, out.length);
  await prefs.setStringList('recent_sutras', out);
}
