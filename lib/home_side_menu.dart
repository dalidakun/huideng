import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'auth_service.dart';
import 'reading_badges.dart';
import 'reading_time_service.dart';
import 'user_avatar.dart';

/// 左侧滑出的个人菜单面板（约占屏宽 2/3）。
///
/// 自上而下：头像、昵称 + 认证徽章（或「获得认证」提示）与 @账户名（右侧为阅藏进度圆环），
/// 其下为累计读经时长（原样式），两者同步更新，
/// 随后是菜单项：个人资料、记录、关注、设置、登录或退出登录。
/// 点击面板外的遮罩即可关闭，面板上不放关闭按钮。
class HomeSideMenu extends StatefulWidget {
  /// 点击「个人资料」。
  final VoidCallback onOpenProfile;

  /// 点击「记录」（读经画线/感想/笔记的时间线）。
  final VoidCallback onOpenRecord;

  /// 点击「关注」（我关注的用户列表）。
  final VoidCallback onOpenFollowing;

  /// 点击「设置」。
  final VoidCallback onOpenSettings;

  /// 点击「登录」（仅未登录时显示本项，替代「退出登录」）。
  final VoidCallback onLogin;

  /// 点击「退出登录」（仅已登录时显示本项）。
  final VoidCallback onLogout;

  /// 点击「获得认证」（仅未认证时显示）。
  final VoidCallback onCertify;

  const HomeSideMenu({
    super.key,
    required this.onOpenProfile,
    required this.onOpenRecord,
    required this.onOpenFollowing,
    required this.onOpenSettings,
    required this.onLogin,
    required this.onLogout,
    required this.onCertify,
  });

  @override
  State<HomeSideMenu> createState() => _HomeSideMenuState();
}

class _HomeSideMenuState extends State<HomeSideMenu> {
  String _nickname = '同修';
  String _accountName = '';
  bool _verified = false;
  bool _loggedIn = false;

  /// 账户名是否已确定（本地读到，或补取接口已返回）。
  /// 为 false 时账户名行留占位，避免开抽屉先闪一下「完善账户名…」提示。
  bool _accountLoaded = false;

  Color get _text => AppPalette.p.text;
  Color get _textHint => AppPalette.p.textHint;
  Color get _border => AppPalette.p.border;
  Color get _green => AppPalette.p.primary;

  @override
  void initState() {
    super.initState();
    _loggedIn = AuthService.instance.isLoggedIn;
    AuthService.instance.currentUser.addListener(_onAuthChanged);
    _loadLocal();
  }

  @override
  void dispose() {
    AuthService.instance.currentUser.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    setState(() => _loggedIn = AuthService.instance.isLoggedIn);
    _loadLocal();
  }

  /// 昵称 / 账户名 / 认证标识优先读本地缓存（与个人主页同一份事实源），
  /// 账户名缺失时再向认证服务补取一次，避免抽屉头部长时间空白。
  /// 阅藏百分比同步刷新本地进度，保证与累计读经时长一起更新到最新值。
  Future<void> _loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    await LocalCanonProgress.refresh();
    if (!mounted) return;
    final user = AuthService.instance.currentUser.value;
    final account = prefs.getString('user_account_name') ?? '';
    final nickname =
        user?.displayName ?? prefs.getString('user_nickname') ?? '同修';
    final verified = prefs.getBool('user_verified') ?? false;
    setState(() {
      _accountName = account;
      _nickname = nickname.trim().isEmpty ? '同修' : nickname;
      _verified = verified && AuthService.instance.isLoggedIn;
      // 本地已有账户名即为已确定；否则等补取结果，期间不显示提示文案。
      _accountLoaded = _accountLoaded || account.isNotEmpty;
    });
    if (account.isEmpty && AuthService.instance.isLoggedIn) {
      final name = await AuthService.instance.getAccountName();
      if (!mounted) return;
      setState(() {
        _accountName = name;
        _accountLoaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.p.card,
      elevation: 16,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            Divider(height: 1, thickness: 0.5, color: _border),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  _buildItem(
                    (_) => const _ProfileMenuIcon(),
                    '个人资料',
                    onTap: widget.onOpenProfile,
                  ),
                  _buildItem(
                    (_) => const _RecordMenuIcon(),
                    '笔记',
                    onTap: widget.onOpenRecord,
                  ),
                  _buildItem(
                    (c) => Icon(Icons.favorite_outline, size: 21, color: c),
                    '关注',
                    onTap: widget.onOpenFollowing,
                  ),
                  _buildItem(
                    (c) => Icon(Icons.settings_outlined, size: 21, color: c),
                    '设置',
                    onTap: widget.onOpenSettings,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                    child: Divider(height: 1, thickness: 0.5, color: _border),
                  ),
                  if (_loggedIn)
                    _buildItem(
                      (c) => Icon(Icons.logout, size: 21, color: c),
                      '退出登录',
                      onTap: widget.onLogout,
                    )
                  else
                    _buildItem(
                      (c) => Icon(Icons.login, size: 21, color: c),
                      '登录',
                      color: _green,
                      onTap: widget.onLogin,
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Text(
                '燃一盏灯，看见自己，照亮别人。',
                style: TextStyle(fontSize: 12, color: _textHint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 头部：头像居上，其下昵称+认证徽章、@账户名，两行右侧为阅藏进度圆环；
  /// 最下方为累计读经时长（原样式），两者同步更新。
  Widget _buildHeader() {
    final user = AuthService.instance.currentUser.value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserAvatar(userId: user?.id, radius: 26),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            _loggedIn ? _nickname : '未登录',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 16.5,
                                height: 1.2,
                                fontWeight: FontWeight.w700,
                                color: _text),
                          ),
                        ),
                        if (_verified) ...[
                          const SizedBox(width: 4),
                          _buildVerifiedBadge(),
                        ] else if (_loggedIn) ...[
                          const SizedBox(width: 8),
                          _buildCertifyButton(),
                        ],
                      ],
                    ),
                    if (_accountName.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text('@$_accountName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5, height: 1.3, color: _textHint)),
                    ] else if (_loggedIn) ...[
                      const SizedBox(height: 2),
                      if (_accountLoaded)
                        Text('完善账户名后可被同修找到',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12.5, height: 1.3, color: _textHint))
                      else
                        const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),
              if (_loggedIn) ...[
                const SizedBox(width: 10),
                _buildProgressRing(),
              ],
            ],
          ),
          if (_loggedIn) ...[
            const SizedBox(height: 10),
            ValueListenableBuilder<int>(
              valueListenable: ReadingTimeService.instance.totalSeconds,
              builder: (context, sec, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.history, size: 12, color: Color(0xFF70867A)),
                  const SizedBox(width: 4),
                  Text('累计${_formatReadTime(sec)}',
                      maxLines: 1,
                      style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF70867A),
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 累计读经时长格式化：与主页顶部徽章同款「x时x分」，不足1分钟显示「0时0分」。
  String _formatReadTime(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    return '$hours时$minutes分';
  }

  /// 阅藏进度圆环（昵称/账户名右侧，高度与两行文字相当）：
  /// 边缘弧线展示进度（已完成黑色、未完成浅灰），圆心只显示百分比。
  /// 点击进入徽章详情页。
  Widget _buildProgressRing() {
    final read = LocalCanonProgress.read;
    final total = LocalCanonProgress.total;
    final progress =
        total > 0 ? (read / total).clamp(0.0, 1.0).toDouble() : 0.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => const BadgeDetailPage())),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 3,
                backgroundColor: const Color(0xFFE9E9E9),
                valueColor: const AlwaysStoppedAnimation(Colors.black),
              ),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(canonPercentOf(read, total),
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: 10.5,
                      height: 1.1,
                      fontWeight: FontWeight.w600,
                      color: _text)),
            ),
          ],
        ),
      ),
    );
  }

  /// 未认证时的提示：与个人主页同款「获得认证」灰底药丸。
  Widget _buildCertifyButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onCertify,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFEFE9E2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFBDBDBD)),
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

  /// 已认证徽章：与菩提空间帖子同款，裸一枚对勾图标，不加任何包裹。
  Widget _buildVerifiedBadge() {
    return const Icon(Icons.verified, size: 16, color: Color(0xFF70867A));
  }

  /// 菜单项：图标 + 18 号文案，右侧不挂箭头，按压有水波纹。
  ///
  /// [icon] 收到当前生效的颜色（禁用时为浅灰），据此自绘图标或图片。
  Widget _buildItem(
    Widget Function(Color color) icon,
    String label, {
    VoidCallback? onTap,
    bool enabled = true,
    Color? color,
    Widget? trailing,
  }) {
    final accent = enabled ? (color ?? _green) : _textHint;
    final fg = enabled ? (color ?? _text) : _textHint;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        splashColor: accent.withValues(alpha: 0.12),
        highlightColor: accent.withValues(alpha: 0.06),
        onTap: enabled && onTap != null ? onTap : null,
        child: Padding(
          // 上下留白加大，菜单项之间更松。
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          child: Row(
            children: [
              icon(accent),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  fontSize: 18,
                  height: 1.2,
                  color: fg,
                  fontWeight: enabled ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
              const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// 侧边菜单「个人资料」图标：沿用原底部菜单「我的」那组资源，
/// 米黄 my.png / my_selected.png，素白 my1.png / my_selected1.png；
/// 按下瞬间换成选中态，抬手还原。
class _ProfileMenuIcon extends StatefulWidget {
  const _ProfileMenuIcon();

  @override
  State<_ProfileMenuIcon> createState() => _ProfileMenuIconState();
}

class _ProfileMenuIconState extends State<_ProfileMenuIcon> {
  bool _pressed = false;

  String get _asset {
    final plain = AppPalette.instance.isPlain;
    if (_pressed) {
      return plain
          ? 'assets/images/my_selected1.png'
          : 'assets/images/my_selected.png';
    }
    return plain ? 'assets/images/my1.png' : 'assets/images/my.png';
  }

  void _set(bool v) {
    if (_pressed == v || !mounted) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: Image.asset(
        _asset,
        // 与同排 21 号矢量图标视觉重量一致。
        width: 21,
        height: 21,
        fit: BoxFit.contain,
      ),
    );
  }
}

/// 侧边菜单「记录」图标：沿用原底部菜单那组资源
/// （米黄 ycode1、素白 bcode1），尺寸与同排矢量图标一致。
class _RecordMenuIcon extends StatelessWidget {
  const _RecordMenuIcon();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      AppPalette.instance.isPlain
          ? 'assets/images/bcode1.png'
          : 'assets/images/ycode1.png',
      width: 21,
      height: 21,
      fit: BoxFit.contain,
    );
  }
}
