import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'loading_widgets.dart';
import 'login_page.dart';
import 'user_avatar.dart';
import 'user_space_page.dart';

import 'app_palette.dart';
Color get _gold => AppPalette.p.accent;
Color get _bg => AppPalette.p.bg;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _border => AppPalette.p.border;
enum UserListMode { following, followers }

/// 关注 / 粉丝 用户列表页。
class UserListPage extends StatefulWidget {
  final UserListMode mode;

  const UserListPage({super.key, required this.mode});

  @override
  State<UserListPage> createState() => _UserListPageState();
}

class _UserListPageState extends State<UserListPage> {
  List<UserProfile> _users = [];
  bool _loading = true;
  bool _error = false;

  bool get _isFollowing => widget.mode == UserListMode.following;

  String get _title => _isFollowing ? '关注' : '粉丝';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    if (!AuthService.instance.isLoggedIn) {
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }
    try {
      final service = CloudNotesService.instance;
      final ids = _isFollowing
          ? await service.getFollowingUserIds()
          : await service.getFollowerUserIds();
      final profiles = await service.getUserProfiles(ids);
      if (!mounted) return;
      setState(() {
        _users = profiles;
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

  Future<void> _toggleFollow(UserProfile user) async {
    if (!AuthService.instance.isLoggedIn) {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }
    final ok = await CloudNotesService.instance.toggleFollow(user.id);
    if (!mounted) return;
    if (_isFollowing) {
      setState(() => _users.removeWhere((u) => u.id == user.id));
    } else {
      setState(() {});
    }
    if (!mounted) return;
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.of(ctx).padding.top + kToolbarHeight + 10,
        left: 20,
        right: 20,
        child: Align(
          alignment: Alignment.topCenter,
          child: Material(
            color: _text.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Text(ok ? '已关注' : '已取消关注',
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 2), () {
      if (entry.mounted) entry.remove();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
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
              Text(_title,
                  style: TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
              const Spacer(),
              if (!_loading && _users.isNotEmpty)
                Text('${_users.length} 位',
                    style: TextStyle(fontSize: 13, color: _textSec)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const AppLoadingIndicator(
        message: '正在加载用户列表...',
      );
    }
    if (!AuthService.instance.isLoggedIn) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 48, color: _textHint),
            const SizedBox(height: 14),
            Text('登录后查看',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            const SizedBox(height: 6),
            Text('登录即可查看你的关注与粉丝',
                style: TextStyle(fontSize: 13, color: _textSec)),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LoginPage()),
              ).then((_) => _load()),
              icon: const Icon(Icons.login, size: 17),
              label: const Text('登录',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              style: FilledButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
          ],
        ),
      );
    }
    if (_error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_outlined, size: 48, color: _textHint),
            const SizedBox(height: 14),
            Text('加载失败',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试', style: TextStyle(fontSize: 14)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
          ],
        ),
      );
    }
    if (_users.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
                _isFollowing ? Icons.people_alt_outlined : Icons.person_outline,
                size: 48,
                color: _textHint),
            const SizedBox(height: 14),
            Text(_isFollowing ? '还没有关注同修' : '还没有粉丝',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            const SizedBox(height: 6),
            Text(_isFollowing ? '关注同修后，这里会显示你关注的同修' : '当同修关注你时，会出现在这里',
                style: TextStyle(fontSize: 13, color: _textSec)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: _users.length,
      itemBuilder: (context, index) => _buildUserTile(_users[index]),
    );
  }

  Widget _buildUserTile(UserProfile user) {
    final me = AuthService.instance.currentUser.value;
    final isSelf = me != null && user.id == me.id;
    final following =
        CloudNotesService.instance.followingUserIds.contains(user.id);
    // 整行点按进入对方主页；关注药丸在内层有自己的点击，优先响应。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  UserSpacePage(userId: user.id, userName: user.name))),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UserAvatar(
                  userId: user.id,
                  imageBase64: user.avatar,
                  radius: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              user.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 16,
                                  color: _text,
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                          if (user.verified) ...[
                            const SizedBox(width: 4),
                            const Icon(Icons.verified,
                                size: 15, color: Color(0xFF70867A)),
                          ],
                        ],
                      ),
                      if (user.account.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text('@${user.account}',
                              style:
                                  TextStyle(fontSize: 13, color: _textHint)),
                        ),
                    ],
                  ),
                ),
                if (!isSelf) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _toggleFollow(user),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 13, vertical: 6),
                      decoration: BoxDecoration(
                        color: following
                            ? Colors.transparent
                            : _gold.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: following
                                ? _border
                                : _gold.withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        following ? '正在关注' : '关注',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color:
                              following ? _text : AppPalette.p.accentDeep,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (user.tagline.isNotEmpty)
              Padding(
                // 与昵称列左对齐（头像 44 + 间距 12），横向不受药丸挤压。
                padding: const EdgeInsets.only(top: 6, left: 56),
                child: Text(
                  user.tagline,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 14, color: _text, height: 1.45),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
