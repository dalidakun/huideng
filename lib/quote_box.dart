import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'note_sutra_links.dart';
import 'reading_badges.dart';
import 'user_avatar.dart';
import 'user_space_page.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _border = Color(0xFFEBE1D6);
const Color _primaryLight = Color(0xFF8B6B5A);

/// 被转发/被回复原帖的引用框（列表与详情共用同一样式）：
/// 线框包裹，内部为头像 + 昵称 + @账号 + 内容（最多3行）+ 时间戳。
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

  /// 原帖作者是否已被当前用户屏蔽。
  bool get _originalAuthorBlocked =>
      _original != null &&
      CloudNotesService.instance.blockedUserIds.contains(_original!.ownerUserId);

  String _time(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '今日${t.hour}时';
    }
    if (t.year == now.year) return '${t.month}月${t.day}日${t.hour}时';
    return '${t.year}年${t.month}月${t.day}日${t.hour}时';
  }

  /// 点击头像/昵称进入该用户个人主页空间。
  void _openOriginalUser(BuildContext context) {
    final uid = _original?.ownerUserId ?? widget.note.repostSourceUserId;
    final name = _original?.authorName ?? widget.note.repostSourceAuthor;
    if (uid.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => UserSpacePage(userId: uid, userName: name)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_originalAuthorBlocked) {
      // 原帖作者已被屏蔽：点击进入该用户主页，方便一键取消屏蔽。
      final blockedOwnerId = _original!.ownerUserId;
      final blockedOwnerName = _original!.authorName;
      return InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserSpacePage(
              userId: blockedOwnerId,
              userName: blockedOwnerName,
            ),
          ),
        ),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(color: _border),
            borderRadius: BorderRadius.circular(8),
            color: _bg,
          ),
          child: const Row(
            children: [
              Icon(Icons.block, size: 16, color: _textSec),
              SizedBox(width: 8),
              Text('已屏蔽用户',
                  style: TextStyle(fontSize: 14, color: _textSec)),
            ],
          ),
        ),
      );
    }
    final src = _original;
    final name = src?.authorName ?? widget.note.repostSourceAuthor;
    final account = src?.authorAccount ?? '';
    final timeMs = src?.createdAt ?? 0;
    final content = src != null
        ? NoteSutraLinks.plainText(src.content)
        : (widget.note.quoteOfContent.isNotEmpty
            ? NoteSutraLinks.plainText(widget.note.quoteOfContent)
            : NoteSutraLinks.plainText(widget.note.content));
    // 原帖作者的认证标记与阅藏进度：与帖子头行一致（自己帖子用本地实时进度，
    // 且昵称用当前登录昵称；历史转发快照可能没存认证/进度，靠 getNoteById 现查）。
    final me = AuthService.instance.currentUser.value;
    final srcUid = src?.ownerUserId ?? widget.note.repostSourceUserId;
    final isSelf = me != null && me.id == srcUid;
    final showName = isSelf ? me.displayName : name;
    final srcVerified = src?.authorVerified ?? false;
    final srcPct = postCanonPercent(
      isSelf: isSelf,
      cloudRead: src?.canonRead ?? 0,
      cloudTotal: src?.canonTotal ?? 0,
    );
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
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _openOriginalUser(context),
                  child: UserAvatar(userId: srcUid, radius: 14),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        // 点击昵称进入该用户个人主页空间。
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _openOriginalUser(context),
                          child: Text(showName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: _text)),
                        ),
                      ),
                      if (srcVerified) ...[
                        const SizedBox(width: 3),
                        const Icon(Icons.verified,
                            size: 14, color: Color(0xFF70867A)),
                      ],
                      if (account.isNotEmpty) ...[
                        const SizedBox(width: 3),
                        Flexible(
                          // 账号名过长时省略显示，保证昵称完整。
                          child: Text('@$account',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF8C8C8C))),
                        ),
                      ],
                      // 阅藏进度百分比：与帖子头行一致，恒显示（0% 也显示）。
                      const SizedBox(width: 3),
                      const Text('·',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF8C8C8C))),
                      const SizedBox(width: 2),
                      Flexible(
                        child: Text(srcPct,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF8C8C8C))),
                      ),
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
            // 原帖发布时间：内容下方。
            const SizedBox(height: 6),
            Text(_time(timeMs),
                style:
                    const TextStyle(fontSize: 12, color: Color(0xFF8C8C8C))),
          ],
        ),
      ),
    );
  }
}
