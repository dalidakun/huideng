import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'checkin_history_stats.dart';
import 'cloud_notes_service.dart';
import 'my_page.dart';
import 'note_detail_page.dart';
import 'post_rich_content.dart';
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

/// 昵称行操作按钮（关注按钮/三个点点圆圈）统一尺寸。
const double _rowBtnSize = 26;

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
  String _profileAccount = '';
  bool _profileVerified = false;
  late bool _following =
      CloudNotesService.instance.followingUserIds.contains(widget.userId);

  /// 对方「精读 / 功课」数据（受对方隐私开关控制）。
  UserHomeData? _homeData;
  bool _homeLoaded = false;
  bool _homeError = false;

  /// 对方账号（优先用资料接口返回的账号，未拉取到则从已加载的笔记中取）。
  String get _account =>
      _profileAccount.isNotEmpty ? _profileAccount : (_notes.isNotEmpty ? _notes.first.authorAccount : '');

  /// 对方是否已实名认证（优先用资料接口返回的认证状态）。
  bool get _verified =>
      _profileVerified || (_notes.isNotEmpty && _notes.first.authorVerified);

  /// 是否已屏蔽对方。
  bool get _isBlocked =>
      CloudNotesService.instance.blockedUserIds.contains(widget.userId);

  /// 是否查看的是自己的主页。
  bool get _isSelf => AuthService.instance.currentUser.value?.id == widget.userId;

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
    if (me == null) return;
    if (me.id == widget.userId) {
      _showToast(context, '这是你自己的主页');
      return;
    }
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
      if (!ok) _load();
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
    if (_isBlocked && !_isSelf) {
      // 已屏蔽对方：帖子/回复/精读/功课等栏目统一显示「已屏蔽用户」占位，
      // 但头部仍需展示对方的 @账户 与注册时间，方便识别/取消屏蔽。
      String tagline = '';
      int joinTime = 0;
      String account = '';
      bool verified = false;
      try {
        final profiles =
            await CloudNotesService.instance.getUserProfiles([widget.userId]);
        if (profiles.isNotEmpty) {
          tagline = profiles.first.tagline;
          joinTime = profiles.first.joinTime;
          account = profiles.first.account;
          verified = profiles.first.verified;
        }
      } catch (_) {}
      // getUserProfiles 未取到 @账户 时，从对方公开笔记的 authorAccount 兜底补齐。
      if (account.isEmpty) {
        try {
          final (list, _) = await CloudNotesService.instance
              .getUserNotes(widget.userId, page: 1);
          if (list.isNotEmpty) {
            account = list.first.authorAccount;
            if (verified == false) verified = list.first.authorVerified;
          }
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _notes.clear();
          _profileTagline = tagline;
          _profileJoinTime = joinTime;
          _profileAccount = account;
          _profileVerified = verified;
          _homeData = null;
          _homeLoaded = false;
          _homeError = false;
        });
      }
      return;
    }
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
      String account = '';
      bool verified = false;
      final me = AuthService.instance.currentUser.value;
      if (me != null && me.id == widget.userId) {
        try {
          final prefs = await SharedPreferences.getInstance();
          tagline = prefs.getString('user_tagline') ?? '燃一盏灯，看见自己，照亮别人。';
          joinTime = prefs.getInt('user_created_at') ?? 0;
          account = prefs.getString('user_account_name') ?? '';
          verified = prefs.getBool('user_verified') ?? false;
        } catch (_) {}
      } else {
        try {
          final profiles =
              await CloudNotesService.instance.getUserProfiles([widget.userId]);
          if (profiles.isNotEmpty) {
            tagline = profiles.first.tagline;
            joinTime = profiles.first.joinTime;
            account = profiles.first.account;
            verified = profiles.first.verified;
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
        _profileAccount = account;
        _profileVerified = verified;
        _page = 1;
        _hasMore = hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
    await _loadHomeData();
  }

  /// 拉取对方「精读 / 功课」数据（失败时保持空态，不影响帖子/回复展示）。
  Future<void> _loadHomeData() async {
    try {
      final data =
          await CloudNotesService.instance.getUserHomeData(widget.userId);
      if (!mounted) return;
      setState(() {
        _homeData = data;
        _homeLoaded = true;
        _homeError = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _homeData = null;
        _homeLoaded = true;
        _homeError = true;
      });
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
      body: SafeArea(
        top: true,
        child: NestedScrollView(
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
          height: 200,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 顶部横幅（他人无本地横幅，用默认渐变占位）。
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 150,
                child: Container(
                  width: double.infinity,
                  height: 150,
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
              // 大头像（重叠在横幅下缘）。
              Positioned(
                left: 20,
                top: 106,
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
                    // 昵称 + 认证（左侧）。
                    Expanded(
                      child: Row(
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
                    ),
                    // 三个点点：中性灰圆圈包裹，直径与关注按钮高度一致（屏蔽菜单）。
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _showBlockSheet,
                      child: Container(
                        width: _rowBtnSize,
                        height: _rowBtnSize,
                        decoration: const BoxDecoration(
                          color: Color(0xFFECE9E4),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.more_horiz,
                            size: 18, color: Color(0xFF8C8C8C)),
                      ),
                    ),
                    // 关注按钮：与三个点点同一行，位于其右侧（他人主页才显示）。
                    if (!isSelf) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _toggleFollow,
                        child: Container(
                          height: _rowBtnSize,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: following
                                ? const Color(0xFFBDB6AC)
                                : const Color(0xFF70867A),
                            borderRadius: BorderRadius.circular(_rowBtnSize / 2),
                          ),
                          child: Text(following ? '已关注' : '关注',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ],
                ),
                if (_account.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('@$_account',
                      style: const TextStyle(fontSize: 13, color: _textHint)),
                ],
                // 签名：未设置时默认展示固定法语（用户可自行修改）。
                const SizedBox(height: 6),
                Text(
                  _displayTagline,
                  style: const TextStyle(
                      fontSize: 14, color: _textSec, height: 1.4),
                ),
                // 注册加入时间。
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
    if (_isBlocked && !_isSelf) {
      return _buildBlockedPlaceholder();
    }
    if (_tab == 2) return _buildReadingTab();
    if (_tab == 3) return _buildCheckinTab();
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

  /// 精读 Tab：对方最近在读的经书（点击进入经书讨论页，未开讨论时显示「还没有讨论」）。
  Widget _buildReadingTab() {
    final data = _homeData;
    if (!_homeLoaded) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (_homeError) {
      return _tabPlaceholder(
        Icons.cloud_off,
        '精读信息加载失败',
        '请检查网络后下拉重试',
        onRefresh: _loadHomeData,
      );
    }
    if (data == null || !data.readingAllowed) {
      return _tabPlaceholder(
        Icons.lock_outline,
        '对方未开启精读分享',
        '对方在「精读经文」中开启「允许」后可见',
      );
    }
    if (data.reading.isEmpty) {
      return _tabPlaceholder(
        Icons.auto_stories_outlined,
        '还没有精读记录',
        '${widget.userName} 暂无精读经文',
      );
    }
    return RefreshIndicator(
      color: _gold,
      onRefresh: _loadHomeData,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
        itemCount: data.reading.length,
        itemBuilder: (context, i) {
          final s = data.reading[i];
          return _buildReadingRow(
            s,
            isCurrent: s.title == data.currentLockedTitle,
          );
        },
      ),
    );
  }

  Widget _buildReadingRow(UserReadingSutra s, {bool isCurrent = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isCurrent ? const Color(0xFF70867A) : _border,
            width: isCurrent ? 1.4 : 0.8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  SutraDiscussionPage(title: s.title, filePath: s.filePath),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFF70867A).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(Icons.menu_book_rounded,
                          size: 18, color: Color(0xFF70867A)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.title,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: _text,
                          height: 1.4,
                        ),
                      ),
                    ),
                    if (isCurrent) ...[
                      const SizedBox(width: 6),
                      Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF70867A),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('当前锁定',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.white,
                                    height: 1.2)),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('查看经书讨论',
                        style: TextStyle(fontSize: 12, color: _textHint)),
                    SizedBox(width: 2),
                    Icon(Icons.chevron_right, size: 18, color: _textHint),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 功课 Tab：对方的打卡功课设置与目标设置（只读）。
  Widget _buildCheckinTab() {
    final data = _homeData;
    if (!_homeLoaded) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (_homeError) {
      return _tabPlaceholder(
        Icons.cloud_off,
        '功课信息加载失败',
        '请检查网络后下拉重试',
        onRefresh: _loadHomeData,
      );
    }
    if (data == null || !data.checkinAllowed) {
      return _tabPlaceholder(
        Icons.lock_outline,
        '对方未开启功课分享',
        '对方在「打卡目标」中开启「允许他人查看我的功课」后可见',
      );
    }
    final tasks = _buildCheckinTaskLines(data.checkin);
    final goals = _buildCheckinGoalEntries(data.checkin);
    final stats = _buildHistoryStatEntries(data.checkin);
    if (tasks.isEmpty && goals.isEmpty && stats.isEmpty) {
      return _tabPlaceholder(
        Icons.event_note_outlined,
        '对方还没有设置功课',
        '${widget.userName} 暂未设置打卡功课与目标',
      );
    }
    return RefreshIndicator(
      color: _gold,
      onRefresh: _loadHomeData,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
        children: [
          if (stats.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 12),
              child: CheckInHistoryStats(entries: stats),
            ),
          ],
          if (tasks.isNotEmpty) ...[
            _sectionTitle('功课设置'),
            ...tasks.map((t) => _buildTaskLine(t)),
          ],
          if (goals.isNotEmpty) ...[
            _sectionTitle('目标设置'),
            ...goals.map((g) => _buildGoalCard(g)),
          ],
        ],
      ),
    );
  }

  /// 由对方同步来的打卡 prefs 生成功课设置行文案。
  List<String> _buildCheckinTaskLines(Map<String, dynamic>? checkin) {
    if (checkin == null) return [];
    final lines = <String>[];
    for (final e in _decodeStringList(checkin['setting_meditation_minutes'])) {
      if (e.trim().isNotEmpty) lines.add('静坐 ${e.trim()}分钟');
    }
    for (final e in _decodeNamedItems(checkin['setting_reading_titles'])) {
      if (e.$1.isNotEmpty) {
        lines.add('诵经 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}遍' : ''}');
      }
    }
    for (final e in _decodeNamedItems(checkin['setting_mantra_items'])) {
      if (e.$1.isNotEmpty) {
        lines.add('持咒 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}遍' : ''}');
      }
    }
    for (final e in _decodeNamedItems(checkin['setting_buddha_items'])) {
      if (e.$1.isNotEmpty) {
        lines.add('称名 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}声' : ''}');
      }
    }
    for (final e in _decodeStringList(checkin['setting_copying_titles'])) {
      if (e.trim().isNotEmpty) lines.add('抄经 ${e.trim()}');
    }
    for (final e in _decodeCustomTypes(checkin['custom_checkin_types'])) {
      if (e.label.isNotEmpty) {
        lines.add('${e.label} ${e.count.trim().isEmpty ? '0' : e.count.trim()}${e.unit}');
      }
    }
    return lines;
  }

  /// 由对方同步来的打卡 prefs 生成目标卡片数据。
  List<_GoalEntry> _buildCheckinGoalEntries(Map<String, dynamic>? checkin) {
    if (checkin == null) return [];
    final goals = _decodeMap(checkin['checkin_goals']);
    final totals = <String, double>{};
    for (final r in _decodeMapList(checkin['checkin_records'])) {
      final key = r['type']?.toString() ?? '';
      if (key.isEmpty) continue;
      final amt = double.tryParse((r['amount'] ?? 1).toString()) ?? 1;
      totals[key] = (totals[key] ?? 0) + amt;
    }
    final customs = _decodeCustomTypes(checkin['custom_checkin_types']);
    final typeInfo = <String, ({String label, String unit})>{
      'meditation': (label: '静坐', unit: '分钟'),
      'reading': (label: '诵经', unit: '遍'),
      'mantra': (label: '持咒', unit: '遍'),
      'buddha': (label: '称名', unit: '声'),
      'copying': (label: '抄经', unit: '篇'),
      for (final c in customs) c.key: (label: c.label, unit: c.unit),
    };
    final out = <_GoalEntry>[];
    goals.forEach((k, v) {
      final info = typeInfo[k];
      if (info == null) return;
      final goal = double.tryParse(v.toString()) ?? 0;
      out.add(_GoalEntry(
          label: info.label,
          unit: info.unit,
          goal: goal,
          total: totals[k] ?? 0));
    });
    return out;
  }

  /// 历史统计条目：各类型自使用以来累计的总量（与目标无关）。
  List<CheckInStatEntry> _buildHistoryStatEntries(Map<String, dynamic>? checkin) {
    if (checkin == null) return [];
    final totals = <String, double>{};
    for (final r in _decodeMapList(checkin['checkin_records'])) {
      final key = r['type']?.toString() ?? '';
      if (key.isEmpty) continue;
      final amt = double.tryParse((r['amount'] ?? 1).toString()) ?? 1;
      totals[key] = (totals[key] ?? 0) + amt;
    }
    final customs = _decodeCustomTypes(checkin['custom_checkin_types']);
    final typeInfo = <String, ({String label, String unit})>{
      'meditation': (label: '静坐', unit: '分钟'),
      'reading': (label: '诵经', unit: '遍'),
      'mantra': (label: '持咒', unit: '遍'),
      'buddha': (label: '称名', unit: '声'),
      'copying': (label: '抄经', unit: '篇'),
      for (final c in customs) c.key: (label: c.label, unit: c.unit),
    };
    final out = <CheckInStatEntry>[];
    totals.forEach((k, v) {
      final info = typeInfo[k];
      if (info == null) return;
      out.add(CheckInStatEntry(label: info.label, unit: info.unit, total: v));
    });
    return out;
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Text(title,
          style: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700, color: _text)),
    );
  }

  Widget _buildTaskLine(String line) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline,
              size: 16, color: Color(0xFF71867A)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(line,
                style: const TextStyle(fontSize: 14, color: _text)),
          ),
        ],
      ),
    );
  }

  Widget _buildGoalCard(_GoalEntry g) {
    final progress = g.goal > 0 ? (g.total / g.goal).clamp(0.0, 1.0) : 0.0;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(g.label,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: _text)),
              const Spacer(),
              if (g.goal > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12)),
                  child: Text('目标 ${_fmtNum(g.goal)}${g.unit}',
                      style: const TextStyle(
                          fontSize: 12,
                          color: _gold,
                          fontWeight: FontWeight.w600)),
                )
              else
                Text('未设置目标',
                    style: TextStyle(fontSize: 12, color: _textHint)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: _border,
              valueColor: AlwaysStoppedAnimation<Color>(
                  g.goal > 0 ? _primary : _textHint),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('已累计 ${_fmtNum(g.total)} ${g.unit}',
                  style: const TextStyle(fontSize: 12, color: _textSec)),
              const Spacer(),
              if (g.goal > 0)
                Text('${(progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _primary)),
            ],
          ),
        ],
      ),
    );
  }

  /// 已屏蔽用户：帖子/回复/精读/功课所有栏目统一显示该占位（如需查看请取消屏蔽）。
  Widget _buildBlockedPlaceholder() {
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
                const Icon(Icons.block, size: 48, color: _textHint),
                const SizedBox(height: 14),
                const Text('已屏蔽用户',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _text)),
                const SizedBox(height: 6),
                const Text('如需查看，请取消屏蔽。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: _textSec)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 空态占位：隐私未开启 / 无数据 / 加载失败（可下拉重试）。
  Widget _tabPlaceholder(IconData icon, String title, String subtitle,
      {Future<void> Function()? onRefresh}) {
    return RefreshIndicator(
      color: _gold,
      onRefresh: onRefresh ?? () async {},
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 32),
            child: Column(
              children: [
                Icon(icon, size: 48, color: _textHint.withValues(alpha: 0.6)),
                const SizedBox(height: 14),
                Text(title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _text)),
                const SizedBox(height: 6),
                Text(subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: _textSec)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtNum(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }

  /// 对方同步来的 prefs 值解析：JSON 字符串或数组 → 字符串列表。
  List<String> _decodeStringList(Object? v) {
    if (v is List) return v.map((e) => e.toString()).toList();
    if (v is String) {
      try {
        final d = jsonDecode(v);
        if (d is List) return d.map((e) => e.toString()).toList();
      } catch (_) {}
    }
    return [];
  }

  /// 对方同步来的 prefs 值解析：JSON 字符串或数组 → Map 列表。
  List<Map<String, dynamic>> _decodeMapList(Object? v) {
    if (v is List) {
      return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    if (v is String) {
      try {
        final d = jsonDecode(v);
        if (d is List) {
          return d
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      } catch (_) {}
    }
    return [];
  }

  /// 对方同步来的 prefs 值解析：JSON 字符串或 Map → Map。
  Map<String, dynamic> _decodeMap(Object? v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    if (v is String) {
      try {
        final d = jsonDecode(v);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return {};
  }

  /// 名称 + 次数项解析（兼容纯字符串列表 / {name,count} 列表，每个元素只解析一次）。
  List<(String, String)> _decodeNamedItems(Object? v) {
    final out = <(String, String)>[];
    final list = _decodeRawList(v);
    for (final e in list) {
      if (e is Map) {
        out.add(((e['name'] ?? '').toString(), (e['count'] ?? '').toString()));
      } else {
        final s = e.toString().trim();
        if (s.isNotEmpty) out.add((s, ''));
      }
    }
    return out;
  }

  /// 解析为原始列表（兼容 JSON 字符串 / 已解析 List），其它返回空。
  List<dynamic> _decodeRawList(Object? v) {
    if (v is List) return v;
    if (v is String) {
      try {
        final d = jsonDecode(v);
        if (d is List) return d;
      } catch (_) {}
    }
    return const [];
  }

  /// 自定义打卡类型解析：{key, label, unit, count}。
  List<_CustomTypeInfo> _decodeCustomTypes(Object? v) {
    return [
      for (final m in _decodeMapList(v))
        _CustomTypeInfo(
          key: (m['key'] ?? '').toString(),
          label: (m['label'] ?? '').toString(),
          unit: (m['unit'] ?? '遍').toString(),
          count: (m['count'] ?? '').toString(),
        ),
    ];
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
        // 屏蔽/关注后刷新，让被屏蔽用户的主页立即变为「已屏蔽」占位。
        if (mounted) setState(() {});
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

  /// 展示的签名：未设置签名时，他人主页默认显示固定法语。
  String get _displayTagline {
    if (_profileTagline.isNotEmpty) return _profileTagline;
    return '安忍不动，犹如大地；静虑深密，犹如密藏。';
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

/// 用户主页的「帖子/回复/精读/功课」吸顶 tab。
class _UserTabsDelegate extends SliverPersistentHeaderDelegate {
  final int tab;
  final ValueChanged<int> onChanged;
  static const double _height = 48;
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
      child: SizedBox(
        height: _height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final (i, label) in const [
                (0, '帖子'),
                (1, '回复'),
                (2, '精读'),
                (3, '功课'),
              ])
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onChanged(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
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
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _UserTabsDelegate oldDelegate) =>
      oldDelegate.tab != tab;
}

/// 他人主页目标卡片数据。
class _GoalEntry {
  final String label;
  final String unit;
  final double goal;
  final double total;
  const _GoalEntry({
    required this.label,
    required this.unit,
    required this.goal,
    required this.total,
  });
}

/// 他人主页自定义打卡类型信息。
class _CustomTypeInfo {
  final String key;
  final String label;
  final String unit;
  final String count;
  const _CustomTypeInfo({
    required this.key,
    required this.label,
    required this.unit,
    required this.count,
  });
}
