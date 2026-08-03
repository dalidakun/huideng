import 'package:flutter/material.dart';

import 'cloud_notes_service.dart';
import 'note_sutra_links.dart';
import 'user_avatar.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _border = Color(0xFFEBE1D6);

/// 回复链：原贴下方一串回复，每个节点左侧头像 + 向下竖线（非末尾节点），
/// 右侧为回复内容与四个指标，头像依次用竖线连接。
class ReplyChain extends StatelessWidget {
  final List<PlazaNote> replies;
  const ReplyChain({super.key, required this.replies});

  String _time(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (t.year == now.year) return '${t.month}月${t.day}日';
    return '${t.year}年${t.month}月${t.day}日';
  }

  Widget _node(PlazaNote note, {required bool connectDown}) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              UserAvatar(userId: note.ownerUserId, radius: 22),
              if (connectDown)
                Expanded(child: Container(width: 2, color: _border)),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(child: _body(note)),
        ],
      ),
    );
  }

  Widget _body(PlazaNote note) {
    final content = NoteSutraLinks.plainText(note.content);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
        ),
        if (content.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(content,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, color: _text, height: 1.6)),
        ],
        const SizedBox(height: 8),
        _metrics(note),
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < replies.length; i++)
          _node(replies[i], connectDown: i < replies.length - 1),
      ],
    );
  }
}
