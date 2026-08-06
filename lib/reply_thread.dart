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

const Color _gold = Color(0xFFD4A06A);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _border = Color(0xFFEBE1D6);
const Color _primaryLight = Color(0xFF8B6B5A);

/// 回复连贴：原帖在上、回复在下，两侧头像用竖线连接。
/// 原帖与回复均为完整帖子样式：头像、昵称、@账号、时间戳、内容、四个指标。
/// 传入 onComment/onLike/onRepost 后，对应指标按钮可点击（回调参数为该节点帖子）。
/// 传入 onMore 后，回复节点右侧显示三点菜单；pinned=true 时回复节点显示置顶样式
/// （回复@原帖作者账户 · 时间 + 已置顶标签 + 三点菜单）。
class ReplyThread extends StatefulWidget {
  final PlazaNote replyNote;
  final void Function(PlazaNote note)? onComment;
  final void Function(PlazaNote note)? onLike;
  final void Function(PlazaNote note)? onRepost;
  final void Function(PlazaNote note)? onMore;
  final bool pinned;

  /// 详情页用于定位到回复节点的 GlobalKey。
  final GlobalKey? replyNodeKey;

  /// 原帖加载完成（布局就绪）后回调，详情页在此之后滚动定位。
  final VoidCallback? onReadyToScroll;
  const ReplyThread({
    super.key,
    required this.replyNote,
    this.onComment,
    this.onLike,
    this.onRepost,
    this.onMore,
    this.pinned = false,
    this.replyNodeKey,
    this.onReadyToScroll,
  });

  @override
  State<ReplyThread> createState() => _ReplyThreadState();
}

class _ReplyThreadState extends State<ReplyThread> {
  PlazaNote? _original;

  /// 原帖作者是否已被当前用户屏蔽。
  bool get _originalBlocked =>
      _original != null &&
      CloudNotesService.instance.blockedUserIds.contains(_original!.ownerUserId);

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
    // 布局就绪（原帖无论是否加载成功）后再通知详情页滚动定位。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onReadyToScroll?.call();
    });
  }

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
  void _openUser(PlazaNote note) {
    if (note.ownerUserId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => UserSpacePage(
              userId: note.ownerUserId, userName: note.authorName)),
    );
  }

  Widget _header(PlazaNote note, {required bool showMenu}) {
    final me = AuthService.instance.currentUser.value;
    // 阅藏进度百分比：自己的帖子用本地实时统计，他人的用云端数据（0% 也显示）。
    final postPct = postCanonPercent(
      isSelf: me != null && note.ownerUserId == me.id,
      cloudRead: note.canonRead,
      cloudTotal: note.canonTotal,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          // 点击昵称进入该用户个人主页空间。
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openUser(note),
            child: Text(note.authorName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: _text)),
          ),
        ),
        if (note.authorVerified) ...[
          const SizedBox(width: 3),
          const Icon(Icons.verified, size: 15, color: Color(0xFF70867A)),
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
                        builder: (_) =>
                            UserSpacePage(userId: note.ownerUserId)),
                  );
                }
              },
            ),
          ),
          // 阅藏进度百分比：灰色（与账户名同色系）。
          const SizedBox(width: 3),
          Text('·',
              style: TextStyle(fontSize: 12, color: Color(0xFF8C8C8C))),
          const SizedBox(width: 2),
          Text(postPct,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFF8C8C8C))),
        ],
        if (showMenu && widget.onMore != null) ...[
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onMore!(note),
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.more_horiz, size: 18, color: Color(0xFF8C8C8C)),
            ),
          ),
        ],
      ],
    );
  }

  /// 置顶回复的头部：`回复@原帖作者账户 + 已置顶标签 + 三点菜单`（时间戳在内容下方）。
  Widget _pinnedHeader(PlazaNote note) {
    final parentAccount = _original?.authorAccount ?? '';
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
                          color: _textSec),
                    ),
                  ],
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
        if (widget.onMore != null) ...[
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onMore!(note),
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.more_horiz, size: 18, color: Color(0xFF8C8C8C)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _metrics(PlazaNote note) {
    final onComment = widget.onComment;
    final onLike = widget.onLike;
    final onRepost = widget.onRepost;
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
              onTap: onComment == null ? null : () => onComment(note),
            ),
            const SizedBox(width: 48),
            _cell(
              Icon(Icons.repeat_rounded, size: 16, color: _textSec),
              '${n.repostCount}',
              onTap: onRepost == null ? null : () => onRepost(note),
            ),
            const SizedBox(width: 48),
            _cell(
              Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  size: 16, color: liked ? _gold : _textSec),
              '${n.likeCount}',
              onTap: onLike == null ? null : () => onLike(note),
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

  Widget _body(PlazaNote note, {required bool showMenu}) {
    final content = NoteSutraLinks.plainText(note.content);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showMenu && widget.pinned)
          _pinnedHeader(note)
        else
          _header(note, showMenu: showMenu),
        if (content.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(content,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, color: _text, height: 1.6)),
        ],
        // 发布时间：内容与指标行之间。
        const SizedBox(height: 6),
        PostTimeLink(
          text: _time(note.createdAt),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => NoteDetailPage(
                      noteId: note.id,
                      // 评论贴打开时定位到评论贴位置。
                      scrollToReplyId: showMenu ? note.id : null,
                    )),
          ),
        ),
        const SizedBox(height: 8),
        _metrics(note),
      ],
    );
  }

  /// 一个节点：左侧头像 + 竖线（非最后节点向下延伸），右侧内容。
  Widget _nodeRow(PlazaNote note,
      {required bool connectDown, required bool showMenu}) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openUser(note),
                child: UserAvatar(userId: note.ownerUserId, radius: 22),
              ),
              if (connectDown)
                Expanded(
                  child: Container(width: 2, color: _border),
                ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(child: _body(note, showMenu: showMenu)),
        ],
      ),
    );
  }

  /// 原帖作者被屏蔽：保留头像连线结构，内容替换为「已屏蔽用户」占位，
  /// 点击占位可进入该用户主页取消屏蔽。
  Widget _blockedOriginalNode(PlazaNote original) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              const CircleAvatar(
                radius: 22,
                backgroundColor: Color(0x1A8B6B5A),
                child: Icon(Icons.block, size: 22, color: _textSec),
              ),
              // 连线通到底，与下方回复头像衔接（与正常连贴样式一致）。
              Expanded(
                child: Container(width: 2, color: _border),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: GestureDetector(
                onTap: original.ownerUserId.isNotEmpty
                    ? () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => UserSpacePage(
                              userId: original.ownerUserId,
                              userName: original.authorName,
                            ),
                          ),
                        )
                    : null,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border.all(color: _border),
                    borderRadius: BorderRadius.circular(8),
                    color: const Color(0xFFF5EDE3),
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
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final original = _original;
    final replyNode =
        _nodeRow(widget.replyNote, connectDown: false, showMenu: true);
    final replyKey = widget.replyNodeKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (original != null)
          _originalBlocked
              ? _blockedOriginalNode(original)
              : _nodeRow(original, connectDown: true, showMenu: false),
        replyKey == null
            ? replyNode
            : KeyedSubtree(key: replyKey, child: replyNode),
      ],
    );
  }
}
