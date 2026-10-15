import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'note_sutra_links.dart';
import 'sutra_asset_path.dart';
import 'sutra_downloader.dart';
import 'sutra_edit_page.dart' show editedSutraFilePath;

/// 已下载经书 ID 的持久化记录键（与经藏页共用同一份）。
const String kDownloadedSutraIdsKey = 'downloaded_sutra_ids';

/// 解析经书规范 ID（如 T08n0235_001）：优先从标题/路径提取；
/// 提取不到时用经书目录按基础经名回查（例如只给了基础经名而没有路径）。
Future<String?> resolveSutraId({String? title, String? filePath}) async {
  final direct = SutraDownloader.extractId(title, filePath);
  if (direct != null && direct.isNotEmpty) return direct;
  final base = _baseTitle(title);
  if (base == null) return null;
  if (NoteSutraCatalog.cachedTitleMap == null) {
    await NoteSutraCatalog.load();
  }
  final entry = NoteSutraCatalog.cachedTitleMap?[base];
  if (entry == null) return null;
  return SutraDownloader.extractId(null, entry.filePath);
}

/// 统一的「经文是否已下载/可离线阅读」判定。
///
/// 所有入口（经藏、收藏、最近阅读、热门榜、经书讨论页…）共用这一口径，
/// 任一命中即视为已下载，避免同一部经在不同入口显示成不同的下载状态：
///   1. 本地编辑副本（云端管理员排版版下载后只落盘编辑副本，不写下载副本）；
///   2. 本地下载副本（按规范资产路径，或按经书 ID）；
///   3. 持久化的已下载 ID 记录（经藏页写入，随离线可用）。
Future<bool> isSutraDownloaded({String? title, String? filePath}) async {
  final path = filePath ?? '';
  // 1. 本地编辑副本。
  if (path.isNotEmpty) {
    try {
      final edited = File(await editedSutraFilePath(path));
      if (await edited.exists()) return true;
    } catch (_) {}
  }
  // 2. 本地下载副本。
  if (path.startsWith(SutraAssetPath.currentRoot)) {
    try {
      if (await SutraDownloader.localFileForAssetPath(path) != null) {
        return true;
      }
    } catch (_) {}
  }
  final id = await resolveSutraId(title: title, filePath: path);
  if (id == null || id.isEmpty) return false;
  try {
    if (await SutraDownloader.isDownloaded(id)) return true;
  } catch (_) {}
  // 3. 持久化的已下载记录。
  try {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(kDownloadedSutraIdsKey) ?? const [];
    return ids.contains(id);
  } catch (_) {
    return false;
  }
}

/// 把经书 ID 记入统一的已下载记录（与经藏页共用同一份），
/// 供其他入口的下载状态判定复用。写入失败不影响本次会话。
Future<void> markSutraDownloaded(String id) async {
  if (id.isEmpty) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(kDownloadedSutraIdsKey) ?? const [];
    if (ids.contains(id)) return;
    await prefs.setStringList(kDownloadedSutraIdsKey, [...ids, id]);
  } catch (_) {}
}

/// 基础经名：去掉末尾的 CBETA 编号（如「地藏菩萨本愿经T13n0412_001」->「地藏菩萨本愿经」）。
String? _baseTitle(String? title) {
  if (title == null || title.isEmpty) return null;
  final stripped =
      title.replaceAll(RegExp(r'T\d+n[0-9A-Za-z]+_\d+$'), '').trim();
  return stripped.isEmpty ? title.trim() : stripped;
}
