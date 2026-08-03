import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';
import 'note_sutra_links.dart';
import 'quote_box.dart';
import 'reading_page.dart';
import 'text_input_sheet.dart';

const Color _primary = Color(0xFF5C4033);
const Color _primaryLight = Color(0xFF8B6B5A);
const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _border = Color(0xFFEBE1D6);

class NoteDetailPage extends StatefulWidget {
  final String noteId;
  const NoteDetailPage({super.key, required this.noteId});

  @override
  State<NoteDetailPage> createState() => _NoteDetailPageState();
}

class _NoteDetailPageState extends State<NoteDetailPage> {
  PlazaNote? _note;
  List<PlazaComment> _comments = [];
  Map<String, NoteSutraLink> _sutraLib = const {};
  bool _loading = true;
  bool _error = false;
  bool _liking = false;
  bool _favoriting = false;
  bool _reposting = false;
  final TextEditingController _commentController = TextEditingController();
  bool _sendingComment = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      await CloudNotesService.instance.refreshFavoriteNoteIds();
      await CloudNotesService.instance.refreshFollowStates();
      final note = await CloudNotesService.instance.getNoteById(widget.noteId);
      final comments =
          await CloudNotesService.instance.getComments(widget.noteId);
      int viewCount = note.viewCount;
      // 阅读量 +1 尽力而为，失败不影响阅读，也不提示用户。
      try {
        viewCount = await CloudNotesService.instance.incView(widget.noteId);
      } catch (_) {}
      Map<String, NoteSutraLink> lib = const {};
      try {
        lib = await NoteSutraCatalog.titleMap();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _sutraLib = lib;
        _note = PlazaNote(
          id: note.id,
          ownerUserId: note.ownerUserId,
          title: note.title,
          content: note.content,
          authorName: note.authorName,
          visibility: note.visibility,
          status: note.status,
          likeCount: note.likeCount,
          commentCount: note.commentCount,
          viewCount: viewCount,
          repostCount: note.repostCount,
          repostOf: note.repostOf,
          repostSourceAuthor: note.repostSourceAuthor,
          quoteContent: note.quoteContent,
          quoteOfTitle: note.quoteOfTitle,
          quoteOfContent: note.quoteOfContent,
          createdAt: note.createdAt,
          updatedAt: note.updatedAt,
        );
        _comments = comments;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  Future<void> _toggleLike() async {
    final note = _note;
    if (note == null) return;
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    if (_liking) return;
    setState(() => _liking = true);
    try {
      final (liked, count) =
          await CloudNotesService.instance.toggleLike(note.id);
      if (!mounted) return;
      setState(() {
        _note = PlazaNote(
          id: note.id,
          ownerUserId: note.ownerUserId,
          title: note.title,
          content: note.content,
          authorName: note.authorName,
          visibility: note.visibility,
          status: note.status,
          likeCount: count,
          commentCount: note.commentCount,
          viewCount: note.viewCount,
          repostCount: note.repostCount,
          repostOf: note.repostOf,
          repostSourceAuthor: note.repostSourceAuthor,
          quoteContent: note.quoteContent,
          quoteOfTitle: note.quoteOfTitle,
          quoteOfContent: note.quoteOfContent,
          createdAt: note.createdAt,
          updatedAt: note.updatedAt,
        );
        _liking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _liking = false);
      _showToast(e.toString());
    }
  }

  void _openCommentSheet() {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    _commentController.clear();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: _border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 44,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: _bg,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: TextField(
                          controller: _commentController,
                          autofocus: true,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _submitComment(sheetCtx),
                          style: const TextStyle(fontSize: 14, color: _text),
                          decoration: const InputDecoration(
                            hintText: '说点什么…',
                            hintStyle: TextStyle(color: _textHint),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      onPressed: _sendingComment
                          ? null
                          : () => _submitComment(sheetCtx),
                      icon: _sendingComment
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: _gold))
                          : const Icon(Icons.send_rounded,
                              color: _primary, size: 22),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submitComment(BuildContext sheetContext) async {
    final content = _commentController.text.trim();
    if (content.isEmpty || _sendingComment) return;
    setState(() => _sendingComment = true);
    try {
      final comment =
          await CloudNotesService.instance.createComment(widget.noteId, content);
      if (!mounted) return;
      setState(() {
        _comments.add(comment);
        _commentController.clear();
        _sendingComment = false;
        _note = _note == null
            ? null
            : PlazaNote(
                id: _note!.id,
                ownerUserId: _note!.ownerUserId,
                title: _note!.title,
                content: _note!.content,
                authorName: _note!.authorName,
                visibility: _note!.visibility,
                status: _note!.status,
                likeCount: _note!.likeCount,
                commentCount: _note!.commentCount + 1,
                viewCount: _note!.viewCount,
                repostCount: _note!.repostCount,
                repostOf: _note!.repostOf,
                repostSourceAuthor: _note!.repostSourceAuthor,
                quoteContent: _note!.quoteContent,
                quoteOfTitle: _note!.quoteOfTitle,
                quoteOfContent: _note!.quoteOfContent,
                createdAt: _note!.createdAt,
                updatedAt: _note!.updatedAt,
              );
      });
      if (mounted && sheetContext.mounted) {
        Navigator.of(sheetContext).pop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendingComment = false);
      _showToast(e.toString());
    }
  }

  Future<void> _deleteComment(PlazaComment comment) async {
    final note = _note;
    final me = AuthService.instance.currentUser.value;
    if (me == null) return;
    if (comment.authorId != me.id && note?.ownerUserId != me.id) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除评论',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: const Text('确定删除这条评论吗？',
            style: TextStyle(color: _textSec)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: _textSec))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除',
                  style: TextStyle(
                      color: Colors.red, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await CloudNotesService.instance.deleteComment(comment.id);
      if (!mounted) return;
      setState(() => _comments.removeWhere((c) => c.id == comment.id));
    } catch (e) {
      if (!mounted) return;
      _showToast(e.toString());
    }
  }

  void _promptLogin() {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  Future<void> _toggleFavorite() async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    if (_favoriting) return;
    setState(() => _favoriting = true);
    try {
      final favorited =
          await CloudNotesService.instance.toggleNoteFavorite(widget.noteId);
      if (!mounted) return;
      setState(() => _favoriting = false);
      _showToast(favorited ? '已收藏' : '已取消收藏');
    } catch (e) {
      if (!mounted) return;
      setState(() => _favoriting = false);
      _showToast(e.toString());
    }
  }

  Future<void> _repost() async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    if (_reposting) return;
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
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: _text)),
            ),
            const Divider(height: 1, color: _border),
            _repostItem(ctx, 'direct', Icons.repeat_rounded, '直接转发',
                '原样分享这条笔记'),
            _repostItem(ctx, 'quote', Icons.format_quote_rounded, '引用转发',
                '写下你的感想，并带上原笔记'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'quote') {
      await _quoteRepost();
    } else {
      await _doRepost('');
    }
  }

  Widget _repostItem(BuildContext ctx, String value, IconData icon,
      String title, String subtitle) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: _primaryLight),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 15, color: _text)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(fontSize: 12, color: _textHint)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _quoteRepost() async {
    final quote = await showModalBottomSheet<String>(
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
    );
    if (quote == null || !mounted) return;
    await _doRepost(quote);
  }

  Future<void> _doRepost(String quote) async {
    if (_reposting) return;
    setState(() => _reposting = true);
    try {
      await CloudNotesService.instance.repostNote(widget.noteId,
          quote: quote, kind: quote.isEmpty ? 'forward' : 'quote');
      if (!mounted) return;
      setState(() => _reposting = false);
      // 转发后停留在当前笔记详情页，不跳转到转发后的新笔记。
      _showToast(quote.isEmpty ? '已转发到菩提空间' : '已引用转发到菩提空间');
    } catch (e) {
      if (!mounted) return;
      setState(() => _reposting = false);
      _showToast(e.toString());
    }
  }

  void _openSutra(String title, String filePath) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingPage(title: title, filePath: filePath),
      ),
    );
  }

  Future<void> _share() async {
    final note = _note;
    if (note == null) return;
    final plain = NoteSutraLinks.plainText(note.content);
    final text = '${plain.length > 120 ? '${plain.substring(0, 120)}…' : plain}\n'
        '—— 来自「慧灯」App · ${note.authorName} 的修学分享';
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (e) {
      if (!mounted) return;
      _showToast('分享失败：$e');
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: const Text('笔记详情',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (_error || _note == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: _textHint),
            const SizedBox(height: 12),
            Text('加载失败', style: TextStyle(fontSize: 15, color: _textSec)),
            const SizedBox(height: 12),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final note = _note!;
    final liked =
        CloudNotesService.instance.likedNoteIds.contains(note.id);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            children: [
              _buildUserHeader(note),
              if (note.repostOf.isNotEmpty && note.repostKind != 'reply') ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.repeat, size: 13, color: _gold),
                    const SizedBox(width: 4),
                    Text(note.quoteContent.isNotEmpty ? '引用' : '转发',
                        style: const TextStyle(fontSize: 12, color: _gold)),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              if (note.content.isNotEmpty)
                NoteSutraLinks.buildRichText(
                  note.content,
                  style:
                      const TextStyle(fontSize: 16, color: _text, height: 1.75),
                  library: _sutraLib,
                  onTap: (title, filePath) => _openSutra(title, filePath),
                ),
              if (note.repostOf.isNotEmpty) ...[
                const SizedBox(height: 12),
                QuoteBox(note: note),
              ],
              const SizedBox(height: 8),
              const Divider(height: 1, color: _border),
              const SizedBox(height: 6),
              _buildActionsRow(note, liked),
              const SizedBox(height: 20),
              Row(
                children: [
                  Text('评论 ${_comments.length}',
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _text)),
                ],
              ),
              const SizedBox(height: 10),
              if (_comments.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Text('还没有评论，来说两句吧',
                        style:
                            TextStyle(fontSize: 13, color: _textHint)),
                  ),
                )
              else
                for (final c in _comments) _buildCommentRow(c),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCommentRow(PlazaComment c) {
    final me = AuthService.instance.currentUser.value;
    final canDelete = me != null &&
        (c.authorId == me.id || _note?.ownerUserId == me.id);
    return InkWell(
      onLongPress: canDelete ? () => _deleteComment(c) : null,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: _primary.withValues(alpha: 0.10),
              child: Icon(Icons.person, size: 15, color: _primaryLight),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(c.authorName,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _primaryLight)),
                      const SizedBox(width: 8),
                      Text(_formatTime(c.createdAt),
                          style: const TextStyle(
                              fontSize: 11, color: _textHint)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(c.content,
                      style: const TextStyle(
                          fontSize: 14, color: _text, height: 1.5)),
                ],
              ),
            ),
            if (canDelete)
              GestureDetector(
                onTap: () => _deleteComment(c),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline,
                      size: 15, color: _textHint),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserHeader(PlazaNote note) {
    final me = AuthService.instance.currentUser.value;
    final isSelf = me != null && note.ownerUserId == me.id;
    return Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: _primary.withValues(alpha: 0.12),
          child: Icon(Icons.person, size: 20, color: _primaryLight),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(note.authorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _text)),
              ),
              if (note.authorVerified) ...[
                const SizedBox(width: 3),
                const Icon(Icons.verified, size: 14, color: Color(0xFFB8860B)),
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
                const SizedBox(width: 3),
                Text('·',
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF8C8C8C))),
                const SizedBox(width: 2),
              ],
              const SizedBox(width: 2),
              Text(_formatTime(note.createdAt),
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF8C8C8C))),
            ],
          ),
        ),
        if (!isSelf)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _showUserMenu(note),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.more_horiz, size: 22, color: _textSec),
            ),
          ),
      ],
    );
  }

  Future<void> _showUserMenu(PlazaNote note) async {
    final me = AuthService.instance.currentUser.value;
    if (me == null) {
      _promptLogin();
      return;
    }
    if (me.id == note.ownerUserId) return;
    final following =
        CloudNotesService.instance.followingUserIds.contains(note.ownerUserId);
    final blocked =
        CloudNotesService.instance.blockedUserIds.contains(note.ownerUserId);
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(note.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _text)),
                  ),
                  if (note.authorVerified) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.verified,
                        size: 15, color: Color(0xFFB8860B)),
                  ],
                ],
              ),
            ),
            const Divider(height: 1, color: _border),
            _menuItem(
              ctx,
              following ? 'unfollow' : 'follow',
              Icons.person_add_alt,
              following ? '取消关注' : '关注该用户',
            ),
            _menuItem(
              ctx,
              blocked ? 'unblock' : 'block',
              Icons.block_outlined,
              blocked ? '取消屏蔽' : '屏蔽该用户',
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      if (choice == 'follow' || choice == 'unfollow') {
        final ok =
            await CloudNotesService.instance.toggleFollow(note.ownerUserId);
        if (!mounted) return;
        setState(() {});
        _showToast(ok ? '已关注' : '已取消关注');
      } else if (choice == 'block') {
        final ok =
            await CloudNotesService.instance.toggleBlockUser(note.ownerUserId);
        if (!mounted) return;
        _showToast(ok ? '已屏蔽，该用户笔记不再展示' : '已取消屏蔽');
        if (ok) Navigator.pop(context);
      } else if (choice == 'unblock') {
        final ok =
            await CloudNotesService.instance.toggleBlockUser(note.ownerUserId);
        if (!mounted) return;
        setState(() {});
        _showToast(ok ? '已屏蔽' : '已取消屏蔽');
      }
    } catch (e) {
      if (!mounted) return;
      _showToast(e.toString());
    }
  }

  Widget _menuItem(
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

  Widget _buildActionsRow(PlazaNote note, bool liked) {
    final favorited =
        CloudNotesService.instance.favoriteNoteIds.contains(note.id);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildActionCell(
                    Image.asset('assets/images/ic_comment.png',
                        width: 18, height: 18),
                    _textSec,
                    '${_comments.length}',
                    _openCommentSheet),
                _buildActionCell(
                    Icon(Icons.repeat_rounded, size: 18, color: _textSec),
                    _textSec,
                    '${note.repostCount}',
                    _reposting ? null : _repost),
                _buildActionCell(
                    Icon(
                        liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 18,
                        color: liked ? _gold : _textSec),
                    liked ? _gold : _textSec,
                    '${note.likeCount}',
                    _liking ? null : _toggleLike),
                _buildActionCell(
                    Image.asset('assets/images/ic_view.png',
                        width: 18, height: 18),
                    _textSec,
                    '${note.viewCount}',
                    null),
              ],
            ),
          ),
          const SizedBox(width: 36),
          _buildActionCell(
              Icon(
                  favorited
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  size: 18,
                  color: favorited ? _gold : _textSec),
              favorited ? _gold : _textSec,
              '',
              _favoriting ? null : _toggleFavorite),
          const SizedBox(width: 6),
          _buildActionCell(
              Icon(Icons.share_rounded, size: 18, color: _textSec),
              _textSec,
              '',
              _share),
        ],
      ),
    );
  }

  Widget _buildActionCell(Widget icon, Color color, String text,
      VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 18, height: 18, child: icon),
            if (text.isNotEmpty) ...[
              const SizedBox(width: 3),
              Text(text,
                  style: TextStyle(
                      fontSize: 15,
                      height: 1,
                      color: color)),
            ],
          ],
        ),
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
