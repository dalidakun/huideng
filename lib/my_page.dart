import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'bodhi_space_page.dart';
import 'cloud_notes_service.dart';
import 'favorites_page.dart';
import 'favorite_notes_page.dart';
import 'login_page.dart';
import 'notes_page.dart';
import 'reader_settings_page.dart';
import 'checkin_reminder_page.dart';
import 'account_info_page.dart';
import 'change_phone_page.dart';
import 'about_page.dart';
import 'notification_service.dart';
import 'settings_widgets.dart';
import 'user_list_page.dart';

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

class MyPageState extends State<MyPage> {
  String? _avatarPath;
  String _nickname = '同修';
  String _tagline = '与经为伴，与法同行';

  MyCounts _counts = const MyCounts();

  void reload() => _loadData();

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadCounts();
    AuthService.instance.currentUser.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    AuthService.instance.currentUser.removeListener(_onAuthChanged);
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
    setState(() {
      _avatarPath = prefs.getString('user_avatar_path');
      if (_isLoggedIn) {
        _nickname = _authUser?.displayName ?? '同修';
        _tagline = (_authUser?.tagline?.isNotEmpty ?? false)
            ? _authUser!.tagline!
            : '与经为伴，与法同行';
      } else {
        _nickname = prefs.getString('user_nickname') ?? '同修';
        _tagline = prefs.getString('user_tagline') ?? '与经为伴，与法同行';
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

  void _openFavorites() {
    Navigator.push(context, slideInFromLeft(const FavoritesPage()));
  }

  void _openFavoriteNotes() {
    Navigator.push(context, slideInFromLeft(const FavoriteNotesPage()))
        .then((_) => reload());
  }

  void _openBodhiSpace() {
    Navigator.push(context, slideInFromLeft(const BodhiSpacePage()))
        .then((_) => _loadCounts());
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

  void _openNotes() {
    Navigator.push(context, slideInFromLeft(const NotesPage())).then((_) => reload());
  }

  void _openSettings() {
    Navigator.push(context, slideInFromLeft(const _SettingsPage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(0, 18, 0, 32),
              children: [
                _buildMenuList(),
              ],
            ),
          ),
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

  Widget _buildHeader() {
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
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
          child: Column(
            children: [
              Row(
                children: _isLoggedIn
                    ? [
                        GestureDetector(
                          onTap: _viewAvatar,
                          child: Container(
                            width: 62, height: 62,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _card,
                              boxShadow: [
                                BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10, offset: const Offset(0, 2)),
                              ],
                              image: _avatarPath != null
                                  ? DecorationImage(image: FileImage(File(_avatarPath!)), fit: BoxFit.cover)
                                  : null,
                            ),
                            child: _avatarPath == null
                                ? const Icon(Icons.person, size: 32, color: _primaryLight)
                                : null,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_nickname, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
                              const SizedBox(height: 5),
                              Text(
                                _tagline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, color: _textSec),
                              ),
                            ],
                          ),
                        ),
                      ]
                    : [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('未登录',
                                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
                              SizedBox(height: 5),
                              Text('登录即可体验完整功能',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13, color: _textSec)),
                            ],
                          ),
                        ),
                        _buildLoginButton(),
                      ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  _buildHeaderEntry(
                    value: _counts.unread,
                    label: '互动',
                    emphasize: _counts.unread > 0,
                    onTap: _openBodhiSpace,
                  ),
                  _buildHeaderEntry(
                    value: _counts.following,
                    label: '关注',
                    onTap: _openFollowing,
                  ),
                  _buildHeaderEntry(
                    value: _counts.followers,
                    label: '粉丝',
                    onTap: _openFollowers,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderEntry({
    required int value,
    required String label,
    required VoidCallback onTap,
    bool emphasize = false,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$value',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: emphasize ? _gold : _text,
              ),
            ),
            const SizedBox(height: 5),
            Text(label,
                style: const TextStyle(
                    fontSize: 12.5,
                    color: _textSec,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuList() {
    return Container(
      color: _bg,
      child: Column(
        children: [
          _buildMenuItem(
            icon: Icons.bookmark_rounded,
            iconColor: _gold,
            title: '书签',
            onTap: _openFavoriteNotes,
          ),
          _buildMenuDivider(),
          _buildMenuItem(
            icon: Icons.star_rounded,
            iconColor: _gold,
            title: '收藏',
            onTap: _openFavorites,
          ),
          _buildMenuDivider(),
          _buildMenuItem(
            icon: Icons.edit_note_rounded,
            iconColor: _primary,
            title: '笔记',
            onTap: _openNotes,
          ),
          _buildMenuDivider(),
          _buildMenuItem(
            icon: Icons.settings_outlined,
            iconColor: _primaryLight,
            title: '设置',
            onTap: _openSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 16, color: _text, fontWeight: FontWeight.w500),
              ),
            ),
            const Icon(Icons.chevron_right, color: _textHint, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuDivider() {
    return const Divider(
      height: 1,
      thickness: 0.5,
      color: Color(0xFFEFE6DB),
      indent: 58,
      endIndent: 0,
    );
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

  AuthUser? get _authUser => AuthService.instance.currentUser.value;

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
                          _SettingsLinkTile(
                            icon: Icons.person_outline,
                            iconColor: _primary,
                            title: '账号信息',
                            subtitle: _isLoggedIn
                                ? (_authUser?.displayName ?? '同修')
                                : '未登录',
                            page: const AccountInfoPage(),
                          ),
                          const SettingsDivider(),
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
