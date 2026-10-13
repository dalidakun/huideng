import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'sutra_downloader.dart';

/// 经文编辑版草稿：按经书 ID 存进 SharedPreferences（SyncService 全量同步上云）。
///
/// 「编辑经文」的正文原本只有本机私有目录 `edited_sutras/` 一份副本，而
/// AndroidManifest 里 `allowBackup="false"`、SyncService 也不备份该目录：
/// 卸载重装、或 debug/release 签名不同必须先卸载再装，都会把这份唯一副本
/// 清掉，用户会看到「排版过的经文又变回原版」。这里在每次保存时把正文
/// 按经书 ID 另存一份 prefs，随既有全量同步上云，重装/换包登录后自动恢复。
///
/// 云端草稿只是本机编辑副本的备份：正文展示仍以 `edited_sutras/` 文件为准，
/// 「完成排版」依旧由管理员显式点击后才对所有用户生效。
class SutraEditDraft {
  SutraEditDraft._();

  static const String _prefix = 'sutra_edit_draft_';

  /// 草稿键名：优先取经书 ID（跨设备、跨安装稳定）；取不到 ID 时
  /// 退回规范化路径（仅本机有效，至少保证本机重装前的读写一致）。
  static String keyFor({String? title, required String filePath}) {
    final id = SutraDownloader.extractId(title, filePath);
    if (id != null && id.isNotEmpty) return '$_prefix$id';
    final sanitized = filePath.replaceAll(RegExp(r'[\\/:*?"<>|.]'), '_');
    return '$_prefix$sanitized';
  }

  /// 写入草稿。内容与上次一致时不写，避免每次打开经书都触发一次云同步推送。
  static Future<void> save({
    String? title,
    required String filePath,
    required String content,
  }) async {
    if (content.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final key = keyFor(title: title, filePath: filePath);
    final existing = prefs.getString(key);
    if (existing != null) {
      try {
        final decoded = jsonDecode(existing);
        if (decoded is Map && decoded['content'] == content) return;
      } catch (_) {
        // 旧值损坏：直接覆盖。
      }
    }
    await prefs.setString(key, jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'content': content,
    }));
  }

  /// 读取草稿；不存在或损坏返回 null。
  static Future<SutraEditDraftData?> read({
    String? title,
    required String filePath,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(keyFor(title: title, filePath: filePath));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final content = decoded['content'];
      if (content is! String || content.isEmpty) return null;
      final savedAt = decoded['savedAt'];
      return SutraEditDraftData(
        content: content,
        savedAt: savedAt is num ? savedAt.toInt() : 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 一条经文编辑版草稿：正文 + 最后保存时间（毫秒时间戳）。
class SutraEditDraftData {
  final String content;
  final int savedAt;

  const SutraEditDraftData({required this.content, required this.savedAt});
}
