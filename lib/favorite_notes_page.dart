import 'package:flutter/material.dart';

import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'note_sutra_links.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);

class FavoriteNotesPage extends StatefulWidget {
  /// [embedded] 为 true 时不显示自己的 Scaffold/头部，用于嵌入标签页。
  const FavoriteNotesPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<FavoriteNotesPage> createState() => _FavoriteNotesPageState();
}

class _FavoriteNotesPageState extends State<FavoriteNotesPage>
    with AutomaticKeepAliveClientMixin {
  List<PlazaNote> _notes = [];
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await CloudNotesService.instance.refreshFavoriteNoteIds();
      final list = await CloudNotesService.instance.getFavoriteNotes();
      if (!mounted) return;
      setState(() {
        _notes = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.embedded) {
      return _buildBody();
    }
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

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (_notes.isEmpty) {
      return _buildEmpty();
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: _gold,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
        itemCount: _notes.length,
        itemBuilder: (context, index) => _buildNoteTile(_notes[index]),
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
                icon: const Icon(Icons.arrow_back_ios_new, color: _text, size: 20),
              ),
              const SizedBox(width: 4),
              const Text('书签', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
              const Spacer(),
              Text('${_notes.length} 篇', style: const TextStyle(fontSize: 13, color: _textSec)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(Icons.bookmark_border_rounded, size: 48, color: _textHint.withValues(alpha: 0.6)),
          const SizedBox(height: 14),
          const Text('暂无书签笔记', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
          const SizedBox(height: 6),
          const Text('在笔记详情中点击收藏，即可在这里查看', style: TextStyle(fontSize: 13, color: _textSec)),
        ],
      ),
    );
  }

  Widget _buildNoteTile(PlazaNote note) {
    final content = NoteSutraLinks.plainText(note.content);
    final preview = content.length > 60
        ? '${content.substring(0, 60)}...'
        : content;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
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
              Text(
                preview,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: _textSec, height: 1.5),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.person_outline, size: 12, color: _textHint),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(note.authorName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: _textSec)),
                        ),
                        if (note.authorVerified) ...[
                          const SizedBox(width: 3),
                          const Icon(Icons.verified,
                              size: 12, color: Color(0xFFB8860B)),
                        ],
                        if (note.authorAccount.isNotEmpty) ...[
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text('@${note.authorAccount}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFF8C8C8C))),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.visibility_outlined, size: 12, color: _textHint),
                  const SizedBox(width: 3),
                  Text('${note.viewCount}', style: const TextStyle(fontSize: 12, color: _textHint)),
                  const SizedBox(width: 10),
                  Icon(Icons.favorite_border, size: 12, color: _textHint),
                  const SizedBox(width: 3),
                  Text('${note.likeCount}', style: const TextStyle(fontSize: 12, color: _textHint)),
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
}
