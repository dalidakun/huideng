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

  /// 本会话内每个键最近确认过的内容/经名，用于免去重复的整篇 jsonDecode。
  /// 每份草稿是整篇经文（几十万字），原先每次自动保存都要读回并 jsonDecode
  /// 一遍再比较，是编辑页打字/保存时掉帧的来源之一。
  static final Map<String, _DraftMemo> _memos = {};

  /// 记忆有效期：只用来挡「短时间内重复写同一份内容」，过期后仍按原逻辑
  /// 读盘比对，避免别的设备/云同步写过之后被记忆误判成「已保存」。
  static const int _memoTtlMs = 15000;

  /// 记忆条数上限：每条都持有一份整篇经文的引用，只留最近几条。
  static const int _memoMaxEntries = 3;

  static void _remember(String key, String content, String title, int at) {
    _memos.remove(key);
    _memos[key] = _DraftMemo(content, title, at);
    while (_memos.length > _memoMaxEntries) {
      _memos.remove(_memos.keys.first);
    }
  }

  /// 草稿键名：优先取经书 ID（跨设备、跨安装稳定）；取不到 ID 时
  /// 退回规范化路径（仅本机有效，至少保证本机重装前的读写一致）。
  static String keyFor({String? title, required String filePath}) {
    final id = SutraDownloader.extractId(title, filePath);
    if (id != null && id.isNotEmpty) return '$_prefix$id';
    final sanitized = filePath.replaceAll(RegExp(r'[\\/:*?"<>|.]'), '_');
    return '$_prefix$sanitized';
  }

  /// 写入草稿。内容与上次一致时不写，避免每次打开经书都触发一次云同步推送。
  /// [displayTitle] 为管理员订正的经名（可选），随草稿备份。
  static Future<void> save({
    String? title,
    required String filePath,
    required String content,
    String? displayTitle,
  }) async {
    if (content.isEmpty) return;
    final key = keyFor(title: title, filePath: filePath);
    final cleanTitle = (displayTitle ?? '').trim();
    final now = DateTime.now().millisecondsSinceEpoch;

    final memo = _memos[key];
    final memoValid = memo != null && now - memo.at < _memoTtlMs;
    if (memoValid) {
      if (memo.content == content && memo.title == cleanTitle) return;
      // 本会话刚写过、内容确实变了：直接覆盖，不必读回整篇经文做比较。
      final prefs = await SharedPreferences.getInstance();
      await _write(prefs, key, content, cleanTitle, now);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(key);
    if (existing != null) {
      try {
        final decoded = jsonDecode(existing);
        if (decoded is Map &&
            decoded['content'] == content &&
            (decoded['displayTitle'] ?? '') == cleanTitle) {
          _remember(key, content, cleanTitle, now);
          return;
        }
      } catch (_) {
        // 旧值损坏：直接覆盖。
      }
    }
    await _write(prefs, key, content, cleanTitle, now);
  }

  static Future<void> _write(SharedPreferences prefs, String key,
      String content, String cleanTitle, int now) async {
    await prefs.setString(
        key,
        jsonEncode({
          'savedAt': now,
          'content': content,
          if (cleanTitle.isNotEmpty) 'displayTitle': cleanTitle,
        }));
    _remember(key, content, cleanTitle, now);
  }

  /// 读取草稿；不存在或损坏返回 null。
  static Future<SutraEditDraftData?> read({
    String? title,
    required String filePath,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = keyFor(title: title, filePath: filePath);
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final content = decoded['content'];
      if (content is! String || content.isEmpty) return null;
      final savedAt = decoded['savedAt'];
      final dt = decoded['displayTitle'];
      final displayTitle = dt is String ? dt : null;
      // 读到的就是磁盘现状，顺手记下来，随后紧跟的 save 可免一次整篇解码。
      _remember(key, content, (displayTitle ?? '').trim(),
          DateTime.now().millisecondsSinceEpoch);
      return SutraEditDraftData(
        content: content,
        savedAt: savedAt is num ? savedAt.toInt() : 0,
        displayTitle: displayTitle,
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
  final String? displayTitle;

  const SutraEditDraftData({
    required this.content,
    required this.savedAt,
    this.displayTitle,
  });
}

/// 本会话内已确认过的草稿内容（用于跳过重复的整篇 jsonDecode 比对）。
class _DraftMemo {
  final String content;
  final String title;

  /// 确认时间（毫秒），超过 [SutraEditDraft._memoTtlMs] 后失效。
  final int at;

  const _DraftMemo(this.content, this.title, this.at);
}
