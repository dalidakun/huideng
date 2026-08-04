import 'dart:async';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'auth_service.dart';
import 'login_page.dart';
import 'note_detail_page.dart';
import 'notification_center.dart';
import 'user_avatar.dart';
import 'user_space_page.dart';

// ==================== 配色（浅色 / 深色） ====================

const Color _bgLight = Color(0xFFF5EDE3);
const Color _bgDark = Color(0xFF14100C);
const Color _cardLight = Color(0xFFFFFAF5);
const Color _cardDark = Color(0xFF211B15);
const Color _textLight = Color(0xFF3E2723);
const Color _textDark = Color(0xFFEFE6DC);
const Color _textSecLight = Color(0xFF8B6B5A);
const Color _textSecDark = Color(0xFFB7A99A);
const Color _textHintLight = Color(0xFFC4B5A8);
const Color _textHintDark = Color(0xFF8A8177);
const Color _borderLight = Color(0xFFEBE1D6);
const Color _borderDark = Color(0xFF383129);
const Color _unreadTintLight = Color(0xFFF2E7D9);
const Color _unreadTintDark = Color(0xFF2C241B);
const Color _primary = Color(0xFF5C4033);
const Color _gold = Color(0xFFD4A06A);

/// 互动类型图标与配色（各类型用色不同，但保持统一视觉风格）。
class _TypeStyle {
  final IconData? icon;

  /// 使用资源图片作为图标时指定（如帖子默认评论图标 ic_comment.png）。
  final String? asset;
  final Color color;
  final String action;
  const _TypeStyle.icon(this.icon, this.color, this.action) : asset = null;
  const _TypeStyle.asset(this.asset, this.color, this.action) : icon = null;

  static const Map<String, _TypeStyle> _map = {
    'like_me': _TypeStyle.icon(Icons.favorite_rounded, Color(0xFFE08A8A), '点赞了你的帖子'),
    'reply': _TypeStyle.asset('assets/images/ic_comment.png', Color(0xFF71867A), '评论了你的帖子'),
    'comment_reply':
        _TypeStyle.icon(Icons.reply_rounded, Color(0xFF6F87A0), '回复了你的评论'),
    'repost_me': _TypeStyle.icon(Icons.repeat_rounded, Color(0xFFD4A06A), '转发了你的帖子'),
    'favorite_me': _TypeStyle.icon(Icons.bookmark_rounded, Color(0xFFC9A227), '收藏了你的帖子'),
    'follow_me': _TypeStyle.icon(Icons.person_add_alt_1_rounded, Color(0xFF5F8A85), '关注了你'),
    'mention': _TypeStyle.icon(Icons.alternate_email_rounded, Color(0xFF9B7FAE), '在评论中@了你'),
  };

  static _TypeStyle of(String type) =>
      _map[type] ??
      const _TypeStyle.icon(
          Icons.notifications_none, Color(0xFF8B6B5A), '与你互动了');
}

class _Palette {
  final Color bg;
  final Color card;
  final Color text;
  final Color textSec;
  final Color textHint;
  final Color border;
  final Color unreadTint;
  final bool dark;

  const _Palette({
    required this.bg,
    required this.card,
    required this.text,
    required this.textSec,
    required this.textHint,
    required this.border,
    required this.unreadTint,
    required this.dark,
  });

  static _Palette of(BuildContext context) {
    final dark = appDarkMode.value;
    return dark
        ? const _Palette(
            bg: _bgDark,
            card: _cardDark,
            text: _textDark,
            textSec: _textSecDark,
            textHint: _textHintDark,
            border: _borderDark,
            unreadTint: _unreadTintDark,
            dark: true,
          )
        : const _Palette(
            bg: _bgLight,
            card: _cardLight,
            text: _textLight,
            textSec: _textSecLight,
            textHint: _textHintLight,
            border: _borderLight,
            unreadTint: _unreadTintLight,
            dark: false,
          );
  }
}

// ==================== 页面 ====================

/// 消息页：展示其他用户与「我」的所有互动（点赞/评论/回复/转发/收藏/关注/@提及）。
/// Feed 流式列表 + 同帖同类型自动聚合 + 头像堆叠 + 未读状态。
class MessagePage extends StatefulWidget {
  /// 左上角头像点击回调：打开「我的」页面。
  final VoidCallback? onOpenMyPage;

  /// 当前底部 Tab 索引（切到本页时播放淡入动画）。
  final ValueNotifier<int>? activeTab;

  const MessagePage({super.key, this.onOpenMyPage, this.activeTab});

  @override
  State<MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends State<MessagePage> with TickerProviderStateMixin {
  final List<NotificationGroup> _groups = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 0;
  bool _error = false;

  late final AnimationController _pageFade =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 380))
        ..forward();
  late final Animation<double> _pageFadeAnim =
      CurvedAnimation(parent: _pageFade, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    appDarkMode.addListener(_onExternalChanged);
    NotificationCenter.instance.unread.addListener(_onExternalChanged);
    AuthService.instance.currentUser.addListener(_onAuthChanged);
    widget.activeTab?.addListener(_onTabChanged);
    _load();
  }

  @override
  void dispose() {
    appDarkMode.removeListener(_onExternalChanged);
    NotificationCenter.instance.unread.removeListener(_onExternalChanged);
    AuthService.instance.currentUser.removeListener(_onAuthChanged);
    widget.activeTab?.removeListener(_onTabChanged);
    _pageFade.dispose();
    super.dispose();
  }

  void _onExternalChanged() {
    if (mounted) setState(() {});
  }

  void _onAuthChanged() {
    if (!mounted) return;
    if (!AuthService.instance.isLoggedIn) {
      setState(() {
        _groups.clear();
        _loading = false;
      });
    } else {
      _load();
    }
  }

  void _onTabChanged() {
    if (!mounted) return;
    if (widget.activeTab?.value == 3) {
      _pageFade.forward(from: 0);
      // 切回通知页时顺带刷新未读数。
      NotificationCenter.instance.refreshUnread();
    }
  }

  Future<void> _load() async {
    if (!AuthService.instance.isLoggedIn) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = false;
      _hasMore = true;
      _page = 0;
    });
    try {
      final (groups, hasMore) =
          await NotificationCenter.instance.fetchGroups(page: 1);
      if (!mounted) return;
      setState(() {
        _groups
          ..clear()
          ..addAll(groups);
        _page = 1;
        _hasMore = hasMore;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final (groups, hasMore) =
          await NotificationCenter.instance.fetchGroups(page: _page + 1);
      if (!mounted) return;
      setState(() {
        _groups.addAll(groups);
        _page += 1;
        _hasMore = hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  /// 静默刷新：不闪加载态，仅替换列表；从详情页返回/新增通知时从顶部插入。
  Future<void> _silentRefresh() async {
    if (!AuthService.instance.isLoggedIn) return;
    try {
      final (groups, hasMore) =
          await NotificationCenter.instance.fetchGroups(page: 1);
      if (!mounted) return;
      setState(() {
        _groups
          ..clear()
          ..addAll(groups);
        _page = 1;
        _hasMore = hasMore;
      });
    } catch (_) {}
  }

  Future<void> _markAllRead() async {
    try {
      await NotificationCenter.instance.markAllRead();
      if (!mounted) return;
      setState(() {
        for (final g in _groups) {
          g.hasUnread = false;
        }
      });
      _toast('已全部标记为已读');
    } catch (_) {
      if (mounted) _toast('操作失败，请重试');
    }
  }

  void _promptLogin() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  void _toast(String text) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.of(ctx).padding.top + kToolbarHeight + 10,
        left: 20,
        right: 20,
        child: IgnorePointer(
          child: Center(
            child: Material(
              color: _primary.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                child: Text(text,
                    style: const TextStyle(fontSize: 13, color: Colors.white)),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (entry.mounted) entry.remove();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = _Palette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: IconThemeData(color: p.text),
        title: Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Row(
            children: [
              GestureDetector(
                onTap: widget.onOpenMyPage,
                child: UserAvatar(
                  userId: AuthService.instance.currentUser.value?.id,
                  radius: 16,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '通知',
                style: TextStyle(
                  color: p.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                '·',
                style: TextStyle(
                  color: Color(0xFF9E9588),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '诸行无常，一切皆苦；诸法无我，寂灭为乐。',
                  style: TextStyle(
                    color: p.textHint,
                    fontSize: 10.5,
                  ),
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (NotificationCenter.instance.unread.value > 0)
            IconButton(
              tooltip: '全部已读',
              icon: Icon(Icons.mark_email_read_outlined,
                  color: const Color(0xFF71867A), size: 21),
              onPressed: _markAllRead,
            ),
          const SizedBox(width: 6),
        ],
      ),
      body: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.04, 0),
          end: Offset.zero,
        ).animate(_pageFadeAnim),
        child: FadeTransition(
          opacity: _pageFadeAnim,
          child: _buildBody(p),
        ),
      ),
    );
  }

  Widget _buildBody(_Palette p) {
    if (!AuthService.instance.isLoggedIn) {
      return _buildCentered(
        p,
        icon: Icons.lock_outline,
        title: '登录后查看互动通知',
        subtitle: '点赞、评论、转发、收藏、关注、@提及都会提醒你',
        buttonText: '去登录',
        onButton: _promptLogin,
      );
    }
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: _gold,
          backgroundColor: p.card,
        ),
      );
    }
    if (_error && _groups.isEmpty) {
      return _buildCentered(
        p,
        icon: Icons.wifi_off_outlined,
        title: '加载失败',
        subtitle: '网络似乎不太顺畅',
        buttonText: '重试',
        onButton: _load,
      );
    }
    if (_groups.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        color: _gold,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            _buildCentered(
              p,
              icon: Icons.notifications_none_rounded,
              title: '暂无通知',
              subtitle: '与其他同修的互动会显示在这里',
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: _gold,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        itemCount: _groups.length + 1,
        itemBuilder: (context, index) {
          if (index == _groups.length) {
            if (!_hasMore) return const SizedBox(height: 12);
            WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
            return const Padding(
              padding: EdgeInsets.all(18),
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
          final g = _groups[index];
          return _NotificationCard(
            key: ValueKey('${g.type}:${g.noteId}:${g.latestAt}'),
            group: g,
            palette: p,
            onTap: () => _openGroup(g),
            onLongPress: () => _showActions(g),
          );
        },
      ),
    );
  }

  Widget _buildCentered(
    _Palette p, {
    required IconData icon,
    required String title,
    String subtitle = '',
    String? buttonText,
    VoidCallback? onButton,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: p.textHint.withValues(alpha: 0.6)),
            const SizedBox(height: 14),
            Text(title,
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: p.text)),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: p.textSec)),
            ],
            if (buttonText != null && onButton != null) ...[
              const SizedBox(height: 18),
              FilledButton(
                onPressed: onButton,
                style: FilledButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 26, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22)),
                ),
                child: Text(buttonText,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ==================== 点击 / 长按行为 ====================

  Future<void> _openGroup(NotificationGroup g) async {
    // 用户真正查看该通知后才减少未读数（后台标记，不阻塞跳转）。
    if (g.hasUnread) {
      unawaited(
        NotificationCenter.instance.markGroupRead(g).catchError((_) {}),
      );
      g.hasUnread = false;
      if (mounted) setState(() {});
    }
    if (!mounted) return;
    if (g.type == 'follow_me') {
      if (g.actors.isNotEmpty) {
        final actor = g.actors.first;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                UserSpacePage(userId: actor.userId, userName: actor.name),
          ),
        );
        if (mounted) _silentRefresh();
      }
      return;
    }
    if (g.noteId.isEmpty) return;
    final scrollTo = (g.type == 'reply' ||
            g.type == 'comment_reply' ||
            g.type == 'mention' ||
            g.type == 'repost_me')
        ? g.commentId
        : null;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NoteDetailPage(
          noteId: g.noteId,
          scrollToReplyId: (scrollTo == null || scrollTo.isEmpty) ? null : scrollTo,
        ),
      ),
    );
    if (mounted) _silentRefresh();
  }

  /// 长按快捷操作：标记已读 / 删除 / 查看用户 / 查看帖子。
  Future<void> _showActions(NotificationGroup g) async {
    final p = _Palette.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: p.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
              child: Text(
                _typeLabel(g),
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: p.text),
              ),
            ),
            Divider(height: 1, color: p.border),
            if (g.hasUnread)
              _menuItem(ctx, 'read', Icons.done_all_rounded, '标记已读'),
            _menuItem(ctx, 'delete', Icons.delete_outline_rounded, '删除通知'),
            if (g.actors.isNotEmpty)
              _menuItem(ctx, 'user', Icons.person_outline_rounded, '查看用户'),
            if (g.noteId.isNotEmpty)
              _menuItem(ctx, 'post', Icons.article_outlined, '查看帖子'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'read':
        try {
          await NotificationCenter.instance.markGroupRead(g);
          if (!mounted) return;
          setState(() => g.hasUnread = false);
          _toast('已标记为已读');
        } catch (_) {
          if (mounted) _toast('操作失败，请重试');
        }
      case 'delete':
        try {
          await NotificationCenter.instance.deleteGroups([g]);
          if (!mounted) return;
          setState(() => _groups.remove(g));
        } catch (_) {
          if (mounted) _toast('删除失败，请重试');
        }
      case 'user':
        if (g.actors.isNotEmpty) {
          final actor = g.actors.first;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  UserSpacePage(userId: actor.userId, userName: actor.name),
            ),
          );
        }
      case 'post':
        if (g.noteId.isNotEmpty) {
          final scrollTo = (g.type == 'reply' ||
                  g.type == 'comment_reply' ||
                  g.type == 'mention' ||
                  g.type == 'repost_me')
              ? g.commentId
              : null;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => NoteDetailPage(
                noteId: g.noteId,
                scrollToReplyId:
                    (scrollTo == null || scrollTo.isEmpty) ? null : scrollTo,
              ),
            ),
          );
        }
    }
  }

  Widget _menuItem(BuildContext ctx, String value, IconData icon, String label) {
    final p = _Palette.of(context);
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 19, color: p.textSec),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(fontSize: 15, color: p.text)),
          ],
        ),
      ),
    );
  }

  String _typeLabel(NotificationGroup g) {
    final actors = g.actors;
    if (actors.isEmpty) return _TypeStyle.of(g.type).action;
    if (actors.length == 1) return '${actors.first.name} ${_TypeStyle.of(g.type).action}';
    return '${actors.take(2).map((a) => a.name).join('、')} 等 ${g.count} 人';
  }
}

// ==================== 通知卡片 ====================

class _NotificationCard extends StatefulWidget {
  final NotificationGroup group;
  final _Palette palette;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _NotificationCard({
    super.key,
    required this.group,
    required this.palette,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;

  late final AnimationController _enter = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420))
    ..forward();
  late final Animation<double> _enterAnim =
      CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic);

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final style = _TypeStyle.of(g.type);
    final p = widget.palette;
    final unread = g.hasUnread;

    return AnimatedBuilder(
      animation: _enter,
      builder: (context, child) {
        final t = _enterAnim.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, -18 * (1 - t)),
            child: child,
          ),
        );
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: unread ? p.unreadTint : p.card,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: p.dark ? 0.25 : 0.05),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 互动类型图标（评论用帖子默认评论图标，其余用 Material 图标）。
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: style.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: style.asset != null
                      ? Image.asset(style.asset!,
                          width: 18, height: 18, color: style.color)
                      : Icon(style.icon, size: 20, color: style.color),
                ),
                const SizedBox(width: 12),
                // 头像堆叠
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: _AvatarStack(
                    actors: g.actors,
                    palette: p,
                    expanded: _pressed,
                  ),
                ),
                const SizedBox(width: 12),
                // 内容
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _buildTitle(g, style, p),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                _formatTime(g.latestAt),
                                style: TextStyle(
                                    fontSize: 11, color: p.textHint),
                              ),
                              if (unread) ...[
                                const SizedBox(height: 4),
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF71867A),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                      if (g.noteContent.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          g.noteContent,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: unread ? p.textSec : p.textHint,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 通知正文：用户名加粗 + 动作文案；多人「Alice、Bob 等 26 人点赞了你的帖子」。
  Widget _buildTitle(NotificationGroup g, _TypeStyle style, _Palette p) {
    final actors = g.actors;
    final action = style.action;
    final nameStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: g.hasUnread ? p.text : p.textSec,
    );
    final plainStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      color: g.hasUnread ? p.text : p.textSec,
    );
    if (actors.isEmpty) {
      return Text(action, style: plainStyle);
    }
    if (actors.length == 1) {
      return Text.rich(
        TextSpan(children: [
          TextSpan(text: actors.first.name, style: nameStyle),
          TextSpan(text: ' $action', style: plainStyle),
        ]),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    final head = actors.take(2).map((a) => a.name).join('、');
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: head, style: nameStyle),
        TextSpan(text: ' 等 ${g.count} 人', style: nameStyle),
        TextSpan(text: ' $action', style: plainStyle),
      ]),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
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
}

// ==================== 头像堆叠 ====================

class _AvatarStack extends StatelessWidget {
  final List<NotificationActor> actors;
  final _Palette palette;
  final bool expanded;

  const _AvatarStack({
    required this.actors,
    required this.palette,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    const double r = 16;
    const double d = r * 2;
    // 重叠率 30%：后续头像左移 d * 0.7；按压时轻微展开（重叠率降为 20%）。
    final step = d * (expanded ? 0.8 : 0.7);
    final shown = actors.take(5).toList();
    final extra = actors.length - shown.length;
    final width = d + step * (shown.length - 1) + (extra > 0 ? step + 22 : 0);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      width: width,
      height: d,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * step,
              child: _stackAvatar(shown[i], r),
            ),
          if (extra > 0)
            Positioned(
              left: shown.length * step,
              child: Container(
                width: d,
                height: d,
                decoration: BoxDecoration(
                  color: palette.dark ? const Color(0xFF3A332B) : const Color(0xFFEDE3D5),
                  shape: BoxShape.circle,
                  border: Border.all(color: palette.card, width: 1.5),
                ),
                alignment: Alignment.center,
                child: Text(
                  '+$extra',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: palette.textSec,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _stackAvatar(NotificationActor actor, double r) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: palette.card, width: 1.5),
      ),
      child: UserAvatar(userId: actor.userId, radius: r - 1.5),
    );
  }
}
