import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';

const Color _primary = Color(0xFF5C4033);
const Color _primaryLight = Color(0xFF8B6B5A);
const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _border = Color(0xFFEBE1D6);

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
              Text(_title,
                  style: const TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
              const Spacer(),
              if (!_loading && _users.isNotEmpty)
                Text('${_users.length} 位',
                    style: const TextStyle(fontSize: 13, color: _textSec)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (!AuthService.instance.isLoggedIn) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 48, color: _textHint),
            const SizedBox(height: 14),
            const Text('登录后查看',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            const SizedBox(height: 6),
            const Text('登录即可查看你的关注与粉丝',
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
            const Text('加载失败',
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
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            const SizedBox(height: 6),
            Text(_isFollowing ? '关注同修后，这里会显示你关注的同修' : '当同修关注你时，会出现在这里',
                style: const TextStyle(fontSize: 13, color: _textSec)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
      itemCount: _users.length,
      itemBuilder: (context, index) => _buildUserTile(_users[index]),
    );
  }

  Widget _buildUserTile(UserProfile user) {
    final me = AuthService.instance.currentUser.value;
    final isSelf = me != null && user.id == me.id;
    final following =
        CloudNotesService.instance.followingUserIds.contains(user.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: _primary.withValues(alpha: 0.12),
              child: Icon(Icons.person, size: 22, color: _primaryLight),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      user.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15,
                          color: _text,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                  if (user.verified) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.verified,
                        size: 14, color: Color(0xFF70867A)),
                  ],
                ],
              ),
            ),
            if (!isSelf)
              GestureDetector(
                onTap: () => _toggleFollow(user),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: following
                        ? Colors.transparent
                        : _gold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color:
                            following ? _border : _gold.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    following ? '已关注' : '关注',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: following ? _textHint : const Color(0xFF9A6B3F),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
