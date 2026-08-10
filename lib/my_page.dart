import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';
import 'reader_settings_page.dart';
import 'edit_profile_page.dart';
import 'change_phone_page.dart';
import 'forgot_password_page.dart';
import 'about_page.dart';
import 'notification_service.dart';
import 'settings_widgets.dart';
import 'text_input_sheet.dart';
import 'user_list_page.dart';
import 'note_edit_page.dart';
import 'note_detail_page.dart';
import 'quote_box.dart';
import 'note_sutra_links.dart';
import 'user_avatar.dart';
import 'user_space_page.dart';
import 'post_time_link.dart';
import 'post_rich_content.dart';
import 'reply_thread.dart';
import 'reply_chain.dart';
import 'certification_page.dart';
import 'note_stats_center.dart';
import 'reading_badges.dart';
import 'reading_time_service.dart';

const Color _primary = Color(0xFF5C4033);
const Color _primaryLight = Color(0xFF8B6B5A);
const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _border = Color(0xFFEBE1D6);

/// 从左侧边缘滑入的页面路由。
Route<T> slideInFromLeft<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
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

class MyPageState extends State<MyPage> with TickerProviderStateMixin {
  String? _avatarPath;
  String? _bannerPath;
  String _nickname = '同修';
  String _tagline = '燃一盏灯，看见自己，照亮别人。';
  String _accountName = '';
  bool _verified = false;

  /// 累计读经时长（秒）：驱动昵称行右侧的五枚修学徽章点亮。
  int _readingSeconds = 0;
  String _joinedDate =
      '${DateTime.now().year}年${DateTime.now().month}月${DateTime.now().day}日加入';

  /// 保存资料成功后，在横幅下边缘显示的"已保存"气泡。
  bool _showSavedBubble = false;

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
    _tabController = TabController(length: 5, vsync: this);
    _loadData();
    _loadCounts();
    AuthService.instance.currentUser.addListener(_onAuthChanged);
    ReadingTimeService.instance.totalSeconds.addListener(_onReadingSeconds);
  }

  @override
  void dispose() {
    _reloadNotifier.dispose();
    AuthService.instance.currentUser.removeListener(_onAuthChanged);
    ReadingTimeService.instance.totalSeconds.removeListener(_onReadingSeconds);
    _tabController.dispose();
    super.dispose();
  }

  void _onReadingSeconds() {
    if (!mounted) return;
    setState(() => _readingSeconds = ReadingTimeService.instance.totalSeconds.value);
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
    final av = prefs.getString('user_avatar_path');
    final bn = prefs.getString('user_banner_path');
    setState(() {
      if (av != null) _avatarPath = av;
      if (bn != null) _bannerPath = bn;
      if (_isLoggedIn) {
        _nickname = user?.displayName ?? '同修';
        _tagline =
            (user?.tagline?.isNotEmpty ?? false) ? user!.tagline! : '燃一盏灯，看见自己，照亮别人。';
      } else {
        _nickname = prefs.getString('user_nickname') ?? '同修';
        _tagline = prefs.getString('user_tagline') ?? '燃一盏灯，看见自己，照亮别人。';
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
    _loadAccountName();
    _loadVerification();
    unawaited(_loadReadingBadge());
  }

  /// 读经徽章：读取本地累计时长驱动徽章点亮；首次点亮新徽章时弹恭喜。
  Future<void> _loadReadingBadge() async {
    await ReadingTimeService.instance.ensureLoaded();
    if (!mounted) return;
    final s = ReadingTimeService.instance.totalSeconds.value;
    setState(() => _readingSeconds = s);
    if (_isLoggedIn && s > 0) {
      await maybeCelebrateNewBadge(context, s);
    }
    // 刷新本地阅藏进度统计（主页 @账户 行右侧的「阅藏x%」）。
    await LocalCanonProgress.refresh();
    if (mounted) setState(() {});
  }

  Future<void> _loadAccountName() async {
    final name = await AuthService.instance.getAccountName();
    if (!mounted) return;
    setState(() => _accountName = name);
  }

  /// 实名认证状态：优先取云端，云端失败时回退到本地缓存。
  Future<void> _loadVerification() async {
    final prefs = await SharedPreferences.getInstance();
    var verified = prefs.getBool('user_verified') ?? false;
    if (_isLoggedIn) {
      try {
        final info = await CloudNotesService.instance.getMyVerification();
        verified = info.verified;
        await prefs.setBool('user_verified', verified);
      } catch (_) {}
    } else {
      verified = false;
    }
    if (!mounted) return;
    setState(() => _verified = verified);
  }

  void _openCertification() {
    Navigator.push(context, slideInFromLeft(const CertificationPage()))
        .then((_) => _loadVerification());
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
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 24),
                  ],
                  image: _avatarPath != null
                      ? DecorationImage(
                          image: FileImage(File(_avatarPath!)),
                          fit: BoxFit.cover)
                      : const DecorationImage(
                          image: AssetImage('assets/images/app_icon.png'),
                          fit: BoxFit.cover),
                ),
                child: null,
              ),
              const SizedBox(height: 16),
              const Text('轻触任意处关闭',
                  style: TextStyle(fontSize: 13, color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _viewBanner() async {
    if (_bannerPath == null || !File(_bannerPath!).existsSync()) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.pop(ctx),
        behavior: HitTestBehavior.opaque,
        child: Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              InteractiveViewer(
                maxScale: 5,
                minScale: 1,
                child: SizedBox.expand(
                  child: Image.file(
                    File(_bannerPath!),
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.close, color: Colors.white70, size: 26),
                  ),
                ),
              ),
              const SafeArea(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 24),
                    child: Text('轻触任意处关闭 · 双指缩放',
                        style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ),
                ),
              ),
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
    Navigator.push(context, slideInFromLeft(const EditProfilePage()))
        .then((saved) {
      _loadData();
      if (saved == true) _flashSavedBubble();
    });
  }

  /// 在个人主页横幅下边缘（与"编辑个人资料"按钮同一水平线）短暂显示"已保存"气泡。
  void _flashSavedBubble() {
    if (!mounted) return;
    setState(() => _showSavedBubble = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showSavedBubble = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = _isLoggedIn;

    return Scaffold(
      backgroundColor: _bg,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(
          width: 48,
          height: 48,
          child: FloatingActionButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NoteEditPage()),
            ).then((_) => reload()),
            heroTag: 'my_page_plaza_fab',
            backgroundColor: const Color(0xFF71867A),
            elevation: 8,
            highlightElevation: 12,
            shape: const CircleBorder(),
            child: const Icon(Icons.add, color: Colors.white, size: 24),
          ),
        ),
      ),
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
              _TabContent(
                  child: _MyPostsTab(
                      isLoggedIn: isLoggedIn, reloadNotifier: _reloadNotifier)),
              _TabContent(
                  child: _MyRepliesTab(
                      isLoggedIn: isLoggedIn, reloadNotifier: _reloadNotifier)),
              _TabContent(
                  child: _MyLikesTab(
                      isLoggedIn: isLoggedIn, reloadNotifier: _reloadNotifier)),
              _TabContent(
                  child: _MyBookmarksTab(
                      isLoggedIn: isLoggedIn, reloadNotifier: _reloadNotifier)),
              _TabContent(child: _MyDraftsTab(reloadNotifier: _reloadNotifier)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileHeader(bool isLoggedIn) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 226,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 160,
                child: GestureDetector(
                  onTap: _viewBanner,
                  child: Container(
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
                            child: Icon(Icons.camera_alt_outlined,
                                size: 28, color: Colors.white38),
                          )
                        : null,
                  ),
                ),
              ),
              Positioned(
                right: 8,
                top: 168,
                child: GestureDetector(
                  onTap: _openEditProfile,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: const Text(
                      '编辑个人资料',
                      style: TextStyle(
                        fontSize: 12,
                        color: _text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              if (_showSavedBubble)
                Positioned(
                  right: 118,
                  top: 168,
                  child: Material(
                    color: _primary,
                    borderRadius: BorderRadius.circular(20),
                    elevation: 0,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle,
                              size: 14, color: Colors.white),
                          const SizedBox(width: 5),
                          const Text(
                            '已保存',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.none,
                              decorationColor: Colors.transparent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 20,
                top: 122,
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
                          : const DecorationImage(
                              image: AssetImage('assets/images/app_icon.png'),
                              fit: BoxFit.cover),
                    ),
                    child: null,
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
                if (isLoggedIn) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(_nickname,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                      color: _text)),
                            ),
                            if (_verified) ...[
                              const SizedBox(width: 4),
                              _buildVerifiedBadge(),
                            ] else ...[
                              const SizedBox(width: 12),
                              _buildCertifyButton(),
                            ],
                          ],
                        ),
                      ),
                      // 修学徽章：依累计读经时长点亮，点击查看五品详情。
                      const SizedBox(width: 8),
                      ReadingBadgesRow(
                        seconds: _readingSeconds,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  BadgeDetailPage(seconds: _readingSeconds)),
                        ),
                      ),
                    ],
                  ),
                  if (_isLoggedIn && _accountName.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          // 账号名完整展示：允许换行，不在任何屏幕宽度下截断。
                          child: Text('@$_accountName',
                              style: const TextStyle(
                                  fontSize: 13, color: _textHint)),
                        ),
                        // 阅藏进度：完成册数 ÷ 总册数（0% 也显示），点击看徽章详情。
                        ReadingProgressChip(
                          text: canonPercentText(
                              LocalCanonProgress.read,
                              LocalCanonProgress.total),
                        ),
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
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.calendar_month_outlined,
                          size: 14, color: _textHint),
                      const SizedBox(width: 4),
                      Text(
                        _joinedDate,
                        style: const TextStyle(fontSize: 13, color: _textHint),
                      ),
                      const Spacer(),
                      if (isLoggedIn)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _openSettings,
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.settings_outlined,
                                size: 20, color: Color(0xFF8C8C8C)),
                          ),
                        ),
                    ],
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
                  fontSize: 16, fontWeight: FontWeight.w700, color: _text)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 13, color: _textSec)),
        ],
      ),
    );
  }

  void _promptLogin() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  /// 未认证时昵称旁的「获得认证」按钮：灰色圆角框 + 图标 + 文案。
  Widget _buildCertifyButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openCertification,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFEFE9E2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Color(0xFFBDBDBD)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_outlined, size: 13, color: Color(0xFF70867A)),
            SizedBox(width: 3),
            Text('获得认证',
                style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF70867A),
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  /// 已认证时昵称后的认证标识：绿色对勾 + 「已认证」，线圈包裹。
  Widget _buildVerifiedBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF1EC),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFF70867A), width: 0.8),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified, size: 13, color: Color(0xFF70867A)),
          SizedBox(width: 3),
          Text('已认证',
              style: TextStyle(
                  fontSize: 10,
                  color: Color(0xFF70867A),
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
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
      child: const Text('登录',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
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
        unselectedLabelStyle:
            const TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
        tabs: const [
          Tab(text: '帖子'),
          Tab(text: '回复'),
          Tab(text: '喜欢'),
          Tab(text: '书签'),
          Tab(text: '草稿'),
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
  _FixedWidthPainter(
      this.color, this.lineWidth, this.barWidth, VoidCallback? onChanged)
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

/// 时间显示：今天「今日x时」，今年「x月x日x时」，往年「x年x月x日x时」。
String postTime(int ms) {
  if (ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return '今日${t.hour}时';
  }
  if (t.year == now.year) return '${t.month}月${t.day}日${t.hour}时';
  return '${t.year}年${t.month}月${t.day}日${t.hour}时';
}

/// 帖子块：左列头像，右侧第一行昵称/时间戳，内容与指标行与昵称同一左缘。
/// onTap 为 null 时点击整块展开/收起内容，否则执行 onTap。
/// allowActions=true 时指标行可交互（评论/转发/点赞），评论内嵌显示在下方。
class PostBlock extends StatefulWidget {
  final String? ownerUserId;
  final String nickname;
  final String account;
  final bool authorVerified;

  /// 作者「阅藏进度」原始数据（完成册数/总册数）：帖子行百分比展示用。
  final int canonRead;
  final int canonTotal;
  final int timeMs;
  final String content;
  final Widget? stats;
  final VoidCallback? onTap;
  final String? noteId;
  final bool allowActions;
  final int likeCount;
  final int repostCount;
  final int commentCount;
  final int viewCount;
  final VoidCallback? onReplyPosted;
  final Widget? quoteBox;
  final bool pinned;
  final bool isRepost;
  final bool isQuoteRepost;
  final VoidCallback? onTogglePin;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool showFollowButton;

  /// 点击自己的头像/昵称时的回调（如切换到「我的」页）；为空时仍进入个人主页空间。
  final VoidCallback? onOpenSelf;
  const PostBlock({
    required this.ownerUserId,
    required this.nickname,
    this.account = '',
    this.authorVerified = false,
    this.canonRead = 0,
    this.canonTotal = 0,
    required this.timeMs,
    required this.content,
    this.stats,
    this.onTap,
    this.noteId,
    this.allowActions = false,
    this.likeCount = 0,
    this.repostCount = 0,
    this.commentCount = 0,
    this.viewCount = 0,
    this.onReplyPosted,
    this.quoteBox,
    this.pinned = false,
    this.isRepost = false,
    this.isQuoteRepost = false,
    this.onTogglePin,
    this.onEdit,
    this.onDelete,
    this.showFollowButton = true,
    this.onOpenSelf,
  });

  @override
  State<PostBlock> createState() => _PostBlockState();
}

class _PostBlockState extends State<PostBlock> {
  bool _expanded = false;
  late int _likeCount = widget.likeCount;
  late int _repostCount = widget.repostCount;
  late int _commentCount = widget.commentCount;
  late int _viewCount = widget.viewCount;
  late bool _liked = widget.noteId != null &&
      CloudNotesService.instance.likedNoteIds.contains(widget.noteId);
  late bool _following = widget.ownerUserId != null &&
      CloudNotesService.instance.followingUserIds.contains(widget.ownerUserId);

  @override
  void initState() {
    super.initState();
    // 实时同步指标：详情页点赞/评论/转发/阅读后，这里的数字立即更新。
    NoteStatsCenter.instance.addListener(_onStatsChanged);
  }

  @override
  void dispose() {
    NoteStatsCenter.instance.removeListener(_onStatsChanged);
    super.dispose();
  }

  void _onStatsChanged() {
    final id = widget.noteId;
    if (id == null) return;
    final n = NoteStatsCenter.instance.latest(id);
    if (n == null || !mounted) return;
    setState(() {
      _likeCount = n.likeCount;
      _repostCount = n.repostCount;
      _commentCount = n.commentCount;
      _viewCount = n.viewCount;
    });
  }

  /// 点击头像/昵称进入该用户个人主页空间。
  /// 自己的头像且提供了 [onOpenSelf] 回调时走回调（与主页头像入口保持一致）。
  void _openUserSpace() {
    final uid = widget.ownerUserId;
    if (uid == null || uid.isEmpty) return;
    final me = AuthService.instance.currentUser.value;
    if (me != null && me.id == uid) {
      final cb = widget.onOpenSelf;
      if (cb != null) {
        cb();
        return;
      }
    }
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) =>
              UserSpacePage(userId: uid, userName: widget.nickname)),
    );
  }

  /// 关注/取消关注帖子作者（已关注的同修在首页「关注」栏目展示其新帖）。
  Future<void> _toggleFollow() async {
    final me = AuthService.instance.currentUser.value;
    final target = widget.ownerUserId;
    if (me == null) {
      if (mounted) {
        Navigator.push(
            context, MaterialPageRoute(builder: (_) => const LoginPage()));
      }
      return;
    }
    if (target == null || target.isEmpty || target == me.id) return;
    try {
      final ok = await CloudNotesService.instance.toggleFollow(target);
      if (!mounted) return;
      setState(() => _following = ok);
      showPostToast(context, ok ? '已关注' : '已取消关注');
    } catch (e) {
      if (mounted) showPostToast(context, e.toString());
    }
  }

  Future<void> _toggleLike() async {
    final noteId = widget.noteId;
    if (noteId == null) return;
    try {
      final (liked, count) =
          await CloudNotesService.instance.toggleLike(noteId);
      if (!mounted) return;
      setState(() {
        _liked = liked;
        // 点赞时确保数字至少 +1（服务端偶尔返回旧值时的兜底）。
        _likeCount =
            liked ? math.max(count, _likeCount + 1) : math.max(0, count);
      });
    } catch (e) {
      if (mounted) showPostToast(context, e.toString());
    }
  }

  /// 回复：增加原帖评论量，并生成一条新帖子（回复内容在上、被回复帖子在下，引用转发样式）。
  Future<void> _openReplySheet() async {
    final noteId = widget.noteId;
    if (noteId == null) return;
    if (!AuthService.instance.isLoggedIn) return;
    // 统一使用大弹层输入（minLines 3 / maxLines 10），长内容编辑体验更好。
    final content = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const SheetTextInput(
        title: '回复',
        hint: '写下你的回复…',
        maxLength: 500,
        minLines: 3,
        maxLines: 10,
        confirmText: '发表',
      ),
    );
    if (content == null || content.isEmpty) return;
    await _submitReply(content);
  }

  Future<void> _submitReply(String content) async {
    final noteId = widget.noteId;
    if (noteId == null || content.isEmpty) return;
    try {
      // 1) 评论原帖：只增加评论量，不在帖子下方内嵌显示。
      await CloudNotesService.instance.createComment(noteId, content);
      // 2) 生成新帖子（引用转发样式：回复内容在上、被回复的帖子在下）。
      final replyId = await CloudNotesService.instance
          .repostNote(noteId, quote: content, kind: 'reply');
      if (!mounted) return;
      setState(() => _commentCount++);
      if (mounted && replyId.isNotEmpty) {
        showPostPublishedToast(context, replyId);
      }
      if (widget.onReplyPosted != null) {
        try {
          final dynamic cb = widget.onReplyPosted!;
          final r = cb();
          if (r is Future) await r.catchError((_) {});
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) showPostToast(context, e.toString());
    }
  }

  Future<void> _repost() async {
    final noteId = widget.noteId;
    if (noteId == null || !AuthService.instance.isLoggedIn) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text('转发到菩提空间',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            const Divider(height: 1, color: _border),
            postMenuItem(ctx, 'direct', Icons.repeat_rounded, '直接转发'),
            postMenuItem(ctx, 'quote', Icons.format_quote_rounded, '引用转发'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    String quote = '';
    if (choice == 'quote') {
      quote = (await showModalBottomSheet<String>(
            context: context,
            isScrollControlled: true,
            backgroundColor: _card,
            shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
            builder: (_) => const SheetTextInput(
              title: '引用转发',
              hint: '写点自己的感想…',
              maxLength: 500,
              minLines: 2,
              maxLines: 3,
              confirmText: '转发',
            ),
          )) ??
          '';
      if (quote.isEmpty) return;
    }
    try {
      await CloudNotesService.instance.repostNote(noteId,
          quote: quote, kind: quote.isEmpty ? 'forward' : 'quote');
      if (!mounted) return;
      setState(() => _repostCount++);
      showPostToast(context, quote.isEmpty ? '已转发到菩提空间' : '已引用转发到菩提空间');
      if (widget.onReplyPosted != null) {
        try {
          final dynamic cb = widget.onReplyPosted!;
          final r = cb();
          if (r is Future) await r.catchError((_) {});
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) showPostToast(context, e.toString());
    }
  }

  /// 帖子管理菜单：置顶/取消置顶、编辑、删除（仅自己的帖子）。
  Future<void> _showManageMenu() async {
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
              child: Text(widget.nickname,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            const Divider(height: 1, color: _border),
            if (widget.onTogglePin != null)
              postMenuItem(ctx, 'pin', Icons.push_pin_outlined,
                  widget.pinned ? '取消置顶' : '置顶'),
            if (widget.onEdit != null)
              postMenuItem(ctx, 'edit', Icons.edit_outlined, '编辑'),
            if (widget.onDelete != null)
              postMenuItem(ctx, 'delete', Icons.delete_outline, '删除'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'pin':
        widget.onTogglePin?.call();
        break;
      case 'edit':
        widget.onEdit?.call();
        break;
      case 'delete':
        widget.onDelete?.call();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = AuthService.instance.currentUser.value;
    final showMore =
        me != null && widget.ownerUserId != null && widget.ownerUserId != me.id;
    final canManage = me != null &&
        widget.ownerUserId != null &&
        widget.ownerUserId == me.id &&
        widget.noteId != null &&
        (widget.onTogglePin != null ||
            widget.onEdit != null ||
            widget.onDelete != null);
    final content = widget.content;
    // 测量用的纯文本：剥离 [@账号](user:ID) / [@经名](路径) 标记，渲染仍用原文。
    final measureContent =
        content.replaceAll(RegExp(r'\[@([^\]]+)\]\([^)]+\)'), r'@$1');
    // 阅藏进度百分比：自己的帖子用本地实时统计，他人的用云端数据（0% 也显示）。
    final postPct = postCanonPercent(
      isSelf: me != null && widget.ownerUserId == me.id,
      cloudRead: widget.canonRead,
      cloudTotal: widget.canonTotal,
    );
    return InkWell(
      onTap: widget.onTap ?? () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openUserSpace,
              child: UserAvatar(userId: widget.ownerUserId, radius: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 第一行：昵称 + @账户名 + 阅藏进度百分比 + 置顶标注 + 更多
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Flexible(
                              // 点击昵称进入该用户个人主页空间。
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: _openUserSpace,
                                child: Text(widget.nickname,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: _text)),
                              ),
                            ),
                            if (widget.authorVerified) ...[
                              const SizedBox(width: 3),
                              const Icon(Icons.verified,
                                  size: 17, color: Color(0xFF70867A)),
                            ],
                            if (widget.account.isNotEmpty) ...[
                              const SizedBox(width: 3),
                              Flexible(
                                // 点击 @账户名 进入该用户个人主页（按下时变暗），
                                // 过长时省略显示，保证昵称完整。
                                child: AccountLink(
                                  account: widget.account,
                                  onTap: () {
                                    final uid = widget.ownerUserId;
                                    if (uid != null && uid.isNotEmpty) {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                UserSpacePage(userId: uid)),
                                      );
                                    }
                                  },
                                ),
                              ),
                              // 阅藏进度百分比：灰色（时间戳同色），前后各一个圆点分隔。
                              const SizedBox(width: 3),
                              Text('·',
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF8C8C8C))),
                              const SizedBox(width: 2),
                              Text(postPct,
                                  maxLines: 1,
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF8C8C8C))),
                              const SizedBox(width: 3),
                            ],
                          ],
                        ),
                      ),
                      if (widget.pinned) ...[
                        const Icon(Icons.push_pin,
                            size: 13, color: Color(0xFF70867A)),
                        const SizedBox(width: 2),
                        const Text('已置顶',
                            style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF70867A),
                                fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                      ],
                      if (canManage) ...[
                        const SizedBox(width: 4),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _showManageMenu,
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.more_horiz,
                                size: 18, color: Color(0xFF8C8C8C)),
                          ),
                        ),
                      ],
                      if (showMore) ...[
                        if (widget.showFollowButton) ...[
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _toggleFollow,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(
                                color: _following
                                    ? const Color(0xFFBDB6AC)
                                    : Colors.black,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(_following ? '已关注' : '关注',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        const SizedBox(width: 4),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => showMoreMenu(
                              context, widget.ownerUserId!, widget.nickname),
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.more_horiz,
                                size: 18, color: Color(0xFF8C8C8C)),
                          ),
                        ),
                      ],
                    ],
                  ),
                  // 转发/引用角标（昵称行下方）
                  if (widget.isRepost) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.repeat, size: 12, color: _gold),
                        const SizedBox(width: 2),
                        Text(widget.isQuoteRepost ? '引用' : '转发',
                            style: const TextStyle(fontSize: 11, color: _gold)),
                      ],
                    ),
                  ],
                  // 内容（与昵称同一左缘）
                  if (content.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final tp = TextPainter(
                          text: TextSpan(
                              text: measureContent,
                              style: const TextStyle(
                                  fontSize: 15,
                                  color: Colors.black,
                                  height: 1.6)),
                          maxLines: 8,
                          ellipsis: '…',
                          textDirection: TextDirection.ltr,
                        )..layout(maxWidth: constraints.maxWidth);
                        final overflow = tp.didExceedMaxLines;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildPostRichText(
                              content,
                              style: const TextStyle(
                                  fontSize: 15,
                                  color: Colors.black,
                                  height: 1.6),
                              library:
                                  NoteSutraCatalog.cachedTitleMap ?? const {},
                              maxLines: _expanded ? null : 8,
                              overflow:
                                  _expanded ? null : TextOverflow.ellipsis,
                              onUserTap: (uid) {
                                if (uid.isNotEmpty) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            UserSpacePage(userId: uid)),
                                  );
                                }
                              },
                              onSutraTap: (title, path) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => SutraDiscussionPage(
                                          title: title, filePath: path)),
                                );
                              },
                              onTopicTap: (topic) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => TopicPage(topic: topic)),
                                );
                              },
                            ),
                            if (overflow && !_expanded)
                              GestureDetector(
                                onTap: () => setState(() => _expanded = true),
                                child: const Padding(
                                  padding: EdgeInsets.only(top: 4),
                                  child: Text('显示更多',
                                      style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF6F877A))),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                  // 被回复的原贴（引用框）
                  if (widget.quoteBox != null) ...[
                    const SizedBox(height: 8),
                    widget.quoteBox!,
                  ],
                  // 发布时间：放在内容和指标行之间（顶部行只留昵称+@账户名+进度百分比），
                  // 点击时间戳进入帖子详情。
                  const SizedBox(height: 6),
                  PostTimeLink(
                    text: postTime(widget.timeMs),
                    onTap: () {
                      final id = widget.noteId;
                      if (id != null) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => NoteDetailPage(noteId: id)),
                        );
                      }
                    },
                  ),
                  // 指标行（与昵称同一左缘）
                  if (widget.allowActions) ...[
                    const SizedBox(height: 10),
                    buildStatsRow(
                      commentCount: _commentCount,
                      repostCount: _repostCount,
                      likeCount: _likeCount,
                      viewCount: _viewCount,
                      liked: _liked,
                      onComment: _openReplySheet,
                      onRepost: _repost,
                      onLike: _toggleLike,
                    ),
                  ] else if (widget.stats != null) ...[
                    const SizedBox(height: 10),
                    widget.stats!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 更多菜单：关注/取消关注、屏蔽/取消屏蔽。
Future<void> showMoreMenu(
    BuildContext context, String targetUserId, String nickname) async {
  final me = AuthService.instance.currentUser.value;
  if (me == null || me.id == targetUserId) return;
  final following =
      CloudNotesService.instance.followingUserIds.contains(targetUserId);
  final blocked =
      CloudNotesService.instance.blockedUserIds.contains(targetUserId);
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
            child: Text(nickname,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
          ),
          const Divider(height: 1, color: _border),
          postMenuItem(ctx, following ? 'unfollow' : 'follow',
              Icons.person_add_alt, following ? '取消关注' : '关注该用户'),
          postMenuItem(ctx, blocked ? 'unblock' : 'block', Icons.block_outlined,
              blocked ? '取消屏蔽' : '屏蔽该用户'),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  try {
    if (choice == 'follow' || choice == 'unfollow') {
      final ok = await CloudNotesService.instance.toggleFollow(targetUserId);
      if (context.mounted) showPostToast(context, ok ? '已关注' : '已取消关注');
    } else if (choice == 'block') {
      final ok = await CloudNotesService.instance.toggleBlockUser(targetUserId);
      if (context.mounted) {
        showPostToast(context, ok ? '已屏蔽，该用户笔记不再展示' : '已取消屏蔽');
      }
    } else if (choice == 'unblock') {
      final ok = await CloudNotesService.instance.toggleBlockUser(targetUserId);
      if (context.mounted) {
        showPostToast(context, ok ? '已屏蔽' : '已取消屏蔽');
      }
    }
  } catch (e) {
    if (context.mounted) showPostToast(context, e.toString());
  }
}

Widget postMenuItem(
    BuildContext ctx, String value, IconData icon, String label) {
  return InkWell(
    onTap: () => Navigator.pop(ctx, value),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      child: Row(
        children: [
          Icon(icon, size: 18, color: _textSec),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(fontSize: 15, color: _text)),
        ],
      ),
    ),
  );
}

void showPostToast(BuildContext context, String text) {
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

/// 回复某帖：打开回复输入弹窗，发表后生成连贴回复帖并回调刷新列表。
Future<void> replyToNote(
    BuildContext context, PlazaNote target, dynamic onPosted) async {
  if (!AuthService.instance.isLoggedIn) return;
  // 统一使用大弹层输入（minLines 3 / maxLines 10），长内容编辑体验更好。
  final content = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: _card,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => const SheetTextInput(
      title: '回复',
      hint: '写下你的回复…',
      maxLength: 500,
      minLines: 3,
      maxLines: 10,
      confirmText: '发表',
    ),
  );
  if (content == null || content.isEmpty) return;
  await submitReplyPost(context, target, content, onPosted);
}

Future<void> submitReplyPost(BuildContext parentCtx, PlazaNote target,
    String content, dynamic onPosted) async {
  if (content.isEmpty) return;
  try {
    await CloudNotesService.instance.createComment(target.id, content);
    final replyId = await CloudNotesService.instance
        .repostNote(target.id, quote: content, kind: 'reply');
    if (parentCtx.mounted && replyId.isNotEmpty) {
      showPostPublishedToast(parentCtx, replyId);
    }
    final dynamic cb = onPosted;
    final r = cb();
    if (r is Future) await r.catchError((_) {});
  } catch (e) {
    if (parentCtx.mounted) showPostToast(parentCtx, e.toString());
  }
}

/// 点赞某帖并回调刷新列表。
Future<void> likeTargetNote(
    BuildContext context, PlazaNote target, dynamic onPosted) async {
  try {
    await CloudNotesService.instance.toggleLike(target.id);
    if (onPosted != null) {
      final dynamic cb = onPosted;
      final r = cb();
      if (r is Future) await r.catchError((_) {});
    }
  } catch (e) {
    if (context.mounted) showPostToast(context, e.toString());
  }
}

/// 转发某帖（直接转发/引用转发）并回调刷新列表。
Future<void> forwardNote(
    BuildContext context, PlazaNote target, dynamic onPosted) async {
  if (!AuthService.instance.isLoggedIn) return;
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: _card,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Text('转发到菩提空间',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
          ),
          const Divider(height: 1, color: _border),
          postMenuItem(ctx, 'direct', Icons.repeat_rounded, '直接转发'),
          postMenuItem(ctx, 'quote', Icons.format_quote_rounded, '引用转发'),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  String quote = '';
  if (choice == 'quote') {
    quote = (await showModalBottomSheet<String>(
          context: context,
          isScrollControlled: true,
          backgroundColor: _card,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          builder: (_) => const SheetTextInput(
            title: '引用转发',
            hint: '写点自己的感想…',
            maxLength: 500,
            minLines: 2,
            maxLines: 3,
            confirmText: '转发',
          ),
        )) ??
        '';
    if (quote.isEmpty) return;
  }
  try {
    await CloudNotesService.instance.repostNote(target.id,
        quote: quote, kind: quote.isEmpty ? 'forward' : 'quote');
    if (!context.mounted) return;
    showPostToast(context, quote.isEmpty ? '已转发到菩提空间' : '已引用转发到菩提空间');
    if (onPosted != null) {
      final dynamic cb = onPosted;
      final r = cb();
      if (r is Future) await r.catchError((_) {});
    }
  } catch (e) {
    if (context.mounted) showPostToast(context, e.toString());
  }
}

/// 帖子行：与笔记详情页同风格——无卡片背景，
/// 头像+用户名/时间 → 内容预览（最多8行，可展开）→ 统计数据行。
class PostFeedRow extends StatelessWidget {
  final PlazaNote note;
  final VoidCallback? onReplyPosted;
  final VoidCallback? onTap;
  final bool pinned;
  final VoidCallback? onTogglePin;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final void Function(PlazaNote note)? onMore;
  final bool showFollowButton;

  /// 点击自己的头像/昵称时的回调（如切换到「我的」页）；为空时仍进入个人主页空间。
  final VoidCallback? onOpenSelf;
  const PostFeedRow({
    required this.note,
    this.onReplyPosted,
    this.onTap,
    this.pinned = false,
    this.onTogglePin,
    this.onEdit,
    this.onDelete,
    this.onMore,
    this.showFollowButton = true,
    this.onOpenSelf,
  });

  static String plainContent(PlazaNote note) =>
      note.content.replaceAll(RegExp(r'\[@([^\]]+)\]\([^)]+\)'), r'@$1');

  void _openDetail(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final note = this.note;
    final me = AuthService.instance.currentUser.value;
    final isMine = me != null && note.ownerUserId == me.id;
    // 回复帖：渲染成连贴样式（原帖在上 + 回复在下 + 头像竖线连接）。
    if (note.repostKind == 'reply') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: GestureDetector(
          onTap: onTap ?? () => _openDetail(context),
          behavior: HitTestBehavior.opaque,
          child: ReplyThread(
            replyNote: note,
            pinned: pinned,
            onComment: (n) => replyToNote(context, n, onReplyPosted),
            onLike: (n) => likeTargetNote(context, n, onReplyPosted),
            onRepost: (n) => forwardNote(context, n, onReplyPosted),
            onMore: onMore,
            onOpenSelf: onOpenSelf,
          ),
        ),
      );
    }
    return PostBlock(
      ownerUserId: note.ownerUserId,
      nickname: isMine ? me.displayName : note.authorName,
      account: note.authorAccount,
      authorVerified: note.authorVerified,
      canonRead: note.canonRead,
      canonTotal: note.canonTotal,
      timeMs: note.createdAt,
      content: note.content,
      noteId: note.id,
      allowActions: true,
      likeCount: note.likeCount,
      repostCount: note.repostCount,
      commentCount: note.commentCount,
      viewCount: note.viewCount,
      onReplyPosted: onReplyPosted,
      onTap: onTap ?? () => _openDetail(context),
      pinned: pinned,
      onTogglePin: onTogglePin,
      onEdit: onEdit,
      onDelete: onDelete,
      showFollowButton: showFollowButton,
      quoteBox: note.repostOf.isNotEmpty ? QuoteBox(note: note) : null,
      isRepost: note.repostOf.isNotEmpty && note.repostKind != 'reply',
      isQuoteRepost: note.quoteContent.isNotEmpty,
      onOpenSelf: onOpenSelf,
      stats: buildStatsRow(
        commentCount: note.commentCount,
        repostCount: note.repostCount,
        likeCount: note.likeCount,
        viewCount: note.viewCount,
        liked: CloudNotesService.instance.likedNoteIds.contains(note.id),
      ),
    );
  }
}

/// 四个数据指标行（评论/转发/点赞/阅读），与菩提空间笔记详情页样式一致。
/// 均匀分布占满整行，第一个图标与昵称/内容左对齐，右侧不留白。
Widget buildStatsRow({
  required int commentCount,
  required int repostCount,
  required int likeCount,
  required int viewCount,
  required bool liked,
  VoidCallback? onComment,
  VoidCallback? onRepost,
  VoidCallback? onLike,
}) {
  return Row(
    children: [
      statsCell(
          Image.asset('assets/images/ic_comment.png', width: 16, height: 16),
          '$commentCount',
          onTap: onComment),
      const SizedBox(width: 48),
      statsCell(
          Icon(Icons.repeat_rounded, size: 16, color: _textSec), '$repostCount',
          onTap: onRepost),
      const SizedBox(width: 48),
      statsCell(
          Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: 16, color: liked ? _gold : _textSec),
          '$likeCount',
          color: liked ? _gold : null,
          onTap: onLike),
      const SizedBox(width: 48),
      statsCell(Image.asset('assets/images/ic_view.png', width: 16, height: 16),
          '$viewCount'),
    ],
  );
}

/// 指标单元格：图标+数字，数字过大时自动缩放，避免溢出/遮挡。
Widget statsCell(Widget icon, String text,
    {Color? color, VoidCallback? onTap}) {
  final cell = Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(width: 16, height: 16, child: icon),
      const SizedBox(width: 3),
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(text,
              style:
                  TextStyle(fontSize: 13, height: 1, color: color ?? _textSec)),
        ),
      ),
    ],
  );
  if (onTap == null) return cell;
  return GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: cell,
    ),
  );
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
  final Set<String> _pinnedIds = {};
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;
  static const int _pageSize = 20;
  static const String _pinnedKey = 'my_pinned_note_ids';

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

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
        _notes.clear();
        _page = 1;
        _hasMore = true;
      });
    }

    // 帖子 = 我发布的帖子 + 我转发（含引用转发）的帖子，不含回复帖。
    List<PlazaNote> cloudNotes = [];
    bool hasMore = false;
    String? errorText;
    if (widget.isLoggedIn) {
      try {
        await CloudNotesService.instance.refreshLikedNoteIds();
        final (list, more) = await CloudNotesService.instance.getMyNotes(
          page: 1,
          pageSize: _pageSize,
        );
        cloudNotes = list.where((n) => n.repostKind != 'reply').toList();
        hasMore = more;
      } catch (e) {
        errorText = '云端加载失败';
      }
    } else {
      errorText = '请先登录';
    }
    if (!mounted) return;

    var merged = cloudNotes;
    // 云端失败/未登录时，用本地已分享的笔记兜底展示。
    if (merged.isEmpty && errorText != null) {
      final localNotes = await _loadLocalNotes();
      if (!mounted) return;
      final cloudIds = cloudNotes.map((n) => n.id).toSet();
      merged = [
        ...cloudNotes,
        ...localNotes.where((n) => !cloudIds.contains(n.id)),
      ];
    }
    await _loadPinnedIds();
    if (!mounted) return;
    _sortNotes(merged);

    setState(() {
      _notes
        ..clear()
        ..addAll(merged);
      _hasMore = hasMore;
      _page = 2;
      _error = errorText;
      _loading = false;
    });
  }

  /// 从本地读取置顶帖子 id 列表。
  Future<void> _loadPinnedIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _pinnedIds
        ..clear()
        ..addAll(prefs.getStringList(_pinnedKey) ?? const []);
    } catch (_) {}
  }

  /// 排序：置顶的帖子在最前，其余按更新时间倒序。
  void _sortNotes(List<PlazaNote> notes) {
    notes.sort((a, b) {
      final ap = _pinnedIds.contains(a.id);
      final bp = _pinnedIds.contains(b.id);
      if (ap != bp) return ap ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
  }

  /// 置顶/取消置顶帖子（本地保存，重启后仍生效）。
  Future<void> _togglePin(PlazaNote note) async {
    final wasPinned = _pinnedIds.contains(note.id);
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_pinnedKey) ?? [];
      if (wasPinned) {
        list.remove(note.id);
        _pinnedIds.remove(note.id);
      } else {
        list.add(note.id);
        _pinnedIds.add(note.id);
      }
      await prefs.setStringList(_pinnedKey, list);
    } catch (_) {}
    if (!mounted) return;
    _sortNotes(_notes);
    setState(() {});
    showPostToast(context, wasPinned ? '已取消置顶' : '已置顶');
  }

  /// 编辑帖子内容：更新云端后重新加载列表。
  Future<void> _editNote(PlazaNote note) async {
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
      showPostToast(context, '已更新');
      _load(silent: true);
    } catch (e) {
      if (mounted) showPostToast(context, e.toString());
    }
  }

  /// 删除帖子：从菩提空间移除，不再展示。
  Future<void> _deleteNote(PlazaNote note) async {
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
      _pinnedIds.remove(note.id);
      if (!mounted) return;
      setState(() => _notes.removeWhere((n) => n.id == note.id));
      showPostToast(context, '已删除');
    } catch (e) {
      if (mounted) showPostToast(context, e.toString());
    }
  }

  /// 本地笔记中已分享（shared=true）的部分，用于云端不可用时的兜底展示。
  Future<List<PlazaNote>> _loadLocalNotes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('notes') ?? '[]';
      final List<dynamic> list = jsonDecode(raw);
      final uid = AuthService.instance.currentUser.value?.id ?? 'local';
      final nickname =
          AuthService.instance.currentUser.value?.displayName ?? '同修';
      return list.reversed
          .where((n) => n['shared'] == true)
          .map<PlazaNote>((n) {
        final tsStr = n['updatedAt']?.toString() ?? '';
        final ts = DateTime.tryParse(tsStr)?.millisecondsSinceEpoch ?? 0;
        return PlazaNote(
          id: n['id']?.toString() ?? '',
          ownerUserId: uid,
          title: n['title']?.toString() ?? '无标题',
          content: n['content']?.toString() ?? '',
          authorName: nickname,
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
        _notes.addAll(list.where((n) => n.repostKind != 'reply'));
        _hasMore = more;
        _page++;
        _loadingMore = false;
      });
      _sortNotes(_notes);
      if (mounted) setState(() {});
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Widget _tabLoading() {
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
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
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
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
    if (_notes.isEmpty) {
      final msg = _error ?? '还没有分享过帖子';
      return _tabEmpty(
          msg, _error != null ? Icons.cloud_off : Icons.post_add_outlined);
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
            SliverToBoxAdapter(
              child: SizedBox(height: 4),
            ),
            SliverPadding(
              // 横向内边距移入每条帖子内部，保证分割线通栏贴边。
              padding: const EdgeInsets.only(top: 4, bottom: 32),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    if (index == _notes.length) {
                      if (_hasMore && widget.isLoggedIn) {
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
                      // 末尾收尾分割线，保证最后一条帖子下方也有分割线（通栏贴边）。
                      return const Divider(
                          height: 1, thickness: 0.6, color: Color(0xFFD8CCBC));
                    }
                    final note = _notes[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 帖子顶部通栏分割线（首条不画，避免顶部多一条线）。
                        if (index > 0)
                          const Divider(
                              height: 1,
                              thickness: 0.6,
                              color: Color(0xFFD8CCBC)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _buildNoteCard(note),
                        ),
                      ],
                    );
                  },
                  childCount: _notes.length + 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 回复节点更多菜单：自己的回复显示置顶/编辑/删除，他人回复显示关注/屏蔽。
  Future<void> _showReplyMenu(PlazaNote note) async {
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
            postMenuItem(ctx, 'pin', Icons.push_pin_outlined,
                _pinnedIds.contains(note.id) ? '取消置顶' : '置顶'),
            postMenuItem(ctx, 'edit', Icons.edit_outlined, '编辑'),
            postMenuItem(ctx, 'delete', Icons.delete_outline, '删除'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'pin':
        _togglePin(note);
        break;
      case 'edit':
        _editNote(note);
        break;
      case 'delete':
        _deleteNote(note);
        break;
    }
  }

  Widget _buildNoteCard(PlazaNote note) {
    return PostFeedRow(
      note: note,
      onReplyPosted: _load,
      pinned: _pinnedIds.contains(note.id),
      onTogglePin: () => _togglePin(note),
      onEdit: () => _editNote(note),
      onDelete: () => _deleteNote(note),
      onMore: (n) => _showReplyMenu(n),
    );
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
  /// 回复 = 我发出的回复帖（repostKind == 'reply'），
  /// 含回复自己的帖子与回复其他人的帖子。
  final List<PlazaNote> _replies = [];

  /// 按最顶层原贴分组：同一原贴下的多条回复归入同一区域（原贴 + 回复链连线）。
  final List<(PlazaNote, List<PlazaNote>)> _groups = [];

  /// 已置顶的回复帖：以独立「置顶帖子」卡片展示在列表顶部。
  final List<PlazaNote> _pinnedReplies = [];

  /// 帖子 id → 作者账号（用于置顶帖子的「回复@账户名」）。
  final Map<String, String> _accountsById = {};
  final Set<String> _pinnedIds = {};
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;
  static const int _pageSize = 20;
  static const String _pinnedKey = 'my_pinned_note_ids';

  @override
  void initState() {
    super.initState();
    _loadPinnedIds();
    if (widget.isLoggedIn) _load();
    widget.reloadNotifier.addListener(_onReload);
  }

  @override
  void dispose() {
    widget.reloadNotifier.removeListener(_onReload);
    super.dispose();
  }

  void _onReload() {
    _loadPinnedIds();
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
      _replies.clear();
      _groups.clear();
      _pinnedReplies.clear();
      _page = 1;
      _hasMore = true;
    });
    try {
      await CloudNotesService.instance.refreshLikedNoteIds();
      final (list, more) = await CloudNotesService.instance.getMyNotes(
        page: 1,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _replies.addAll(list.where((n) => n.repostKind == 'reply'));
        _hasMore = more;
        _page = 2;
      });
      await _buildGroups();
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (_) {
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
      final (list, more) = await CloudNotesService.instance.getMyNotes(
        page: _page,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _replies.addAll(list.where((n) => n.repostKind == 'reply'));
        _hasMore = more;
        _page++;
        _loadingMore = false;
      });
      await _buildGroups();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  /// 按最顶层原贴分组：沿 repostOf 逐级向上找到根原贴，
  /// 同一根下的所有回复（含置顶的）归入一组；组内按时间正序成链。
  /// 置顶的回复额外单独作为「置顶帖子」展示在列表顶部。
  Future<void> _buildGroups() async {
    await _loadPinnedIds();
    final pinned = _replies.where((n) => _pinnedIds.contains(n.id)).toList();
    final accountsById = <String, String>{
      for (final n in _replies) n.id: n.authorAccount,
    };

    final allById = {for (final n in _replies) n.id: n};
    final children = <String, List<PlazaNote>>{};
    final rootIds = <String>[];
    for (final n in _replies) {
      var top = n.repostOf;
      var guard = 0;
      while (top.isNotEmpty && allById.containsKey(top) && guard < 30) {
        final node = allById[top]!;
        if (node.repostOf.isNotEmpty && allById.containsKey(node.repostOf)) {
          top = node.repostOf;
        } else {
          break;
        }
        guard++;
      }
      if (!children.containsKey(top)) rootIds.add(top);
      children.putIfAbsent(top, () => []).add(n);
    }
    // 并行预取各组原贴数据（失败时用已有数据或占位兜底）。
    final futures = rootIds.map((id) async {
      PlazaNote? root;
      try {
        root = await CloudNotesService.instance.getNoteById(id);
      } catch (_) {
        root = allById[id];
      }
      return MapEntry(id, root);
    });
    final roots = <String, PlazaNote>{};
    for (final e in await Future.wait(futures)) {
      final root = e.value ??
          PlazaNote(
            id: e.key,
            ownerUserId: '',
            title: '',
            content: '',
            authorName: '同修',
            visibility: 'public',
            status: 'normal',
            likeCount: 0,
            commentCount: 0,
            createdAt: 0,
            updatedAt: 0,
          );
      roots[e.key] = root;
      accountsById[e.key] = root.authorAccount;
    }
    final groups = <(PlazaNote, List<PlazaNote>)>[];
    for (final id in rootIds) {
      final list = children[id]!;
      if (list.isEmpty) continue;
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      groups.add((roots[id]!, list));
    }
    // 分组按组内最新回复倒序展示。
    groups.sort((a, b) => b.$2.last.createdAt.compareTo(a.$2.last.createdAt));
    if (!mounted) return;
    setState(() {
      _accountsById
        ..clear()
        ..addAll(accountsById);
      _pinnedReplies
        ..clear()
        ..addAll(pinned);
      _groups
        ..clear()
        ..addAll(groups);
    });
  }

  Future<void> _loadPinnedIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _pinnedIds
        ..clear()
        ..addAll(prefs.getStringList(_pinnedKey) ?? const []);
    } catch (_) {}
  }

  /// 置顶/取消置顶回复（本地保存，与帖子 Tab 共用同一份置顶记录）。
  /// 置顶后立即重建分组：被置顶的评论移出回复链，生成独立置顶帖子。
  Future<void> _togglePin(PlazaNote note) async {
    final wasPinned = _pinnedIds.contains(note.id);
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_pinnedKey) ?? [];
      if (wasPinned) {
        list.remove(note.id);
        _pinnedIds.remove(note.id);
      } else {
        list.add(note.id);
        _pinnedIds.add(note.id);
      }
      await prefs.setStringList(_pinnedKey, list);
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
    showPostToast(context, wasPinned ? '已取消置顶' : '已置顶');
    await _buildGroups();
  }

  /// 编辑回复内容：更新云端后重新加载列表。
  Future<void> _editNote(PlazaNote note) async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SheetTextInput(
        title: '编辑回复',
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
      showPostToast(context, '已更新');
      _load();
    } catch (e) {
      if (mounted) showPostToast(context, e.toString());
    }
  }

  /// 删除回复：从菩提空间移除，不再展示。
  Future<void> _deleteNote(PlazaNote note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除回复',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: const Text('删除后回复将从菩提空间移除，且无法恢复。确定删除吗？',
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
      _pinnedIds.remove(note.id);
      if (!mounted) return;
      setState(() => _replies.removeWhere((n) => n.id == note.id));
      showPostToast(context, '已删除');
    } catch (e) {
      if (mounted) showPostToast(context, e.toString());
    }
  }

  /// 回复节点更多菜单：自己的回复显示置顶/编辑/删除，他人回复显示关注/屏蔽。
  Future<void> _showReplyMenu(PlazaNote note) async {
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
            postMenuItem(ctx, 'pin', Icons.push_pin_outlined,
                _pinnedIds.contains(note.id) ? '取消置顶' : '置顶'),
            postMenuItem(ctx, 'edit', Icons.edit_outlined, '编辑'),
            postMenuItem(ctx, 'delete', Icons.delete_outline, '删除'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'pin':
        _togglePin(note);
        break;
      case 'edit':
        _editNote(note);
        break;
      case 'delete':
        _deleteNote(note);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoggedIn) {
      return _tabEmpty('请先登录', Icons.lock_outlined);
    }
    if (_loading) return _tabLoading();
    if (_error != null) return _tabEmpty(_error!, Icons.error_outline);
    if (_replies.isEmpty) {
      return _tabEmpty('还没有回复过帖子', Icons.reply_outlined);
    }

    final itemCount = _pinnedReplies.length + _groups.length;
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
            SliverToBoxAdapter(
              child: SizedBox(height: 4),
            ),
            SliverPadding(
              padding: const EdgeInsets.only(top: 4, bottom: 32),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    if (index == itemCount) {
                      if (_hasMore) {
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
                      return const Divider(
                          height: 1, thickness: 0.6, color: Color(0xFFD8CCBC));
                    }
                    final Widget body;
                    if (index < _pinnedReplies.length) {
                      // 置顶回复：独立置顶帖子卡片。
                      body = _buildPinnedReplyCard(_pinnedReplies[index]);
                    } else {
                      final g = _groups[index - _pinnedReplies.length];
                      // 同一原贴下的多条回复归入一个区域。
                      body = _buildGroupCard(g.$1, g.$2);
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (index > 0)
                          const Divider(
                              height: 1,
                              thickness: 0.6,
                              color: Color(0xFFD8CCBC)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: body,
                        ),
                      ],
                    );
                  },
                  childCount: itemCount + (_hasMore ? 1 : 0),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 置顶帖子卡片：与正常帖子同风格（头像 + 昵称，无卡片背景），
  /// 昵称下方多一行 `回复@账户名`（被回复者账号，不一定是自己），再下面是回复内容。
  Widget _buildPinnedReplyCard(PlazaNote reply) {
    final me = AuthService.instance.currentUser.value;
    final parentAccount = _accountsById[reply.repostOf] ?? '';
    final nickname = me != null
        ? me.displayName
        : (reply.authorName.isNotEmpty ? reply.authorName : '我');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserAvatar(userId: reply.ownerUserId, radius: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 第一行：昵称 + 账号 + 已置顶 + 三点菜单（时间戳在内容下方）
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(nickname,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: _text)),
                          ),
                          if (reply.authorVerified) ...[
                            const SizedBox(width: 3),
                            const Icon(Icons.verified,
                                size: 15, color: Color(0xFF70867A)),
                          ],
                          if (reply.authorAccount.isNotEmpty) ...[
                            const SizedBox(width: 3),
                            Flexible(
                              // 账号名过长时省略显示，保证昵称完整。
                              child: Text('@${reply.authorAccount}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF8C8C8C))),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const Icon(Icons.push_pin,
                        size: 13, color: Color(0xFF70867A)),
                    const SizedBox(width: 2),
                    const Text('已置顶',
                        style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF70867A),
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 4),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _showReplyMenu(reply),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.more_horiz,
                            size: 18, color: Color(0xFF8C8C8C)),
                      ),
                    ),
                  ],
                ),
                // 回复@账户名（被回复者）
                const SizedBox(height: 3),
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(
                        text: '回复@',
                        style: TextStyle(fontSize: 14, color: _textSec),
                      ),
                      TextSpan(
                        text: parentAccount.isEmpty ? '同修' : parentAccount,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _textSec),
                      ),
                    ],
                  ),
                ),
                // 回复内容
                const SizedBox(height: 4),
                Text(PostFeedRow.plainContent(reply),
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, color: _text, height: 1.6)),
                // 发布时间：内容与指标行之间。
                const SizedBox(height: 6),
                Text(postTime(reply.createdAt),
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF8C8C8C))),
                // 指标行（与下方帖子的指标对齐）
                const SizedBox(height: 10),
                buildStatsRow(
                  commentCount: reply.commentCount,
                  repostCount: reply.repostCount,
                  likeCount: reply.likeCount,
                  viewCount: reply.viewCount,
                  liked: CloudNotesService.instance.likedNoteIds
                      .contains(reply.id),
                  onComment: () => replyToNote(context, reply, _load),
                  onRepost: () => forwardNote(context, reply, _load),
                  onLike: () => likeTargetNote(context, reply, _load),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 分组卡片：原贴在上 + 头像连线 + 其下所有回复链。
  Widget _buildGroupCard(PlazaNote root, List<PlazaNote> replies) {
    // 原贴作者已被屏蔽：上方显示「已屏蔽用户」占位，自己的评论仍连线在下方。
    if (CloudNotesService.instance.blockedUserIds.contains(root.ownerUserId)) {
      return _buildBlockedGroupCard(root, replies);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 原贴：其头像下方画一条连线，延伸到第一个回复的头像（两端留距）。
        Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 21,
              top: 62,
              bottom: 0,
              child: Container(width: 1, color: const Color(0xFFC9C9C9)),
            ),
            PostFeedRow(
              note: root,
              onReplyPosted: _load,
              // 分组区域不显示已置顶（已置顶只在顶部置顶卡片展示）。
              pinned: false,
              onTogglePin: () => _togglePin(root),
              onEdit: () => _editNote(root),
              onDelete: () => _deleteNote(root),
              onMore: (n) => _showReplyMenu(n),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 8),
          child: ReplyChain(
            replies: replies,
            parentAccounts: {
              root.id: root.authorAccount,
              for (final r in replies) r.id: r.authorAccount,
            },
            onComment: (n) => replyToNote(context, n, _load),
            onLike: (n) => likeTargetNote(context, n, _load),
            onRepost: (n) => forwardNote(context, n, _load),
            onMore: (n) => _showReplyMenu(n),
          ),
        ),
      ],
    );
  }

  /// 原贴作者被屏蔽时的分组卡片：上方显示「已屏蔽用户」占位，
  /// 下方仍用头像连线展示自己的评论，点击占位可进入该用户主页取消屏蔽。
  Widget _buildBlockedGroupCard(PlazaNote root, List<PlazaNote> replies) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 21,
              top: 52,
              bottom: -18,
              child: Container(width: 1, color: const Color(0xFFC9C9C9)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: CircleAvatar(
                      radius: 22,
                      backgroundColor: Color(0x1A8B6B5A),
                      child: Icon(Icons.block, size: 22, color: _textSec),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      onTap: root.ownerUserId.isNotEmpty
                          ? () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => UserSpacePage(
                                    userId: root.ownerUserId,
                                    userName: root.authorName,
                                  ),
                                ),
                              )
                          : null,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          border: Border.all(color: _border),
                          borderRadius: BorderRadius.circular(8),
                          color: _bg,
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.block, size: 16, color: _textSec),
                            SizedBox(width: 8),
                            Text('已屏蔽用户',
                                style:
                                    TextStyle(fontSize: 14, color: _textSec)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 8),
          child: ReplyChain(
            replies: replies,
            parentAccounts: {
              root.id: root.authorAccount,
              for (final r in replies) r.id: r.authorAccount,
            },
            onComment: (n) => replyToNote(context, n, _load),
            onLike: (n) => likeTargetNote(context, n, _load),
            onRepost: (n) => forwardNote(context, n, _load),
            onMore: (n) => _showReplyMenu(n),
          ),
        ),
      ],
    );
  }

  Widget _tabLoading() {
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
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
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
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
      // 喜欢 Tab 里的帖子全部是已点赞的，写入点赞记录让爱心显示为填充色。
      CloudNotesService.instance.likedNoteIds.addAll(notes.map((n) => n.id));
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
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final note = _notes![index];
                  return PostFeedRow(note: note, onReplyPosted: _load);
                },
                childCount: _notes!.length,
              ),
            ),
          ),
        ],
      ),
    );
  } // _MyLikesTab build

  Widget _tabLoading() {
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
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
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
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
  const _MyBookmarksTab(
      {required this.isLoggedIn, required this.reloadNotifier});

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
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final note = _notes![index];
                  return PostFeedRow(note: note, onReplyPosted: _load);
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
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
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
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
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

/// 草稿行：本地保存但未分享到菩提空间的笔记，样式与帖子一致，但没有统计指标行（未发表）。
class _DraftRow extends StatelessWidget {
  final Map<String, dynamic> note;
  final VoidCallback onTap;
  final String account;
  final bool verified;
  const _DraftRow({
    required this.note,
    required this.onTap,
    this.account = '',
    this.verified = false,
  });

  @override
  Widget build(BuildContext context) {
    final note = this.note;
    final content = note['content']?.toString() ?? '';
    final ts = DateTime.tryParse(note['updatedAt']?.toString() ?? '');
    final nickname =
        AuthService.instance.currentUser.value?.displayName ?? '同修';
    return PostBlock(
      ownerUserId: AuthService.instance.currentUser.value?.id,
      nickname: nickname,
      account: account,
      authorVerified: verified,
      timeMs: ts?.millisecondsSinceEpoch ?? 0,
      content: content,
      onTap: onTap,
    );
  }
}

/// 草稿 Tab：本地保存但未分享到菩提空间的笔记。
class _MyDraftsTab extends StatefulWidget {
  final ValueNotifier<int> reloadNotifier;
  const _MyDraftsTab({required this.reloadNotifier});

  @override
  State<_MyDraftsTab> createState() => _MyDraftsTabState();
}

class _MyDraftsTabState extends State<_MyDraftsTab> {
  List<Map<String, dynamic>> _notes = [];
  bool _loading = true;
  String _account = '';
  bool _verified = false;

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
  void didUpdateWidget(covariant _MyDraftsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reloadNotifier != oldWidget.reloadNotifier) {
      oldWidget.reloadNotifier.removeListener(_onReload);
      widget.reloadNotifier.addListener(_onReload);
    }
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('notes') ?? '[]';
      final notes = (jsonDecode(raw) as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((n) => n['shared'] != true)
          .toList()
        ..sort((a, b) => (b['updatedAt']?.toString() ?? '')
            .compareTo(a['updatedAt']?.toString() ?? ''));
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _account = prefs.getString('user_account_name') ?? '';
        _verified = prefs.getBool('user_verified') ?? false;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notes = [];
        _loading = false;
      });
    }
  }

  void _openEdit(Map<String, dynamic> note) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteEditPage(note: note)),
    ).then((_) {
      if (mounted) _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return _tabLoading();
    if (_notes.isEmpty) {
      return _tabEmpty('还没有草稿', Icons.edit_note);
    }
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
          ),
          SliverPadding(
            // 横向内边距移入每条草稿内部，保证分割线通栏贴边（与主页帖子一致）。
            padding: const EdgeInsets.only(top: 4, bottom: 32),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final note = _notes[index];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 草稿顶部通栏分割线（首条不画，避免顶部多一条线）。
                      if (index > 0)
                        const Divider(
                            height: 1,
                            thickness: 0.6,
                            color: Color(0xFFD8CCBC)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _DraftRow(
                          note: note,
                          account: _account,
                          verified: _verified,
                          onTap: () => _openEdit(note),
                        ),
                      ),
                    ],
                  );
                },
                childCount: _notes.length,
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
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
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
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
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

class _SettingsPage extends StatefulWidget {
  const _SettingsPage();

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  bool _reminderOn = false;
  String _reminderTime = '21:00';
  bool _loaded = false;

  bool get _isLoggedIn => AuthService.instance.isLoggedIn;

  bool get reminderOn => _reminderOn;
  String get reminderTime => _reminderTime;

  void reloadForSettings() => _load();

  void requireLogin() => _pushLogin();

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
    _reminderOn = await NotificationService.instance.isReminderEnabled();
    _reminderTime = await NotificationService.instance.getReminderTime();
    if (mounted) setState(() => _loaded = true);
  }

  void _pushLogin() {
    _showToast('请先登录');
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const LoginPage()));
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

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(text,
          style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: _textSec)),
    );
  }

  Widget _buildLogoutRow() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2)),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        leading: const Icon(Icons.logout, size: 20, color: Colors.redAccent),
        title: const Text('退出登录',
            style: TextStyle(fontSize: 15, color: Colors.redAccent)),
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
        title: const Text('退出登录',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content:
            const Text('退出后需重新登录才能管理云端笔记', style: TextStyle(color: _textSec)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: _textSec))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出',
                style:
                    TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
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
                      icon: const Icon(Icons.arrow_back_ios_new,
                          color: _text, size: 20),
                    ),
                    const SizedBox(width: 4),
                    const Text('设置',
                        style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                            color: _text)),
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
                      _sectionTitle('安全'),
                      SettingsCard(
                        children: [
                          _SettingsAccountTile(),
                          const SettingsDivider(),
                          _SettingsPhoneTile(),
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
            context
                .findAncestorStateOfType<_SettingsPageState>()
                ?.reloadForSettings();
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
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16,
                          color: _text,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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

/// 打卡提醒行：点击跳转到手机自带闹钟页面设置（最可靠，保证响铃）。
class _SettingsReminderTile extends StatelessWidget {
  const _SettingsReminderTile();

  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_SettingsPageState>()!;
    return InkWell(
      onTap: () async {
        // 打开系统闹钟 App 的新建闹钟界面，时间按设置的时间预填。
        final res =
            await NotificationService.instance.armSystemAlarm(skipUI: false);
        if (res == null && context.mounted) {
          state._showToast('无法打开手机闹钟，请手动打开手机「闹钟」应用');
        }
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
                  const Text('打卡提醒',
                      style: TextStyle(
                          fontSize: 16,
                          color: _text,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(
                    '跳转手机闹钟设置',
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

/// 忘记密码行：通过手机验证码重置登录密码，未登录也可使用。
class _SettingsAccountTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_SettingsPageState>()!;
    return InkWell(
      onTap: () {
        Navigator.push(context, slideInFromLeft(const ForgotPasswordPage()))
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
              child:
                  const Icon(Icons.lock_reset, color: _primaryLight, size: 20),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('忘记密码',
                      style: TextStyle(
                          fontSize: 16,
                          color: _text,
                          fontWeight: FontWeight.w500)),
                  SizedBox(height: 2),
                  Text('通过手机验证码重置登录密码',
                      style: TextStyle(fontSize: 12, color: _textHint)),
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
              child: const Icon(Icons.phone_iphone_outlined,
                  color: _primaryLight, size: 20),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('更换手机号',
                      style: TextStyle(
                          fontSize: 16,
                          color: _text,
                          fontWeight: FontWeight.w500)),
                  SizedBox(height: 2),
                  Text('更换后数据自动保留',
                      style: TextStyle(fontSize: 12, color: _textHint)),
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
