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
        Image.asset('assets/images/ic_comment.png', width: 16, height: 16),
        const SizedBox(width: 3),
        Text('${note.commentCount}',
            style: const TextStyle(fontSize: 13, color: _textSec)),
        const SizedBox(width: 48),
        Icon(Icons.repeat_rounded, size: 16, color: _textSec),
        const SizedBox(width: 3),
        Text('${note.repostCount}',
            style: const TextStyle(fontSize: 13, color: _textSec)),
        const SizedBox(width: 48),
        Icon(Icons.favorite_border_rounded, size: 16, color: _textSec),
        const SizedBox(width: 3),
        Text('${note.likeCount}',
            style: const TextStyle(fontSize: 13, color: _textSec)),
        const SizedBox(width: 48),
        Image.asset('assets/images/ic_view.png', width: 16, height: 16),
        const SizedBox(width: 3),
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

  /// 一个节点：左侧头像 + 竖线（非最后节点向下延伸），右侧内容。
  Widget _nodeRow(PlazaNote note, {required bool connectDown}) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              UserAvatar(userId: note.ownerUserId, radius: 22),
              if (connectDown)
                Expanded(
                  child: Container(width: 2, color: _border),
                ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(child: _body(note)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final original = _original;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (original != null) _nodeRow(original, connectDown: true),
        _nodeRow(widget.replyNote, connectDown: false),
      ],
    );
  }
}
