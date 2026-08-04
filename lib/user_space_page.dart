import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'my_page.dart';
import 'note_detail_page.dart';
import 'reply_chain.dart';
import 'text_input_sheet.dart';
import 'user_avatar.dart';

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
  int _tab = 0;
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;
  String _profileTagline = '';
  int _profileJoinTime = 0;
  late bool _following =
      CloudNotesService.instance.followingUserIds.contains(widget.userId);

  /// 对方账号（从已加载的笔记中取，用于「屏蔽@账号」等展示）。
  String get _account => _notes.isNotEmpty ? _notes.first.authorAccount : '';

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
    final label =
        blocked ? '取消屏蔽' : (account.isNotEmpty ? '屏蔽@$account' : '屏蔽该用户');
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
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            const Divider(height: 1, color: _border),
            InkWell(
              onTap: () => Navigator.pop(ctx, 'block'),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                child: Row(
                  children: [
                    const Icon(Icons.block_outlined, size: 18, color: _textSec),
                    const SizedBox(width: 12),
                    Text(label,
                        style: const TextStyle(fontSize: 15, color: _text)),
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
      // 签名/加入时间：查看自己主页时用本地数据；他人用 getUserProfiles。
      String tagline = '';
      int joinTime = 0;
      final me = AuthService.instance.currentUser.value;
      if (me != null && me.id == widget.userId) {
        try {
          final prefs = await SharedPreferences.getInstance();
          tagline = prefs.getString('user_tagline') ?? '与经为伴，与法同行';
          joinTime = prefs.getInt('user_created_at') ?? 0;
        } catch (_) {}
      } else {
        try {
          final profiles =
              await CloudNotesService.instance.getUserProfiles([widget.userId]);
          if (profiles.isNotEmpty) {
            tagline = profiles.first.tagline;
            joinTime = profiles.first.joinTime;
          }
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _notes
          ..clear()
          ..addAll(list);
        _profileTagline = tagline;
        _profileJoinTime = joinTime;
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
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverToBoxAdapter(child: _buildHeader()),
          // 帖子/回复 tab 吸顶：滚动时横幅/头像上移，tab 钉在顶部。
          SliverPersistentHeader(
            pinned: true,
            delegate: _UserTabsDelegate(
              tab: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
          ),
        ],
        body: _buildBody(),
      ),
    );
  }

  /// 与「我的菜单页」同款头部：横幅 + 大头像 + 昵称/认证/@账户。
  /// 自己主页没有关注按钮与编辑资料；他人主页有关注按钮（70867A）。
  Widget _buildHeader() {
    final following = _following;
    final me = AuthService.instance.currentUser.value;
    final isSelf = me != null && me.id == widget.userId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 226,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 顶部横幅（他人无本地横幅，用默认渐变占位）。
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 160,
                child: Container(
                  width: double.infinity,
                  height: 160,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFFD2C5B3), Color(0xFFC6B79E)],
                    ),
                  ),
                ),
              ),
              // 返回按钮。
              Positioned(
                left: 4,
                top: 0,
                child: SafeArea(
                  child: IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_ios_new,
                        color: _text, size: 20),
                  ),
                ),
              ),
              // 屏蔽三点 + 关注按钮（横幅下缘右侧，他人主页才有关注）。
              Positioned(
                right: 16,
                top: 168,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                    const SizedBox(width: 8),
                    if (!isSelf)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _toggleFollow,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            color: following
                                ? const Color(0xFFBDB6AC)
                                : const Color(0xFF70867A),
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
              ),
              // 大头像（重叠在横幅下缘）。
              Positioned(
                left: 20,
                top: 122,
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _card,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 12,
                          offset: const Offset(0, 2)),
                    ],
                  ),
                  child: ClipOval(
                    child: UserAvatar(userId: widget.userId, radius: 38),
                  ),
                ),
              ),
            ],
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(widget.userName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: _text)),
                    ),
                    if (_verified) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.verified,
                          size: 17, color: Color(0xFF70867A)),
                    ],
                  ],
                ),
                if (_account.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('@$_account',
                      style: const TextStyle(fontSize: 13, color: _textHint)),
                ],
                // 签名与加入时间（服务端返回则展示，让其他用户可见该用户信息）。
                if (_profileTagline.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(_profileTagline,
                      style: const TextStyle(
                          fontSize: 14, color: _textSec, height: 1.4)),
                ],
                if (_profileJoinTime > 0) ...[
                  const SizedBox(height: 4),
                  Text('${_joinDateText(_profileJoinTime)}加入',
                      style: const TextStyle(fontSize: 12, color: _textHint)),
                ],
              ],
            ),
          ),
        ),
      ],
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
    return _tab == 0 ? _buildPostsTab() : _buildRepliesTab();
  }

  List<PlazaNote> get _posts =>
      _notes.where((n) => n.repostKind != 'reply').toList();

  List<PlazaNote> get _replies =>
      _notes.where((n) => n.repostKind == 'reply').toList();

  /// 帖子 Tab：自己的帖子 + 转发（引用转发），与「我的菜单页 → 帖子」同款样式。
  Widget _buildPostsTab() {
    final posts = _posts;
    if (posts.isEmpty) {
      return const Center(
        child: Text('还没有帖子', style: TextStyle(fontSize: 14, color: _textHint)),
      );
    }
    return RefreshIndicator(
      color: _gold,
      onRefresh: _load,
      child: _buildScrollListener(
        ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
          itemCount: posts.length,
          itemBuilder: (context, index) => _buildNoteRow(posts[index], posts),
        ),
      ),
    );
  }

  /// 回复 Tab：按原贴分组，原贴一次 + 头像连线串起所有回复（与「我的菜单页 → 回复」一致）。
  Widget _buildRepliesTab() {
    final replies = _replies;
    if (replies.isEmpty) {
      return const Center(
        child: Text('还没有回复', style: TextStyle(fontSize: 14, color: _textHint)),
      );
    }
    final groups = _buildReplyGroups(replies);
    return RefreshIndicator(
      color: _gold,
      onRefresh: _load,
      child: _buildScrollListener(
        ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
          itemCount: groups.length,
          itemBuilder: (context, index) {
            final g = groups[index];
            return _buildReplyGroupCard(g.$1, g.$2);
          },
        ),
      ),
    );
  }

  /// 滚动到底部时自动加载下一页。
  Widget _buildScrollListener(Widget child) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
          _loadMore();
        }
        return false;
      },
      child: child,
    );
  }

  /// 按最顶层原贴分组：非回复为根，回复（含回复的回复）递归挂到父帖下。
  List<(PlazaNote, List<PlazaNote>)> _buildReplyGroups(
      List<PlazaNote> replies) {
    final byId = {for (final n in replies) n.id: n};
    final children = <String, List<PlazaNote>>{};
    final roots = <PlazaNote>[];
    for (final n in replies) {
      if (byId.containsKey(n.repostOf)) {
        children.putIfAbsent(n.repostOf, () => []).add(n);
      } else {
        roots.add(n);
      }
    }
    List<PlazaNote> collect(PlazaNote node) {
      final subs = children[node.id] ?? const <PlazaNote>[];
      return [
        for (final c in subs) c,
        for (final c in subs) ...collect(c),
      ];
    }

    return [
      for (final r in roots) (r, collect(r)),
    ];
  }

  Widget _buildNoteRow(PlazaNote note, List<PlazaNote> all) {
    final me = AuthService.instance.currentUser.value;
    final isMine = me != null && note.ownerUserId == me.id;
    return PostFeedRow(
      note: note,
      onReplyPosted: _load,
      onTap: () => _openNote(note),
      onEdit: isMine ? () => _editOwnNote(note) : null,
      onDelete: isMine ? () => _deleteOwnNote(note) : null,
      onMore: (n) => _showNoteMenu(n),
      showFollowButton: false,
    );
  }

  /// 回复分组卡片：根帖在上 + 头像连线 + 其下回复链。
  Widget _buildReplyGroupCard(PlazaNote root, List<PlazaNote> replies) {
    final rootWidget = _buildNoteRow(root, _notes);
    if (replies.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: rootWidget,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 21,
              top: 62,
              bottom: 0,
              child: Container(width: 1, color: const Color(0xFFC9C9C9)),
            ),
            rootWidget,
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 6),
          child: ReplyChain(
            replies: replies,
            parentAccounts: {
              root.id: root.authorAccount,
              for (final r in replies) r.id: r.authorAccount,
            },
            onComment: (n) => replyToNote(context, n, _load),
            onLike: (n) => likeTargetNote(context, n, _load),
            onRepost: (n) => forwardNote(context, n, _load),
            onMore: (n) => _showNoteMenu(n),
          ),
        ),
      ],
    );
  }

  /// 笔记三点菜单：自己的显示编辑/删除，他人显示关注/屏蔽。
  Future<void> _showNoteMenu(PlazaNote note) async {
    final me = AuthService.instance.currentUser.value;
    if (me == null || note.ownerUserId != me.id) {
      if (me != null && note.ownerUserId.isNotEmpty) {
        await showMoreMenu(context, note.ownerUserId, note.authorName);
      }
      return;
    }
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
              child: Text(note.authorName,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            const Divider(height: 1, color: _border),
            postMenuItem(ctx, 'edit', Icons.edit_outlined, '编辑'),
            postMenuItem(ctx, 'delete', Icons.delete_outline, '删除'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'edit') {
      _editOwnNote(note);
    } else if (choice == 'delete') {
      _deleteOwnNote(note);
    }
  }

  Future<void> _editOwnNote(PlazaNote note) async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SheetTextInput(
        title: '编辑帖子',
        hint: '写下新的内容…',
        initialText: note.content,
        maxLength: 2000,
        minLines: 3,
        maxLines: 6,
        confirmText: '保存',
      ),
    );
    if (saved == null || saved.trim().isEmpty || !mounted) return;
    try {
      await CloudNotesService.instance
          .updateSharedNote(cloudId: note.id, content: saved.trim());
      if (!mounted) return;
      _showToast(context, '已更新');
      _load();
    } catch (e) {
      if (mounted) _showToast(context, e.toString());
    }
  }

  Future<void> _deleteOwnNote(PlazaNote note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除帖子',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: const Text('删除后帖子将从菩提空间移除，且无法恢复。确定删除吗？',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: _textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除',
                style: TextStyle(
                    color: Color(0xFFC0392B), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await CloudNotesService.instance.deleteCloudNote(note.id);
      if (!mounted) return;
      setState(() => _notes.removeWhere((n) => n.id == note.id));
      _showToast(context, '已删除');
    } catch (e) {
      if (mounted) _showToast(context, e.toString());
    }
  }

  /// 加入时间格式：x年x月x日。
  String _joinDateText(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.year}年${t.month}月${t.day}日';
  }

  void _openNote(PlazaNote note) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)),
    ).then((_) {
      if (mounted) _load();
    });
  }
}

/// 用户主页的「帖子/回复」吸顶 tab。
class _UserTabsDelegate extends SliverPersistentHeaderDelegate {
  final int tab;
  final ValueChanged<int> onChanged;
  static const double _height = 46;
  const _UserTabsDelegate({required this.tab, required this.onChanged});

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return ColoredBox(
      color: _bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (final (i, label) in const [(0, '帖子'), (1, '回复')])
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight:
                                tab == i ? FontWeight.w600 : FontWeight.w400,
                            color: tab == i ? _text : _textSec,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Container(
                          width: 36,
                          height: 3,
                          decoration: BoxDecoration(
                            color: tab == i ? _gold : Colors.transparent,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _UserTabsDelegate oldDelegate) =>
      oldDelegate.tab != tab;
}
