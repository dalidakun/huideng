import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';
import 'reader_settings_page.dart';
import 'checkin_reminder_page.dart';
import 'edit_profile_page.dart';
import 'change_phone_page.dart';
import 'about_page.dart';
import 'notification_service.dart';
import 'settings_widgets.dart';
import 'user_list_page.dart';
import 'note_detail_page.dart';

const Color _primary = Color(0xFF5C4033);
const Color _primaryLight = Color(0xFF8B6B5A);
const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);

/// 从左侧边缘滑入的页面路由。
Route<T> slideInFromLeft<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(-1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

class MyPage extends StatefulWidget {
  const MyPage({super.key});

  @override
  State<MyPage> createState() => MyPageState();
}

class MyPageState extends State<MyPage>
    with TickerProviderStateMixin {
  String? _avatarPath;
  String? _bannerPath;
  String _nickname = '同修';
  String _tagline = '与经为伴，与法同行';
  String _phone = '';
  String _joinedDate = '${DateTime.now().year}年${DateTime.now().month}月${DateTime.now().day}日加入';

  MyCounts _counts = const MyCounts();

  late TabController _tabController;

  final ValueNotifier<int> _reloadNotifier = ValueNotifier<int>(0);

  void reload() {
    _loadData();
    _reloadNotifier.value++;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadData();
    _loadCounts();
    AuthService.instance.currentUser.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    _reloadNotifier.dispose();
    AuthService.instance.currentUser.removeListener(_onAuthChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    _loadData();
    _loadCounts();
  }

  bool get _isLoggedIn => AuthService.instance.isLoggedIn;

  AuthUser? get _authUser => AuthService.instance.currentUser.value;

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final user = _authUser;
    setState(() {
      _avatarPath = prefs.getString('user_avatar_path');
      _bannerPath = prefs.getString('user_banner_path');
      if (_isLoggedIn) {
        _nickname = user?.displayName ?? '同修';
        _tagline = (user?.tagline?.isNotEmpty ?? false)
            ? user!.tagline!
            : '与经为伴，与法同行';
        _phone = user?.mobilePhoneNumber ?? '';
      } else {
        _nickname = prefs.getString('user_nickname') ?? '同修';
        _tagline = prefs.getString('user_tagline') ?? '与经为伴，与法同行';
        _phone = '';
      }
      final createdMs = prefs.getInt('user_created_at');
      if (createdMs != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(createdMs);
        _joinedDate = '${dt.year}年${dt.month}月${dt.day}日加入';
      } else {
        final now = DateTime.now().millisecondsSinceEpoch;
        prefs.setInt('user_created_at', now);
        final dt = DateTime.fromMillisecondsSinceEpoch(now);
        _joinedDate = '${dt.year}年${dt.month}月${dt.day}日加入';
      }
    });
  }

  Future<void> _loadCounts() async {
    try {
      final counts = await CloudNotesService.instance.getMyCounts();
      if (!mounted) return;
      setState(() => _counts = counts);
    } catch (_) {
      if (!mounted) return;
      setState(() => _counts = const MyCounts());
    }
  }

  Future<void> _viewAvatar() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.pop(ctx),
        behavior: HitTestBehavior.opaque,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _card,
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 24),
                  ],
                  image: _avatarPath != null
                      ? DecorationImage(image: FileImage(File(_avatarPath!)), fit: BoxFit.cover)
                      : null,
                ),
                child: _avatarPath == null
                    ? const Icon(Icons.person, size: 140, color: _primaryLight)
                    : null,
              ),
              const SizedBox(height: 16),
              const Text('轻触任意处关闭', style: TextStyle(fontSize: 13, color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _viewBanner() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.pop(ctx),
        behavior: HitTestBehavior.opaque,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 300,
                  height: 170,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD2C5B3),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 24),
                    ],
                    image: _bannerPath != null
                        ? DecorationImage(image: FileImage(File(_bannerPath!)), fit: BoxFit.cover)
                        : null,
                  ),
                  child: _bannerPath == null
                      ? const Icon(Icons.image, size: 48, color: Colors.white38)
                      : null,
                ),
              ),
              const SizedBox(height: 16),
              const Text('轻触任意处关闭', style: TextStyle(fontSize: 13, color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
  }

  void _openFollowing() {
    Navigator.push(
      context,
      slideInFromLeft(const UserListPage(mode: UserListMode.following)),
    ).then((_) => _loadCounts());
  }

  void _openFollowers() {
    Navigator.push(
      context,
      slideInFromLeft(const UserListPage(mode: UserListMode.followers)),
    ).then((_) => _loadCounts());
  }

  void _openSettings() {
    Navigator.push(context, slideInFromLeft(const _SettingsPage()));
  }

  void _openEditProfile() {
    Navigator.push(context, slideInFromLeft(const EditProfilePage()));
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = _isLoggedIn;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        top: true,
        child: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverToBoxAdapter(
              child: _buildProfileHeader(isLoggedIn),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _TabBarDelegate(
                controller: _tabController,
                backgroundColor: _bg,
              ),
            ),
          ];
        },
        body: TabBarView(
          controller: _tabController,
          children: [
            _TabContent(child: _MyPostsTab(isLoggedIn: isLoggedIn, reloadNotifier: _reloadNotifier)),
            _TabContent(child: _MyRepliesTab(isLoggedIn: isLoggedIn, reloadNotifier: _reloadNotifier)),
            _TabContent(child: _MyLikesTab(isLoggedIn: isLoggedIn, reloadNotifier: _reloadNotifier)),
            _TabContent(child: _MyBookmarksTab(isLoggedIn: isLoggedIn, reloadNotifier: _reloadNotifier)),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildProfileHeader(bool isLoggedIn) {
    final phoneDisplay = _phone.isNotEmpty
        ? '${_phone.substring(0, math.min(3, _phone.length))}****${_phone.length >= 7 ? _phone.substring(_phone.length - 4) : ''}'
        : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: _viewBanner,
          child: Stack(
            children: [
              Container(
                width: double.infinity,
                height: 160,
                decoration: BoxDecoration(
                  color: const Color(0xFFD2C5B3),
                  image: _bannerPath != null
                      ? DecorationImage(
                          image: FileImage(File(_bannerPath!)),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: _bannerPath == null
                    ? const Center(
                        child: Icon(Icons.camera_alt_outlined, size: 28, color: Colors.white38),
                      )
                    : null,
              ),
              Positioned(
                right: 20,
                bottom: 12,
                child: GestureDetector(
                  onTap: _openEditProfile,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Text(
                      '编辑个人资料',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Transform.translate(
            offset: const Offset(0, -38),
            child: GestureDetector(
              onTap: _viewAvatar,
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
                  image: _avatarPath != null
                      ? DecorationImage(
                          image: FileImage(File(_avatarPath!)),
                          fit: BoxFit.cover)
                      : null,
                ),
                child: _avatarPath == null
                    ? const Icon(Icons.person, size: 38, color: _primaryLight)
                    : null,
              ),
            ),
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -24),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isLoggedIn) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(_nickname,
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: _text)),
                    ),
                    IconButton(
                      onPressed: _openSettings,
                      icon: const Icon(Icons.settings_outlined,
                          size: 20, color: _textHint),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                if (phoneDisplay.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.phone_iphone_outlined,
                          size: 13, color: _textHint),
                      const SizedBox(width: 4),
                      Text(phoneDisplay,
                          style: const TextStyle(
                              fontSize: 13, color: _textHint)),
                    ],
                  ),
                ],
              ] else ...[
                Row(
                  children: [
                    const Expanded(
                      child: Text('未登录',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: _text)),
                    ),
                    _buildLoginButton(),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              Text(
                _tagline,
                style: const TextStyle(fontSize: 13, color: _textSec),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (_joinedDate.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _joinedDate,
                  style: const TextStyle(fontSize: 13, color: _textHint),
                ),
              ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 0),
      ],
    );
  }

  Widget _buildStatItem(String value, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: _text)),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 13,
                  color: _textSec)),
        ],
      ),
    );
  }

  void _promptLogin() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  Widget _buildLoginButton() {
    return FilledButton(
      onPressed: _promptLogin,
      style: FilledButton.styleFrom(
        backgroundColor: _gold,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        minimumSize: const Size(0, 36),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 0,
      ),
      child: const Text('登录', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

/// 吸顶的 TabBar 委托。
class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabController controller;
  final Color backgroundColor;

  _TabBarDelegate({required this.controller, required this.backgroundColor});

  @override
  double get minExtent => 40;
  @override
  double get maxExtent => 40;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: backgroundColor,
      child: TabBar(
        controller: controller,
        labelColor: _text,
        unselectedLabelColor: _textSec,
        dividerColor: const Color(0x1A000000),
        dividerHeight: 0.5,
        indicator: const _FixedWidthIndicator(
          color: Color(0xFF71867A),
          lineWidth: 2.5,
          barWidth: 60,
        ),
        labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
        tabs: const [
          Tab(text: '帖子'),
          Tab(text: '回复'),
          Tab(text: '喜欢'),
          Tab(text: '书签'),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) {
    return controller != oldDelegate.controller ||
        backgroundColor != oldDelegate.backgroundColor;
  }
}

/// 固定宽度的 TabBar 指示条，静止/动画状态宽度一致。
class _FixedWidthIndicator extends Decoration {
  final Color color;
  final double lineWidth;
  final double barWidth;
  const _FixedWidthIndicator({
    required this.color,
    this.lineWidth = 2.5,
    this.barWidth = 60,
  });
  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _FixedWidthPainter(color, lineWidth, barWidth, onChanged);
}

class _FixedWidthPainter extends BoxPainter {
  final Color color;
  final double lineWidth;
  final double barWidth;
  _FixedWidthPainter(this.color, this.lineWidth, this.barWidth, VoidCallback? onChanged)
      : super(onChanged);
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    final x = rect.center.dx - barWidth / 2;
    final y = rect.bottom - lineWidth;
    canvas.drawRect(
      Rect.fromLTWH(x, y, barWidth, lineWidth),
      Paint()..color = color,
    );
  }
}

/// NestedScrollView 内部 Tab 内容包装器。
class _TabContent extends StatelessWidget {
  final Widget child;
  const _TabContent({required this.child});

  @override
  Widget build(BuildContext context) {
    return child;
  }
}

/// 帖子 Tab：我自己发布的广场笔记。
class _MyPostsTab extends StatefulWidget {
  final bool isLoggedIn;
  final ValueNotifier<int> reloadNotifier;
  const _MyPostsTab({required this.isLoggedIn, required this.reloadNotifier});

  @override
  State<_MyPostsTab> createState() => _MyPostsTabState();
}

class _MyPostsTabState extends State<_MyPostsTab> {
  final List<PlazaNote> _notes = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;
  static const int _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _load();
    widget.reloadNotifier.addListener(_onReload);
  }

  @override
  void dispose() {
    widget.reloadNotifier.removeListener(_onReload);
    super.dispose();
  }

  void _onReload() => _load();

  @override
  void didUpdateWidget(covariant _MyPostsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoggedIn && !oldWidget.isLoggedIn) _load();
    if (widget.reloadNotifier != oldWidget.reloadNotifier) {
      oldWidget.reloadNotifier.removeListener(_onReload);
      widget.reloadNotifier.addListener(_onReload);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _notes.clear();
      _page = 1;
      _hasMore = true;
    });
    // 本地笔记始终加载（未登录/未同步时也显示）
    final localNotes = await _loadLocalNotes();
    if (!mounted) return;

    List<PlazaNote> cloudNotes = [];
    bool hasMore = false;
    String? errorText;
    if (widget.isLoggedIn) {
      try {
        final (list, more) = await CloudNotesService.instance.getMyNotes(
          page: 1,
          pageSize: _pageSize,
        );
        cloudNotes = list;
        hasMore = more;
      } catch (e) {
        errorText = '云端加载失败';
      }
    }
    if (!mounted) return;

    final cloudIds = cloudNotes.map((n) => n.id).toSet();
    final merged = <PlazaNote>[
      ...cloudNotes,
      ...localNotes.where((n) => !cloudIds.contains(n.id)),
    ];
    merged.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    setState(() {
      _notes.addAll(merged);
      _hasMore = hasMore;
      _page = 2;
      _error = errorText;
      _loading = false;
    });
  }

  Future<List<PlazaNote>> _loadLocalNotes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('notes') ?? '[]';
      final List<dynamic> list = jsonDecode(raw);
      final uid = AuthService.instance.currentUser.value?.id ?? 'local';
      return list.reversed.map<PlazaNote>((n) {
        final tsStr = n['updatedAt']?.toString() ?? '';
        final ts = DateTime.tryParse(tsStr)?.millisecondsSinceEpoch ?? 0;
        return PlazaNote(
          id: n['id']?.toString() ?? '',
          ownerUserId: uid,
          title: n['title']?.toString() ?? '无标题',
          content: n['content']?.toString() ?? '',
          authorName: '我',
          visibility: 'public',
          status: 'normal',
          likeCount: 0,
          commentCount: 0,
          createdAt: ts,
          updatedAt: ts,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || !widget.isLoggedIn) return;
    setState(() => _loadingMore = true);
    try {
      final (list, more) = await CloudNotesService.instance.getMyNotes(
        page: _page,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _notes.addAll(list);
        _hasMore = more;
        _page++;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  void _openNote(PlazaNote note) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)),
    );
  }

  Widget _tabLoading() {
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          const SliverFillRemaining(
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2.2, color: _gold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabEmpty(String text, IconData icon) {
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          SliverFillRemaining(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 48, color: _textHint),
                  const SizedBox(height: 12),
                  Text(text,
                      style: const TextStyle(fontSize: 14, color: _textHint)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return _tabLoading();
    if (_error != null) return _tabEmpty(_error!, Icons.error_outline);
    if (_notes.isEmpty) return _tabEmpty('还没有发布过帖子', Icons.post_add_outlined);

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          _loadMore();
        }
        return false;
      },
      child: Builder(
        builder: (context) => CustomScrollView(
          slivers: [
            SliverOverlapInjector(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    if (index == _notes.length) {
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
                    return _buildNoteCard(_notes[index]);
                  },
                  childCount: _notes.length + (_hasMore && widget.isLoggedIn ? 1 : 0),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoteCard(PlazaNote note) {
    final content = note.content.replaceAll(RegExp(r'\[@([^\]]+)\]\([^)]+\)'), r'@$1');
    final preview = content.length > 60
        ? '${content.substring(0, 60)}...'
        : content;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 8,
              offset: const Offset(0, 1)),
        ],
      ),
      child: InkWell(
        onTap: () => _openNote(note),
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(note.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _text)),
            if (preview.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, color: _textSec, height: 1.4)),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.schedule, size: 12, color: _textHint),
                const SizedBox(width: 3),
                Text(_fmtTime(note.createdAt),
                    style: const TextStyle(fontSize: 11, color: _textHint)),
                const Spacer(),
                Icon(
                  CloudNotesService.instance.likedNoteIds.contains(note.id)
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  size: 13,
                  color: CloudNotesService.instance.likedNoteIds.contains(note.id)
                      ? _gold
                      : _textHint,
                ),
                const SizedBox(width: 2),
                Text('${note.likeCount}',
                    style: const TextStyle(fontSize: 11, color: _textHint)),
                const SizedBox(width: 12),
                const Icon(Icons.chat_bubble_outline, size: 12, color: _textHint),
                const SizedBox(width: 2),
                Text('${note.commentCount}',
                    style: const TextStyle(fontSize: 11, color: _textHint)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = DateTime(now.year, now.month, now.day)
        .difference(DateTime(t.year, t.month, t.day))
        .inDays;
    if (diff == 0) return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (diff == 1) return '昨天';
    return '${t.month}月${t.day}日';
  }
}

/// 回复 Tab：我的互动动态（转发 + 评论/回复）。
class _MyRepliesTab extends StatefulWidget {
  final bool isLoggedIn;
  final ValueNotifier<int> reloadNotifier;
  const _MyRepliesTab({required this.isLoggedIn, required this.reloadNotifier});

  @override
  State<_MyRepliesTab> createState() => _MyRepliesTabState();
}

class _MyRepliesTabState extends State<_MyRepliesTab> {
  final List<PlazaActivity> _activities = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;
  static const int _pageSize = 20;

  @override
  void initState() {
    super.initState();
    if (widget.isLoggedIn) _load();
    widget.reloadNotifier.addListener(_onReload);
  }

  @override
  void dispose() {
    widget.reloadNotifier.removeListener(_onReload);
    super.dispose();
  }

  void _onReload() {
    if (widget.isLoggedIn) _load();
  }

  @override
  void didUpdateWidget(covariant _MyRepliesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoggedIn && !oldWidget.isLoggedIn) _load();
    if (widget.reloadNotifier != oldWidget.reloadNotifier) {
      oldWidget.reloadNotifier.removeListener(_onReload);
      widget.reloadNotifier.addListener(_onReload);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _activities.clear();
      _page = 1;
      _hasMore = true;
    });
    try {
      final (list, more) = await CloudNotesService.instance.getMyActivities(
        page: 1,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _activities.addAll(list);
        _hasMore = more;
        _page = 2;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final (list, more) = await CloudNotesService.instance.getMyActivities(
        page: _page,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _activities.addAll(list);
        _hasMore = more;
        _page++;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  void _openNote(String noteId) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: noteId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoggedIn) {
      return _tabEmpty('请先登录', Icons.lock_outlined);
    }
    if (_loading) return _tabLoading();
    if (_error != null) return _tabEmpty(_error!, Icons.error_outline);
    if (_activities.isEmpty) {
      return _tabEmpty('还没有互动记录', Icons.reply_outlined);
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          _loadMore();
        }
        return false;
      },
      child: Builder(
        builder: (context) => CustomScrollView(
          slivers: [
            SliverOverlapInjector(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    if (index == _activities.length) {
                      return const Padding(
                        padding: EdgeInsets.all(20),
                        child: Center(
                          child: SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: _gold),
                          ),
                        ),
                      );
                    }
                    return _buildActivityCard(_activities[index]);
                  },
                  childCount: _activities.length + (_hasMore ? 1 : 0),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabLoading() {
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          const SliverFillRemaining(
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2.2, color: _gold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabEmpty(String text, IconData icon) {
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          SliverFillRemaining(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 48, color: _textHint),
                  const SizedBox(height: 12),
                  Text(text,
                      style: const TextStyle(fontSize: 14, color: _textHint)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityCard(PlazaActivity activity) {
    final typeIcon = activity.type == 'repost'
        ? Icons.repeat_rounded
        : Icons.chat_bubble_outline;
    final typeLabel = activity.type == 'repost' ? '转发' : '回复';
    Color typeColor;
    switch (activity.type) {
      case 'repost':
        typeColor = _gold;
        break;
      case 'comment':
        typeColor = _primaryLight;
        break;
      default:
        typeColor = _primary;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 8,
              offset: const Offset(0, 1)),
        ],
      ),
      child: InkWell(
        onTap: () => _openNote(activity.noteId),
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(typeIcon, size: 14, color: typeColor),
                const SizedBox(width: 4),
                Text(typeLabel,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: typeColor)),
                const Spacer(),
                Text(_fmtTime(activity.createdAt),
                    style: const TextStyle(
                        fontSize: 11, color: _textHint)),
              ],
            ),
            if (activity.content.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(activity.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, color: _text, height: 1.5)),
            ],
            if (activity.noteTitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _bg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.article_outlined,
                        size: 13, color: _textHint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(activity.noteTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: _textSec)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = DateTime(now.year, now.month, now.day)
        .difference(DateTime(t.year, t.month, t.day))
        .inDays;
    if (diff == 0) return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (diff == 1) return '昨天';
    return '${t.month}月${t.day}日';
  }
}

/// 喜欢 Tab：我点赞过的帖子列表。
class _MyLikesTab extends StatefulWidget {
  final bool isLoggedIn;
  final ValueNotifier<int> reloadNotifier;
  const _MyLikesTab({required this.isLoggedIn, required this.reloadNotifier});

  @override
  State<_MyLikesTab> createState() => _MyLikesTabState();
}

class _MyLikesTabState extends State<_MyLikesTab> {
  List<PlazaNote>? _notes;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.isLoggedIn) _load();
    widget.reloadNotifier.addListener(_onReload);
  }

  @override
  void dispose() {
    widget.reloadNotifier.removeListener(_onReload);
    super.dispose();
  }

  void _onReload() {
    if (widget.isLoggedIn) _load();
  }

  @override
  void didUpdateWidget(covariant _MyLikesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoggedIn && !oldWidget.isLoggedIn) _load();
    if (widget.reloadNotifier != oldWidget.reloadNotifier) {
      oldWidget.reloadNotifier.removeListener(_onReload);
      widget.reloadNotifier.addListener(_onReload);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final notes = await CloudNotesService.instance.getLikedNotes();
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notes = [];
        _error = '加载失败';
        _loading = false;
      });
    }
  }

  void _openNote(PlazaNote note) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoggedIn) {
      return _tabEmpty('请先登录', Icons.lock_outlined);
    }
    if (_loading) return _tabLoading();
    if (_error != null) return _tabEmpty(_error!, Icons.error_outline);
    if (_notes == null || _notes!.isEmpty) {
      return _tabEmpty('还没有点赞过帖子', Icons.favorite_border);
    }
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final note = _notes![index];
                  final content = note.content.replaceAll(
                      RegExp(r'\[@([^\]]+)\]\([^)]+\)'), r'@$1');
                  final preview = content.length > 60
                      ? '${content.substring(0, 60)}...'
                      : content;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 8,
                            offset: const Offset(0, 1)),
                      ],
                    ),
                    child: InkWell(
                      onTap: () => _openNote(note),
                      borderRadius: BorderRadius.circular(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.person_outline, size: 13, color: _textHint),
                              const SizedBox(width: 4),
                              Text(note.authorName,
                                  style: const TextStyle(fontSize: 12, color: _textSec)),
                              const Spacer(),
                              const Icon(Icons.favorite_rounded, size: 12, color: _gold),
                              const SizedBox(width: 2),
                              Text('${note.likeCount}',
                                  style: const TextStyle(fontSize: 11, color: _textHint)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(note.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: _text)),
                          if (preview.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(preview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13, color: _textSec, height: 1.4)),
                          ],
                        ],
                      ),
                    ),
                  );
                },
                childCount: _notes!.length,
              ),
            ),
          ),
        ],
      ),
    );
  }  // _MyLikesTab build

  Widget _tabLoading() {
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          const SliverFillRemaining(
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2.2, color: _gold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabEmpty(String text, IconData icon) {
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          SliverFillRemaining(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 48, color: _textHint),
                  const SizedBox(height: 12),
                  Text(text,
                      style: const TextStyle(fontSize: 14, color: _textHint)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 书签 Tab：我收藏的笔记（已登录）。
class _MyBookmarksTab extends StatefulWidget {
  final bool isLoggedIn;
  final ValueNotifier<int> reloadNotifier;
  const _MyBookmarksTab({required this.isLoggedIn, required this.reloadNotifier});

  @override
  State<_MyBookmarksTab> createState() => _MyBookmarksTabState();
}

class _MyBookmarksTabState extends State<_MyBookmarksTab> {
  List<PlazaNote>? _notes;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.isLoggedIn) _load();
    widget.reloadNotifier.addListener(_onReload);
  }

  @override
  void dispose() {
    widget.reloadNotifier.removeListener(_onReload);
    super.dispose();
  }

  void _onReload() {
    if (widget.isLoggedIn) _load();
  }

  @override
  void didUpdateWidget(covariant _MyBookmarksTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoggedIn && !oldWidget.isLoggedIn) _load();
    if (widget.reloadNotifier != oldWidget.reloadNotifier) {
      oldWidget.reloadNotifier.removeListener(_onReload);
      widget.reloadNotifier.addListener(_onReload);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final notes = await CloudNotesService.instance.getFavoriteNotes();
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notes = [];
        _error = '加载失败';
        _loading = false;
      });
    }
  }

  void _openNote(PlazaNote note) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)),
    ).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoggedIn) {
      return _tabEmpty('请先登录', Icons.lock_outlined);
    }
    if (_loading) return _tabLoading();
    if (_error != null) return _tabEmpty(_error!, Icons.error_outline);
    if (_notes == null || _notes!.isEmpty) {
      return _tabEmpty('还没有收藏过帖子', Icons.bookmark_border);
    }
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final note = _notes![index];
                  final content = note.content.replaceAll(
                      RegExp(r'\[@([^\]]+)\]\([^)]+\)'), r'@$1');
                  final preview = content.length > 60
                      ? '${content.substring(0, 60)}...'
                      : content;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 8,
                            offset: const Offset(0, 1)),
                      ],
                    ),
                    child: InkWell(
                      onTap: () => _openNote(note),
                      borderRadius: BorderRadius.circular(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.bookmark_rounded, size: 13, color: _gold),
                              const SizedBox(width: 4),
                              Text(note.authorName,
                                  style: const TextStyle(fontSize: 12, color: _textSec)),
                              const Spacer(),
                              Text(_fmtTime(note.createdAt),
                                  style: const TextStyle(fontSize: 11, color: _textHint)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(note.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: _text)),
                          if (preview.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(preview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13, color: _textSec, height: 1.4)),
                          ],
                        ],
                      ),
                    ),
                  );
                },
                childCount: _notes!.length,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabLoading() {
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          const SliverFillRemaining(
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2.2, color: _gold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabEmpty(String text, IconData icon) {
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          SliverFillRemaining(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 48, color: _textHint),
                  const SizedBox(height: 12),
                  Text(text,
                      style: const TextStyle(fontSize: 14, color: _textHint)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = DateTime(now.year, now.month, now.day)
        .difference(DateTime(t.year, t.month, t.day))
        .inDays;
    if (diff == 0) return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (diff == 1) return '昨天';
    return '${t.month}月${t.day}日';
  }
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage();

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  bool _notifOn = false;
  bool _reminderOn = false;
  String _reminderTime = '21:00';
  bool _loaded = false;

  bool get _isLoggedIn => AuthService.instance.isLoggedIn;

  bool get notifOn => _notifOn;
  bool get reminderOn => _reminderOn;
  String get reminderTime => _reminderTime;

  void reloadForSettings() => _load();

  void requireLogin() => _pushLogin();

  Future<void> toggleNotif(bool v) => _toggleNotif(v);

  @override
  void initState() {
    super.initState();
    _load();
    AuthService.instance.currentUser.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    AuthService.instance.currentUser.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    _notifOn = await NotificationService.instance.isMasterEnabled();
    _reminderOn = await NotificationService.instance.isReminderEnabled();
    _reminderTime = await NotificationService.instance.getReminderTime();
    if (mounted) setState(() => _loaded = true);
  }

  void _pushLogin() {
    _showToast('请先登录');
    Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  Future<void> _toggleNotif(bool value) async {
    final ok = await NotificationService.instance.setMasterEnabled(value);
    if (!mounted) return;
    if (!ok) {
      _showToast('未获得通知权限，请在系统设置中开启');
      return;
    }
    setState(() => _notifOn = value);
    await _load();
  }

  void _showToast(String text) {
    if (!mounted) return;
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
                color: _primary,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
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

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(text,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _textSec)),
    );
  }

  Widget _buildLogoutRow() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2)),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        leading: const Icon(Icons.logout, size: 20, color: Colors.redAccent),
        title: const Text('退出登录', style: TextStyle(fontSize: 15, color: Colors.redAccent)),
        trailing: const Icon(Icons.chevron_right, color: _textHint, size: 20),
        onTap: _confirmLogout,
      ),
    );
  }

  Future<void> _confirmLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('退出登录', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: const Text('退出后需重新登录才能管理云端笔记', style: TextStyle(color: _textSec)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: _textSec))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await AuthService.instance.logout();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          Container(
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
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_ios_new, color: _text, size: 20),
                    ),
                    const SizedBox(width: 4),
                    const Text('设置', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: _loaded
                ? ListView(
                    padding: const EdgeInsets.only(top: 4, bottom: 32),
                    children: [
                      _sectionTitle('阅读与提醒'),
                      SettingsCard(
                        children: [
                          _SettingsLinkTile(
                            icon: Icons.text_fields,
                            iconColor: _gold,
                            title: '阅读偏好',
                            subtitle: '字号 · 行距 · 背景 · 翻页方式',
                            page: const ReaderSettingsPage(),
                          ),
                          const SettingsDivider(),
                          const _SettingsReminderTile(),
                        ],
                      ),
                      _sectionTitle('账号'),
                      SettingsCard(
                        children: [
                          _SettingsPhoneTile(),
                          const SettingsDivider(),
                          _SettingsNotifTile(),
                        ],
                      ),
                      _sectionTitle('其他'),
                      SettingsCard(
                        children: [
                          _SettingsLinkTile(
                            icon: Icons.info_outline,
                            iconColor: _primaryLight,
                            title: '关于我们',
                            subtitle: '版本 · 介绍 · 版权',
                            page: const AboutPage(),
                          ),
                        ],
                      ),
                      if (_isLoggedIn) ...[
                        const SizedBox(height: 14),
                        _buildLogoutRow(),
                      ],
                    ],
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
        ],
      ),
    );
  }
}

class _SettingsLinkTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget page;

  const _SettingsLinkTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.page,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Navigator.push(context, slideInFromLeft(page)).then((_) {
          if (context.mounted) {
            context.findAncestorStateOfType<_SettingsPageState>()?.reloadForSettings();
          }
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, color: _text, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: _textHint)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: _textHint, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 打卡提醒行：显示开关状态与时间，点击进入设置。
class _SettingsReminderTile extends StatelessWidget {
  const _SettingsReminderTile();

  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_SettingsPageState>()!;
    return InkWell(
      onTap: () {
        Navigator.push(context, slideInFromLeft(const CheckinReminderPage()))
            .then((_) => state.reloadForSettings());
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.alarm_outlined, color: _gold, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('打卡提醒', style: TextStyle(fontSize: 16, color: _text, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(
                    state.reminderOn ? '每日 ${state.reminderTime}' : '未开启',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _textHint),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: _textHint, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 更换手机号行：未登录时引导登录。
class _SettingsPhoneTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_SettingsPageState>()!;
    return InkWell(
      onTap: () {
        if (!AuthService.instance.isLoggedIn) {
          state.requireLogin();
          return;
        }
        Navigator.push(context, slideInFromLeft(const ChangePhonePage()))
            .then((_) => state.reloadForSettings());
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _primaryLight.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.phone_iphone_outlined, color: _primaryLight, size: 20),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('更换手机号', style: TextStyle(fontSize: 16, color: _text, fontWeight: FontWeight.w500)),
                  SizedBox(height: 2),
                  Text('更换后数据自动保留', style: TextStyle(fontSize: 12, color: _textHint)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: _textHint, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 消息通知总开关行。
class _SettingsNotifTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_SettingsPageState>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.notifications_outlined, color: _gold, size: 20),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('消息通知', style: TextStyle(fontSize: 16, color: _text, fontWeight: FontWeight.w500)),
                SizedBox(height: 2),
                Text('打卡提醒等系统通知', style: TextStyle(fontSize: 12, color: _textHint)),
              ],
            ),
          ),
          SwitchTheme(
            data: SwitchThemeData(
              trackOutlineColor: WidgetStateProperty.resolveWith((_) => Colors.transparent),
            ),
            child: Switch(
              value: state.notifOn,
              activeThumbColor: _card,
              activeTrackColor: _gold,
              onChanged: state.toggleNotif,
            ),
          ),
        ],
      ),
    );
  }
}
