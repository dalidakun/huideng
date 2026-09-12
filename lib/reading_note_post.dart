import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'post_rich_content.dart';
import 'reading_notes_page.dart';
import 'reading_sutra_notes_page.dart';
import 'sutra_highlights_page.dart';
import 'sutra_live_sync.dart';
import 'sutra_paragraph_page.dart';
import 'sutra_underline.dart';

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
    // - 读经感想（ReadingNoteEditPage）：`$经名\n\n段原文\n\n笔记`（空行分隔）
    // - 普通笔记（主页新建 NoteEditPage）：`$经名\n笔记`（单换行，无段原文）
    // 只有读经感想分享（标题后紧跟空行）才区块包裹段原文；普通笔记不包裹。
    if (nl + 1 >= trimmed.length || trimmed[nl + 1] != '\n') {
      return null;
    }

    final rest = trimmed.substring(nl + 1).trim();
    // 剩余内容按空行（\n\n）分割：第一段为段原文，其余为笔记。
    final parts = rest.split(RegExp(r'\n\s*\n'));
    final paragraph = parts.isNotEmpty ? parts[0].trim() : '';
    final noteText =
        parts.length > 1 ? parts.sublist(1).join('\n\n').trim() : '';
    if (paragraph.isEmpty) return null;
    return ReadingNotePost(
      sutraTitle: sutraTitle,
      paragraph: paragraph,
      noteText: noteText,
    );
  }
}

/// 读经笔记汇总帖数据：包含经文名和笔记内容列表。
class SutraNotesPost {
  final String sutraTitle;
  final String firstNote;
  final List<String> notes;
  final String message;

  const SutraNotesPost({
    required this.sutraTitle,
    required this.firstNote,
    required this.notes,
    this.message = '',
  });

  /// 判断正文是否为读经笔记汇总帖格式。
  static bool isSutraNotesPost(String content) =>
      parse(content) != null;

  /// 解析 base64 元数据为笔记内容列表。
  static List<String> _decodeNotes(String base) {
    final notes = <String>[];
    try {
      final decoded = utf8.decode(base64Decode(base.trim()));
      final arr = jsonDecode(decoded);
      if (arr is List) {
        for (final it in arr) {
          if (it is Map) {
            final c = (it['c'] ?? '').toString().trim();
            if (c.isNotEmpty) notes.add(c);
          }
        }
      }
    } catch (_) {}
    return notes;
  }

  /// 解析正文。非读经笔记汇总帖格式返回 null。
  static SutraNotesPost? parse(String content) {
    if (content.isEmpty) return null;
    if (!content.contains(kSutraNotesMetaPrefix)) return null;
    final trimmed = content.trimRight();
    final nl = trimmed.indexOf('\n');
    if (nl < 0) return null;
    final firstLine = trimmed.substring(0, nl).trim();
    if (!firstLine.startsWith(r'$')) return null;
    final sutraTitle = firstLine.substring(1).trim();
    if (sutraTitle.isEmpty) return null;

    final metaIdx = trimmed.indexOf(kSutraNotesMetaPrefix);
    var metaSection =
        trimmed.substring(metaIdx + kSutraNotesMetaPrefix.length);
    final metaEnd = metaSection.indexOf('\n');
    if (metaEnd >= 0) metaSection = metaSection.substring(0, metaEnd);
    final notes = _decodeNotes(metaSection);

    // 第一篇笔记 = 标题与哨兵之间、按空行分的首段。
    final before = trimmed.substring(nl + 1, metaIdx).trim();
    final first =
        before.split(RegExp(r'\n\s*\n')).map((s) => s.trim()).firstWhere(
              (s) => s.isNotEmpty,
              orElse: () => notes.isNotEmpty ? notes.first : '',
            );

    // 留言 = 哨兵那一行之后的内容（可为空）。
    final afterMetaLine =
        trimmed.substring(metaIdx + kSutraNotesMetaPrefix.length);
    final firstNl = afterMetaLine.indexOf('\n');
    final message =
        firstNl >= 0 ? afterMetaLine.substring(firstNl + 1).trim() : '';

    return SutraNotesPost(
      sutraTitle: sutraTitle,
      firstNote: first,
      notes: notes,
      message: message,
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
  // 帖子作者昵称，用于在经文色块顶部标注「xxx的感想」（选择性文字分享）。
  final String? authorName;

  const ReadingNotePostView({
    super.key,
    required this.note,
    required this.noteId,
    required this.sutraLibrary,
    this.authorName,
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
          // 笔记内容（用户的感想，放在经文色块上方）
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (authorName != null && authorName!.trim().isNotEmpty) ...[
                    Text(
                      '$authorName的感想',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    note.paragraph,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: p.text,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 读经笔记汇总帖数据（解析后的结构）。
/// 已在文件顶部定义，此处不再重复。

/// 读经笔记汇总帖渲染组件。
/// 样式与读经笔记分享帖一致：
///   - $经名 → 经文讨论页
///   - 第一篇笔记（背景色块）→ 打开该经文笔记汇总页
///   - 其余区域 → 笔记详情页
class SutraNotesPostView extends StatefulWidget {
  final SutraNotesPost post;
  final String noteId;
  final Map<String, dynamic> sutraLibrary;
  final String? authorName;
  final String ownerUserId;

  const SutraNotesPostView({
    super.key,
    required this.post,
    required this.noteId,
    required this.sutraLibrary,
    this.authorName,
    this.ownerUserId = '',
  });

  @override
  State<SutraNotesPostView> createState() => _SutraNotesPostViewState();
}

class _SutraNotesPostViewState extends State<SutraNotesPostView> {
  int? _liveCount;

  @override
  void initState() {
    super.initState();
    _loadLiveCount();
  }

  Future<void> _loadLiveCount() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('notes');
      if (raw == null || raw.isEmpty) return;
      final arr = jsonDecode(raw);
      if (arr is! List) return;
      final sutraTag = '\$${widget.post.sutraTitle}';
      var count = 0;
      for (final note in arr) {
        if (note is Map) {
          final content = (note['content'] ?? '').toString();
          final shared = note['shared'] == true;
          if (content.contains(sutraTag) && shared) count++;
        }
      }
      if (mounted) setState(() => _liveCount = count);
    } catch (_) {}
  }

  void _openDetail(BuildContext context) async {
    if (widget.noteId.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: widget.noteId)),
    );
  }

  void _openNotesPage(BuildContext context) {
    // 将 SutraNotesPost 的笔记列表转为 ReadingSutraNotesPage 需要的格式
    final initialNotes = <Map<String, dynamic>>[];
    for (final noteText in widget.post.notes) {
      initialNotes.add({
        'id': '',
        'content': noteText,
        'updatedAt': DateTime.now().toIso8601String(),
        'shared': true,
        'cloudId': null,
      });
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReadingSutraNotesPage(
          title: widget.post.sutraTitle,
          ownerUserId: widget.ownerUserId,
          initialNotes: initialNotes,
          noteId: widget.noteId,
        ),
      ),
    ).then((_) => _loadLiveCount());
  }

  void _openDiscussion(BuildContext context) {
    final path = widget.sutraLibrary[widget.post.sutraTitle]?.filePath ?? widget.post.sutraTitle;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SutraDiscussionPage(
          title: widget.post.sutraTitle,
          filePath: path,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final post = widget.post;
    final count = _liveCount ?? post.notes.length;
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
          // 留言内容
          if (post.message.isNotEmpty) ...[
            Text(
              post.message,
              style: TextStyle(
                fontSize: 15,
                height: 1.6,
                color: p.text,
              ),
            ),
            const SizedBox(height: 10),
          ],
          // 第一篇笔记（背景色块，点击进入笔记汇总页）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openNotesPage(context),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.authorName != null && widget.authorName!.trim().isNotEmpty) ...[
                    Text(
                      '${widget.authorName}的所有笔记',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    post.firstNote,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: p.text,
                    ),
                  ),
                  if (count > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      '共 $count 篇笔记，点击查看',
                      style: TextStyle(
                        fontSize: 12,
                        color: p.accent,
                      ),
                    ),
                  ],
                ],
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
    var metaSection =
        trimmed.substring(metaIdx + kSutraHighlightsMetaPrefix.length);
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
class SutraHighlightsPostView extends StatefulWidget {
  final SutraHighlightsPost post;
  final String noteId;
  final Map<String, dynamic> sutraLibrary;
  // 帖子作者昵称，用于在画线色块顶部标注「xxx的所有画线」（画线页分享）。
  final String? authorName;

  /// 帖子作者 userId：作者本人查看自己的分享帖时，画线页加载实时数据而非快照。
  final String ownerUserId;

  const SutraHighlightsPostView({
    super.key,
    required this.post,
    required this.noteId,
    required this.sutraLibrary,
    this.authorName,
    this.ownerUserId = '',
  });

  @override
  State<SutraHighlightsPostView> createState() => _SutraHighlightsPostViewState();
}

class _SutraHighlightsPostViewState extends State<SutraHighlightsPostView> {
  int? _liveCount;

  @override
  void initState() {
    super.initState();
    _loadLiveCount();
  }

  Future<void> _loadLiveCount() async {
    try {
      final meId = AuthService.instance.cachedUserId;
      final isOwner = meId != null && meId.isNotEmpty && widget.ownerUserId == meId;
      if (!isOwner) return;

      final loaded = await loadSutraTightByTitle(widget.post.sutraTitle,
          filePath: widget.post.filePath);
      final paragraphs = loaded?.paragraphs;
      if (paragraphs == null || !mounted) return;

      final union = await fetchParagraphNotesUnion(widget.post.sutraTitle,
          widget.ownerUserId,
          filePath: loaded!.filePath);
      final cloudItems = union.items;

      List<LiveHighlightItem>? computed;
      try {
        computed = await Isolate.run(
            () => buildLiveHighlights(paragraphs, loaded!.tight, cloudItems));
      } catch (_) {}

      if (computed != null && mounted) {
        final count = computed.length;
        setState(() => _liveCount = count);
      }
    } catch (_) {}
  }

  void _openDetail(BuildContext context) async {
    if (widget.noteId.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: widget.noteId)),
    );
  }

  /// 打开画线归集页：以「作者当前最新画线」为准（对所有查看者）。
  /// 无法定位作者或加载不到经文时，才回退到分享时的快照。
  Future<void> _openHighlights(BuildContext context) async {
    final meId = AuthService.instance.cachedUserId;
    final isOwner = meId != null && meId.isNotEmpty && widget.ownerUserId == meId;

    var highlights = List.of(widget.post.highlights);
    var items = <LiveHighlightItem>[];
    var canDelete = false;
    var liveLoaded = false;
    var liveEmpty = false;
    String? emptyHint;
    String? syncNotice;
    Future<bool> Function(List<LiveHighlightSegment>)? deleteCb;

    if (widget.ownerUserId.isNotEmpty) {
      try {
        final loaded = await loadSutraTightByTitle(widget.post.sutraTitle,
            filePath: widget.post.filePath);
        final paragraphs = loaded?.paragraphs;
        if (paragraphs != null) {
          // 帖子标题是展示名，与读经页存笔记的 key 未必逐字相等；
          // 用候选 key 并集拉取作者当前笔记，避免误判「作者已删除全部画线」。
          final union = await fetchParagraphNotesUnion(widget.post.sutraTitle,
              widget.ownerUserId,
              filePath: loaded!.filePath);
          final cloudItems = union.items;
          // 重建计算放后台隔离区：巨量画线/大幅合并也只影响耗时，不卡 UI。
          List<LiveHighlightItem>? computed;
          try {
            computed = await Isolate.run(
                () => buildLiveHighlights(paragraphs, loaded!.tight, cloudItems));
          } catch (e, st) {
            debugPrint('[highlights] 实时重建失败: $e\n$st');
          }
          if (computed == null) {
            // 重建失败：静默回退到分享时快照，不打扰用户。
          } else {
            items = computed;
            debugPrint('[highlights-post] 实时 ${computed.length} 条, notesKey=${union.key}');
            canDelete = isOwner && items.isNotEmpty;
            liveLoaded = true;
            liveEmpty = items.isEmpty;
            if (isOwner) {
              final paragraphsRef = paragraphs;
              final notesKey = union.key;
              deleteCb = (segs) => deleteLiveUnderline(
                  sutraKey: notesKey,
                  paragraphs: paragraphsRef,
                  segments: segs);
            }
          }
        } else {
          // 无法定位经文正文：静默回退到分享时快照。
        }
      } catch (e) {
        // 实时数据加载失败：静默回退到分享快照。
        liveLoaded = false;
      }
      if (liveLoaded) {
        highlights = [for (final it in items) it.text];
        if (liveEmpty) emptyHint = '作者已删除全部画线\n该分享帖已同步为空';
      }
    }

    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SutraHighlightsPage(
          title: widget.post.sutraTitle,
          highlights: highlights,
          canDelete: canDelete,
          sutraKey: widget.post.sutraTitle,
          itemSegments: [for (final it in items) it.segments],
          onDeleteUnderline: deleteCb,
          emptyHint: emptyHint,
          syncNotice: syncNotice,
        ),
      ),
    );
  }

  void _openDiscussion(BuildContext context) {
    final path = widget.post.filePath ??
        (widget.sutraLibrary[widget.post.sutraTitle]?.filePath ?? widget.post.sutraTitle);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SutraDiscussionPage(
          title: widget.post.sutraTitle,
          filePath: path,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final post = widget.post;
    final count = _liveCount ?? post.highlights.length;
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.authorName != null && widget.authorName!.trim().isNotEmpty) ...[
                    Text(
                      '${widget.authorName}的所有画线',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  SutraUnderlineText(
                    text: post.firstHighlight,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: p.text,
                    ),
                    lineColor: p.accent.withValues(alpha: 0.8),
                  ),
                  if (count > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      '共 $count 次划线，点击查看',
                      style: TextStyle(
                        fontSize: 12,
                        color: p.accent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 感想分享帖的解析。
///
/// 分享时 `ReadingNotesPage._buildShareContent()` 生成的正文格式：
///   $经书名
///   <空行>
///   第一条经文
///   <空行>
///   §§TS§§ + base64((经文,感想) 成对数组 JSON)
/// 展示时只显示第一条经文（背景色包裹块），点击色块用完整数据打开感想页。
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

  /// 解析 base64 元数据为「经文,感想」成对数组。
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
    var metaSection =
        trimmed.substring(metaIdx + kSutraThoughtsMetaPrefix.length);
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

/// 把读经「画线 / 感想」分享帖正文转成适合纯文本（如 PDF 导出）的洁净文本。
///
/// 这种帖子末尾带一段 base64 元数据（哨兵 `§§HS§§` / `§§TS§§` 编码的成对
/// 数组），直接导出会显示乱码。这里按分享帖结构还原成可读文本：
///   - 感想帖：`$经名` + 第一条「经文/感想」
///   - 画线帖：`$经名` + 第一条画线文字
///   - 用户的留言单独放在最后的「【留言】」小节，与经文列表区分开
/// 只导出第一条，避免整页感想/画线全部导出导致 PDF 生成过重卡死。
/// 非分享帖返回 null。
String? sutraPostPlainText(String content) {
  final thoughts = SutraThoughtsPost.parse(content);
  if (thoughts != null) {
    final lines = <String>[
      if (thoughts.sutraTitle.isNotEmpty) '\$${thoughts.sutraTitle}',
    ];
    if (thoughts.pairs.isNotEmpty) {
      // 只导出第一条「经文,感想」。
      final (p, t) = thoughts.pairs.first;
      final seg = <String>[];
      final pTrim = p.trim();
      final tTrim = t.trim();
      if (pTrim.isNotEmpty) seg.add('经文：$pTrim');
      if (tTrim.isNotEmpty) seg.add('感想：$tTrim');
      if (seg.isNotEmpty) lines.add(seg.join('\n'));
    } else if (thoughts.firstParagraph.trim().isNotEmpty) {
      // 极端历史数据：无成对元数据但展示块里有首条经文。
      lines.add(thoughts.firstParagraph.trim());
    }
    final msg = thoughts.message.trim();
    if (msg.isNotEmpty) lines.add('【留言】\n$msg');
    return lines.isEmpty ? null : lines.join('\n\n');
  }
  final highlights = SutraHighlightsPost.parse(content);
  if (highlights != null) {
    final lines = <String>[
      if (highlights.sutraTitle.isNotEmpty) '\$${highlights.sutraTitle}',
    ];
    if (highlights.highlights.isNotEmpty) {
      // 只导出第一条画线。
      final h = highlights.highlights.first.trim();
      if (h.isNotEmpty) lines.add(h);
    } else if (highlights.firstHighlight.trim().isNotEmpty) {
      lines.add(highlights.firstHighlight.trim());
    }
    final msg = highlights.message.trim();
    if (msg.isNotEmpty) lines.add('【留言】\n$msg');
    return lines.isEmpty ? null : lines.join('\n\n');
  }
  return null;
}

/// 感想分享帖渲染组件。
/// 样式与画线分享帖完全一致：
///   - $经名 → 经文讨论页
///   - 第一条经文（背景色块）→ 打开该经书感想汇总页（展示分享时发布的完整感想）
///   - 留言 → 显示在色块上方
///   - 其余区域 → 笔记详情页
class SutraThoughtsPostView extends StatefulWidget {
  final SutraThoughtsPost post;
  final String noteId;
  final Map<String, dynamic> sutraLibrary;
  // 帖子作者昵称，用于在经文色块顶部标注「xxx的所有感想」（感想汇总页分享）。
  final String? authorName;

  /// 帖子作者 userId：作者本人查看自己的分享帖时，感想页加载实时数据而非快照。
  final String ownerUserId;

  const SutraThoughtsPostView({
    super.key,
    required this.post,
    required this.noteId,
    required this.sutraLibrary,
    this.authorName,
    this.ownerUserId = '',
  });

  @override
  State<SutraThoughtsPostView> createState() => _SutraThoughtsPostViewState();
}

class _SutraThoughtsPostViewState extends State<SutraThoughtsPostView> {
  int? _liveCount;

  @override
  void initState() {
    super.initState();
    _loadLiveCount();
  }

  Future<void> _loadLiveCount() async {
    try {
      final meId = AuthService.instance.cachedUserId;
      final isOwner = meId != null && meId.isNotEmpty && widget.ownerUserId == meId;
      if (!isOwner) return;

      final loaded = await loadSutraTightByTitle(widget.post.sutraTitle,
          filePath: widget.post.filePath);
      final allParagraphs = loaded?.paragraphs;
      if (allParagraphs == null || !mounted) return;

      final union = await fetchParagraphNotesUnion(widget.post.sutraTitle,
          widget.ownerUserId,
          filePath: loaded!.filePath);
      final cloudItems = union.items;

      List<LiveThoughtItem>? computed;
      try {
        computed = await Isolate.run(() =>
            buildLiveThoughts(allParagraphs, loaded!.tight, cloudItems));
      } catch (_) {}

      if (computed != null && mounted) {
        final livePairs = <(String, String)>[];
        for (final item in computed) {
          final note = (item.note ?? '').trim();
          if (note.isNotEmpty) {
            livePairs.add((item.paragraph, note));
          }
        }
        setState(() => _liveCount = livePairs.length);
      }
    } catch (_) {}
  }

  void _openDetail(BuildContext context) async {
    if (widget.noteId.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: widget.noteId)),
    );
  }

  /// 打开感想汇总页：以「作者当前最新感想」为准（对所有查看者）。
  /// 无法定位作者或加载不到经文时，才回退到分享时的快照。
  Future<void> _openThoughts(BuildContext context) async {
    final meId = AuthService.instance.cachedUserId;
    final isOwner = meId != null && meId.isNotEmpty && widget.ownerUserId == meId;

    var paragraphs = [for (final (p, _) in widget.post.pairs) p];
    var notes = [for (final (_, t) in widget.post.pairs) t];
    var itemIndexes = const <int>[];
    var canDelete = false;
    var liveLoaded = false;
    var liveEmpty = false;
    String? emptyHint;
    String? syncNotice;
    Future<bool> Function(int)? deleteCb;

    if (widget.ownerUserId.isNotEmpty) {
      try {
        final loaded = await loadSutraTightByTitle(widget.post.sutraTitle,
            filePath: widget.post.filePath);
        final allParagraphs = loaded?.paragraphs;
        if (allParagraphs != null) {
          // 帖子标题是展示名，与读经页存笔记的 key 未必逐字相等；
          // 用候选 key 并集拉取作者当前感想，避免误判「作者已删除全部感想」。
          final union = await fetchParagraphNotesUnion(widget.post.sutraTitle,
              widget.ownerUserId,
              filePath: loaded!.filePath);
          final cloudItems = union.items;
          // 重建计算放后台隔离区：巨量感想/大幅合并也只影响耗时，不卡 UI。
          List<LiveThoughtItem>? computed;
          try {
            computed = await Isolate.run(() =>
                buildLiveThoughts(allParagraphs, loaded!.tight, cloudItems));
          } catch (e, st) {
            debugPrint('[thoughts] 实时重建失败: $e\n$st');
          }
          if (computed == null) {
            // 重建失败：静默回退到分享时快照，不打扰用户。
          } else {
            final items = computed;
            paragraphs = [for (final it in items) it.paragraph];
            notes = [for (final it in items) it.note];
            itemIndexes = [for (final it in items) it.para];
            canDelete = isOwner && items.isNotEmpty;
            liveLoaded = true;
            liveEmpty = items.isEmpty;
            if (isOwner) {
              final paragraphsRef = allParagraphs;
              final notesKey = union.key;
              deleteCb = (p) =>
                  deleteLiveNote(sutraKey: notesKey, paragraphs: paragraphsRef, index: p);
            }
          }
        } else {
          // 无法定位经文正文：静默回退到分享时快照。
        }
      } catch (e) {
        // 实时数据加载失败：静默回退到分享快照。
        liveLoaded = false;
      }
      if (liveLoaded && liveEmpty) {
        emptyHint = '作者已删除全部感想\n该分享帖已同步为空';
      }
    }

    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReadingNotesPage(
          title: widget.post.sutraTitle,
          paragraphs:
              liveLoaded ? paragraphs : [for (final (p, _) in widget.post.pairs) p],
          notes: liveLoaded ? notes : [for (final (_, t) in widget.post.pairs) t],
          canDelete: canDelete,
          sutraKey: widget.post.sutraTitle,
          itemParagraphIndexes: liveLoaded ? itemIndexes : const <int>[],
          onDeleteNote: deleteCb,
          emptyHint: emptyHint,
          syncNotice: syncNotice,
        ),
      ),
    );
  }

  void _openDiscussion(BuildContext context) {
    final path = widget.post.filePath ??
        (widget.sutraLibrary[widget.post.sutraTitle]?.filePath ?? widget.post.sutraTitle);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SutraDiscussionPage(
          title: widget.post.sutraTitle,
          filePath: path,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final post = widget.post;
    final count = _liveCount ?? post.pairs.length;
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
          // 第一条经文：纯背景色包裹块，点击进入感想汇总页。
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openThoughts(context),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.authorName != null && widget.authorName!.trim().isNotEmpty) ...[
                    Text(
                      '${widget.authorName}的所有感想',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    post.firstParagraph,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: p.text,
                    ),
                  ),
                  if (count > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      '共 $count 篇感想，点击查看',
                      style: TextStyle(
                        fontSize: 12,
                        color: p.accent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
