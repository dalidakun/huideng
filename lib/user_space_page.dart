import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'note_sutra_links.dart';
import 'reply_thread.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _primary = Color(0xFF5C4033);
const Color _primaryLight = Color(0xFF8B6B5A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _border = Color(0xFFEBE1D6);

/// 某位用户的菩提空间：展示对方公开发布的所有笔记（含转发），点击可查看评论/点赞等。
class UserSpacePage extends StatefulWidget {
  final String userId;
  final String userName;

  const UserSpacePage({
    super.key,
    required this.userId,
    this.userName = '同修',
  });

  @override
  State<UserSpacePage> createState() => _UserSpacePageState();
}

class _UserSpacePageState extends State<UserSpacePage> {
  final List<PlazaNote> _notes = [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;
  late bool _following =
      CloudNotesService.instance.followingUserIds.contains(widget.userId);

  /// 对方账号（从已加载的笔记中取，用于「屏蔽@账号」等展示）。
  String get _account =>
      _notes.isNotEmpty ? _notes.first.authorAccount : '';

  /// 对方是否已实名认证（从已加载的笔记中取）。
  bool get _verified => _notes.isNotEmpty && _notes.first.authorVerified;

  /// 关注/取消关注对方（已关注的同修在首页「关注」栏目展示其新帖）。
  Future<void> _toggleFollow() async {
    final me = AuthService.instance.currentUser.value;
    if (me == null || me.id == widget.userId) return;
    try {
      final ok = await CloudNotesService.instance.toggleFollow(widget.userId);
      if (!mounted) return;
      setState(() => _following = ok);
      _showToast(context, ok ? '已关注' : '已取消关注');
    } catch (e) {
      if (mounted) _showToast(context, e.toString());
    }
  }

  /// 屏蔽/取消屏蔽对方：屏蔽后对方的帖子不再出现在修学主页菩提空间的推荐/最新等栏目。
  Future<void> _showBlockSheet() async {
    final me = AuthService.instance.currentUser.value;
    if (me == null || me.id == widget.userId) return;
    final blocked =
        CloudNotesService.instance.blockedUserIds.contains(widget.userId);
    final account = _account;
    final label = blocked
        ? '取消屏蔽'
        : (account.isNotEmpty ? '屏蔽@$account' : '屏蔽该用户');
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text(widget.userName,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: _text)),
            ),
            const Divider(height: 1, color: _border),
            InkWell(
              onTap: () => Navigator.pop(ctx, 'block'),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                child: Row(
                  children: [
                    const Icon(Icons.block_outlined,
                        size: 18, color: _textSec),
                    const SizedBox(width: 12),
                    Text(label,
                        style: const TextStyle(
                            fontSize: 15, color: _text)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice != 'block' || !mounted) return;
    try {
      final ok =
          await CloudNotesService.instance.toggleBlockUser(widget.userId);
      if (!mounted) return;
      setState(() {});
      _showToast(context, ok ? '已屏蔽，该用户笔记不再展示' : '已取消屏蔽');
    } catch (e) {
      if (mounted) _showToast(context, e.toString());
    }
  }

  void _showToast(BuildContext context, String text) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final topInset = MediaQuery.of(ctx).padding.top;
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: EdgeInsets.only(top: topInset + kToolbarHeight + 10),
            child: Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: _text,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (entry.mounted) entry.remove();
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _hasMore = true;
      _page = 0;
    });
    try {
      final (list, hasMore) =
          await CloudNotesService.instance.getUserNotes(widget.userId, page: 1);
      if (!mounted) return;
      setState(() {
        _notes
          ..clear()
          ..addAll(list);
        _page = 1;
        _hasMore = hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final (list, hasMore) = await CloudNotesService.instance
          .getUserNotes(widget.userId, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _notes.addAll(list);
        _page += 1;
        _hasMore = hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final following = _following;
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF3E8DB), Color(0xFFF9F1E7)],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 20, 18),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_ios_new,
                        color: _text, size: 20),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${widget.userName} 的菩提空间',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          color: _text),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(width: 14),
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: _primary.withValues(alpha: 0.10),
                    child:
                        const Icon(Icons.person, size: 24, color: _primaryLight),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(widget.userName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: _text)),
                            ),
                            if (_verified) ...[
                              const SizedBox(width: 4),
                              const Icon(Icons.verified,
                                  size: 14, color: Color(0xFF70867A)),
                            ],
                          ],
                        ),
                        if (_account.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text('@$_account',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF8C8C8C))),
                        ],
                      ],
                    ),
                  ),
                  // 三个横向点点（圆圈裹住）
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _showBlockSheet,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.3),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.more_horiz,
                          size: 18, color: _text),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 关注按钮
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleFollow,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: following
                            ? const Color(0xFFBDB6AC)
                            : Colors.black,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(following ? '已关注' : '关注',
                          style: const TextStyle(
                              fontSize: 13,
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (_notes.isEmpty) {
      return RefreshIndicator(
        color: _gold,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 32),
              child: Column(
                children: [
                  Icon(Icons.spa_outlined,
                      size: 48, color: _textHint.withValues(alpha: 0.6)),
                  const SizedBox(height: 14),
                  const Text('还没有公开分享',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _text)),
                  const SizedBox(height: 6),
                  Text('${widget.userName} 暂未公开发布笔记',
                      style: const TextStyle(fontSize: 13, color: _textSec)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: _gold,
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
        itemCount: _notes.length + 1,
        itemBuilder: (context, index) {
          if (index == _notes.length) {
            if (!_hasMore) return const SizedBox(height: 16);
            WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
            return const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: _gold),
                ),
              ),
            );
          }
          return _buildNoteTile(_notes[index]);
        },
      ),
    );
  }

  Widget _buildNoteTile(PlazaNote note) {
    // 回复帖：渲染成连贴样式。
    if (note.repostKind == 'reply') {
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2)),
          ],
        ),
        padding: const EdgeInsets.all(12),
        child: ReplyThread(replyNote: note),
      );
    }
    final content = NoteSutraLinks.plainText(note.content);
    final preview = note.quoteContent.isNotEmpty
        ? (content.isEmpty ? '转发自同修的笔记' : content)
        : content;
    final text = preview.length > 60 ? '${preview.substring(0, 60)}...' : preview;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openNote(note),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (note.repostOf.isNotEmpty && note.repostKind != 'reply') ...[
                Row(
                  children: [
                    Icon(Icons.repeat, size: 12, color: _gold),
                    const SizedBox(width: 2),
                    Text(note.quoteContent.isNotEmpty ? '引用' : '转发',
                        style: const TextStyle(
                            fontSize: 11, color: _gold)),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              if (text.isNotEmpty)
                Text(
                  text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, color: _textSec, height: 1.5),
                ),
              if (note.repostOf.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _bg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('@${note.repostSourceAuthor} 的笔记',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: _textSec)),
                      const SizedBox(height: 3),
                      Text(
                        NoteSutraLinks.plainText(
                            note.quoteOfContent.isNotEmpty
                                ? note.quoteOfContent
                                : note.content),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: _textSec, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  if (note.authorAccount.isNotEmpty) ...[
                    Flexible(
                      child: Text('@${note.authorAccount}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF8C8C8C))),
                    ),
                    const SizedBox(width: 3),
                    Text('·',
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFF8C8C8C))),
                    const SizedBox(width: 2),
                  ],
                  Icon(Icons.schedule, size: 13, color: Color(0xFF8C8C8C)),
                  const SizedBox(width: 2),
                  Text(_formatTime(note.createdAt),
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFF8C8C8C))),
                  const Spacer(),
                  Icon(Icons.mode_comment_outlined,
                      size: 12, color: _textHint),
                  const SizedBox(width: 3),
                  Text('${note.commentCount}',
                      style: const TextStyle(fontSize: 12, color: _textHint)),
                  const SizedBox(width: 10),
                  Icon(Icons.favorite_border, size: 12, color: _textHint),
                  const SizedBox(width: 3),
                  Text('${note.likeCount}',
                      style: const TextStyle(fontSize: 12, color: _textHint)),
                  const SizedBox(width: 10),
                  Icon(Icons.visibility_outlined,
                      size: 12, color: _textHint),
                  const SizedBox(width: 3),
                  Text('${note.viewCount}',
                      style: const TextStyle(fontSize: 12, color: _textHint)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openNote(PlazaNote note) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)),
    ).then((_) {
      if (mounted) _load();
    });
  }

  String _formatTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) {
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    if (diff == 1) return '昨天';
    if (t.year == now.year) return '${t.month}月${t.day}日';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}
