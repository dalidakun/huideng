import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';
import 'my_page.dart';
import 'note_detail_page.dart';
import 'notification_center.dart';
import 'post_time_link.dart';
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

/// 互动类型图标（评论用帖子默认评论图标，其余用 Material 图标）。
class _TypeIcon extends StatelessWidget {
  final _TypeStyle style;

  const _TypeIcon({required this.style});

  @override
  Widget build(BuildContext context) {
    const size = 38.0;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: style.asset != null
          ? Image.asset(style.asset!, width: size * 0.47, height: size * 0.47,
              color: style.color)
          : Icon(style.icon, size: size * 0.53, color: style.color),
    );
  }
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
      // 切回通知页时顺带刷新未读数，并静默拉取最新通知列表。
      NotificationCenter.instance.refreshUnread();
      _silentRefresh();
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
                  '诸菩萨非己所安，不加于物。',
                  style: TextStyle(
                    color: p.textHint,
                    fontSize: 12,
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
          if (g.type == 'like_me' || g.type == 'repost_me') {
            // 点赞/转发共用同一格局（以点赞类为标准）。
            return _LikeNotificationCard(
              key: ValueKey('like:${g.noteId}:${g.latestAt}'),
              group: g,
              palette: p,
              onTap: () => _openGroup(g),
              onLongPress: () => _showActions(g),
            );
          }
          if (g.type == 'reply' || g.type == 'comment_reply') {
            return _ReplyNotificationCard(
              key: ValueKey('reply:${g.noteId}:${g.latestAt}'),
              group: g,
              palette: p,
              onTap: () => _openGroup(g),
              onLongPress: () => _showActions(g),
            );
          }
          if (g.type == 'follow_me') {
            return _FollowNotificationCard(
              key: ValueKey('follow:${g.latestAt}'),
              group: g,
              palette: p,
              onTap: () => _openGroup(g),
              onLongPress: () => _showActions(g),
            );
          }
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
    // 点赞的是回复帖时，定位到被点赞的回复；其余交互帖定位到对应评论。
    final scrollTo = (g.type == 'like_me' && g.noteRepostKind == 'reply')
        ? g.noteId
        : (g.type == 'reply' ||
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
          final scrollTo = (g.type == 'like_me' && g.noteRepostKind == 'reply')
              ? g.noteId
              : (g.type == 'reply' ||
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
    final style = _TypeStyle.of(g.type);
    if (g.type == 'like_me') {
      final base = g.noteRepostKind == 'reply' ? '喜欢了你的回复' : '点赞了你的帖子';
      if (actors.isEmpty) return base;
      if (actors.length == 1) return '${actors.first.name} $base';
      return '${actors.first.name} 和另外 ${g.count - 1} 人$base';
    }
    if (actors.isEmpty) return style.action;
    if (actors.length == 1) return '${actors.first.name} ${style.action}';
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
                _TypeIcon(style: style),
                const SizedBox(width: 12),
                // 头像堆叠
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: _AvatarStack(
                    actors: g.actors,
                    palette: p,
                    expanded: _pressed,
                    onAvatarTap: (a) => _openActorSpace(context, a),
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
                          if (unread)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF71867A),
                                  shape: BoxShape.circle,
                                ),
                              ),
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
                            color: g.type == 'repost_me'
                                ? p.text
                                : (unread ? p.textSec : p.textHint),
                            height: 1.45,
                          ),
                        ),
                      ],
                      // 时间戳：内容下方（与帖子/回复卡一致）。
                      const SizedBox(height: 6),
                      Text(
                        _formatNotifTime(g.latestAt),
                        style: TextStyle(fontSize: 11, color: p.textHint),
                      ),
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
}

// ==================== 点赞通知卡片 ====================

/// 点赞通知卡片（like_me）：
/// 第一行：点赞用户头像（单人单头像 / 多人并排、最新点赞在前）；
/// 第二行：昵称 + 认证标志 + 动作文案 + 点赞时间戳；
/// 第三行：我的评论/帖子内容。
class _LikeNotificationCard extends StatefulWidget {
  final NotificationGroup group;
  final _Palette palette;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _LikeNotificationCard({
    super.key,
    required this.group,
    required this.palette,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<_LikeNotificationCard> createState() => _LikeNotificationCardState();
}

class _LikeNotificationCardState extends State<_LikeNotificationCard>
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
    final actors = g.actors;
    final isReply = g.type == 'like_me' && g.noteRepostKind == 'reply';

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
                // 互动类型图标。
                _TypeIcon(style: style),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 第一行：头像。
                      _LikeAvatarRow(
                        actors: actors,
                        palette: p,
                        onAvatarTap: (a) => _openActorSpace(context, a),
                      ),
                      const SizedBox(height: 8),
                      // 第二行：昵称 + 认证 + 动作文案 + 时间戳。
                      _buildActionLine(g, p, unread, isReply),
                      // 第三行：我的评论/帖子内容。
                      if (g.noteContent.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          g.noteContent,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            // 与回复类内容字号一致。
                            fontSize: 15,
                            color: p.text,
                            height: 1.6,
                          ),
                        ),
                      ],
                      // 时间戳：内容下方（与帖子/回复卡一致）。
                      const SizedBox(height: 6),
                      Text(
                        _formatLikeTime(g.latestAt),
                        style: TextStyle(fontSize: 11, color: p.textHint),
                      ),
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

  /// 第二行：昵称（多人时取第一个）+ 认证标志 + 动作文案（时间戳在内容下方）。
  Widget _buildActionLine(
      NotificationGroup g, _Palette p, bool unread, bool isReply) {
    final actors = g.actors;
    final name = actors.isNotEmpty ? actors.first.name : '同修';
    final verified = actors.isNotEmpty && actors.first.verified;
    final others = actors.length - 1;
    // 点赞/转发/收藏等共用同一格局：动作文案随类型变化。
    final base = isReply ? '喜欢了你的回复' : _TypeStyle.of(g.type).action;
    final action = actors.length <= 1 ? base : '和另外$others人$base';

    final nameStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: unread ? p.text : p.textSec,
    );
    final plainStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      color: unread ? p.text : p.textSec,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 3,
            runSpacing: 2,
            children: [
              Text(name, style: nameStyle),
              if (verified) ...[
                const Icon(Icons.verified, size: 15, color: Color(0xFF70867A)),
              ],
              const SizedBox(width: 1),
              Text(action, style: plainStyle),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (unread)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Color(0xFF71867A),
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }

  String _formatLikeTime(int ms) {
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
    if (t.year == now.year) return '${t.month}月${t.day}日${t.hour}时';
    return '${t.year}年${t.month}月${t.day}日${t.hour}时';
  }
}

/// 点赞头像行：单人单头像；多人并排（最新点赞在前），最多展示 5 个头像 + 「+N」。
class _LikeAvatarRow extends StatelessWidget {
  final List<NotificationActor> actors;
  final _Palette palette;

  /// 点击某个头像进入该用户主页。
  final void Function(NotificationActor actor)? onAvatarTap;

  const _LikeAvatarRow({
    required this.actors,
    required this.palette,
    this.onAvatarTap,
  });

  @override
  Widget build(BuildContext context) {
    if (actors.isEmpty) {
      return _ActorAvatar(
        actor: const NotificationActor('', '同修'),
        radius: 18,
        palette: palette,
      );
    }
    final shown = actors.take(5).toList();
    final extra = actors.length - shown.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(width: 5),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onAvatarTap == null
                ? null
                : () => onAvatarTap!(shown[i]),
            child: _ActorAvatar(actor: shown[i], radius: 18, palette: palette),
          ),
        ],
        if (extra > 0) ...[
          const SizedBox(width: 5),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color:
                  palette.dark ? const Color(0xFF3A332B) : const Color(0xFFEDE3D5),
              shape: BoxShape.circle,
              border: Border.all(color: palette.card, width: 1.5),
            ),
            alignment: Alignment.center,
            child: Text(
              '+$extra',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: palette.textSec,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ==================== 头像堆叠 ====================

class _AvatarStack extends StatelessWidget {
  final List<NotificationActor> actors;
  final _Palette palette;
  final bool expanded;

  /// 点击某个头像进入该用户主页。
  final void Function(NotificationActor actor)? onAvatarTap;

  const _AvatarStack({
    required this.actors,
    required this.palette,
    this.expanded = false,
    this.onAvatarTap,
  });

  @override
  Widget build(BuildContext context) {
    // 头像大小与点赞卡片统一（radius 18）。
    const double r = 18;
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
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onAvatarTap == null
                    ? null
                    : () => onAvatarTap!(shown[i]),
                child: _stackAvatar(shown[i], r),
              ),
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
    return _ActorAvatar(actor: actor, radius: r, palette: palette);
  }
}

/// 互动用户头像：有 base64 头像时展示真实头像，否则回退到默认 App 头像。
class _ActorAvatar extends StatelessWidget {
  final NotificationActor actor;
  final double radius;
  final _Palette palette;

  const _ActorAvatar({
    required this.actor,
    required this.radius,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final avatarB64 = actor.avatar;
    if (avatarB64.isNotEmpty) {
      try {
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: palette.card, width: 1.5),
          ),
          child: ClipOval(
            child: Image.memory(
              base64Decode(avatarB64),
              width: radius * 2,
              height: radius * 2,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _fallback(),
            ),
          ),
        );
      } catch (_) {}
    }
    return _fallback();
  }

  Widget _fallback() {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: palette.card, width: 1.5),
      ),
      child: UserAvatar(userId: actor.userId, radius: radius - 1.5),
    );
  }
}

/// 回复类通知卡片（reply / comment_reply）：
/// 与主页帖子同款样式：头像 + 昵称 + @账号 + 时间 + 三点菜单（关注/屏蔽），
/// 下方「回复@我的账号」+ 回复内容，底部为 6 个指标（评论/转发/点赞/阅读/收藏/分享）。
class _ReplyNotificationCard extends StatefulWidget {
  final NotificationGroup group;
  final _Palette palette;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ReplyNotificationCard({
    super.key,
    required this.group,
    required this.palette,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<_ReplyNotificationCard> createState() => _ReplyNotificationCardState();
}

class _ReplyNotificationCardState extends State<_ReplyNotificationCard>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;

  /// 被回复的帖子（用于底部指标计数）。
  PlazaNote? _note;

  late final AnimationController _enter = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420))
    ..forward();
  late final Animation<double> _enterAnim =
      CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    _loadNote();
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  Future<void> _loadNote() async {
    final nid = widget.group.noteId;
    if (nid.isEmpty) return;
    try {
      final n = await CloudNotesService.instance.getNoteById(nid);
      if (mounted) setState(() => _note = n);
    } catch (_) {}
  }

  /// 三点菜单：关注/取消关注、屏蔽/取消屏蔽。
  Future<void> _showUserMenu(NotificationActor actor) async {
    if (actor.userId.isEmpty) return;
    await showMoreMenu(context, actor.userId, actor.name);
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final p = widget.palette;
    final unread = g.hasUnread;
    final actor = g.actors.isNotEmpty ? g.actors.first : null;
    final name = actor?.name ?? '同修';
    final verified = actor?.verified ?? false;
    final account = actor?.account ?? '';

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
                // 头像在左（与主页帖子同尺寸，去掉回复类型图标让整体左移）。
                if (actor != null) ...[
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openUser(actor),
                    child: _ActorAvatar(actor: actor, radius: 18, palette: p),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 第一行：昵称 + 认证 + @账号 + 三点菜单（时间在内容下方）。
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: p.text,
                                    ),
                                  ),
                                ),
                                if (verified) ...[
                                  const SizedBox(width: 3),
                                  const Icon(Icons.verified,
                                      size: 17, color: Color(0xFF70867A)),
                                ],
                                if (account.isNotEmpty) ...[
                                  const SizedBox(width: 3),
                                  Flexible(
                                    child: AccountLink(
                                      account: account,
                                      onTap: actor == null
                                          ? null
                                          : () => _openUser(actor),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: actor == null
                                ? null
                                : () => _showUserMenu(actor),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(Icons.more_horiz,
                                  size: 18, color: Color(0xFF8C8C8C)),
                            ),
                          ),
                        ],
                      ),
                      // 回复@我的账号。
                      const SizedBox(height: 4),
                      _ReplyToMeLine(palette: p),
                      // 回复内容。
                      if (g.noteContent.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          g.noteContent,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            color: p.text,
                            height: 1.6,
                          ),
                        ),
                      ],
                      // 回复时间：内容与指标行之间。
                      if (g.latestAt > 0) ...[
                        const SizedBox(height: 6),
                        Text(_formatMonthDay(g.latestAt),
                            style: TextStyle(fontSize: 12, color: p.textHint)),
                      ],
                      // 底部 6 个指标（与详情页同款：评论/转发/点赞/阅读/收藏/分享）。
                      const SizedBox(height: 10),
                      _buildMetricsRow(p),
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

  /// 底部指标行：评论/转发/点赞/阅读 带数字，收藏/分享 仅图标。
  Widget _buildMetricsRow(_Palette p) {
    final nid = widget.group.noteId;
    final note = _note;
    final liked = nid.isNotEmpty &&
        CloudNotesService.instance.likedNoteIds.contains(nid);
    final favorited = nid.isNotEmpty &&
        CloudNotesService.instance.favoriteNoteIds.contains(nid);
    final sec = p.textSec;
    return Row(
      children: [
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _metricCell(Image.asset('assets/images/ic_comment.png',
                  width: 18, height: 18), sec, '${note?.commentCount ?? 0}'),
              _metricCell(Icon(Icons.repeat_rounded,
                  size: 18, color: sec), sec, '${note?.repostCount ?? 0}'),
              _metricCell(
                  Icon(liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                      size: 18,
                      color: liked ? _gold : sec),
                  liked ? _gold : sec,
                  '${note?.likeCount ?? 0}'),
              _metricCell(Image.asset('assets/images/ic_view.png',
                  width: 18, height: 18), sec, '${note?.viewCount ?? 0}'),
            ],
          ),
        ),
        const SizedBox(width: 36),
        _metricCell(
            Icon(favorited
                ? Icons.bookmark_rounded
                : Icons.bookmark_border_rounded,
                size: 18,
                color: favorited ? _gold : sec),
            favorited ? _gold : sec,
            ''),
        const SizedBox(width: 6),
        _metricCell(Icon(Icons.share_rounded, size: 18, color: sec), sec, ''),
      ],
    );
  }

  Widget _metricCell(Widget icon, Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 18, height: 18, child: icon),
        if (text.isNotEmpty) ...[
          const SizedBox(width: 3),
          Text(text,
              style: TextStyle(fontSize: 15, height: 1, color: color)),
        ],
      ],
    );
  }

  void _openUser(NotificationActor actor) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            UserSpacePage(userId: actor.userId, userName: actor.name),
      ),
    );
  }
}

/// 关注通知卡片（follow_me）：
/// 第一行 = 头像（单个用户一个头像，多个用户头像排列）；
/// 第二行 = 最新关注者的昵称 + 关注文案 + 关注时间戳。
class _FollowNotificationCard extends StatefulWidget {
  final NotificationGroup group;
  final _Palette palette;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _FollowNotificationCard({
    super.key,
    required this.group,
    required this.palette,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<_FollowNotificationCard> createState() => _FollowNotificationCardState();
}

class _FollowNotificationCardState extends State<_FollowNotificationCard>
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

  void _openUser(NotificationActor actor) {
    if (actor.userId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            UserSpacePage(userId: actor.userId, userName: actor.name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final p = widget.palette;
    final unread = g.hasUnread;
    final actors = g.actors;
    final single = actors.length <= 1;
    final actor = actors.isNotEmpty ? actors.first : null;
    final name = actor?.name ?? '同修';
    final verified = actor?.verified ?? false;
    final actionText = single
        ? ' 关注了你'
        : ' 和另外 ${g.count - 1} 个人关注了你';
    final nameStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w700,
      color: g.hasUnread ? p.text : p.textSec,
    );
    final plainStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w400,
      color: g.hasUnread ? p.text : p.textSec,
    );

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
                // 互动类型图标（关注）。
                _TypeIcon(style: _TypeStyle.of(g.type)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 第一行：头像（单个 / 多个排列，统一大小、点击进入主页）。
                      if (actor != null)
                        single
                            ? GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _openUser(actor),
                                child: _ActorAvatar(
                                    actor: actor, radius: 18, palette: p),
                              )
                            : _AvatarStack(
                                actors: actors,
                                palette: p,
                                expanded: _pressed,
                                onAvatarTap: (a) => _openUser(a),
                              ),
                      // 第二行：昵称 + 认证（如有）+ 关注文案，时间戳靠右。
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text.rich(
                              TextSpan(children: [
                                TextSpan(text: name, style: nameStyle),
                                if (verified) ...[
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 3),
                                      child: Icon(Icons.verified,
                                          size: 14, color: Color(0xFF70867A)),
                                    ),
                                  ),
                                ],
                                TextSpan(text: actionText, style: plainStyle),
                              ]),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (g.latestAt > 0) ...[
                            const SizedBox(width: 8),
                            Text(
                              _formatNotifTime(g.latestAt),
                              style: TextStyle(fontSize: 12, color: p.textHint),
                            ),
                          ],
                        ],
                      ),
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
}

/// 「回复@B账号」一行：异步读取当前登录用户账号名（B 即通知接收者本人）。
class _ReplyToMeLine extends StatefulWidget {
  final _Palette palette;

  const _ReplyToMeLine({required this.palette});

  @override
  State<_ReplyToMeLine> createState() => _ReplyToMeLineState();
}

class _ReplyToMeLineState extends State<_ReplyToMeLine> {
  String _account = '';

  @override
  void initState() {
    super.initState();
    AuthService.instance.getAccountName().then((name) {
      if (mounted && name != _account) setState(() => _account = name);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    if (_account.isEmpty) {
      return Text('回复了我',
          style: TextStyle(fontSize: 13, color: p.textSec));
    }
    // @账户 以青色显示，点击进入自己的个人主页（AccountLink 自带 @ 前缀）。
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('回复', style: TextStyle(fontSize: 13, color: p.textSec)),
        AccountLink(
          account: _account,
          onTap: () {
            final me = AuthService.instance.currentUser.value;
            if (me != null && me.id.isNotEmpty) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => UserSpacePage(
                      userId: me.id, userName: _account.isEmpty ? '同修' : _account),
                ),
              );
            }
          },
        ),
      ],
    );
  }
}

/// 回复时间戳：今天「今日x时」，今年「x月x日x时」，往年「x年x月x日x时」。
String _formatMonthDay(int ms) {
  if (ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return '今日${t.hour}时';
  }
  if (t.year == now.year) return '${t.month}月${t.day}日${t.hour}时';
  return '${t.year}年${t.month}月${t.day}日${t.hour}时';
}

/// 关注/通知时间戳：刚刚 / x分钟前 / x小时前 / 昨天 / 前天 / x月x日x时 / x年x月x日x时。
String _formatNotifTime(int ms) {
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
  if (t.year == now.year) return '${t.month}月${t.day}日${t.hour}时';
  return '${t.year}年${t.month}月${t.day}日${t.hour}时';
}

/// 点击通知卡片里的某个头像进入该用户个人主页。
void _openActorSpace(BuildContext context, NotificationActor actor) {
  if (actor.userId.isEmpty) return;
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) =>
          UserSpacePage(userId: actor.userId, userName: actor.name),
    ),
  );
}
