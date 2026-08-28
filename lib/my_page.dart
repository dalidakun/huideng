import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';
import 'reader_settings_page.dart';
import 'edit_profile_page.dart';
import 'change_phone_page.dart';
import 'forgot_password_page.dart';
import 'about_page.dart';
import 'donate_page.dart';
import 'export_notes_page.dart';
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
import 'loading_widgets.dart';

import 'app_palette.dart';
Color get _primary => AppPalette.p.primary;
Color get _primaryLight => AppPalette.p.textSec;
Color get _gold => AppPalette.p.accent;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _border => AppPalette.p.border;
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
  /// 注意：初始值必须为空串，绝不能用 DateTime.now() 兜底！
  /// 冷启动同步未完成时本地可能暂无值，用当前日期会误导用户以为"注册时间变成昨天"。
  String _joinedDate = '';

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
    _tabController = TabController(length: 4, vsync: this);
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
    // 会话变化（登录/登出/缓存兜底→真实身份/token刷新恢复）后，
    // 主动触发各子 Tab reload，避免竞态窗口下首次加载失败、
    // 后续会话恢复却不重新拉取而一直显示空列表/错误状态。
    reload();
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
      if (createdMs != null && createdMs > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(createdMs);
        _joinedDate = '${dt.year}年${dt.month}月${dt.day}日加入';
      }
      // 注意：绝不在 createdMs 为 null 时用 DateTime.now() 兜底写入！
      // 冷启动时同步还没完成，本地缓存可能暂时缺失；若此时写入当前日期，
      // 会把云端的真实注册时间永久覆盖掉（sync_service 默认"本地有值就跳过"）。
      // 缺失时由 _ensureJoinTimeFromCloud() 后台从云端拉取补齐。
    });
    unawaited(_ensureJoinTimeFromCloud());
    _loadAccountName();
    _loadVerification();
    unawaited(_loadReadingBadge());
  }

  /// 用权威数据源（getUserProfiles.joinTime / getMyVerification）无条件
  /// 覆盖本地 prefs 的事实性字段，修复旧版本「兜底写入当前日期→再push污染云端」。
  /// 即便本地已经有 user_created_at（可能是被污染的"昨天"），也必须重跑，
  /// 用服务端注册时的真实 joinTime 覆盖掉。
  Future<void> _ensureJoinTimeFromCloud() async {
    if (!_isLoggedIn) return;
    final me = AuthService.instance.currentUser.value;
    if (me == null) return;
    final prefs = await SharedPreferences.getInstance();
    try {
      // 并行拉：getUserProfiles（joinTime/account/name）+ getMyVerification（verified/realName）
      final profF = CloudNotesService.instance.getUserProfiles([me.id]);
      final verF = Future<VerificationInfo?>.delayed(
        Duration.zero,
        () async {
          try {
            return await CloudNotesService.instance.getMyVerification();
          } catch (_) {
            return null;
          }
        },
      );
      final results = await Future.wait([profF, verF]);
      final profiles = results[0] as List<UserProfile>;
      final info = results[1] as VerificationInfo?;

      if (profiles.isNotEmpty) {
        final p = profiles.first;
        if (p.joinTime > 0) {
          final local = prefs.getInt('user_created_at');
          if (local == null || local != p.joinTime) {
            await prefs.setInt('user_created_at', p.joinTime);
          }
        }
        if (p.account.isNotEmpty) {
          final local = prefs.getString('user_account_name') ?? '';
          if (local != p.account) {
            await prefs.setString('user_account_name', p.account);
          }
        }
        if (p.name.isNotEmpty) {
          final local = prefs.getString('user_nickname') ?? '';
          if (local != p.name) {
            await prefs.setString('user_nickname', p.name);
          }
        }
      }
      if (info != null) {
        // 认证状态永久单向：只在云端确认为「已认证」时覆盖为 true，
        // 绝不因云端误报 false（匿名/降级会话）把已认证清掉。
        final localVer = prefs.getBool('user_verified') ?? false;
        if (info.verified && !localVer) {
          await prefs.setBool('user_verified', true);
        }
        // 认证后的脱敏真名（如「张*三」），显示在昵称下方；一旦写入不再清空。
        if (info.realNameMasked.isNotEmpty) {
          final local = prefs.getString('user_verified_name') ?? '';
          if (local != info.realNameMasked) {
            await prefs.setString('user_verified_name', info.realNameMasked);
          }
        }
      }
      // 重新从 prefs 读一次（可能被上面覆盖了权威值）刷新 UI
      if (mounted) {
        final newCreatedMs = prefs.getInt('user_created_at');
        final newVerified = prefs.getBool('user_verified') ?? false;
        setState(() {
          if (newCreatedMs != null && newCreatedMs > 0) {
            final dt = DateTime.fromMillisecondsSinceEpoch(newCreatedMs);
            _joinedDate = '${dt.year}年${dt.month}月${dt.day}日加入';
          }
          _verified = newVerified;
          _accountName = prefs.getString('user_account_name') ?? '';
          _nickname = prefs.getString('user_nickname') ?? _nickname;
        });
      }
    } catch (_) {}
  }

  /// 读经徽章：读取本地累计时长驱动徽章点亮；首次点亮新徽章时弹恭喜。
  /// 整体兜底 try/catch：本方法经 _loadData 以 unawaited 方式触发
  /// （含登录态变化瞬间），异常外抛会成为未处理异步错误、被全局错误
  /// 处理器弹成错误页面。
  Future<void> _loadReadingBadge() async {
    try {
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
    } catch (_) {}
  }

  Future<void> _loadAccountName() async {
    final name = await AuthService.instance.getAccountName();
    if (!mounted) return;
    setState(() => _accountName = name);
  }

  /// 实名认证状态：优先取云端，云端失败时回退到本地缓存。
  /// 注意：认证是永久单向的（同一账号仅可认证一次），
  /// 因此本地已知「已认证」时绝不因云端误报 false（如匿名/降级会话
  /// 解析到共享匿名 uid）而降级，避免认证标识莫名消失。
  Future<void> _loadVerification() async {
    final prefs = await SharedPreferences.getInstance();
    var verified = prefs.getBool('user_verified') ?? false;
    if (_isLoggedIn) {
      try {
        final info = await CloudNotesService.instance.getMyVerification();
        if (info.verified) {
          verified = true;
          await prefs.setBool('user_verified', true);
          if (info.realNameMasked.isNotEmpty) {
            await prefs.setString('user_verified_name', info.realNameMasked);
          }
        }
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
            // 素白外观下改黑色底 + 白色加号；暖黄保持青绿。
            backgroundColor: AppPalette.instance.isPlain
                ? const Color(0xFF1A1A1A)
                : const Color(0xFF71867A),
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
                  child: _MyRepostsTab(
                      isLoggedIn: isLoggedIn, reloadNotifier: _reloadNotifier)),
              _TabContent(
                  child: _MyBookmarksTab(
                      isLoggedIn: isLoggedIn, reloadNotifier: _reloadNotifier)),
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
                      color: AppPalette.p.muted,
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
                    child: Text(
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
                                  style: TextStyle(
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
                              style: TextStyle(
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
                      Expanded(
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
                  style: TextStyle(fontSize: 13, color: _textSec),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (_joinedDate.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.calendar_month_outlined,
                          size: 14, color: _textHint),
                      const SizedBox(width: 4),
                      Text(
                        _joinedDate,
                        style: TextStyle(fontSize: 13, color: _textHint),
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
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: _text)),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 13, color: _textSec)),
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
          Tab(text: '笔记'),
          Tab(text: '回复'),
          Tab(text: '转发'),
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
  final FutureOr<void> Function(PlazaNote note)? onReplyPosted;
  final Widget? quoteBox;
  final bool pinned;
  final bool isRepost;
  final bool isQuoteRepost;

  /// 转发时被转发的原帖数据：用于 X 式直接展示原帖（头像/昵称/内容/指标）。
  final PlazaNote? repostNote;
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
    this.repostNote,
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
  late int _likeCount;
  late int _repostCount;
  late int _commentCount;
  late int _viewCount;
  late bool _liked;
  late bool _following;

  @override
  void initState() {
    super.initState();
    // X 式转发：用 repostNote 数据初始化指标。
    final rn = widget.repostNote;
    final bool useOriginal = widget.isRepost && rn != null;
    _likeCount = useOriginal ? rn.likeCount : widget.likeCount;
    _repostCount = useOriginal ? rn.repostCount : widget.repostCount;
    _commentCount = useOriginal ? rn.commentCount : widget.commentCount;
    _viewCount = useOriginal ? rn.viewCount : widget.viewCount;
    final noteId = useOriginal ? rn.id : widget.noteId;
    _liked = noteId != null &&
        CloudNotesService.instance.likedNoteIds.contains(noteId);
    final ownerId = useOriginal ? rn.ownerUserId : widget.ownerUserId;
    _following = ownerId != null &&
        CloudNotesService.instance.followingUserIds.contains(ownerId);
    // 实时同步指标：详情页点赞/评论/转发/阅读后，这里的数字立即更新。
    NoteStatsCenter.instance.addListener(_onStatsChanged);
    // 经书目录未缓存时预加载：$引用链接与多卷「卷X」卷标渲染依赖它。
    if (NoteSutraCatalog.cachedTitleMap == null) {
      NoteSutraCatalog.load().then((_) {
        if (mounted) setState(() {});
      });
    }
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
  /// 自己的头像/昵称在提供 onOpenSelf 时走回调（如切换到「我的」页，与修学主页
  /// 左上角头像一致）；否则仍进个人主页空间。
  void _openUserSpace() {
    final rn = widget.repostNote;
    final bool useOriginal = widget.isRepost && rn != null;
    final uid = useOriginal ? rn.ownerUserId : widget.ownerUserId;
    final uname = useOriginal ? rn.authorName : widget.nickname;
    if (uid == null || uid.isEmpty) return;
    final me = AuthService.instance.currentUser.value;
    final cachedUid = AuthService.instance.cachedUserId;
    final isSelf = (me != null && uid == me.id) ||
        (cachedUid != null && uid == cachedUid);
    if (isSelf && widget.onOpenSelf != null) {
      widget.onOpenSelf!();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) =>
              UserSpacePage(userId: uid, userName: uname)),
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
      // 双写：评论（评论量/通知）+ 回复帖（头像连线链）。回复帖不计转发量。
      await CloudNotesService.instance.createComment(noteId, content);
      var replyId = '';
      try {
        replyId = await CloudNotesService.instance
            .repostNote(noteId, quote: content, kind: 'reply');
      } catch (_) {}
      if (!mounted) return;
      setState(() => _commentCount++);
      if (replyId.isNotEmpty) {
        // 广播给发现/关注流：回复立即连线挂到原帖下方，不等列表刷新。
        await broadcastReplyPosted(
          replyId: replyId,
          parentId: noteId,
          content: content,
        );
        showPostPublishedToast(context, replyId);
      }
      if (widget.onReplyPosted != null) {
        try {
          final cb = widget.onReplyPosted!;
          final r = cb(PlazaNote(
            id: replyId, ownerUserId: AuthService.instance.currentUser.value?.id ?? '',
            title: '', content: content, authorName: AuthService.instance.currentUser.value?.displayName ?? '同修',
            createdAt: DateTime.now().millisecondsSinceEpoch, updatedAt: DateTime.now().millisecondsSinceEpoch,
            repostKind: 'reply', repostOf: noteId ?? '', quoteContent: content,
            visibility: 'public', status: 'normal', likeCount: 0, commentCount: 0,
          ));
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
            Divider(height: 1, color: _border),
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
          final cb = widget.onReplyPosted!;
          final r = cb(PlazaNote(
            id: '', ownerUserId: '', title: '', content: '', authorName: '',
            createdAt: 0, updatedAt: 0, repostKind: 'forward', repostOf: noteId ?? '',
            visibility: 'public', status: 'normal', likeCount: 0, commentCount: 0,
          ));
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
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            Divider(height: 1, color: _border),
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
    final cachedUid = AuthService.instance.cachedUserId;
    // X 式转发：isRepost 时用 repostNote（被转发的原帖）数据替代转发者的数据，
    // 直接展示原帖头像/昵称/内容/指标，转发者引言（quoteContent）单独展示。
    final rn = widget.repostNote;
    final bool showOriginal = widget.isRepost && rn != null;
    // 判断「自己」：转发场景下判断原帖作者是否是自己。
    final displayUserId = showOriginal ? rn.ownerUserId : widget.ownerUserId;
    final displayNickname = showOriginal ? rn.authorName : widget.nickname;
    final displayAccount = showOriginal ? rn.authorAccount : widget.account;
    final displayVerified = showOriginal ? rn.authorVerified : widget.authorVerified;
    final displayContent = showOriginal
        ? (rn.content.isNotEmpty ? rn.content : widget.content)
        : widget.content;
    final displayTimeMs = showOriginal ? rn.createdAt : widget.timeMs;
    final displayCanonRead = showOriginal ? rn.canonRead : widget.canonRead;
    final displayCanonTotal = showOriginal ? rn.canonTotal : widget.canonTotal;
    final displayNoteId = showOriginal ? rn.id : widget.noteId;
    final isSelf = (me != null && displayUserId == me.id) ||
        (cachedUid != null && displayUserId == cachedUid);
    final showMore = !isSelf &&
        me != null &&
        displayUserId != null &&
        displayUserId.isNotEmpty;
    // 使用 isSelf（含 cachedUid 兜底）判断，避免会话恢复竞态时 me 为 null
    // 导致自己的帖子显示屏蔽菜单而非编辑/删除/置顶菜单。
    final canManage = isSelf &&
        displayUserId != null &&
        displayUserId.isNotEmpty &&
        displayNoteId != null &&
        (widget.onTogglePin != null ||
            widget.onEdit != null ||
            widget.onDelete != null);
    final content = displayContent;
    // 测量用的纯文本：剥离 [@账号](user:ID) / [@经名](路径) 标记，渲染仍用原文。
    final measureContent =
        content.replaceAll(RegExp(r'\[@([^\]]+)\]\([^)]+\)'), r'@$1');
    // 阅藏进度百分比：自己的帖子用本地实时统计，他人的用云端数据（0% 也显示）。
    final postPct = postCanonPercent(
      isSelf: isSelf,
      cloudRead: displayCanonRead,
      cloudTotal: displayCanonTotal,
    );
    return InkWell(
      onTap: widget.onTap ?? () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // X 式转发角标（最顶部，与内容列对齐）
            if (widget.isRepost) ...[
              Padding(
                padding: const EdgeInsets.only(left: 54),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.repeat, size: 12, color: Color(0xFF8C8C8C)),
                    const SizedBox(width: 4),
                    Text('你已转帖',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFF8C8C8C))),
                  ],
                ),
              ),
              const SizedBox(height: 4),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openUserSpace,
                  child: UserAvatar(userId: displayUserId, radius: 22),
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
                                child: Text(displayNickname,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: _text)),
                              ),
                            ),
                            if (displayVerified) ...[
                              const SizedBox(width: 3),
                              const Icon(Icons.verified,
                                  size: 17, color: Color(0xFF70867A)),
                            ],
                            if (displayAccount.isNotEmpty) ...[
                              const SizedBox(width: 3),
                              Flexible(
                                // 点击 @账户名 进入该用户个人主页（按下时变暗），
                                // 过长时省略显示，保证昵称完整。
                                child: AccountLink(
                                  account: displayAccount,
                                  onTap: () {
                                    final uid = displayUserId;
                                    if (uid != null && uid.isNotEmpty) {
                                      final me = AuthService
                                          .instance.currentUser.value;
                                      final cachedUid = AuthService
                                          .instance.cachedUserId;
                                      final isSelf =
                                          (me != null && uid == me.id) ||
                                              (cachedUid != null &&
                                                  uid == cachedUid);
                                      if (isSelf &&
                                          widget.onOpenSelf != null) {
                                        widget.onOpenSelf!();
                                        return;
                                      }
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => UserSpacePage(
                                                userId: uid)),
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
                                    ? AppPalette.p.muted
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
                              context, displayUserId!, displayNickname),
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.more_horiz,
                                size: 18, color: Color(0xFF8C8C8C)),
                          ),
                        ),
                      ],
                    ],
                  ),

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
                              multiVolumeBases:
                                  NoteSutraCatalog.cachedMultiVolumeBases,
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
                  // 被回复的原贴（引用框）——X 式转发时不显示（原帖已直接展示），
                  // 仅非转发场景（如回复帖嵌套原贴）才显示。
                  if (widget.quoteBox != null && !widget.isRepost) ...[
                    const SizedBox(height: 8),
                    widget.quoteBox!,
                  ],
                  // X 式引用转发：原帖下方展示转发者引言。
                  if (showOriginal && widget.isQuoteRepost && rn.quoteContent.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppPalette.p.card,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text.rich(
                        TextSpan(
                          text: '💬 ',
                          style: TextStyle(fontSize: 12, color: _textSec),
                          children: [
                            TextSpan(
                              text: rn.quoteContent,
                              style: TextStyle(fontSize: 14, color: _text, height: 1.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  // 发布时间：放在内容和指标行之间（顶部行只留昵称+@账户名+进度百分比），
                  // 点击时间戳进入帖子详情。
                  const SizedBox(height: 6),
                  PostTimeLink(
                    text: postTime(displayTimeMs),
                    onTap: () {
                      final id = displayNoteId;
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
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
          ),
          Divider(height: 1, color: _border),
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
          Text(label, style: TextStyle(fontSize: 15, color: _text)),
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
    // 双写：评论（评论量/通知）+ 回复帖（头像连线链，repostOf 指向被回复帖，
    // 服务端对 kind='reply' 不计转发量）。回复帖 id 用于广播与「点击查看」。
    await CloudNotesService.instance.createComment(target.id, content);
    var replyId = '';
    try {
      replyId = await CloudNotesService.instance
          .repostNote(target.id, quote: content, kind: 'reply');
    } catch (_) {
      // 回复帖创建失败不影响评论本身；本次不乐观插入。
    }
    if (parentCtx.mounted && replyId.isNotEmpty) {
      // 广播给发现/关注流：回复立即连线挂到原帖下方，不等列表刷新。
      await broadcastReplyPosted(
        replyId: replyId,
        parentId: target.id,
        parent: target,
        content: content,
      );
      showPostPublishedToast(parentCtx, replyId);
    } else if (parentCtx.mounted) {
      showPostPublishedToast(parentCtx, '');
    }
    final me = AuthService.instance.currentUser.value;
    var myAccount = '';
    var myVerified = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      myAccount = prefs.getString('user_account_name') ?? '';
      myVerified = prefs.getBool('user_verified') ?? false;
    } catch (_) {}
    final PlazaNote replyNote = PlazaNote(
      id: replyId,
      ownerUserId: me?.id ?? '',
      title: '',
      content: content,
      authorName: me?.displayName ?? '同修',
      authorAccount: myAccount,
      authorVerified: myVerified,
      canonRead: LocalCanonProgress.loaded ? LocalCanonProgress.read : 0,
      canonTotal: LocalCanonProgress.loaded ? LocalCanonProgress.total : 0,
      visibility: 'public',
      status: 'normal',
      likeCount: 0,
      commentCount: 0,
      repostOf: target.id,
      repostSourceAuthor: target.authorName,
      repostKind: 'reply',
      quoteContent: content,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final dynamic cb = onPosted;
    final r = cb(replyNote);
    if (r is Future) await r.catchError((_) {});
  } catch (e) {
    if (parentCtx.mounted) showPostToast(parentCtx, e.toString());
  }
}

/// 本地构造刚发布的回复帖并广播：发现/关注流收到后立即把它挂到当前列表里的
/// 根帖下方，头像连线即时出现，不等列表刷新（云端索引可见性 + 网络往返会晚数秒）。
/// 作者展示字段（@账号/认证/阅藏进度）从本地缓存补齐，否则乐观插入的回复
/// 头部只剩昵称，要等下次列表刷新才显示完整。
Future<void> broadcastReplyPosted({
  required String replyId,
  required String parentId,
  PlazaNote? parent,
  required String content,
}) async {
  if (replyId.isEmpty || parentId.isEmpty) return;
  final me = AuthService.instance.currentUser.value;
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  var account = '';
  var verified = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    account = prefs.getString('user_account_name') ?? '';
    verified = prefs.getBool('user_verified') ?? false;
  } catch (_) {}
  NoteStatsCenter.instance.lastReplyPosted.value = PlazaNote(
    id: replyId,
    ownerUserId: me?.id ?? '',
    title: '',
    content: content,
    authorName: me?.displayName ?? '同修',
    authorAccount: account,
    authorVerified: verified,
    canonRead: LocalCanonProgress.loaded ? LocalCanonProgress.read : 0,
    canonTotal: LocalCanonProgress.loaded ? LocalCanonProgress.total : 0,
    visibility: 'public',
    status: 'normal',
    likeCount: 0,
    commentCount: 0,
    repostOf: parentId,
    repostSourceAuthor: parent?.authorName ?? '',
    repostSourceUserId: parent?.ownerUserId ?? '',
    repostKind: 'reply',
    quoteContent: content,
    quoteOfTitle: parent?.title ?? '',
    quoteOfContent: parent?.content ?? '',
    createdAt: nowMs,
    updatedAt: nowMs,
  );
}

/// 点赞某帖并回调刷新列表。
Future<void> likeTargetNote(
    BuildContext context, PlazaNote target, dynamic onPosted) async {
  try {
    await CloudNotesService.instance.toggleLike(target.id);
    if (onPosted != null) {
      final dynamic cb = onPosted;
      final r = cb(target);
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
          Divider(height: 1, color: _border),
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
      final r = cb(target);
      if (r is Future) await r.catchError((_) {});
    }
  } catch (e) {
    if (context.mounted) showPostToast(context, e.toString());
  }
}

/// 帖子行：与笔记详情页同风格——无卡片背景，
/// 头像+用户名/时间 → 内容预览（最多8行，可展开）→ 统计数据行。
class PostFeedRow extends StatefulWidget {
  final PlazaNote note;
  final FutureOr<void> Function(PlazaNote note)? onReplyPosted;
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

  @override
  State<PostFeedRow> createState() => _PostFeedRowState();
}

class _PostFeedRowState extends State<PostFeedRow> {
  PlazaNote? _repostNote;

  @override
  void initState() {
    super.initState();
    _fetchRepostNote();
  }

  @override
  void didUpdateWidget(covariant PostFeedRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.id != widget.note.id) {
      _repostNote = null;
      _fetchRepostNote();
    }
  }

  Future<void> _fetchRepostNote() async {
    final note = widget.note;
    if (note.repostOf.isEmpty || note.repostKind == 'reply') return;
    try {
      final n = await CloudNotesService.instance.getNoteById(note.repostOf);
      if (!mounted) return;
      setState(() => _repostNote = n);
    } catch (_) {}
  }

  void _openDetail(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: widget.note.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final me = AuthService.instance.currentUser.value;
    final cachedUid = AuthService.instance.cachedUserId;
    final isMine = (me != null && note.ownerUserId == me.id) ||
        (cachedUid != null && note.ownerUserId == cachedUid);
    if (note.repostKind == 'reply') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: GestureDetector(
          onTap: widget.onTap ?? () => _openDetail(context),
          behavior: HitTestBehavior.opaque,
          child: ReplyThread(
            replyNote: note,
            pinned: widget.pinned,
            onComment: (n) => replyToNote(context, n, widget.onReplyPosted),
            onLike: (n) => likeTargetNote(context, n, widget.onReplyPosted),
            onRepost: (n) => forwardNote(context, n, widget.onReplyPosted),
            onMore: widget.onMore,
            onOpenSelf: widget.onOpenSelf,
          ),
        ),
      );
    }
    final isRepost = note.repostOf.isNotEmpty && note.repostKind != 'reply';
    return PostBlock(
      ownerUserId: note.ownerUserId,
      nickname: (isMine && me != null) ? me.displayName : note.authorName,
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
      onReplyPosted: widget.onReplyPosted,
      onTap: widget.onTap ?? () => _openDetail(context),
      pinned: widget.pinned,
      onTogglePin: widget.onTogglePin,
      onEdit: widget.onEdit,
      onDelete: widget.onDelete,
      showFollowButton: widget.showFollowButton && !isMine,
      quoteBox: !isRepost && note.repostOf.isNotEmpty ? QuoteBox(note: note) : null,
      isRepost: isRepost,
      isQuoteRepost: note.quoteContent.isNotEmpty,
      repostNote: _repostNote,
      onOpenSelf: widget.onOpenSelf,
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
/// 四个指标均分整行宽度：第一个图标与昵称/内容左对齐，指标间保留固定间隔，
/// 数字在所在指标格内等比缩小。这样最后一个指标（阅读量）即使上万，
/// 也不会因为三处固定间隔占位过多而被挤出屏幕右缘。
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
      Expanded(
        child: statsCell(
            Image.asset('assets/images/ic_comment.png', width: 16, height: 16),
            '$commentCount',
            onTap: onComment),
      ),
      const SizedBox(width: 20),
      Expanded(
        child: statsCell(
            Icon(Icons.repeat_rounded, size: 16, color: _textSec),
            '$repostCount',
            onTap: onRepost),
      ),
      const SizedBox(width: 20),
      Expanded(
        child: statsCell(
            Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                size: 16, color: liked ? _gold : _textSec),
            '$likeCount',
            color: liked ? _gold : null,
            onTap: onLike),
      ),
      const SizedBox(width: 20),
      Expanded(
        child: statsCell(
            Image.asset('assets/images/ic_view.png', width: 16, height: 16),
            '$viewCount'),
      ),
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

/// 笔记 Tab：我自己直接新建的原创帖子（不含回复帖与转发帖）。
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

    // didUpdateWidget 中：基于 widget 属性的变化检测保留。
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

    // 笔记 = 我自己直接新建的原创帖子：不含回复帖（对自己的回复折叠到原帖
    // 评论图标下），也不含转发/引用转发帖（在「转发」Tab 展示）。
    // 注意：此处用实时 AuthService.instance.isLoggedIn 判断，
    // 避免 reloadNotifier 同步触发时 widget 属性还是旧值导致跳过加载。
    List<PlazaNote> cloudNotes = [];
    bool hasMore = false;
    String? errorText;
    final loggedIn = AuthService.instance.isLoggedIn;
    // 只展示属于当前真实账号的帖子：降级/匿名会话时服务端可能返回
    // 共享匿名 uid 名下其他人的帖子（昵称/头像串号），一律过滤掉。
    final myUid = AuthService.instance.currentUser.value?.id ??
        AuthService.instance.cachedUserId;
    if (loggedIn) {
      try {
        await CloudNotesService.instance.refreshLikedNoteIds();
        final (list, more) = await CloudNotesService.instance.getMyNotes(
          page: 1,
          pageSize: _pageSize,
        );
        cloudNotes = list
            .where((n) =>
                n.repostKind.isEmpty &&
                // 双保险：直接新建的原创帖 repostOf 恒为空；旧数据可能存在
                // 未标记 repostKind 的回复/转帖，靠 repostOf 一并排除。
                n.repostOf.isEmpty &&
                (myUid == null || myUid.isEmpty || n.ownerUserId == myUid))
            .toList();
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
        title: Text('删除帖子',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: Text('删除后帖子将从菩提空间移除，且无法恢复。确定删除吗？',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: _textSec)),
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
      // 本地兜底也要补齐 @账户 / 认证符号 / 阅藏百分比：
      // 云调用全部失败降级到本地缓存时，帖子卡片才能显示完整作者信息
      // （否则昵称后 @账户、认证符号、阅藏百分比会消失）。
      final account = prefs.getString('user_account_name') ?? '';
      final verified = prefs.getBool('user_verified') ?? false;
      final canonRead = LocalCanonProgress.read;
      final canonTotal = LocalCanonProgress.total;
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
          authorAccount: account,
          authorVerified: verified,
          canonRead: canonRead,
          canonTotal: canonTotal,
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
        final myUid = AuthService.instance.currentUser.value?.id ??
            AuthService.instance.cachedUserId;
        // 与首屏一致：只保留直接新建的原创帖子。
        _notes.addAll(list.where((n) =>
            n.repostKind.isEmpty &&
            n.repostOf.isEmpty &&
            (myUid == null || myUid.isEmpty || n.ownerUserId == myUid)));
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
              child: AppLoadingIndicator(message: '正在加载内容...'),
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
                      style: TextStyle(fontSize: 14, color: _textHint)),
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
              // 横向内边距放在列表层：分割线随内容缩进 16px、不贴手机边缘（与首页一致）。
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    if (index == _notes.length) {
                      if (_hasMore && widget.isLoggedIn) {
                        return Padding(
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
                      // 末尾收尾分割线，保证最后一条帖子下方也有分割线（随内容缩进）。
                      return Divider(
                          height: 1, thickness: 0.5, color: AppPalette.p.divider);
                    }
                    final note = _notes[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 帖子顶部分割线（首条不画，避免顶部多一条线）。
                        if (index > 0)
                          Divider(
                              height: 1,
                              thickness: 0.5,
                              color: AppPalette.p.divider),
                        _buildNoteCard(note),
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
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            Divider(height: 1, color: _border),
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
      // 笔记 Tab 全部是自己的原创帖：回复/转发后不整页刷新——
      // 评论数由 PostBlock 本地即时 +1，对自己的回复按规则折叠到原帖
      // 评论图标下（详情页可见），列表本身无需任何变化。
      onReplyPosted: null,
      pinned: _pinnedIds.contains(note.id),
      onTogglePin: () => _togglePin(note),
      onEdit: () => _editNote(note),
      onDelete: () => _deleteNote(note),
      onMore: (n) => _showReplyMenu(n),
      // 我的主页帖子 Tab：全部是自己发布的帖子，显式关闭关注按钮，
      // 不受会话恢复竞态（currentUser 短暂为 null）影响。
      showFollowButton: false,
    );
  }
}

/// 回复 Tab：我对其他人的回复（不含对自己帖子/回复的回复；
/// 对自己的回复与其他人的回复一样，折叠到原帖评论图标下）。
class _MyRepliesTab extends StatefulWidget {
  final bool isLoggedIn;
  final ValueNotifier<int> reloadNotifier;
  const _MyRepliesTab({required this.isLoggedIn, required this.reloadNotifier});

  @override
  State<_MyRepliesTab> createState() => _MyRepliesTabState();
}

class _MyRepliesTabState extends State<_MyRepliesTab> {
  /// 回复 = 我对其他人发出的回复帖（repostKind == 'reply' 且回复对象不是自己）。
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
    // initState 时：用实时登录态判断（创建时已是新属性，无过时问题，但统一风格）。
    if (AuthService.instance.isLoggedIn) _load();
    widget.reloadNotifier.addListener(_onReload);
  }

  @override
  void dispose() {
    widget.reloadNotifier.removeListener(_onReload);
    super.dispose();
  }

  void _onReload() {
    _loadPinnedIds();
    // 注意：reloadNotifier 同步触发时 widget 属性可能是旧值，必须用实时 getter 判断。
    if (AuthService.instance.isLoggedIn) _load();
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
      // 服务端按 repostKind='reply' 过滤，直接拉取全部回复帖，不再只取前 20 条。
      // 旧版服务端不识别 repostKind 时返回全部笔记，客户端仍做兜底过滤。
      // 翻完所有分页确保历史回复全部加载，maxPages 兜底防死循环。
      var p = 1;
      var hasMore = true;
      const maxPages = 100;
      final collected = <PlazaNote>[];
      while (p <= maxPages && hasMore) {
        final (list, more) = await CloudNotesService.instance.getMyNotes(
          page: p,
          pageSize: _pageSize,
          repostKind: 'reply',
        );
        // 客户端兜底过滤：旧版服务端未按 repostKind 过滤时仍能正确筛选。
        // 同时只保留属于当前真实账号的回复（降级/匿名会话串号数据一律过滤）。
        final myUid = AuthService.instance.currentUser.value?.id ??
            AuthService.instance.cachedUserId;
        final repliesInPage = list
            .where((n) =>
                n.repostKind == 'reply' &&
                (myUid == null || myUid.isEmpty || n.ownerUserId == myUid))
            .toList();
        if (repliesInPage.isNotEmpty) {
          debugPrint('[Replies] page=$p found ${repliesInPage.length} replies');
        }
        collected.addAll(repliesInPage);
        hasMore = more;
        if (!hasMore) break;
        p++;
      }
      debugPrint('[Replies] _load done: total collected=${collected.length}, lastPage=$p, hasMore=$hasMore');
      if (!mounted) return;
      // 去掉「对自己的回复」：回复对象是我自己的帖子/回复时不展示在回复 Tab。
      final visible = await _excludeSelfReplies(
          collected, collected.map((n) => n.id).toSet());
      if (!mounted) return;
      setState(() {
        _replies.addAll(visible);
        _hasMore = hasMore;
        _page = p + 1;
      });
      try {
        await _buildGroups();
      } catch (e, st) {
        debugPrint('[Replies] _buildGroups error: $e\n$st');
        if (!mounted) return;
        setState(() => _error = '分组数据出错，请下拉重试');
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e, st) {
      debugPrint('[Replies] _load error: $e\n$st');
      if (!mounted) return;
      setState(() {
        _error = '加载失败：${e.toString().replaceAll('Exception: ', '')}';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      // 加载更多：服务端已按 repostKind='reply' 过滤，直接翻页即可。
      // 旧版服务端未过滤时客户端仍做兜底筛选。
      var p = _page;
      var hasMore = _hasMore;
      const maxExtraPages = 50;
      final collected = <PlazaNote>[];
      var tried = 0;
      while (tried < maxExtraPages && hasMore) {
        final (list, more) = await CloudNotesService.instance.getMyNotes(
          page: p,
          pageSize: _pageSize,
          repostKind: 'reply',
        );
        final myUid = AuthService.instance.currentUser.value?.id ??
            AuthService.instance.cachedUserId;
        final repliesInPage = list
            .where((n) =>
                n.repostKind == 'reply' &&
                (myUid == null || myUid.isEmpty || n.ownerUserId == myUid))
            .toList();
        if (repliesInPage.isNotEmpty) {
          debugPrint('[Replies] loadMore page=$p found ${repliesInPage.length} replies');
        }
        collected.addAll(repliesInPage);
        hasMore = more;
        p++;
        tried++;
        if (collected.isNotEmpty || !hasMore) break;
      }
      debugPrint('[Replies] _loadMore done: collected=${collected.length}, nextPage=$p, hasMore=$hasMore');
      if (!mounted) return;
      // 去掉「对自己的回复」：回复对象判定需包含已加载的全部回复帖 id。
      final knownReplyIds = <String>{
        ..._replies.map((n) => n.id),
        ...collected.map((n) => n.id),
      };
      final visible = await _excludeSelfReplies(collected, knownReplyIds);
      if (!mounted) return;
      setState(() {
        _replies.addAll(visible);
        _hasMore = hasMore;
        _page = p;
        _loadingMore = false;
      });
      try {
        await _buildGroups();
      } catch (e, st) {
        debugPrint('[Replies] _buildGroups (loadMore) error: $e\n$st');
      }
    } catch (e, st) {
      debugPrint('[Replies] _loadMore error: $e\n$st');
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  /// 去掉「对自己的回复」：回复对象是我自己的帖子/回复时，不展示在回复 Tab——
  /// 这类回复与其他人的回复一样，折叠到原帖评论图标下。
  /// 判定优先用回复帖自带的 repostSourceUserId（服务端创建回复时记录的被回复帖
  /// 作者 uid，无需联网，新旧数据通用）；旧数据缺失该字段时才按 repostOf 回源查询。
  /// [myReplyIds] 为我自己回复帖的 id 集合（回复对象是其中一条时即回复自己）。
  Future<List<PlazaNote>> _excludeSelfReplies(
      List<PlazaNote> batch, Set<String> myReplyIds) async {
    final myUid = AuthService.instance.currentUser.value?.id ??
        AuthService.instance.cachedUserId;
    if (myUid == null || myUid.isEmpty || batch.isEmpty) return batch;
    final keeps = await Future.wait(batch.map((n) async {
      // 首选：被回复帖作者 uid 在创建回复时已写入，直接本地比对。
      if (n.repostSourceUserId.isNotEmpty) {
        return n.repostSourceUserId != myUid;
      }
      final parentId = n.repostOf;
      if (parentId.isEmpty) return true;
      if (myReplyIds.contains(parentId)) return false;
      // 旧数据缺失 repostSourceUserId 时回源查询被回复帖判断归属。
      try {
        final parent = await CloudNotesService.instance.getNoteById(parentId);
        if (parent.ownerUserId.isNotEmpty && parent.ownerUserId == myUid) {
          return false;
        }
      } catch (_) {
        // 原帖获取失败（已删/隐藏/网络异常）时先保留，避免误隐藏对他人的回复；
        // _buildGroups 内还有「根帖是自己的帖子则整组跳过」的兜底拦截。
      }
      return true;
    }));
    final kept = [
      for (var i = 0; i < batch.length; i++)
        if (keeps[i]) batch[i],
    ];
    debugPrint('[Replies] _excludeSelfReplies: myUid=$myUid '
        'batch=${batch.length} kept=${kept.length} '
        'excluded=${batch.length - kept.length}');
    return kept;
  }

  /// 在自己的回复下再回复（对自己的回复）：新回复按规则不展示在回复 Tab，
  /// 无需整页刷新，只把目标回复的评论量本地 +1 即时展示。
  void _bumpCommentCountLocal(PlazaNote target) {
    final bumped = target.copyWith(commentCount: target.commentCount + 1);
    for (var i = 0; i < _replies.length; i++) {
      if (_replies[i].id == target.id) _replies[i] = bumped;
    }
    for (var i = 0; i < _pinnedReplies.length; i++) {
      if (_pinnedReplies[i].id == target.id) _pinnedReplies[i] = bumped;
    }
    for (final g in _groups) {
      final list = g.$2;
      for (var i = 0; i < list.length; i++) {
        if (list[i].id == target.id) list[i] = bumped;
      }
    }
    if (mounted) setState(() {});
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
    // 并行预取各组原贴数据。
    // 关键修复：若直接按 rootId 取帖失败（典型场景：中间回复 b 被删，
    // c.repostOf 仍指向 b.id，b 既不在本地也无法从云端拿到），不使用空的
    // 「同修」占位，而是沿该组第一条回复的 repostOf 链向云端逐级向上查找，
    // 直到找到存在的根帖子；极端情况下把该回复本身当作根卡片展示（至少
    // 作者、内容是正确的），避免原贴区域变成空白占位。
    Future<MapEntry<String, PlazaNote>> resolveRoot(String rootId) async {
      PlazaNote? root;
      try {
        root = await CloudNotesService.instance.getNoteById(rootId);
      } catch (_) {
        root = allById[rootId];
      }
      if (root != null && (root.ownerUserId.isNotEmpty || root.content.isNotEmpty)) {
        accountsById[rootId] = root.authorAccount;
        return MapEntry(rootId, root);
      }
      // 本地 + 直接云端都没拿到，走逐级回溯链兜底
      final list = children[rootId] ?? const <PlazaNote>[];
      PlazaNote? fallback;
      for (final reply in list) {
        if (fallback == null) fallback = reply;
        var currentId = reply.repostOf;
        var guard = 0;
        while (currentId.isNotEmpty && guard < 20) {
          guard++;
          try {
            final n = await CloudNotesService.instance.getNoteById(currentId);
            if (n.repostKind != 'reply' || n.repostOf.isEmpty) {
              // 找到真正的根帖子（非 reply 类型或已到顶）
              accountsById[rootId] = n.authorAccount;
              return MapEntry(rootId, n);
            }
            currentId = n.repostOf;
          } catch (_) {
            break;
          }
        }
      }
      // 整条链都拿不到，就用该组第一条回复当作展示的「根」，
      // 至少作者头像/昵称/内容是真实的，不会显示空的"同修"占位。
      final fallbackRoot = fallback ??
          PlazaNote(
            id: rootId,
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
      accountsById[rootId] = fallbackRoot.authorAccount;
      return MapEntry(rootId, fallbackRoot);
    }

    final futures = rootIds.map((id) => resolveRoot(id));
    final roots = <String, PlazaNote>{};
    for (final e in await Future.wait(futures)) {
      roots[e.key] = e.value;
    }
    final groups = <(PlazaNote, List<PlazaNote>)>[];
    final myUid = AuthService.instance.currentUser.value?.id ??
        AuthService.instance.cachedUserId;
    for (final id in rootIds) {
      final list = children[id]!;
      if (list.isEmpty) continue;
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      // 兜底「根」可能就是本组第一条回复（原贴已被删、云端也取不到时），
      // 此时把它从回复链里去掉，避免同一条回复在卡片上重复显示两次。
      final rootNote = roots[id]!;
      if (rootNote.repostKind == 'reply') {
        list.removeWhere((n) => n.id == rootNote.id);
      }
      if (list.isEmpty) continue;
      // 兜底拦截：根帖是「我自己的帖子」时整组跳过——对自己的回复不进回复 Tab。
      // 正常情况这类回复已被 _excludeSelfReplies 过滤；此处专门拦截旧数据缺失
      // repostSourceUserId 且回源查询失败漏进来的情况。
      // - 根帖是普通帖：作者是我 → 整组都是对我自己帖子的回复 → 跳过；
      // - 根帖是回复帖（回源失败的兜底展示，或别人在我帖子下的评论）：
      //   仅当它是我发的、且回复的也是我时才是「对自己的回复」→ 跳过；
      //   别人发的评论（哪怕评的是我的帖子）我回复了，属于对他人的回复 → 保留。
      if (myUid != null && myUid.isNotEmpty) {
        final selfRoot = rootNote.repostKind == 'reply'
            ? (rootNote.ownerUserId == myUid &&
                rootNote.repostSourceUserId == myUid)
            : rootNote.ownerUserId == myUid;
        if (selfRoot) {
          debugPrint('[Replies] _buildGroups: skip self-reply group '
              'rootId=$id rootKind=${rootNote.repostKind}');
          continue;
        }
      }
      groups.add((rootNote, list));
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
        title: Text('删除回复',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: Text('删除后回复将从菩提空间移除，且无法恢复。确定删除吗？',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: _textSec)),
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
      // 删除后立即重建分组，避免"切换页面才消失"；
      // 同时 _buildGroups 内的兜底逻辑会修复被删中间回复导致的原贴占位问题。
      await _buildGroups();
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
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            Divider(height: 1, color: _border),
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
              // 横向内边距放在列表层：分割线随内容缩进 16px、不贴手机边缘（与首页一致）。
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    if (index == itemCount) {
                      if (_hasMore) {
                        return Padding(
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
                      return Divider(
                          height: 1, thickness: 0.5, color: AppPalette.p.divider);
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
                        // 分割线上下各留 8px：与上面帖子、下面帖子的间隔都更宽松。
                        if (index > 0) ...[
                          const SizedBox(height: 8),
                          Divider(
                              height: 1,
                              thickness: 0.5,
                              color: AppPalette.p.divider),
                          const SizedBox(height: 8),
                        ],
                        body,
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
                                style: TextStyle(
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
                      TextSpan(
                        text: '回复@',
                        style: TextStyle(fontSize: 14, color: _textSec),
                      ),
                      TextSpan(
                        text: parentAccount.isEmpty ? '同修' : parentAccount,
                        style: TextStyle(
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
                    style: TextStyle(
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
                  onComment: () =>
                      replyToNote(context, reply, (_) => _bumpCommentCountLocal(reply)),
                  onRepost: () => forwardNote(context, reply, (_) => _load()),
                  onLike: () => likeTargetNote(context, reply, (_) => _load()),
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
            // top:68 = 根帖外层顶内边距(6) + 头像区顶内边距(12) + 头像高(44) + 线上端留白(6)；
            // bottom:6 = 线下端距 ReplyChain 首个头像 6px（等于链内节点间距）。
            Positioned(
              left: 21,
              top: 68,
              bottom: 6,
              child: Container(width: 1, color: const Color(0xFFC9C9C9)),
            ),
            // 与首页发现流同款 vertical:6 外边距：分割线与帖子边缘的间隔一致。
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: PostFeedRow(
                note: root,
                onReplyPosted: (_) => _load(),
                // 分组区域不显示已置顶（已置顶只在顶部置顶卡片展示）。
                pinned: false,
                onTogglePin: () => _togglePin(root),
                onEdit: () => _editNote(root),
                onDelete: () => _deleteNote(root),
                onMore: (n) => _showReplyMenu(n),
                // 回复 Tab 只展示我回复过的帖子，原贴无需显示关注按钮。
                showFollowButton: false,
              ),
            ),
          ],
        ),
        // 原帖与回复链之间留 6px 间距，作为连线底部到回复头像的间隔。
        ReplyChain(
          replies: replies,
          parentAccounts: {
            root.id: root.authorAccount,
            for (final r in replies) r.id: r.authorAccount,
          },
          onComment: (n) =>
              replyToNote(context, n, (_) => _bumpCommentCountLocal(n)),
          onLike: (n) => likeTargetNote(context, n, (_) => _load()),
          onRepost: (n) => forwardNote(context, n, (_) => _load()),
          onMore: (n) => _showReplyMenu(n),
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
            // top:58 = 外层顶内边距(6) + 头像上内边距(2) + 头像高(44) + 线上端留白(6)；
            // bottom:6 = 线下端距 ReplyChain 首个头像 6px（与 _buildGroupCard 一致）。
            Positioned(
              left: 21,
              top: 58,
              bottom: 6,
              child: Container(width: 1, color: const Color(0xFFC9C9C9)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
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
                        child: Row(
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
        ReplyChain(
          replies: replies,
          parentAccounts: {
            root.id: root.authorAccount,
            for (final r in replies) r.id: r.authorAccount,
          },
          onComment: (n) =>
              replyToNote(context, n, (_) => _bumpCommentCountLocal(n)),
          onLike: (n) => likeTargetNote(context, n, (_) => _load()),
          onRepost: (n) => forwardNote(context, n, (_) => _load()),
          onMore: (n) => _showReplyMenu(n),
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
              child: AppLoadingIndicator(message: '正在加载内容...'),
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
                      style: TextStyle(fontSize: 14, color: _textHint)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「转发 / 书签」Tab 共用的帖子管理操作：置顶（本地）/ 编辑 / 删除自己的帖子，
/// 与「我的帖子」Tab 行为一致；三点菜单由 PostBlock 内部按是否本人自动分发
/// （本人 → 置顶/编辑/删除，他人 → 关注/屏蔽）。
mixin _SharedNoteActions<T extends StatefulWidget> on State<T> {
  final Set<String> _sharedPinnedIds = {};
  static const String _sharedPinnedKey = 'my_pinned_note_ids';

  /// 编辑等操作成功后由 Tab 自行刷新列表。
  void onSharedNotesChanged();

  bool isSharedPinned(PlazaNote note) => _sharedPinnedIds.contains(note.id);

  Future<void> loadSharedPinnedIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _sharedPinnedIds
        ..clear()
        ..addAll(prefs.getStringList(_sharedPinnedKey) ?? const []);
    } catch (_) {}
  }

  /// 置顶/取消置顶（本地保存，与帖子/回复 Tab 共用同一份置顶记录）。
  Future<void> toggleSharedPin(PlazaNote note) async {
    final wasPinned = _sharedPinnedIds.contains(note.id);
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_sharedPinnedKey) ?? [];
      if (wasPinned) {
        list.remove(note.id);
        _sharedPinnedIds.remove(note.id);
      } else {
        list.add(note.id);
        _sharedPinnedIds.add(note.id);
      }
      await prefs.setStringList(_sharedPinnedKey, list);
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
    showPostToast(context, wasPinned ? '已取消置顶' : '已置顶');
  }

  /// 编辑帖子内容：更新云端后通知 Tab 刷新。
  Future<void> editSharedNote(PlazaNote note) async {
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
      onSharedNotesChanged();
    } catch (e) {
      if (mounted) showPostToast(context, e.toString());
    }
  }

  /// 删除帖子：从菩提空间移除后回调移除该条并刷新界面。
  Future<void> deleteSharedNote(
    PlazaNote note, {
    required VoidCallback onRemoved,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除帖子',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: Text('删除后帖子将从菩提空间移除，且无法恢复。确定删除吗？',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: _textSec)),
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
      _sharedPinnedIds.remove(note.id);
      if (!mounted) return;
      setState(onRemoved);
      showPostToast(context, '已删除');
    } catch (e) {
      if (mounted) showPostToast(context, e.toString());
    }
  }
}

/// 转发 Tab：我转发过的其他人的帖子（直接转发 + 引用转发）。
class _MyRepostsTab extends StatefulWidget {
  final bool isLoggedIn;
  final ValueNotifier<int> reloadNotifier;
  const _MyRepostsTab({required this.isLoggedIn, required this.reloadNotifier});

  @override
  State<_MyRepostsTab> createState() => _MyRepostsTabState();
}

class _MyRepostsTabState extends State<_MyRepostsTab>
    with _SharedNoteActions<_MyRepostsTab> {
  List<PlazaNote>? _notes;
  bool _loading = true;
  String? _error;

  @override
  void onSharedNotesChanged() => _load(silent: true);

  @override
  void initState() {
    super.initState();
    if (AuthService.instance.isLoggedIn) _load();
    widget.reloadNotifier.addListener(_onReload);
  }

  @override
  void dispose() {
    widget.reloadNotifier.removeListener(_onReload);
    super.dispose();
  }

  void _onReload() {
    // reloadNotifier 同步触发时 widget 属性可能是旧值，必须用实时 getter。
    if (AuthService.instance.isLoggedIn) _load();
  }

  @override
  void didUpdateWidget(covariant _MyRepostsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // didUpdateWidget：widget 属性变化检测保留。
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
      });
    }
    // 先校验登录态：避免 widget 属性过时导致误判。
    if (!AuthService.instance.isLoggedIn) {
      if (!mounted) return;
      setState(() {
        _notes = [];
        _loading = false;
      });
      return;
    }
    try {
      // 置顶记录与「笔记」Tab 共用，每次加载时同步一次。
      await loadSharedPinnedIds();
      await CloudNotesService.instance.refreshLikedNoteIds();
      // 服务端一次只能按一个 repostKind 过滤：直接转发/引用转发分两路拉取合并。
      // 旧版服务端不识别 repostKind 时返回全部笔记，客户端按 repostKind 兜底过滤。
      final byId = <String, PlazaNote>{};
      for (final kind in const ['forward', 'quote']) {
        var p = 1;
        var hasMore = true;
        const maxPages = 100;
        while (p <= maxPages && hasMore) {
          final (list, more) = await CloudNotesService.instance.getMyNotes(
            page: p,
            pageSize: 50,
            repostKind: kind,
          );
          for (final n in list) {
            // 双重校验：repostKind 匹配且 repostOf 非空才是真正的转发帖。
            // 旧数据可能存在 repostKind 被错误赋值但 repostOf 为空的情况。
            if (n.repostKind == kind && n.repostOf.isNotEmpty) byId[n.id] = n;
          }
          hasMore = more;
          p++;
        }
      }
      // 只保留转发「其他人」的帖子：转发自己的帖子不展示。
      // repostSourceUserId 为原帖作者 uid；旧数据缺失时按 repostOf 回源判断。
      final myUid = AuthService.instance.currentUser.value?.id ??
          AuthService.instance.cachedUserId;
      final all = byId.values.toList();
      final sourceOwners = await Future.wait(all.map((n) async {
        if (myUid == null || myUid.isEmpty) return '';
        if (n.repostSourceUserId.isNotEmpty) return n.repostSourceUserId;
        if (n.repostOf.isEmpty) return '';
        try {
          final src =
              await CloudNotesService.instance.getNoteById(n.repostOf);
          return src.ownerUserId;
        } catch (_) {
          // 原帖获取失败（已删/隐藏/网络异常）时保留，避免误隐藏对他人的转发。
          return '';
        }
      }));
      final notes = <PlazaNote>[];
      for (var i = 0; i < all.length; i++) {
        final owner = sourceOwners[i];
        if (owner.isEmpty || owner != myUid) notes.add(all[i]);
      }
      // 两路合并后按转发时间倒序（最新在前）。
      notes.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _loading = false;
      });
    } catch (e, st) {
      debugPrint('[Reposts] _load error: $e\n$st');
      if (!mounted) return;
      setState(() {
        _notes = [];
        _error = '加载失败：${e.toString().replaceAll('Exception: ', '')}';
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
      return _tabEmpty('还没有转发过帖子', Icons.repeat_rounded);
    }
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
          ),
          SliverPadding(
            // 横向内边距放在列表层：分割线随内容缩进 16px、不贴手机边缘（与首页一致）。
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  // 末尾收尾分割线，保证最后一条帖子下方也有分割线（与「笔记」Tab 一致）。
                  if (index == _notes!.length) {
                    return Divider(
                        height: 1, thickness: 0.5, color: AppPalette.p.divider);
                  }
                  final note = _notes![index];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 帖子顶部分割线（首条不画，避免顶部多一条线）。
                      if (index > 0)
                        Divider(
                            height: 1,
                            thickness: 0.5,
                            color: AppPalette.p.divider),
                      PostFeedRow(
                        note: note,
                        onReplyPosted: (_) => _load(),
                        pinned: isSharedPinned(note),
                        onTogglePin: () => toggleSharedPin(note),
                        onEdit: () => editSharedNote(note),
                        onDelete: () => deleteSharedNote(note,
                            onRemoved: () =>
                                _notes!.removeWhere((n) => n.id == note.id)),
                        // 转发 Tab 不单独显示关注按钮，三点菜单仍可操作关注/屏蔽。
                        showFollowButton: false,
                      ),
                    ],
                  );
                },
                childCount: _notes!.length + 1,
              ),
            ),
          ),
        ],
      ),
    );
  } // _MyRepostsTab build

  Widget _tabLoading() {
    return Builder(
      builder: (context) => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: 4),
          ),
          const SliverFillRemaining(
            child: Center(
              child: AppLoadingIndicator(message: '正在加载内容...'),
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
                      style: TextStyle(fontSize: 14, color: _textHint)),
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

class _MyBookmarksTabState extends State<_MyBookmarksTab>
    with _SharedNoteActions<_MyBookmarksTab> {
  List<PlazaNote>? _notes;
  bool _loading = true;
  String? _error;

  @override
  void onSharedNotesChanged() => _load(silent: true);

  @override
  void initState() {
    super.initState();
    if (AuthService.instance.isLoggedIn) _load();
    widget.reloadNotifier.addListener(_onReload);
  }

  @override
  void dispose() {
    widget.reloadNotifier.removeListener(_onReload);
    super.dispose();
  }

  void _onReload() {
    // reloadNotifier 同步触发时 widget 属性可能是旧值，必须用实时 getter。
    if (AuthService.instance.isLoggedIn) _load();
  }

  @override
  void didUpdateWidget(covariant _MyBookmarksTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // didUpdateWidget：widget 属性变化检测保留。
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
      });
    }
    // 先校验登录态：避免 widget 属性过时导致误判。
    if (!AuthService.instance.isLoggedIn) {
      if (!mounted) return;
      setState(() {
        _notes = [];
        _loading = false;
      });
      return;
    }
    try {
      // 置顶记录与「帖子」Tab 共用，每次加载时同步一次。
      await loadSharedPinnedIds();
      final notes = await CloudNotesService.instance.getFavoriteNotes();
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _loading = false;
      });
    } catch (e, st) {
      debugPrint('[Bookmarks] _load error: $e\n$st');
      if (!mounted) return;
      setState(() {
        _notes = [];
        _error = '加载失败：${e.toString().replaceAll('Exception: ', '')}';
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
            // 横向内边距放在列表层：分割线随内容缩进 16px、不贴手机边缘（与首页一致）。
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  // 末尾收尾分割线，保证最后一条帖子下方也有分割线（与「帖子」Tab 一致）。
                  if (index == _notes!.length) {
                    return Divider(
                        height: 1, thickness: 0.5, color: AppPalette.p.divider);
                  }
                  final note = _notes![index];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 帖子顶部分割线（首条不画，避免顶部多一条线）。
                      if (index > 0)
                        Divider(
                            height: 1,
                            thickness: 0.5,
                            color: AppPalette.p.divider),
                      PostFeedRow(
                        note: note,
                        onReplyPosted: (_) => _load(),
                        pinned: isSharedPinned(note),
                        onTogglePin: () => toggleSharedPin(note),
                        onEdit: () => editSharedNote(note),
                        onDelete: () => deleteSharedNote(note,
                            onRemoved: () =>
                                _notes!.removeWhere((n) => n.id == note.id)),
                        // 书签 Tab 不单独显示关注按钮，三点菜单仍可操作关注/屏蔽。
                        showFollowButton: false,
                      ),
                    ],
                  );
                },
                childCount: _notes!.length + 1,
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
              child: AppLoadingIndicator(message: '正在加载内容...'),
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
                      style: TextStyle(fontSize: 14, color: _textHint)),
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
          style: TextStyle(
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
        trailing: Icon(Icons.chevron_right, color: _textHint, size: 20),
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
        title: Text('退出登录',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content:
            Text('退出后需重新登录才能管理云端笔记', style: TextStyle(color: _textSec)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('取消', style: TextStyle(color: _textSec))),
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
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppPalette.p.gradTop, AppPalette.p.gradBot],
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
                      icon: Icon(Icons.arrow_back_ios_new,
                          color: _text, size: 20),
                    ),
                    const SizedBox(width: 4),
                    Text('设置',
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
                          const SettingsDivider(),
                          _SettingsExportNotesTile(),
                        ],
                      ),
                      _sectionTitle('其他'),
                      SettingsCard(
                        children: [
                          const _SettingsAppearanceTile(),
                          const SettingsDivider(),
                          _SettingsLinkTile(
                            icon: Icons.favorite_outline,
                            iconColor: _gold,
                            title: '资助',
                            subtitle: '捐款资助服务器运行',
                            page: const DonatePage(),
                          ),
                          const SettingsDivider(),
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
                      style: TextStyle(
                          fontSize: 16,
                          color: _text,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: _textHint)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: _textHint, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 「外观」行：点击弹出暖黄/素白选择面板，切换后全局即时换肤。
class _SettingsAppearanceTile extends StatelessWidget {
  const _SettingsAppearanceTile();

  void _openSheet(BuildContext context) {
    final state = context.findAncestorStateOfType<_SettingsPageState>();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppPalette.p.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Row(
                children: [
                  Text('外观',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: AppPalette.p.text)),
                  const SizedBox(width: 8),
                  Text('切换后自动记住偏好，重启应用后完全生效',
                      style: TextStyle(
                          fontSize: 12, color: AppPalette.p.textHint)),
                ],
              ),
            ),
            _AppearanceOption(mode: AppearanceMode.warm),
            Container(
                height: 0.5,
                margin: const EdgeInsets.symmetric(horizontal: 20),
                color: AppPalette.p.borderSoft),
            _AppearanceOption(mode: AppearanceMode.plain),
            const SizedBox(height: 10),
          ],
        ),
      ),
    ).then((_) {
      // 弹层关闭后刷新设置页自身（若用户确实改了外观）。
      state?.reloadForSettings();
    });
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _openSheet(context),
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
              child:
                  Icon(Icons.palette_outlined, color: _gold, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('外观',
                      style: TextStyle(
                          fontSize: 16,
                          color: _text,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text('当前：${AppPalette.instance.mode.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: _textHint)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: _textHint, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 外观选项行：左侧双色圆片预览 + 名称描述 + 右侧选中勾。
class _AppearanceOption extends StatelessWidget {
  final AppearanceMode mode;

  const _AppearanceOption({required this.mode});

  @override
  Widget build(BuildContext context) {
    final palette =
        mode == AppearanceMode.warm ? AppPalette.warm : AppPalette.plain;
    final selected = AppPalette.instance.mode == mode;
    return InkWell(
      onTap: () async {
        if (selected) {
          Navigator.of(context).pop();
          return;
        }
        // 持久化外观偏好后自动重启 App，确保换肤完全生效。
        await AppPalette.instance.setMode(mode);
        if (!context.mounted) return;
        Navigator.of(context).pop();
        const platform = MethodChannel('app_channel');
        try {
          await platform.invokeMethod('restartApp');
        } catch (_) {
          // 重启失败时兜底提示：重启应用后可完全生效。
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            elevation: 0,
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppPalette.p.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: AppPalette.p.borderSoft),
            ),
            duration: const Duration(seconds: 3),
            content: Text('外观已切换，重启应用后可完全生效',
                style: TextStyle(
                    fontSize: 13, color: AppPalette.p.textSec)),
          ));
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            // 双色预览：大圆为背景色，右上小圆为主色。
            SizedBox(
              width: 40,
              height: 40,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: palette.bg,
                      shape: BoxShape.circle,
                      border: Border.all(color: palette.border, width: 1),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: palette.accent,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: AppPalette.p.card, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mode.label,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: AppPalette.p.text)),
                  const SizedBox(height: 2),
                  Text(mode.desc,
                      style: TextStyle(
                          fontSize: 12, color: AppPalette.p.textSec)),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle, color: AppPalette.p.accent, size: 22)
            else
              Icon(Icons.radio_button_off,
                  color: AppPalette.p.textHint, size: 22),
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
              child: Icon(Icons.alarm_outlined, color: _gold, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('打卡提醒',
                      style: TextStyle(
                          fontSize: 16,
                          color: _text,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(
                    '跳转手机闹钟设置',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: _textHint),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: _textHint, size: 20),
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
                  Icon(Icons.lock_reset, color: _primaryLight, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
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
            Icon(Icons.chevron_right, color: _textHint, size: 20),
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
              child: Icon(Icons.phone_iphone_outlined,
                  color: _primaryLight, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
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
            Icon(Icons.chevron_right, color: _textHint, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 导出笔记行：点击进入「导出笔记」页面，把自己发的帖子按年份导出为 PDF。
class _SettingsExportNotesTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_SettingsPageState>()!;
    return InkWell(
      onTap: () {
        if (!AuthService.instance.isLoggedIn) {
          state.requireLogin();
          return;
        }
        Navigator.push(context, slideInFromLeft(const ExportNotesPage()))
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
              child: Icon(Icons.picture_as_pdf_outlined,
                  color: _gold, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('导出笔记',
                      style: TextStyle(
                          fontSize: 16,
                          color: _text,
                          fontWeight: FontWeight.w500)),
                  SizedBox(height: 2),
                  Text('按年份把我的帖子导出为 PDF',
                      style: TextStyle(fontSize: 12, color: _textHint)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: _textHint, size: 20),
          ],
        ),
      ),
    );
  }
}
