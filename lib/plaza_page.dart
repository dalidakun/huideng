import 'package:flutter/material.dart';

import 'cloud_notes_service.dart';
import 'note_detail_page.dart';

const Color _primary = Color(0xFF5C4033);
const Color _primaryLight = Color(0xFF8B6B5A);
const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _border = Color(0xFFEBE1D6);

class PlazaPage extends StatefulWidget {
  const PlazaPage({super.key});

  @override
  State<PlazaPage> createState() => _PlazaPageState();
}

class _PlazaPageState extends State<PlazaPage> {
  final List<PlazaNote> _notes = [];
  final ScrollController _scroll = ScrollController();
  String _sort = 'latest';
  int _page = 1;
  bool _hasMore = true;
  bool _loading = false;
  bool _error = false;
  String _errorMsg = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
      _page = 1;
    });
    await CloudNotesService.instance.refreshLikedNoteIds();
    await CloudNotesService.instance.refreshFavoriteNoteIds();
    try {
      final (list, hasMore) =
          await CloudNotesService.instance.getPlazaNotes(page: 1, sort: _sort);
      if (!mounted) return;
      setState(() {
        _notes
          ..clear()
          ..addAll(list);
        _page = 2;
        _hasMore = hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
        _errorMsg = e.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final (list, hasMore) = await CloudNotesService.instance
          .getPlazaNotes(page: _page, sort: _sort);
      if (!mounted) return;
      setState(() {
        _notes.addAll(list);
        _page++;
        _hasMore = hasMore;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _onSortChanged(String sort) {
    if (sort == _sort) return;
    _sort = sort;
    _load();
  }

  void _openDetail(PlazaNote note) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)),
    ).then((_) {
      if (mounted) _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: const Text('菩提空间',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'latest', label: Text('最新')),
                ButtonSegment(value: 'hot', label: Text('最热')),
              ],
              selected: {_sort},
              onSelectionChanged: (s) => _onSortChanged(s.first),
              style: SegmentedButton.styleFrom(
                foregroundColor: _primary,
                selectedForegroundColor: Colors.white,
                selectedBackgroundColor: _gold,
                side: const BorderSide(color: _border),
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: _gold,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _notes.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (_error && _notes.isEmpty) {
      return _buildError();
    }
    if (_notes.isEmpty) {
      return _buildEmpty();
    }
    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      itemCount: _notes.length + 1,
      itemBuilder: (context, index) {
        if (index == _notes.length) return _buildFooter();
        return _buildCard(_notes[index]);
      },
    );
  }

  Widget _buildCard(PlazaNote note) {
    final preview = note.content.length > 60
        ? '${note.content.substring(0, 60)}...'
        : note.content;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2)),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openDetail(note),
          child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 15,
                    backgroundColor: _primary.withValues(alpha: 0.12),
                    child:
                        Icon(Icons.person, size: 16, color: _primaryLight),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      note.authorName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _text),
                    ),
                  ),
                  Text(_formatTime(note.createdAt),
                      style:
                          const TextStyle(fontSize: 11, color: _textHint)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _text),
                    ),
                  ),
                  if (note.repostOf.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.repeat, size: 12, color: _gold),
                        const SizedBox(width: 2),
                        Text('转发',
                            style:
                                const TextStyle(fontSize: 11, color: _gold)),
                      ],
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text(
                preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, color: _textSec, height: 1.5),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    CloudNotesService.instance.likedNoteIds.contains(note.id)
                        ? Icons.favorite
                        : Icons.favorite_border,
                    size: 13,
                    color: _primaryLight,
                  ),
                  const SizedBox(width: 3),
                  Text('${note.likeCount}',
                      style: const TextStyle(fontSize: 12, color: _textSec)),
                  const SizedBox(width: 14),
                  Icon(Icons.mode_comment_outlined,
                      size: 12, color: _textHint),
                  const SizedBox(width: 3),
                  Text('${note.commentCount}',
                      style: const TextStyle(fontSize: 12, color: _textHint)),
                  const SizedBox(width: 14),
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

  Widget _buildFooter() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
          ),
        ),
      );
    }
    if (!_hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text('— 到底了 —',
              style: const TextStyle(fontSize: 12, color: _textHint)),
        ),
      );
    }
    return const SizedBox(height: 16);
  }

  Widget _buildEmpty() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 120),
      children: [
        Column(
          children: [
            Icon(Icons.people_outline, size: 56, color: _textHint),
            const SizedBox(height: 14),
            Text('菩提空间还没有笔记',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            const SizedBox(height: 6),
            Text('分享你的修学心得，让大家一起受益',
                style: TextStyle(fontSize: 13, color: _textSec)),
          ],
        ),
      ],
    );
  }

  Widget _buildError() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 120),
      children: [
        Column(
          children: [
            Icon(Icons.wifi_off_outlined, size: 56, color: _textHint),
            const SizedBox(height: 14),
            Text('加载失败',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            if (_errorMsg.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(_errorMsg,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: _textHint)),
              ),
            ],
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试', style: TextStyle(fontSize: 14)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _formatTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (diff == 1) return '昨天';
    if (t.year == now.year) {
      return '${t.month}月${t.day}日';
    }
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}
