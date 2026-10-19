import 'package:flutter/services.dart';

import 'shanzhishi_store.dart';
import 'sutra_downloader.dart';

/// 善知识「引用段落」：从经文正文里找出提到某位佛菩萨的句子。
///
/// 正文读取顺序与阅读页一致：优先用户编辑版（assets/sutras_edited/），
/// 其次打包原文，最后本地已下载副本。面板展示与编辑面板的「自动识别」
/// 共用这一份逻辑，避免两处口径不一致。
class ShanZhiShiQuotes {
  ShanZhiShiQuotes._();

  /// 读取经书正文；经名解析不到、文件读不到时返回 null。
  static Future<String?> loadSutraText(String sutra) async {
    final link = ShanZhiShiStore.resolveSutra(sutra);
    final filePath = link?.filePath ?? '';
    if (filePath.isEmpty) return null;
    if (filePath.startsWith('assets/sutras_ascii/')) {
      final rel = filePath.substring('assets/sutras_ascii/'.length);
      try {
        return await rootBundle.loadString('assets/sutras_edited/$rel');
      } catch (_) {
        // 没有编辑版就继续读原文。
      }
    }
    try {
      return await rootBundle.loadString(filePath);
    } catch (_) {
      // 打包里没有这份正文，再看本地下载副本。
    }
    try {
      final f = await SutraDownloader.localFileForAssetPath(filePath);
      if (f != null && await f.exists()) return await f.readAsString();
    } catch (_) {
      // 读取失败按「没有正文」处理。
    }
    return null;
  }

  /// 从正文中抽取提到 [name] 的段落（按行分段，去掉常见排版标记），最多 30 条。
  static List<String> extractParagraphs(String content, String name) {
    final key = name.trim();
    if (key.isEmpty) return const [];
    final out = <String>[];
    for (final raw in content.split('\n')) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      // 去常见标记：分段/遮挡/加粗/备注。
      line = line.replaceAll('。。。', '');
      line = line.replaceAll('///', '');
      line = line.replaceAll('／／／', '');
      line = line.replaceAll(RegExp(r'^[bB]{3}'), '');
      line = line.replaceAll(RegExp(r'[bB]{3}$'), '');
      line = line.replaceAll('@@', '');
      line = line.trim();
      if (line.isEmpty) continue;
      if (line.contains(key)) {
        out.add(line);
        if (out.length >= 30) break;
      }
    }
    return out;
  }

  /// 自动识别：返回某部经里提到 [name] 的段落；读不到正文时返回空列表。
  static Future<List<String>> autoParagraphs({
    required String sutra,
    required String name,
  }) async {
    try {
      final content = await loadSutraText(sutra);
      if (content == null || content.isEmpty) return const [];
      return extractParagraphs(content, name);
    } catch (_) {
      return const [];
    }
  }
}
