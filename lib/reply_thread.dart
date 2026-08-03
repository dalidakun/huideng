import 'package:flutter/material.dart';

import 'cloud_notes_service.dart';
import 'note_sutra_links.dart';
import 'user_avatar.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _border = Color(0xFFEBE1D6);
const Color _primaryLight = Color(0xFF8B6B5A);

/// 回复连贴：原帖在上、回复在下，两侧头像用竖线连接。
/// 原帖与回复均为完整帖子样式：头像、昵称、@账号、时间戳、内容、四个指标。
class ReplyThread extends StatefulWidget {
  final PlazaNote replyNote;
  const ReplyThread({super.key, required this.replyNote});

  @override
  State<ReplyThread> createState() => _ReplyThreadState();
}

class _ReplyThreadState extends State<ReplyThread> {
  PlazaNote? _original;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final n = await CloudNotesService.instance
          .getNoteById(widget.replyNote.repostOf);
      if (!mounted) return;
      setState(() => _original = n);
    } catch (_) {
      // 原帖已删除/隐藏：仅显示回复本身。
    }
  }

  String _time(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (t.year == now.year) return '${t.month}月${t.day}日';
    return '${t.year}年${t.month}月${t.day}日';
  }

  Widget _avatar(String? userId) {
    return UserAvatar(userId: userId, radius: 22);
  }

  Widget _header(PlazaNote note) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
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
          const Icon(Icons.verified, size: 15, color: Color(0xFFB8860B)),
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
          const Text('·',
              style: TextStyle(fontSize: 12, color: Color(0xFF8C8C8C))),
          const SizedBox(width: 2),
        ],
        Text(_time(note.createdAt),
            style: const TextStyle(
                fontSize: 12, color: Color(0xFF8C8C8C))),
      ],
    );
  }

  Widget _metrics(PlazaNote note) {
    return Row(
      children: [
        Icon(Icons.mode_comment_outlined, size: 16, color: _textSec),
        const SizedBox(width: 4),
        Text('${note.commentCount}',
            style: const TextStyle(fontSize: 13, color: _textSec)),
        const SizedBox(width: 20),
        Icon(Icons.repeat_rounded, size: 16, color: _textSec),
        const SizedBox(width: 4),
        Text('${note.repostCount}',
            style: const TextStyle(fontSize: 13, color: _textSec)),
        const SizedBox(width: 20),
        Icon(Icons.favorite_border_rounded, size: 16, color: _textSec),
        const SizedBox(width: 4),
        Text('${note.likeCount}',
            style: const TextStyle(fontSize: 13, color: _textSec)),
        const SizedBox(width: 20),
        Icon(Icons.visibility_outlined, size: 16, color: _textSec),
        const SizedBox(width: 4),
        Text('${note.viewCount}',
            style: const TextStyle(fontSize: 13, color: _textSec)),
      ],
    );
  }

  Widget _body(PlazaNote note) {
    final content = NoteSutraLinks.plainText(note.content);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(note),
        if (content.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(content,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 15, color: _text, height: 1.6)),
        ],
        const SizedBox(height: 8),
        _metrics(note),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final original = _original;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 原帖：头像 + 下方竖线
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: [
                _avatar(original?.ownerUserId),
                if (original != null)
                  Container(
                    width: 2,
                    height: 30,
                    color: _border,
                  ),
              ],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: original != null
                  ? _body(original)
                  : const SizedBox(height: 44),
            ),
          ],
        ),
        // 回复：头像接在原帖竖线下方
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _avatar(widget.replyNote.ownerUserId),
            const SizedBox(width: 10),
            Expanded(child: _body(widget.replyNote)),
          ],
        ),
      ],
    );
  }
}
