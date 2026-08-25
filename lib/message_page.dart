import 'dart:async';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'loading_widgets.dart';
import 'login_page.dart';
import 'my_page.dart';
import 'note_detail_page.dart';
import 'notification_center.dart';
import 'post_time_link.dart';
import 'user_avatar.dart';
import 'user_space_page.dart';

import 'app_palette.dart';
// ==================== 配色（浅色 / 深色） ====================

Color get _bgLight => AppPalette.p.bg;
const Color _bgDark = Color(0xFF14100C);
Color get _cardLight => AppPalette.p.card;
const Color _cardDark = Color(0xFF211B15);
Color get _textLight => AppPalette.p.text;
const Color _textDark = Color(0xFFEFE6DC);
Color get _textSecLight => AppPalette.p.textSec;
const Color _textSecDark = Color(0xFFB7A99A);
Color get _textHintLight => AppPalette.p.textHint;
const Color _textHintDark = Color(0xFF8A8177);
Color get _borderLight => AppPalette.p.border;
const Color _borderDark = Color(0xFF383129);
Color get _unreadTintLight => AppPalette.p.tintBg;
const Color _unreadTintDark = Color(0xFF2C241B);
Color get _primary => AppPalette.p.primary;
Color get _gold => AppPalette.p.accent;
class _TypeStyle {
  final IconData? icon;

  /// 使用资源图片作为图标时指定（如帖子默认评论图标 ic_comment.png）。
  final String? asset;
  final Color color;
  final String action;
  const _TypeStyle.icon(this.icon, this.color, this.action) : asset = null;
  const _TypeStyle.asset(this.asset, this.color, this.action) : icon = null;

  static final Map<String, _TypeStyle> _map = {
    'like_me': _TypeStyle.icon(Icons.favorite_rounded, Color(0xFFE08A8A), '点赞了你的帖子'),
    'reply': _TypeStyle.asset('assets/images/ic_comment.png', Color(0xFF71867A), '评论了你的帖子'),
    'comment_reply':
        _TypeStyle.icon(Icons.reply_rounded, Color(0xFF6F87A0), '回复了你的评论'),
    'repost_me': _TypeStyle.icon(Icons.repeat_rounded, AppPalette.p.accent, '转发了你的帖子'),
    'favorite_me': _TypeStyle.icon(Icons.bookmark_rounded, Color(0xFFC9A227), '收藏了你的帖子'),
    'follow_me': _TypeStyle.icon(Icons.person_add_alt_1_rounded, Color(0xFF5F8A85), '关注了你'),
    'mention': _TypeStyle.icon(Icons.alternate_email_rounded, Color(0xFF9B7FAE), '在评论中@了你'),
  };

  static _TypeStyle of(String type) =>
      _map[type] ??
      _TypeStyle.icon(
          Icons.notifications_none, AppPalette.p.textSec, '与你互动了');
}

/// 独立的消息类型图案：与头像分开，置于头像左侧，指示消息类型
/// （回复/转发/点赞/收藏/关注/@提及等；评论用帖子默认评论图标）。
class _TypeIcon extends StatelessWidget {
  final _TypeStyle style;
  final double size;

  const _TypeIcon({required this.style, this.size = 20});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: style.asset != null
          ? Image.asset(style.asset!,
              width: size, height: size, color: style.color)
          : Icon(style.icon, size: size, color: style.color),
    );
  }
}

/// 类型图案 + 用户头像：类型图案在前（指示消息类型），用户头像在后，两者分开。
class _TypeIconAndAvatars extends StatelessWidget {
  final Widget avatars;
  final _TypeStyle style;

  /// 类型图案尺寸：点赞/转发/收藏/关注类用更大图标（24），其余默认 20。
  final double iconSize;

  const _TypeIconAndAvatars({
    required this.avatars,
    required this.style,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _TypeIcon(style: style, size: iconSize),
        const SizedBox(width: _kTypeIconAvatarGap),
        avatars,
      ],
    );
  }
}

/// 点赞/转发/收藏/关注卡的较大类型图案尺寸。
const double _kTypeIconSize = 24;

/// 类型图案与头像之间的间距。
const double _kTypeIconAvatarGap = 8;

/// 头像左缘相对卡片左缘的偏移 = 类型图案宽 + 图案与头像间距。
/// 昵称行 / 帖子内容行需与头像左缘对齐（不顶格显示），缩进量取此值。
const double _kAvatarLeftInset = _kTypeIconSize + _kTypeIconAvatarGap;

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
        : _Palette(
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

  /// 最近一次加载失败的具体错误信息（展示在错误页，便于定位原因）。
  String _errorMsg = '';

  /// 是否已完成一次真正的列表加载（含失败）。用于「首次切到通知页才加载」：
  /// 消息页位于底部 IndexedStack，App 启动时即便用户没看也会被构建；老实现
  /// 启动即打 getNotifications（含逐条摘要补齐），与首页预取形成云调用风暴，
  /// 弱网下互相拖慢导致「通知加载失败」。延迟到用户真正切到该 Tab 再拉取。
  bool _loadedOnce = false;

  /// 首次加载失败后已自动重试的次数（最多 [_maxLoadRetries] 次）。
  /// 冷启动时会话恢复/token 刷新需要几秒，期间拉取会失败，等待会话就绪后
  /// 自动重试，避免一直停在「加载失败」、要等切页或手动刷新才恢复。
  int _loadRetries = 0;
  static const int _maxLoadRetries = 2;
  static const Duration _retryDelay = Duration(seconds: 4);

  /// 上一次见到的未读数：用于检测「未读数增加 → 有新通知到达」。
  int _prevUnread = 0;

  late final AnimationController _pageFade =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 380))
        ..forward();
  late final Animation<double> _pageFadeAnim =
      CurvedAnimation(parent: _pageFade, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    appDarkMode.addListener(_onExternalChanged);
    NotificationCenter.instance.unread.addListener(_onUnreadChanged);
    AuthService.instance.currentUser.addListener(_onAuthChanged);
    widget.activeTab?.addListener(_onTabChanged);
    _prevUnread = NotificationCenter.instance.unread.value;
    // 首次可见时才加载（activeTab==3 或独立页面无 Tab）；否则切到该页时再拉。
    if (widget.activeTab == null || widget.activeTab!.value == 3) {
      _load();
    }
  }

  @override
  void dispose() {
    appDarkMode.removeListener(_onExternalChanged);
    NotificationCenter.instance.unread.removeListener(_onUnreadChanged);
    AuthService.instance.currentUser.removeListener(_onAuthChanged);
    widget.activeTab?.removeListener(_onTabChanged);
    _pageFade.dispose();
    super.dispose();
  }

  void _onExternalChanged() {
    if (mounted) setState(() {});
  }

  /// 未读数变化时：增加（新通知到达）则静默刷新列表；其余仅重建 UI。
  /// 初始 _load() 进行中时不重复触发，避免与首次拉取并发。
  void _onUnreadChanged() {
    if (!mounted) return;
    final n = NotificationCenter.instance.unread.value;
    if (n > _prevUnread && !_loading) {
      _silentRefresh();
    }
    _prevUnread = n;
    if (mounted) setState(() {});
  }

  void _onAuthChanged() {
    if (!mounted) return;
    if (!AuthService.instance.isLoggedIn) {
      setState(() {
        _groups.clear();
        _loading = false;
      });
    } else if (_loadedOnce ||
        widget.activeTab == null ||
        widget.activeTab!.value == 3) {
      // 只有看过的页面才在登录态变化时后台刷新；从未看过的 Tab 保持延迟加载，
      // 避免冷启动会话恢复一完成就替用户打通知请求（与首页预取叠加成风暴）。
      _load();
    }
  }

  void _onTabChanged() {
    if (!mounted) return;
    if (widget.activeTab?.value == 3) {
      _pageFade.forward(from: 0);
      // 切回通知页时顺带刷新未读数，并静默拉取最新通知列表。
      NotificationCenter.instance.refreshUnread();
      if (_loadedOnce) {
        _silentRefresh();
      } else {
        _load();
      }
    }
  }

  Future<void> _load() async {
    _loadedOnce = true;
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
      _loadRetries = 0;
      setState(() {
        _groups
          ..clear()
          ..addAll(groups);
        _page = 1;
        _hasMore = hasMore;
        _loading = false;
        _errorMsg = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
        _errorMsg = _describeError(e);
      });
      debugPrint('[Notif] load failed: $e');
      _scheduleRetry();
    }
  }

  /// 把异常转成给用户看的简短文案（保留关键信息便于定位）。
  String _describeError(Object e) {
    final s = e.toString();
    if (s.contains('CloudApiException')) {
      return s.replaceFirst('CloudApiException', '').replaceAll(RegExp(r'^[:\s]+'), '');
    }
    return s;
  }

  /// 首次加载失败后延迟自动重试：等待会话恢复完成窗口（_retryRestoreSession
  /// 4s 后重试 + token 修复）后再拉取一次，期间已被其它路径（静默刷新/切页/
  /// 下拉）恢复时不再重复请求。
  void _scheduleRetry() {
    if (_loadRetries >= _maxLoadRetries || !mounted) return;
    _loadRetries++;
    Future.delayed(_retryDelay, () {
      if (!mounted) return;
      if (_groups.isNotEmpty) return;
      _load();
    });
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
  /// 加载中/翻页中/从未看过此页时直接跳过，避免并发互相覆盖或启动即拉取。
  Future<void> _silentRefresh() async {
    if (!AuthService.instance.isLoggedIn) return;
    if (_loading || _loadingMore) return;
    if (!_loadedOnce) return;
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
      return const AppLoadingIndicator(
        message: '正在加载通知...',
      );
    }
    if (_error && _groups.isEmpty) {
      return AppLoadError(
        subtitle: _errorMsg.isNotEmpty ? _errorMsg : '网络似乎不太顺畅',
        onRetry: _load,
      );
    }
    if (_groups.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        color: _gold,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const AppEmptyState(
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
        // 素白外观：横向缩进比主页发现流（16）更多一档，信息离屏幕边缘更远；
        // 条目间分割线与内容同宽对齐。
        padding: AppPalette.instance.isPlain
            ? const EdgeInsets.fromLTRB(20, 8, 20, 28)
            : const EdgeInsets.fromLTRB(12, 8, 12, 28),
        itemCount: _groups.length + 1,
        itemBuilder: (context, index) {
          if (index == _groups.length) {
            if (!_hasMore) return const SizedBox(height: 12);
            WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
            return const AppLoadMoreIndicator();
          }
          final g = _groups[index];
          final Widget card;
          if (g.type == 'like_me' ||
              g.type == 'repost_me' ||
              g.type == 'favorite_me') {
            // 点赞/转发/收藏共用同一卡片格局：头像排列 + 动作文案·时间 + 帖子内容。
            card = _LikeNotificationCard(
              key: ValueKey('like:${g.type}:${g.noteId}:${g.latestAt}'),
              group: g,
              palette: p,
              onTap: () => _openGroup(g),
              onLongPress: () => _showActions(g),
            );
          } else if (g.type == 'follow_me') {
            // 关注用独立卡片格局（头像排列 + 关注文案）。
            card = _FollowNotificationCard(
              key: ValueKey('follow:${g.noteId}:${g.latestAt}'),
              group: g,
              palette: p,
              onTap: () => _openGroup(g),
              onLongPress: () => _showActions(g),
            );
          } else if (g.type == 'reply' || g.type == 'comment_reply') {
            card = _ReplyNotificationCard(
              key: ValueKey('reply:${g.noteId}:${g.latestAt}'),
              group: g,
              palette: p,
              onTap: () => _openGroup(g),
              onLongPress: () => _showActions(g),
            );
          } else {
            card = _NotificationCard(
              key: ValueKey('${g.type}:${g.noteId}:${g.latestAt}'),
              group: g,
              palette: p,
              onTap: () => _openGroup(g),
              onLongPress: () => _showActions(g),
            );
          }
          // 素白外观：卡片无底色块，条目之间用主页发现帖同款细分割线分隔
          // （首条不画，避免顶部多一条线；样式与 study_hub 帖子列表一致）。
          if (AppPalette.instance.isPlain) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (index > 0)
                  Divider(
                      height: 1, thickness: 0.5, color: AppPalette.p.divider),
                card,
              ],
            );
          }
          return card;
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
    final plain = AppPalette.instance.isPlain;
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
            // 素白外观：去掉通知底色区块，信息直接放在页面底色上，
            // 由列表内与主页发现帖同款的细分割线分隔（首条不画）。
            margin: EdgeInsets.only(bottom: plain ? 0 : 10),
            // 素白：无卡片边界，上下内边距加大让相邻通知的间隔更宽松。
            padding: plain
                ? const EdgeInsets.fromLTRB(0, 18, 0, 18)
                : const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: plain
                ? null
                : BoxDecoration(
                    color: unread ? p.unreadTint : p.card,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color:
                            Colors.black.withValues(alpha: p.dark ? 0.25 : 0.05),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 类型图案 + 头像行：类型图案在前指示消息类型，用户头像在后。
                _TypeIconAndAvatars(
                  style: style,
                  avatars: _AvatarStack(
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

/// 点赞/转发/收藏通知卡片（like_me / repost_me / favorite_me），纵向布局：
/// 第一行：消息类型图案（较大）+ 互动用户头像排列（按时间顺序、最新在前）；
/// 第二行：最新互动者昵称 + 认证标志 + 和另外N人 + 动作文案 +「·」+ 时间戳；
/// 第三行：被点赞/转发/收藏的帖子内容（全部显示，超长「显示更多」折叠），
/// 点击卡片进入帖子详情。
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

  /// 被点赞帖子内容是否已展开全文（超长内容点「显示更多」）。
  bool _expanded = false;

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
    final plain = AppPalette.instance.isPlain;
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
            // 素白外观：去掉通知底色区块，信息直接放在页面底色上，
            // 由列表内与主页发现帖同款的细分割线分隔（首条不画）。
            margin: EdgeInsets.only(bottom: plain ? 0 : 10),
            // 素白：无卡片边界，上下内边距加大让相邻通知的间隔更宽松。
            padding: plain
                ? const EdgeInsets.fromLTRB(0, 18, 0, 18)
                : const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: plain
                ? null
                : BoxDecoration(
                    color: unread ? p.unreadTint : p.card,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color:
                            Colors.black.withValues(alpha: p.dark ? 0.25 : 0.05),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 第一行：类型图案（较大）+ 头像行（类型图案在前指示消息类型，
                // 用户头像在后，按时间排列、最新互动者在前）。
                _TypeIconAndAvatars(
                  style: style,
                  iconSize: _kTypeIconSize,
                  avatars: _LikeAvatarRow(
                    actors: actors,
                    palette: p,
                    onAvatarTap: (a) => _openActorSpace(context, a),
                  ),
                ),
                const SizedBox(height: 8),
                // 第二行：昵称 + 认证 + 和另外N人 + 动作文案 +「·」+ 时间戳。
                // 与头像左缘对齐（缩进类型图案宽度，不顶格显示）。
                Padding(
                  padding: const EdgeInsets.only(left: _kAvatarLeftInset),
                  child: _buildActionLine(g, p, unread, isReply),
                ),
                // 第三行：被点赞/转发/收藏的帖子内容全部显示，超长「显示更多」折叠。
                // 同样与头像左缘对齐。
                if (g.noteContent.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.only(left: _kAvatarLeftInset),
                    child: _buildExpandableContent(g.noteContent, p),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 第一行：昵称（多人时取第一个）+ 认证标志 + 动作文案 +「·」+ 时间戳。
  Widget _buildActionLine(
      NotificationGroup g, _Palette p, bool unread, bool isReply) {
    final actors = g.actors;
    final name = actors.isNotEmpty ? actors.first.name : '同修';
    final verified = actors.isNotEmpty && actors.first.verified;
    final others = actors.length - 1;
    // 点赞/转发/收藏等共用同一格局：动作文案随类型变化。
    final base = isReply ? '喜欢了你的回复' : _TypeStyle.of(g.type).action;
    final action = actors.length <= 1 ? base : '和另外$others人$base';
    final time = _formatLikeTime(g.latestAt);

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
    final timeStyle = TextStyle(fontSize: 12, color: p.textHint);

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
              if (time.isNotEmpty) Text('· $time', style: timeStyle),
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

  /// 帖子内容：全部显示；超过 8 行时折叠并出现「显示更多」，点击展开（可再「收起」）。
  /// 与主页发现页/回复链同款折叠逻辑（LayoutBuilder 测宽 + TextPainter 测溢出）。
  Widget _buildExpandableContent(String content, _Palette p) {
    final textStyle = TextStyle(fontSize: 15, color: p.text, height: 1.6);
    return LayoutBuilder(
      builder: (context, constraints) {
        final tp = TextPainter(
          text: TextSpan(text: content, style: textStyle),
          maxLines: 8,
          ellipsis: '…',
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);
        final overflow = tp.didExceedMaxLines;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              content,
              maxLines: _expanded ? null : 8,
              overflow: _expanded ? null : TextOverflow.ellipsis,
              style: textStyle,
            ),
            if (overflow)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _expanded ? '收起' : '显示更多',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF70867A),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
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
        radius: 14,
        palette: palette,
      );
    }
    final shown = actors.take(5).toList();
    final extra = actors.length - shown.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onAvatarTap == null
                ? null
                : () => onAvatarTap!(shown[i]),
            child: _ActorAvatar(actor: shown[i], radius: 14, palette: palette),
          ),
        ],
        if (extra > 0) ...[
          const SizedBox(width: 4),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color:
                  palette.dark ? const Color(0xFF3A332B) : AppPalette.p.borderSoft,
              shape: BoxShape.circle,
              border: Border.all(color: palette.card, width: 1.5),
            ),
            alignment: Alignment.center,
            child: Text(
              '+$extra',
              style: TextStyle(
                fontSize: 10,
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

// ==================== 头像并排（无重叠） ====================

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
    const double r = 14;
    const double spacing = 4;
    final shown = actors.take(5).toList();
    final extra = actors.length - shown.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(width: spacing),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onAvatarTap == null
                ? null
                : () => onAvatarTap!(shown[i]),
            child: _ActorAvatar(actor: shown[i], radius: r, palette: palette),
          ),
        ],
        if (extra > 0) ...[
          const SizedBox(width: spacing),
          Container(
            width: r * 2,
            height: r * 2,
            decoration: BoxDecoration(
              color: palette.dark ? const Color(0xFF3A332B) : AppPalette.p.borderSoft,
              shape: BoxShape.circle,
              border: Border.all(color: palette.card, width: 1.5),
            ),
            alignment: Alignment.center,
            child: Text(
              '+$extra',
              style: TextStyle(
                fontSize: 10,
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
              decodeAvatarBase64(avatarB64),
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
/// 开头直接是用户头像（不带类型图案，比其它类型更大、与主页帖子同尺寸），
/// 右侧第一行昵称等信息、第二行「回复@我的账号」，两行总高与头像相当，
/// 接下来一行是回复内容，底部为 4 个指标（评论/转发/点赞/阅读）。
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
    final plain = AppPalette.instance.isPlain;
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
            // 素白外观：去掉通知底色区块，信息直接放在页面底色上，
            // 由列表内与主页发现帖同款的细分割线分隔（首条不画）。
            margin: EdgeInsets.only(bottom: plain ? 0 : 10),
            // 素白：无卡片边界，上下内边距加大让相邻通知的间隔更宽松。
            padding: plain
                ? const EdgeInsets.fromLTRB(0, 18, 0, 18)
                : const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: plain
                ? null
                : BoxDecoration(
                    color: unread ? p.unreadTint : p.card,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color:
                            Colors.black.withValues(alpha: p.dark ? 0.25 : 0.05),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 回复类不带类型图案，开头直接是用户头像（半径 22，与主页帖子同尺寸，
                // 与右侧昵称行 +「回复@账号」两行的总高度相当）。
                if (actor != null) ...[
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openUser(actor),
                    child: _ActorAvatar(actor: actor, radius: 22, palette: p),
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
                      // 底部 4 个指标（评论/转发/点赞/阅读），与主页帖子同款布局。
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

  /// 底部指标行：评论/转发/点赞/阅读 带数字。
  /// 与主页帖子同款：第一个指标与正文左对齐，其余固定间距，数字较多时等比缩小。
  Widget _buildMetricsRow(_Palette p) {
    final nid = widget.group.noteId;
    final note = _note;
    final liked = nid.isNotEmpty &&
        CloudNotesService.instance.likedNoteIds.contains(nid);
    final sec = p.textSec;
    return Row(
      children: [
        _metricCell(Image.asset('assets/images/ic_comment.png',
            width: 16, height: 16), sec, '${note?.commentCount ?? 0}'),
        const SizedBox(width: 48),
        _metricCell(Icon(Icons.repeat_rounded,
            size: 16, color: sec), sec, '${note?.repostCount ?? 0}'),
        const SizedBox(width: 48),
        _metricCell(
            Icon(liked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
                size: 16,
                color: liked ? _gold : sec),
            liked ? _gold : sec,
            '${note?.likeCount ?? 0}'),
        const SizedBox(width: 48),
        _metricCell(Image.asset('assets/images/ic_view.png',
            width: 16, height: 16), sec, '${note?.viewCount ?? 0}'),
      ],
    );
  }

  Widget _metricCell(Widget icon, Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 16, height: 16, child: icon),
        if (text.isNotEmpty) ...[
          const SizedBox(width: 3),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(text,
                  maxLines: 1,
                  style: TextStyle(fontSize: 13, height: 1, color: color)),
            ),
          ),
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

/// 关注通知卡片（follow_me），纵向布局：
/// 第一行：消息类型图案（较大）+ 用户头像排列（按时间顺序、最新关注在前）；
/// 第二行：最新关注者优先昵称 + 认证标志 + 和另外N人关注了你 +「·」+ 时间戳。
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
    final plain = AppPalette.instance.isPlain;
    final unread = g.hasUnread;
    final actors = g.actors;
    final single = actors.length <= 1;
    final actor = actors.isNotEmpty ? actors.first : null;
    final name = actor?.name ?? '同修';
    final verified = actor?.verified ?? false;
    // 关注卡片：动作文案随类型变化（多人时「和另外N人关注了你」）。
    final baseAction = _TypeStyle.of(g.type).action;
    final actionText =
        single ? baseAction : '和另外${g.count - 1}人$baseAction';
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
            // 素白外观：去掉通知底色区块，信息直接放在页面底色上，
            // 由列表内与主页发现帖同款的细分割线分隔（首条不画）。
            margin: EdgeInsets.only(bottom: plain ? 0 : 10),
            // 素白：无卡片边界，上下内边距加大让相邻通知的间隔更宽松。
            padding: plain
                ? const EdgeInsets.fromLTRB(0, 18, 0, 18)
                : const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: plain
                ? null
                : BoxDecoration(
                    color: unread ? p.unreadTint : p.card,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color:
                            Colors.black.withValues(alpha: p.dark ? 0.25 : 0.05),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 第一行：类型图案（较大）+ 用户头像排列（按时间顺序、最新关注在前，
                // 单个 / 多个排列，统一大小、点击进入主页）。
                if (actor != null) ...[
                  _TypeIconAndAvatars(
                    style: _TypeStyle.of(g.type),
                    iconSize: _kTypeIconSize,
                    avatars: single
                        ? GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _openUser(actor),
                            child: _ActorAvatar(
                                actor: actor, radius: 14, palette: p),
                          )
                        : _AvatarStack(
                            actors: actors,
                            palette: p,
                            expanded: _pressed,
                            onAvatarTap: (a) => _openUser(a),
                          ),
                  ),
                  const SizedBox(height: 8),
                ],
                // 第二行：昵称 + 认证 + 和另外N人关注了你 +「·」+ 时间戳。
                // 与头像左缘对齐（缩进类型图案宽度，不顶格显示）。
                Padding(
                  padding: const EdgeInsets.only(left: _kAvatarLeftInset),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 3,
                    runSpacing: 2,
                    children: [
                      Text(name, style: nameStyle),
                      if (verified)
                        const Icon(Icons.verified,
                            size: 15, color: Color(0xFF70867A)),
                      const SizedBox(width: 1),
                      Text(actionText, style: plainStyle),
                      if (g.latestAt > 0)
                        Text('· ${_formatNotifTime(g.latestAt)}',
                            style: TextStyle(fontSize: 12, color: p.textHint)),
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
