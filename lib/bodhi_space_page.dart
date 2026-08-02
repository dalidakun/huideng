import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';
import 'note_detail_page.dart';
import 'note_sutra_links.dart';
import 'user_space_page.dart';

const Color _primary = Color(0xFF5C4033);
const Color _primaryLight = Color(0xFF8B6B5A);
const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);

/// 菩提空间：记录我自己的互动动态（转发、我发表的评论、别人对我的回复）。
class BodhiSpacePage extends StatefulWidget {
  const BodhiSpacePage({super.key});

  @override
  State<BodhiSpacePage> createState() => _BodhiSpacePageState();
}

class _BodhiSpacePageState extends State<BodhiSpacePage> {
  final List<PlazaActivity> _activities = [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;

  int _tab = 0;

  static const _mineTypes = {'share', 'repost', 'comment'};
  static const _receivedTypes = {'reply', 'repost_me', 'like_me'};

  List<PlazaActivity> get _visible {
    if (_tab == 0) {
      return _activities.where((a) => _mineTypes.contains(a.type)).toList();
    }
    return _activities.where((a) => _receivedTypes.contains(a.type)).toList();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!AuthService.instance.isLoggedIn) {
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _hasMore = true;
      _page = 0;
    });
    try {
      final (list, hasMore) =
          await CloudNotesService.instance.getMyActivities(page: 1);
      if (!mounted) return;
      setState(() {
        _activities
          ..clear()
          ..addAll(list);
        _page = 1;
        _hasMore = hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final (list, hasMore) =
          await CloudNotesService.instance.getMyActivities(page: _page + 1);
      if (!mounted) return;
      setState(() {
        _activities.addAll(list);
        _page += 1;
        _hasMore = hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  void _promptLogin() {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          _buildHeader(),
          _buildTabBar(),
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
              const Text('互动',
                  style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                      color: _text)),
              const Spacer(),
              Text('${_activities.length} 条动态',
                  style: const TextStyle(fontSize: 13, color: _textSec)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      width: double.infinity,
      color: _bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: Row(
          children: [
            Expanded(child: _buildTab(0, '我的动态')),
            Expanded(child: _buildTab(1, '收到的互动')),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(int index, String label) {
    final selected = _tab == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _tab = index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? _text : _textSec,
            ),
          ),
          const SizedBox(height: 3),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 64,
            height: 3,
            decoration: BoxDecoration(
              color: selected ? _gold : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (!AuthService.instance.isLoggedIn) {
      return _buildEmpty(
        icon: Icons.lock_outline,
        title: '登录后查看你的菩提空间',
        subtitle: '记录你转发、评论与他人的回复',
        buttonText: '去登录',
        onButton: _promptLogin,
      );
    }
    if (_activities.isEmpty) {
      return RefreshIndicator(
        color: _gold,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            _buildEmpty(
              icon: Icons.spa_outlined,
              title: '还没有动态',
              subtitle: '分享笔记、转发帖子、发表评论，都会记录在这里',
            ),
          ],
        ),
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return RefreshIndicator(
        color: _gold,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            _buildEmpty(
              icon: _tab == 1 ? Icons.favorite_border : Icons.spa_outlined,
              title: _tab == 1 ? '还没有收到互动' : '还没有相关动态',
              subtitle: _tab == 1 ? '有人回复、点赞或转发你的笔记后会显示在这里' : '',
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: _gold,
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
        itemCount: visible.length + 1,
        itemBuilder: (context, index) {
          if (index == visible.length) {
            if (!_hasMore) return const SizedBox(height: 16);
            WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
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
          return _buildActivityTile(visible[index]);
        },
      ),
    );
  }

  Widget _buildEmpty({
    required IconData icon,
    required String title,
    String subtitle = '',
    String? buttonText,
    VoidCallback? onButton,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 32),
      child: Column(
        children: [
          Icon(icon, size: 48, color: _textHint.withValues(alpha: 0.6)),
          const SizedBox(height: 14),
          Text(title,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _text)),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: _textSec)),
          ],
          if (buttonText != null && onButton != null) ...[
            const SizedBox(height: 18),
            FilledButton(
              onPressed: onButton,
              style: FilledButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
              child: Text(buttonText,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActivityTile(PlazaActivity a) {
    final (icon, iconColor) = _typeStyle(a.type);
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
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openNote(a.noteId),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 19),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _buildTitle(a),
                        ),
                        const SizedBox(width: 8),
                        Text(_formatTime(a.createdAt),
                            style: const TextStyle(
                                fontSize: 11, color: _textHint)),
                      ],
                    ),
                    if (a.content.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        NoteSutraLinks.plainText(a.content),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, color: _textSec, height: 1.5),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 动态标题，@用户 与 《笔记》 分别可点击。
  Widget _buildTitle(PlazaActivity a) {
    final baseStyle = const TextStyle(
        fontSize: 14, fontWeight: FontWeight.w600, color: _text);
    final linkStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: _primaryLight,
      decoration: TextDecoration.underline,
      decorationColor: _primaryLight.withValues(alpha: 0.35),
    );
    final actor = a.actorName.isEmpty ? '同修' : a.actorName;
    final noteLabel = a.noteTitle.isEmpty ? '这篇笔记' : '《${a.noteTitle}》';
    TextSpan plain(String t) => TextSpan(text: t, style: baseStyle);
    TextSpan noteLink() => TextSpan(
          text: noteLabel,
          style: linkStyle,
          recognizer: a.noteId.isEmpty
              ? null
              : (TapGestureRecognizer()
                ..onTap = () => _openNote(a.noteId)),
        );
    TextSpan actorLink() => TextSpan(
          text: '@$actor',
          style: linkStyle,
          recognizer: a.actorId.isEmpty
              ? null
              : (TapGestureRecognizer()
                ..onTap = () => _openUser(a.actorId, actor)),
        );
    final spans = <TextSpan>[];
    switch (a.type) {
      case 'share':
        spans
          ..add(plain('你分享了 '))
          ..add(noteLink());
      case 'repost':
        spans
          ..add(plain('你转发了 '))
          ..add(noteLink());
      case 'comment':
        spans
          ..add(plain('你评论了 '))
          ..add(noteLink());
      case 'repost_me':
        spans
          ..add(actorLink())
          ..add(plain(' 转发了你的 '))
          ..add(noteLink());
      case 'like_me':
        spans
          ..add(actorLink())
          ..add(plain(' 赞了你的 '))
          ..add(noteLink());
      case 'reply':
        spans
          ..add(actorLink())
          ..add(plain(' 回复了你的 '))
          ..add(noteLink());
      default:
        spans.add(noteLink());
    }
    return Text.rich(TextSpan(children: spans, style: baseStyle),
        maxLines: 2, overflow: TextOverflow.ellipsis);
  }

  (IconData, Color) _typeStyle(String type) {
    switch (type) {
      case 'repost':
        return (Icons.repeat_rounded, _gold);
      case 'repost_me':
        return (Icons.repeat_on_rounded, _gold);
      case 'like_me':
        return (Icons.favorite_rounded, Color(0xFFE08A8A));
      case 'reply':
        return (Icons.reply_rounded, _primaryLight);
      case 'share':
        return (Icons.add_circle_outline, _primary);
      case 'comment':
      default:
        return (Icons.mode_comment_outlined, _primary);
    }
  }

  void _openNote(String noteId) {
    if (noteId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: noteId)),
    ).then((_) {
      if (mounted) _load();
    });
  }

  void _openUser(String userId, String userName) {
    if (userId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UserSpacePage(userId: userId, userName: userName),
      ),
    );
  }

  String _formatTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) {
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    if (diff == 1) return '昨天';
    if (t.year == now.year) return '${t.month}月${t.day}日';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}
