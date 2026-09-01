import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'note_detail_page.dart';
import 'post_rich_content.dart';
import 'reading_notes_page.dart';
import 'sutra_highlights_page.dart';
import 'sutra_paragraph_page.dart';

/// 读经笔记分享帖的解析与渲染。
///
/// 分享时 `_buildShareContent()` 生成的内容格式为：
///   $经书名
///   <空行>
///   段原文
///   <空行>
///   笔记内容
/// 三段之间用 `\n\n`（空行）分隔，便于在帖子展示时解析出
/// 经书名 / 段原文 / 笔记三个部分，以实现：
///   - $经文名 → 点击进入该经文的讨论页
///   - 段原文 → 一行高亮区块，点击进入专门的段落查看页（含 AI 翻译）
///   - 笔记内容 → 其余区域点击进入笔记详情页
class ReadingNotePost {
  final String sutraTitle;
  final String paragraph;
  final String noteText;
  // 经书 filePath（可空，用于进入讨论页）。
  final String? filePath;

  const ReadingNotePost({
    this.sutraTitle = '',
    this.paragraph = '',
    this.noteText = '',
    this.filePath,
  });

  /// 判断正文是否为读经笔记分享帖格式。
  static bool isReadingNote(String content) {
    return parse(content) != null;
  }

  /// 合法 $经名：以汉字开头、且不含句读标点 / 空格等会话痕迹，
  /// 避免把「$经名，……昨天读了……」这类讨论 / AI 互动帖误判成读经笔记分享
  /// （误判会让 AI 复制文字被当成「段原文高亮块」显示）。
  static final RegExp _titleStartRe = RegExp(r'^[\u4e00-\u9fff]');
  static final RegExp _invalidTitleRe = RegExp(r'[，。！？；：、,;:!?．\s]');

  /// 解析正文。非读经笔记格式返回 null。
  static ReadingNotePost? parse(String content) {
    if (content.isEmpty) return null;
    // 必须以 `$经书名` 开头。
    final trimmed = content.trimRight();
    final nl = trimmed.indexOf('\n');
    if (nl < 0) return null;
    final firstLine = trimmed.substring(0, nl).trim();
    if (!firstLine.startsWith(r'$')) return null;
    final sutraTitle = firstLine.substring(1).trim();
    // 严格校验 $经名：以汉字开头且无会话标点/空格，才当作读经笔记分享。
    if (sutraTitle.isEmpty ||
        !_titleStartRe.hasMatch(sutraTitle) ||
        _invalidTitleRe.hasMatch(sutraTitle)) {
      return null;
    }
    // 两个分享入口用空行区分：
    // - 读经想法（ReadingNoteEditPage）：`$经名\n\n段原文\n\n笔记`（空行分隔）
    // - 普通笔记（主页新建 NoteEditPage）：`$经名\n笔记`（单换行，无段原文）
    // 只有读经想法分享（标题后紧跟空行）才区块包裹段原文；普通笔记不包裹。
    if (nl + 1 >= trimmed.length || trimmed[nl + 1] != '\n') {
      return null;
    }

    final rest = trimmed.substring(nl + 1).trim();
    // 剩余内容按空行（\n\n）分割：第一段为段原文，其余为笔记。
    final parts = rest.split(RegExp(r'\n\s*\n'));
    final paragraph = parts.isNotEmpty ? parts[0].trim() : '';
    final noteText = parts.length > 1
        ? parts.sublist(1).join('\n\n').trim()
        : '';
    if (paragraph.isEmpty) return null;
    return ReadingNotePost(
      sutraTitle: sutraTitle,
      paragraph: paragraph,
      noteText: noteText,
    );
  }
}

/// 读经笔记分享帖渲染组件。
///
/// 三个可点击区域（内层 GestureDetector 会消费自身点击，
/// 其余区域触发整块点击进入笔记详情页）：
///   - $经文名 → SutraDiscussionPage（经文讨论页）
///   - 段原文高亮区块 → SutraParagraphPage（专门段落查看页）
///   - 笔记内容 / 整块其它区域 → NoteDetailPage（笔记详情页）
class ReadingNotePostView extends StatelessWidget {
  final ReadingNotePost note;
  final String noteId;
  final Map<String, dynamic> sutraLibrary;

  const ReadingNotePostView({
    super.key,
    required this.note,
    required this.noteId,
    required this.sutraLibrary,
  });

  void _openDetail(BuildContext context) async {
    if (noteId.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: noteId)),
    );
  }

  void _openParagraph(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SutraParagraphPage(
          sutraTitle: note.sutraTitle,
          paragraph: note.paragraph,
          filePath: note.filePath,
        ),
      ),
    );
  }

  void _openDiscussion(BuildContext context) {
    final path = note.filePath ??
        (sutraLibrary[note.sutraTitle]?.filePath ?? note.sutraTitle);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SutraDiscussionPage(
          title: note.sutraTitle,
          filePath: path,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openDetail(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // $经文名 链接（点击进入讨论页，无书本图标）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openDiscussion(context),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '\$${note.sutraTitle}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: p.accent,
                ),
              ),
            ),
          ),
          // 笔记内容（用户的想法，放在经文色块上方）
          if (note.noteText.isNotEmpty) ...[
            Text(
              note.noteText,
              style: TextStyle(
                fontSize: 15,
                height: 1.6,
                color: p.text,
              ),
            ),
            const SizedBox(height: 10),
          ],
          // 段原文区块（无边缘线条、无书本图标；整段全文显示，点击进入段落查看页）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openParagraph(context),
            child: Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                note.paragraph,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.6,
                  color: p.text,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 画线分享帖的解析。
///
/// 分享时 `SutraHighlightsPage._buildShareContent()` 生成的正文格式：
///   $经书名
///   <空行>
///   第一条画线文字
///   <空行>
///   §§HS§§ + base64(全部画线文字 JSON 数组)
/// 展示时只显示第一条画线（背景色包裹块），点击色块用完整数据打开画线归集页。
class SutraHighlightsPost {
  final String sutraTitle;
  final String firstHighlight;
  final List<String> highlights;
  final String message;
  final String? filePath;

  const SutraHighlightsPost({
    this.sutraTitle = '',
    this.firstHighlight = '',
    this.highlights = const [],
    this.message = '',
    this.filePath,
  });

  static bool isHighlightsPost(String content) =>
      content.contains(kSutraHighlightsMetaPrefix);

  static SutraHighlightsPost? parse(String content) {
    if (content.isEmpty) return null;
    if (!content.contains(kSutraHighlightsMetaPrefix)) return null;
    final trimmed = content.trimRight();
    final nl = trimmed.indexOf('\n');
    if (nl < 0) return null;
    final firstLine = trimmed.substring(0, nl).trim();
    if (!firstLine.startsWith(r'$')) return null;
    final sutraTitle = firstLine.substring(1).trim();
    if (sutraTitle.isEmpty) return null;

    // 解析哨兵之后的元数据。
    final metaIdx = trimmed.indexOf(kSutraHighlightsMetaPrefix);
    var metaSection = trimmed.substring(
        metaIdx + kSutraHighlightsMetaPrefix.length);
    final metaEnd = metaSection.indexOf('\n');
    if (metaEnd >= 0) metaSection = metaSection.substring(0, metaEnd);
    final highlights = <String>[];
    try {
      final decoded = utf8.decode(base64Decode(metaSection.trim()));
      final arr = jsonDecode(decoded);
      if (arr is List) {
        for (final it in arr) {
          if (it is String && it.trim().isNotEmpty) {
            highlights.add(it.trim());
          }
        }
      }
    } catch (_) {}

    // 第一条画线 = 标题与哨兵之间、按空行分的首段。
    final before = trimmed.substring(nl + 1, metaIdx).trim();
    final first =
        before.split(RegExp(r'\n\s*\n')).map((s) => s.trim()).firstWhere(
              (s) => s.isNotEmpty,
              orElse: () => '',
            );

    // 留言 = 哨兵那一行之后的内容（可为空）。
    final afterMetaLine =
        trimmed.substring(metaIdx + kSutraHighlightsMetaPrefix.length);
    final firstNl = afterMetaLine.indexOf('\n');
    final message =
        firstNl >= 0 ? afterMetaLine.substring(firstNl + 1).trim() : '';

    return SutraHighlightsPost(
      sutraTitle: sutraTitle,
      firstHighlight: first,
      highlights: highlights,
      message: message,
    );
  }
}

/// 画线分享帖渲染组件。
/// 样式与读经笔记分享帖一致：
///   - $经名 → 经文讨论页
///   - 第一条画线（背景色块）→ 打开该经书画线归集页（展示分享时发布的完整画线）
///   - 其余区域 → 笔记详情页
class SutraHighlightsPostView extends StatelessWidget {
  final SutraHighlightsPost post;
  final String noteId;
  final Map<String, dynamic> sutraLibrary;

  const SutraHighlightsPostView({
    super.key,
    required this.post,
    required this.noteId,
    required this.sutraLibrary,
  });

  void _openDetail(BuildContext context) async {
    if (noteId.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: noteId)),
    );
  }

  void _openHighlights(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SutraHighlightsPage(
          title: post.sutraTitle,
          highlights: List.of(post.highlights),
        ),
      ),
    );
  }

  void _openDiscussion(BuildContext context) {
    final path = post.filePath ??
        (sutraLibrary[post.sutraTitle]?.filePath ?? post.sutraTitle);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SutraDiscussionPage(
          title: post.sutraTitle,
          filePath: path,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openDetail(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openDiscussion(context),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '\$${post.sutraTitle}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: p.accent,
                ),
              ),
            ),
          ),
          // 留言（用户说的话，放在经文色块上方）
          if (post.message.isNotEmpty) ...[
            Text(
              post.message,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: p.text,
              ),
            ),
            const SizedBox(height: 10),
          ],
          // 第一条画线：纯背景色包裹块，点击进入画线归集页。
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openHighlights(context),
            child: Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                post.firstHighlight,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.6,
                  color: p.text,
                  decoration: TextDecoration.underline,
                  decorationColor:
                      p.accent.withValues(alpha: 0.6),
                  decorationThickness: 1.2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 想法分享帖的解析。
///
/// 分享时 `ReadingNotesPage._buildShareContent()` 生成的正文格式：
///   $经书名
///   <空行>
///   第一条经文
///   <空行>
///   §§TS§§ + base64((经文,想法) 成对数组 JSON)
/// 展示时只显示第一条经文（背景色包裹块），点击色块用完整数据打开想法页。
class SutraThoughtsPost {
  final String sutraTitle;
  final String firstParagraph;
  final List<(String, String)> pairs;
  final String message;
  final String? filePath;

  const SutraThoughtsPost({
    this.sutraTitle = '',
    this.firstParagraph = '',
    this.pairs = const [],
    this.message = '',
    this.filePath,
  });

  static bool isThoughtsPost(String content) =>
      content.contains(kSutraThoughtsMetaPrefix);

  /// 解析 base64 元数据为「经文,想法」成对数组。
  static List<(String, String)> _decodePairs(String base) {
    final pairs = <(String, String)>[];
    try {
      final decoded = utf8.decode(base64Decode(base.trim()));
      final arr = jsonDecode(decoded);
      if (arr is List) {
        for (final it in arr) {
          if (it is Map) {
            final p = (it['p'] ?? '').toString().trim();
            final t = (it['t'] ?? '').toString().trim();
            if (p.isNotEmpty || t.isNotEmpty) pairs.add((p, t));
          } else if (it is String && it.trim().isNotEmpty) {
            // 兼容单字符串形式（当作只有经文）。
            pairs.add((it.trim(), ''));
          }
        }
      }
    } catch (_) {}
    return pairs;
  }

  static SutraThoughtsPost? parse(String content) {
    if (content.isEmpty) return null;
    if (!content.contains(kSutraThoughtsMetaPrefix)) return null;
    final trimmed = content.trimRight();
    final nl = trimmed.indexOf('\n');
    if (nl < 0) return null;
    final firstLine = trimmed.substring(0, nl).trim();
    if (!firstLine.startsWith(r'$')) return null;
    final sutraTitle = firstLine.substring(1).trim();
    if (sutraTitle.isEmpty) return null;

    final metaIdx = trimmed.indexOf(kSutraThoughtsMetaPrefix);
    var metaSection = trimmed.substring(
        metaIdx + kSutraThoughtsMetaPrefix.length);
    final metaEnd = metaSection.indexOf('\n');
    if (metaEnd >= 0) metaSection = metaSection.substring(0, metaEnd);
    final pairs = _decodePairs(metaSection);

    // 第一条经文 = 标题与哨兵之间、按空行分的首段。
    final before = trimmed.substring(nl + 1, metaIdx).trim();
    final first =
        before.split(RegExp(r'\n\s*\n')).map((s) => s.trim()).firstWhere(
              (s) => s.isNotEmpty,
              orElse: () => pairs.isNotEmpty ? pairs.first.$1 : '',
            );

    // 留言 = 哨兵那一行之后的内容（可为空）。
    final afterMetaLine =
        trimmed.substring(metaIdx + kSutraThoughtsMetaPrefix.length);
    final firstNl = afterMetaLine.indexOf('\n');
    final message =
        firstNl >= 0 ? afterMetaLine.substring(firstNl + 1).trim() : '';

    return SutraThoughtsPost(
      sutraTitle: sutraTitle,
      firstParagraph: first,
      pairs: pairs,
      message: message,
    );
  }
}

/// 想法分享帖渲染组件。
/// 样式与画线分享帖完全一致：
///   - $经名 → 经文讨论页
///   - 第一条经文（背景色块）→ 打开该经书想法汇总页（展示分享时发布的完整想法）
///   - 留言 → 显示在色块上方
///   - 其余区域 → 笔记详情页
class SutraThoughtsPostView extends StatelessWidget {
  final SutraThoughtsPost post;
  final String noteId;
  final Map<String, dynamic> sutraLibrary;

  const SutraThoughtsPostView({
    super.key,
    required this.post,
    required this.noteId,
    required this.sutraLibrary,
  });

  void _openDetail(BuildContext context) async {
    if (noteId.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: noteId)),
    );
  }

  void _openThoughts(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReadingNotesPage(
          title: post.sutraTitle,
          paragraphs: [for (final (p, _) in post.pairs) p],
          notes: [for (final (_, t) in post.pairs) t],
        ),
      ),
    );
  }

  void _openDiscussion(BuildContext context) {
    final path = post.filePath ??
        (sutraLibrary[post.sutraTitle]?.filePath ?? post.sutraTitle);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SutraDiscussionPage(
          title: post.sutraTitle,
          filePath: path,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openDetail(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openDiscussion(context),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '\$${post.sutraTitle}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: p.accent,
                ),
              ),
            ),
          ),
          // 留言（用户说的话，放在经文色块上方）
          if (post.message.isNotEmpty) ...[
            Text(
              post.message,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: p.text,
              ),
            ),
            const SizedBox(height: 10),
          ],
          // 第一条经文：纯背景色包裹块，点击进入想法汇总页。
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openThoughts(context),
            child: Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                post.firstParagraph,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.6,
                  color: p.text,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
