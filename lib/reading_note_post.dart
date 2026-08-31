import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'note_detail_page.dart';
import 'post_rich_content.dart';
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

  /// 解析正文。非读经笔记格式返回 null。
  static ReadingNotePost? parse(String content) {
    if (content.isEmpty) return null;
    // 必须以 `$经书名` 开头，且紧跟空行（\n\n）。
    final trimmed = content.trimRight();
    final nl = trimmed.indexOf('\n');
    if (nl < 0) return null;
    final firstLine = trimmed.substring(0, nl).trim();
    if (!firstLine.startsWith(r'$')) return null;
    final sutraTitle = firstLine.substring(1).trim();
    if (sutraTitle.isEmpty) return null;

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
          // $经文名 链接（点击进入讨论页）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openDiscussion(context),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
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
          // 段原文一行高亮区块（点击进入段落查看页）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openParagraph(context),
            child: Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.accent.withValues(alpha: 0.2)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.menu_book_rounded, size: 16, color: p.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      note.paragraph,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: p.textSec,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: p.textHint),
                ],
              ),
            ),
          ),
          // 笔记内容
          if (note.noteText.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              note.noteText,
              style: TextStyle(
                fontSize: 15,
                height: 1.6,
                color: p.text,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
