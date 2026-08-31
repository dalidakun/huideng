import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'reading_note_post.dart';
import 'user_avatar.dart';

/// 把读经笔记分享帖正文解析成 (想法正文, 标题) 用于展示。
/// 内容格式：$经名\n\n段原文\n\n想法；想法为空时展示「分享了这段经文的读经想法」占位。
class _Thought {
  final PlazaNote note;
  final String noteId;
  final String text;
  final String title;

  const _Thought({
    required this.note,
    required this.noteId,
    required this.text,
    required this.title,
  });
}

/// 「段落想法」汇总底部弹层：列出该段经文下所有用户分享的想法。
///
/// 打开时从底部向上滑出，顶部停在标题栏下边缘再往下半个标题栏高度的位置
/// （即 `顶部安全区 + 1.5 倍 AppBar 高度`），上方左右圆角。
/// 支持加载更多、点赞、点击某条进入对应笔记详情页、下拉/点击遮罩关闭。
class ParagraphThoughtsPage extends StatefulWidget {
  final String sutraTitle;
  final String paragraph;

  const ParagraphThoughtsPage({
    super.key,
    required this.sutraTitle,
    required this.paragraph,
  });

  /// 打开该弹层时使用下滑渐显的过渡路由（底部抽屉效果）。
  static Future<void> open(
    BuildContext context, {
    required String sutraTitle,
    required String paragraph,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        barrierColor: Colors.black54,
        barrierDismissible: true,
        pageBuilder: (_, __, ___) => ParagraphThoughtsPage(
          sutraTitle: sutraTitle,
          paragraph: paragraph,
        ),
        transitionsBuilder: (_, anim, __, child) {
          final topOffset =
              MediaQuery.of(context).padding.top + kToolbarHeight * 1.5;
          final full = MediaQuery.of(context).size.height;
          // 真正的底部抽屉：背景为全屏 Stack，绘制一个随动画升降的抽屉面板。
          return Stack(
            children: [
              // 抽屉面板：从底部升起，顶部停在 顶部安全区 + 1.5 倍标题栏高度。
              AnimatedBuilder(
                animation: anim,
                builder: (context, _) {
                  final t = Curves.easeOutCubic.transform(anim.value);
                  final top = topOffset + (full - topOffset) * (1 - t);
                  return Positioned(
                    left: 0,
                    right: 0,
                    top: top,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(18)),
                      child: child,
                    ),
                  );
                },
              ),
            ],
          );
        },
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
      ),
    );
  }

  @override
  State<ParagraphThoughtsPage> createState() => _ParagraphThoughtsPageState();
}

class _ParagraphThoughtsPageState extends State<ParagraphThoughtsPage> {
  final List<_Thought> _thoughts = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPage(reset: true);
  }

  /// 解析读经笔记帖，仅保留「段原文」与当前段落一致的帖子。
  _Thought? _toThought(PlazaNote n) {
    final parsed = ReadingNotePost.parse(n.content);
    if (parsed == null || parsed.paragraph.trim() != widget.paragraph.trim()) {
      return null;
    }
    return _Thought(
      note: n,
      noteId: n.id,
      text: (parsed.noteText.isNotEmpty ? parsed.noteText : parsed.paragraph),
      title: parsed.sutraTitle,
    );
  }

  Future<void> _loadPage({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _page = 1;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final (list, hasMore) = await CloudNotesService.instance
          .getParagraphThoughts(widget.paragraph, page: _page, pageSize: 20);
      if (!mounted) return;
      final thoughts = list.map(_toThought).whereType<_Thought>().toList();
      setState(() {
        if (reset) {
          _thoughts
            ..clear()
            ..addAll(thoughts);
        } else {
          _thoughts.addAll(thoughts);
        }
        _hasMore = hasMore;
        _page += 1;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (reset) {
          _error = e is CloudApiException
              ? e.message
              : (e.toString().replaceFirst('Exception: ', ''));
        }
      });
    }
  }

  Future<void> _toggleLike(_Thought t) async {
    try {
      final (liked, count) =
          await CloudNotesService.instance.toggleLike(t.noteId);
      if (!mounted) return;
      setState(() {
        final idx = _thoughts.indexWhere((x) => x.noteId == t.noteId);
        if (idx >= 0) {
          final updated = t.note.copyWith(likeCount: count);
          _thoughts[idx] = _Thought(
            note: updated,
            noteId: t.noteId,
            text: t.text,
            title: t.title,
          );
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  void _openDetail(_Thought t) {
    if (t.noteId.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: t.noteId)),
    );
  }

  void _close() {
    Navigator.of(context).pop();
  }

  String _formatTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24 && t.day == now.day) return '${diff.inHours}小时前';
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final dayDiff = today.difference(day).inDays;
    if (dayDiff == 1) return '昨天';
    if (dayDiff == 2) return '前天';
    if (t.year == now.year) return '${t.month}月${t.day}日';
    return '${t.year}年${t.month}月${t.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final headerHeight = kToolbarHeight * 0.9;

    return Material(
      color: p.card,
      borderRadius:
          const BorderRadius.vertical(top: Radius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // 顶部把手 / 标题栏（可点击关闭）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
            child: SizedBox(
              height: headerHeight,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppPalette.p.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                      '${widget.sutraTitle} · 想法',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, thickness: 1, color: AppPalette.p.border),
            Expanded(child: SafeArea(top: false, child: _buildBody())),
          ],
        ),
    );
  }

  Widget _buildBody() {
    final p = AppPalette.p;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 40, color: p.textHint),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: p.textSec)),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _loadPage(reset: true),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_thoughts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_stories_outlined, size: 40, color: p.textHint),
              const SizedBox(height: 12),
              Text(
                '还没有同修分享这段经文的想法\n点击段落旁的「AI译」旁按钮即可记录并分享',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.6, color: p.textSec),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      itemCount: _thoughts.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) => Divider(
          height: 16, thickness: 1, color: AppPalette.p.border),
      itemBuilder: (context, i) {
        if (i >= _thoughts.length) {
          if (_loadingMore) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: TextButton(
                onPressed: _loadPage,
                child: const Text('加载更多'),
              ),
            ),
          );
        }
        return _buildThoughtCard(_thoughts[i]);
      },
    );
  }

  Widget _buildThoughtCard(_Thought t) {
    final p = AppPalette.p;
    final liked = CloudNotesService.instance.likedNoteIds.contains(t.noteId);
    final title = t.title.isNotEmpty ? t.title : widget.sutraTitle;
    return InkWell(
      onTap: () => _openDetail(t),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              UserAvatar(userId: t.note.ownerUserId, radius: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        t.note.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: p.text),
                      ),
                    ),
                    if (t.note.authorVerified) ...[
                      const SizedBox(width: 3),
                      const Icon(Icons.verified,
                          size: 13, color: Color(0xFF70867A)),
                    ],
                    if (t.note.authorAccount.isNotEmpty) ...[
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          '@${t.note.authorAccount}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: p.textSec),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _formatTime(t.note.createdAt),
                style: TextStyle(fontSize: 11, color: p.textHint),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 经名小标签
          Text(
            '\$$title',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.accent),
          ),
          const SizedBox(height: 4),
          Text(
            t.text,
            style: TextStyle(
                fontSize: 14, height: 1.6, color: p.text),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // 点赞
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _toggleLike(t),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      liked ? Icons.favorite : Icons.favorite_border,
                      size: 16,
                      color: liked ? const Color(0xFFE0506D) : p.textHint,
                    ),
                    if (t.note.likeCount > 0) ...[
                      const SizedBox(width: 3),
                      Text(
                        '${t.note.likeCount}',
                        style: TextStyle(
                            fontSize: 12, color: p.textHint),
                      ),
                    ],
                  ],
                ),
              ),
              const Spacer(),
              Text(
                '查看详情',
                style: TextStyle(
                    fontSize: 12,
                    color: p.accent,
                    fontWeight: FontWeight.w500),
              ),
              Icon(Icons.chevron_right, size: 16, color: p.textHint),
            ],
          ),
        ],
      ),
    );
  }
}
