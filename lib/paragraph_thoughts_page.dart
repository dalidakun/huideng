import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'reading_badges.dart';
import 'reading_note_post.dart';
import 'user_avatar.dart';

/// 单条想法的展示数据（兼容云端已分享想法与本地未分享想法）。
class _Thought {
  /// 云端想法 id；本地想法（未分享）为空串，表示不可点赞。
  final String noteId;
  final String text;
  final String authorUserId;
  final String authorName;
  final bool authorVerified;
  final String authorAccount;
  final int canonRead;
  final int canonTotal;
  final int likeCount;
  final int createdAt;

  const _Thought({
    required this.noteId,
    required this.text,
    required this.authorUserId,
    required this.authorName,
    this.authorVerified = false,
    this.authorAccount = '',
    this.canonRead = 0,
    this.canonTotal = 0,
    this.likeCount = 0,
    this.createdAt = 0,
  });

  factory _Thought.fromPlaza(PlazaNote n, String text) => _Thought(
        noteId: n.id,
        text: text,
        authorUserId: n.ownerUserId,
        authorName: n.authorName,
        authorVerified: n.authorVerified,
        authorAccount: n.authorAccount,
        canonRead: n.canonRead,
        canonTotal: n.canonTotal,
        likeCount: n.likeCount,
        createdAt: n.createdAt,
      );
}

/// 「段落想法」汇总底部弹层：列出该段经文下所有用户分享的想法，
/// 并附带当前用户自己在本段记录的想法（无论是否分享到菩提空间）。
///
/// 打开时从底部向上滑出，顶部只停在标题栏下方一个标题栏高度的位置
/// （`顶部安全区 + 2 倍标题栏高度`），且路由透明白色不遮挡：
/// 上方的经文仍清晰可见，也不会出现黑色蒙层。
/// 每个想法展示：头像 + 昵称/认证/@账户 + 阅藏百分比 + 想法正文（可折叠），
/// 只有一个「喜欢」指标，并按其数量从高到低排序。
class ParagraphThoughtsPage extends StatefulWidget {
  final String sutraTitle;
  final String paragraph;

  /// 经书 filePath（sutra key），用于拉取当前用户本段本地想法。
  final String sutraKey;

  /// 当前段落在本经中的下标，用于匹配本地想法。
  final int paragraphIndex;

  const ParagraphThoughtsPage({
    super.key,
    required this.sutraTitle,
    required this.paragraph,
    this.sutraKey = '',
    this.paragraphIndex = -1,
  });

  /// 打开该弹层时使用下滑渐显的过渡路由（底部抽屉效果）。
  /// 路由非不透明（opaque=false）、遮罩透明，顶部经文仍可见；
  /// 抽屉只占据到标题栏下方一个标题栏高度的位置。
  static Future<void> open(
    BuildContext context, {
    required String sutraTitle,
    required String paragraph,
    String sutraKey = '',
    int paragraphIndex = -1,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        barrierDismissible: true,
        pageBuilder: (_, __, ___) => ParagraphThoughtsPage(
          sutraTitle: sutraTitle,
          paragraph: paragraph,
          sutraKey: sutraKey,
          paragraphIndex: paragraphIndex,
        ),
        transitionsBuilder: (_, anim, __, child) {
          final topOffset =
              MediaQuery.of(context).padding.top + kToolbarHeight * 2;
          final full = MediaQuery.of(context).size.height;
          return Stack(
            children: [
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
                    child: DecoratedBox(
                      // 顶部阴影与 AI 翻译弹层一致：黑色 18% 透明度、上抛 4px。
                      decoration: const BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                            top: Radius.circular(18)),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x2E000000),
                            blurRadius: 16,
                            offset: Offset(0, -4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(18)),
                        child: child,
                      ),
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
  int _total = 0;
  String? _error;

  /// 当前用户自己的昵称/账号/认证（为本地未分享想法渲染用）。
  String _myName = '同修';
  String _myAccount = '';
  bool _myVerified = false;

  /// 折叠状态：key 为想法正文，true 表示展开全文。
  final Set<String> _expanded = {};

  /// 本地（未分享）想法的本地点赞状态：key 为想法正文。
  final Map<String, bool> _myLocalLiked = {};

  /// 下拉关闭：手指向下拖动的距离。
  double _dragY = 0;

  @override
  void initState() {
    super.initState();
    _initSelf();
    _loadPage(reset: true);
  }

  Future<void> _initSelf() async {
    final me = AuthService.instance.currentUser.value;
    if (me == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _myName = me.displayName;
        _myAccount = prefs.getString('user_account_name') ?? '';
        _myVerified = prefs.getBool('user_verified') ?? false;
      });
    } catch (_) {}
  }

  /// 解析读经笔记帖，仅保留「段原文」与当前段落一致的帖子。
  _Thought? _toThought(PlazaNote n) {
    final parsed = ReadingNotePost.parse(n.content);
    if (parsed == null || parsed.paragraph.trim() != widget.paragraph.trim()) {
      return null;
    }
    return _Thought.fromPlaza(
      n,
      parsed.noteText.isNotEmpty ? parsed.noteText : parsed.paragraph,
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
      final (list, hasMore, total) = await CloudNotesService.instance
          .getParagraphThoughts(widget.paragraph, page: _page, pageSize: 20);
      final thoughts = list.map(_toThought).whereType<_Thought>().toList();

      // 把当前用户自己在本段记录的想法（无论是否分享）合并进来，
      // 避免出现「已经记录却不在本页显示」。
      final ownNote = await _findOwnNoteText();
      if (!mounted) return;

      setState(() {
        if (reset) {
          _thoughts
            ..clear()
            ..addAll(thoughts);
        } else {
          _thoughts.addAll(thoughts);
        }
        if (ownNote != null) {
          _mergeOwnThought(ownNote.$1, ownNote.$2, ownNote.$3);
        }
        _hasMore = hasMore;
        _total = total + (ownNote != null ? 1 : 0);
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

  /// 拉取当前用户在本段的本地想法（正文 + 更新时间 + 云端分享 id）；
  /// 没有则返回 null。cloudId 非空表示该想法已分享，可用于点赞。
  Future<(String, int, String)?> _findOwnNoteText() async {
    if (widget.sutraKey.isEmpty || widget.paragraphIndex < 0) return null;
    if (AuthService.instance.cachedUserId == null) return null;
    try {
      final items =
          await CloudNotesService.instance.getParagraphNotes(widget.sutraKey);
      for (final it in items) {
        final idx = it['index'];
        if (idx is int && idx == widget.paragraphIndex) {
          final note = (it['note'] ?? '').toString().trim();
          if (note.isNotEmpty) {
            final updatedAt = (it['updatedAt'] as num?)?.toInt() ?? 0;
            final cloudId = (it['cloudId'] ?? '').toString();
            return (note, updatedAt, cloudId);
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// 把当前用户自己的想法合并进列表；若内容与云端已展示的重复则跳过。
  void _mergeOwnThought(String text, int createdAt, String noteId) {
    final me = AuthService.instance.currentUser.value;
    if (me == null) return;
    final already = _thoughts.any((t) =>
        t.authorUserId == me.id &&
        t.text.replaceAll(RegExp(r'\s'), '') ==
            text.replaceAll(RegExp(r'\s'), ''));
    if (already) return;
    _thoughts.add(_Thought(
      noteId: noteId,
      text: text,
      authorUserId: me.id,
      authorName: _myName,
      authorVerified: _myVerified,
      authorAccount: _myAccount,
      canonRead: LocalCanonProgress.read,
      canonTotal: LocalCanonProgress.total,
      createdAt: createdAt,
    ));
  }

  /// 是否已喜欢：云端想法看全局已赞集合，本地（未分享）想法看本地点赞状态。
  bool _isLiked(_Thought t) {
    if (t.noteId.isNotEmpty) {
      return CloudNotesService.instance.likedNoteIds.contains(t.noteId);
    }
    return _myLocalLiked[t.text] ?? false;
  }

  /// 有效喜欢数：本地（未分享）想法在本地点赞时 +1。
  int _effectiveLikeCount(_Thought t) {
    if (t.noteId.isEmpty && (_myLocalLiked[t.text] ?? false)) {
      return t.likeCount + 1;
    }
    return t.likeCount;
  }

  Future<void> _toggleLike(_Thought t) async {
    // 本地（未分享）想法：本地点赞，即时生效并增加数量。
    if (t.noteId.isEmpty) {
      setState(() {
        _myLocalLiked[t.text] = !(_myLocalLiked[t.text] ?? false);
        _thoughts.sort(
            (a, b) => _effectiveLikeCount(b).compareTo(_effectiveLikeCount(a)));
      });
      return;
    }
    try {
      final (liked, count) =
          await CloudNotesService.instance.toggleLike(t.noteId);
      if (!mounted) return;
      setState(() {
        final idx = _thoughts.indexWhere((x) => x.noteId == t.noteId);
        if (idx >= 0) {
          final cur = _thoughts[idx];
          _thoughts[idx] = _Thought(
            noteId: cur.noteId,
            text: cur.text,
            authorUserId: cur.authorUserId,
            authorName: cur.authorName,
            authorVerified: cur.authorVerified,
            authorAccount: cur.authorAccount,
            canonRead: cur.canonRead,
            canonTotal: cur.canonTotal,
            likeCount: count,
            createdAt: cur.createdAt,
          );
          _thoughts.sort((a, b) => b.likeCount.compareTo(a.likeCount));
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
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

  void _onVerticalDragStart(DragStartDetails d) {
    _dragY = 0;
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    // 仅向下拖动生效（向上不跟随），避免与列表滚动冲突。
    final next = _dragY + d.delta.dy;
    setState(() => _dragY = next < 0 ? 0 : next);
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    if (_dragY > 120 || velocity > 600) {
      _close();
      return;
    }
    setState(() => _dragY = 0);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final headerHeight = kToolbarHeight * 0.9;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: _onVerticalDragStart,
      onVerticalDragUpdate: _onVerticalDragUpdate,
      onVerticalDragEnd: _onVerticalDragEnd,
      onVerticalDragCancel: () => setState(() => _dragY = 0),
      child: Transform.translate(
        offset: Offset(0, _dragY),
        child: Material(
          color: p.card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
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
                        '本段所有想法·$_total条',
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
        ),
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
                '还没有同修记录想法。\n选择文字，记录想法。',
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
      separatorBuilder: (_, __) =>
          Divider(height: 16, thickness: 1, color: AppPalette.p.border),
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
    final liked = _isLiked(t);
    final likeCount = _effectiveLikeCount(t);

    final cachedUid = AuthService.instance.cachedUserId;
    final isSelf = cachedUid != null && t.authorUserId == cachedUid;
    final postPct = postCanonPercent(
      isSelf: isSelf,
      cloudRead: t.canonRead,
      cloudTotal: t.canonTotal,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UserAvatar(userId: t.authorUserId, radius: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 用户信息（一行，与主页帖子同款）：昵称 + 认证 + @账户 · 阅藏百分比
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        t.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: p.text,
                        ),
                      ),
                    ),
                    if (t.authorVerified) ...[
                      const SizedBox(width: 3),
                      const Icon(Icons.verified,
                          size: 14, color: Color(0xFF70867A)),
                    ],
                    if (t.authorAccount.isNotEmpty) ...[
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          '@${t.authorAccount}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: p.textSec),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Text('·',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF8C8C8C))),
                      const SizedBox(width: 2),
                      Text(
                        postPct,
                        maxLines: 1,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF8C8C8C)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                // 想法正文：与昵称左对齐（同在右侧列）
                _buildCollapsibleText(t.text),
                const SizedBox(height: 8),
                // 底部一行：时间戳在左侧，喜欢在右侧，二者不相邻。
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _formatTime(t.createdAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: p.textHint),
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _toggleLike(t),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            liked ? Icons.favorite : Icons.favorite_border,
                            size: 19,
                            color: liked
                                ? const Color(0xFF71867A)
                                : const Color(0xFFB0B0B0),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$likeCount',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color:
                                  liked ? const Color(0xFF71867A) : p.textSec,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 想法正文，超过 5 行可折叠；点击「显示更多/收起」切换展开。
  Widget _buildCollapsibleText(String text) {
    final p = AppPalette.p;
    final expanded = _expanded.contains(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          maxLines: expanded ? null : 5,
          overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, height: 1.6, color: p.text),
        ),
        if (text.length > 80) ...[
          const SizedBox(height: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() {
                if (expanded) {
                  _expanded.remove(text);
                } else {
                  _expanded.add(text);
                }
              });
            },
            child: Text(
              expanded ? '收起' : '显示更多',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: p.accent,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
