import 'package:flutter/material.dart';

import 'cloud_notes_service.dart';
import 'note_detail_page.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);

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
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _hasMore = true;
      _page = 0;
    });
    try {
      final (list, hasMore) =
          await CloudNotesService.instance.getUserNotes(widget.userId, page: 1);
      if (!mounted) return;
      setState(() {
        _notes
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
              Expanded(
                child: Text(
                  '${widget.userName} 的菩提空间',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                      color: _text),
                ),
              ),
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
    return RefreshIndicator(
      color: _gold,
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
        itemCount: _notes.length + 1,
        itemBuilder: (context, index) {
          if (index == _notes.length) {
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
          return _buildNoteTile(_notes[index]);
        },
      ),
    );
  }

  Widget _buildNoteTile(PlazaNote note) {
    final preview = note.quoteContent.isNotEmpty
        ? (note.quoteOfTitle.isNotEmpty
            ? '${note.content}\n转发自《${note.quoteOfTitle}》'
            : note.content)
        : note.content;
    final text = preview.length > 60 ? '${preview.substring(0, 60)}...' : preview;
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
        onTap: () => _openNote(note),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15,
                          color: _text,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (note.repostOf.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.repeat, size: 12, color: _gold),
                        const SizedBox(width: 2),
                        Text(note.quoteContent.isNotEmpty ? '引用' : '转发',
                            style: const TextStyle(
                                fontSize: 11, color: _gold)),
                      ],
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, color: _textSec, height: 1.5),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.schedule, size: 12, color: _textHint),
                  const SizedBox(width: 4),
                  Text(_formatTime(note.createdAt),
                      style: const TextStyle(fontSize: 12, color: _textHint)),
                  const Spacer(),
                  Icon(Icons.mode_comment_outlined,
                      size: 12, color: _textHint),
                  const SizedBox(width: 3),
                  Text('${note.commentCount}',
                      style: const TextStyle(fontSize: 12, color: _textHint)),
                  const SizedBox(width: 10),
                  Icon(Icons.favorite_border, size: 12, color: _textHint),
                  const SizedBox(width: 3),
                  Text('${note.likeCount}',
                      style: const TextStyle(fontSize: 12, color: _textHint)),
                  const SizedBox(width: 10),
                  Icon(Icons.visibility_outlined,
                      size: 12, color: _textHint),
                  const SizedBox(width: 3),
                  Text('${note.viewCount}',
                      style: const TextStyle(fontSize: 12, color: _textHint)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openNote(PlazaNote note) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)),
    ).then((_) {
      if (mounted) _load();
    });
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
