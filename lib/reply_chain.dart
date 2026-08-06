import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'note_stats_center.dart';
import 'note_sutra_links.dart';
import 'post_time_link.dart';
import 'reading_badges.dart';
import 'user_avatar.dart';
import 'user_space_page.dart';

const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _gold = Color(0xFFD4A06A);
const Color _connector = Color(0xFFC9C9C9);

/// 回复链：原贴下方一串回复，每个节点左侧头像 + 向下竖线（非末尾节点），
/// 右侧为回复内容与四个指标，头像依次用竖线连接。
/// 传入 onComment/onLike/onRepost 后，对应指标按钮可点击（回调参数为该节点帖子）。
class ReplyChain extends StatelessWidget {
  final List<PlazaNote> replies;
  final void Function(PlazaNote note)? onComment;
  final void Function(PlazaNote note)? onLike;
  final void Function(PlazaNote note)? onRepost;
  final void Function(PlazaNote note)? onMore;
  final Set<String> pinnedIds;
  final Map<String, String> parentAccounts;
  const ReplyChain({
    super.key,
    required this.replies,
    this.onComment,
    this.onLike,
    this.onRepost,
    this.onMore,
    this.pinnedIds = const {},
    this.parentAccounts = const {},
  });

  String _time(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (t.year == now.year) return '${t.month}月${t.day}日';
    return '${t.year}年${t.month}月${t.day}日';
  }

  /// 点击头像/昵称进入该用户个人主页空间。
  void _openUser(BuildContext context, PlazaNote note) {
    if (note.ownerUserId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => UserSpacePage(
              userId: note.ownerUserId, userName: note.authorName)),
    );
  }

  /// 一个节点：左侧头像 + 向下竖线（最后一个节点不画线，连线两端留距），右侧内容。
  Widget _node(BuildContext context, PlazaNote note,
      {required bool connectDown}) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openUser(context, note),
                child: UserAvatar(userId: note.ownerUserId, radius: 22),
              ),
              if (connectDown)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Container(width: 1, color: _connector),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(child: _body(context, note)),
        ],
      ),
    );
  }

  /// 置顶回复的头部：`回复@账户 · 时间 + 已置顶标签 + 三点菜单`。
  Widget _pinnedHeader(
      BuildContext context, PlazaNote note, String parentAccount) {
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(
                      text: '回复@',
                      style: TextStyle(fontSize: 13, color: Color(0xFF8C8C8C)),
                    ),
                    TextSpan(
                      text: parentAccount.isEmpty ? '同修' : parentAccount,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF8B6B5A)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Text('·',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8C8C8C))),
              const SizedBox(width: 2),
              PostTimeLink(
                text: _time(note.createdAt),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => NoteDetailPage(
                            noteId: note.id,
                            scrollToReplyId: note.id,
                          )),
                ),
              ),
            ],
          ),
        ),
        const Icon(Icons.push_pin, size: 13, color: Color(0xFF70867A)),
        const SizedBox(width: 2),
        const Text('已置顶',
            style: TextStyle(
                fontSize: 12,
                color: Color(0xFF70867A),
                fontWeight: FontWeight.w600)),
        if (onMore != null) ...[
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onMore!(note),
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.more_horiz, size: 18, color: Color(0xFF8C8C8C)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _body(BuildContext context, PlazaNote note) {
    final content = NoteSutraLinks.plainText(note.content);
    final pinned = pinnedIds.contains(note.id);
    final parentAccount = parentAccounts[note.repostOf] ?? '';
    // 阅藏进度百分比：自己的帖子用本地实时统计，他人的用云端数据（0% 也显示）。
    final me = AuthService.instance.currentUser.value;
    final postPct = postCanonPercent(
      isSelf: me != null && note.ownerUserId == me.id,
      cloudRead: note.canonRead,
      cloudTotal: note.canonTotal,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pinned)
          _pinnedHeader(context, note, parentAccount)
        else
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      // 点击昵称进入该用户个人主页空间。
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _openUser(context, note),
                        child: Text(note.authorName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: _text)),
                      ),
                    ),
                    if (note.authorVerified) ...[
                      const SizedBox(width: 3),
                      const Icon(Icons.verified,
                          size: 15, color: Color(0xFF70867A)),
                    ],
                    if (note.authorAccount.isNotEmpty) ...[
                      const SizedBox(width: 3),
                      Flexible(
                        // 点击 @账户名 进入该用户个人主页（按下时变 70867A）。
                        child: AccountLink(
                          account: note.authorAccount,
                          onTap: () {
                            if (note.ownerUserId.isNotEmpty) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => UserSpacePage(
                                        userId: note.ownerUserId)),
                              );
                            }
                          },
                        ),
                      ),
                      // 阅藏进度百分比：灰色（时间戳同色）。
                      const SizedBox(width: 3),
                      Text('·',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF8C8C8C))),
                      const SizedBox(width: 2),
                      Text(postPct,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF8C8C8C))),
                      const SizedBox(width: 3),
                      Text('·',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF8C8C8C))),
                      const SizedBox(width: 2),
                    ],
                    PostTimeLink(
                      text: _time(note.createdAt),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => NoteDetailPage(
                                  noteId: note.id,
                                  scrollToReplyId: note.id,
                                )),
                      ),
                    ),
                  ],
                ),
              ),
              if (onMore != null) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onMore!(note),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.more_horiz,
                        size: 18, color: Color(0xFF8C8C8C)),
                  ),
                ),
              ],
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
        // 头像连线上下帖子之间留出更大间距。
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _metrics(PlazaNote note) {
    // 实时监听指标广播，详情页操作后数字立即刷新。
    return ListenableBuilder(
      listenable: NoteStatsCenter.instance,
      builder: (context, _) {
        final n = NoteStatsCenter.instance.latest(note.id) ?? note;
        final liked = CloudNotesService.instance.likedNoteIds.contains(n.id);
        return Row(
          children: [
            _cell(
              Image.asset('assets/images/ic_comment.png',
                  width: 16, height: 16),
              '${n.commentCount}',
              onTap: onComment == null ? null : () => onComment!(note),
            ),
            const SizedBox(width: 48),
            _cell(
              Icon(Icons.repeat_rounded, size: 16, color: _textSec),
              '${n.repostCount}',
              onTap: onRepost == null ? null : () => onRepost!(note),
            ),
            const SizedBox(width: 48),
            _cell(
              Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  size: 16, color: liked ? _gold : _textSec),
              '${n.likeCount}',
              onTap: onLike == null ? null : () => onLike!(note),
            ),
            const SizedBox(width: 48),
            Image.asset('assets/images/ic_view.png', width: 16, height: 16),
            const SizedBox(width: 3),
            Text('${n.viewCount}',
                style: const TextStyle(fontSize: 13, color: _textSec)),
          ],
        );
      },
    );
  }

  Widget _cell(Widget icon, String text, {VoidCallback? onTap}) {
    final cell = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 16, height: 16, child: icon),
        const SizedBox(width: 3),
        Text(text, style: const TextStyle(fontSize: 13, color: _textSec)),
      ],
    );
    if (onTap == null) return cell;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: cell,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < replies.length; i++)
          _node(context, replies[i], connectDown: i < replies.length - 1),
      ],
    );
  }
}
