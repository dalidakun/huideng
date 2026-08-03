import 'package:flutter/material.dart';

import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'note_sutra_links.dart';
import 'user_avatar.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _border = Color(0xFFEBE1D6);
const Color _primaryLight = Color(0xFF8B6B5A);

/// 被转发/被回复原帖的引用框（列表与详情共用同一样式）：
/// 线框包裹，内部为头像 + 昵称 + @账号 + 时间戳 + 内容（最多3行）。
class QuoteBox extends StatefulWidget {
  final PlazaNote note;
  const QuoteBox({super.key, required this.note});

  @override
  State<QuoteBox> createState() => _QuoteBoxState();
}

class _QuoteBoxState extends State<QuoteBox> {
  PlazaNote? _original;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final n =
          await CloudNotesService.instance.getNoteById(widget.note.repostOf);
      if (!mounted) return;
      setState(() => _original = n);
    } catch (_) {
      // 原帖已删除/隐藏，用转发时保存的快照。
    }
  }

  String _time(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (t.year == now.year) return '${t.month}月${t.day}日';
    return '${t.year}年${t.month}月${t.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final src = _original;
    final name = src?.authorName ?? widget.note.repostSourceAuthor;
    final account = src?.authorAccount ?? '';
    final timeMs = src?.createdAt ?? 0;
    final content = src != null
        ? NoteSutraLinks.plainText(src.content)
        : (widget.note.quoteOfContent.isNotEmpty
            ? NoteSutraLinks.plainText(widget.note.quoteOfContent)
            : NoteSutraLinks.plainText(widget.note.content));
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => NoteDetailPage(noteId: src?.id ?? widget.note.repostOf)),
      ),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                UserAvatar(userId: src?.ownerUserId ?? widget.note.ownerUserId, radius: 14),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: _text)),
                      ),
                      if (account.isNotEmpty) ...[
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text('@$account',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF8C8C8C))),
                        ),
                        const SizedBox(width: 3),
                        const Text('·',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF8C8C8C))),
                        const SizedBox(width: 2),
                      ],
                      const SizedBox(width: 2),
                      Text(_time(timeMs),
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF8C8C8C))),
                    ],
                  ),
                ),
              ],
            ),
            if (content.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, color: _text, height: 1.6)),
            ],
          ],
        ),
      ),
    );
  }
}
