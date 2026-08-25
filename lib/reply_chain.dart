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

import 'app_palette.dart';
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _gold => AppPalette.p.accent;
const Color _connector = Color(0xFFC9C9C9);

/// 回复链：原贴下方一串回复，每个节点左侧头像 + 向下竖线（非末尾节点），
/// 右侧为回复内容与四个指标，头像依次用竖线连接。
/// 传入 onComment/onLike/onRepost 后，对应指标按钮可点击（回调参数为该节点帖子）。
/// 回复内容默认最多显示 8 行，超出时出现「显示更多」，点击展开全文（可再收起）。
class ReplyChain extends StatefulWidget {
  final List<PlazaNote> replies;
  final void Function(PlazaNote note)? onComment;
  final void Function(PlazaNote note)? onLike;
  final void Function(PlazaNote note)? onRepost;
  final void Function(PlazaNote note)? onMore;
  final Set<String> pinnedIds;
  final Map<String, String> parentAccounts;

  /// 点击自己的头像/昵称时的回调（如切换到「我的」页）；为空时仍进入个人主页空间。
  final VoidCallback? onOpenSelf;
  const ReplyChain({
    super.key,
    required this.replies,
    this.onComment,
    this.onLike,
    this.onRepost,
    this.onMore,
    this.pinnedIds = const {},
    this.parentAccounts = const {},
    this.onOpenSelf,
  });

  @override
  State<ReplyChain> createState() => _ReplyChainState();
}

class _ReplyChainState extends State<ReplyChain> {
  /// 已点「显示更多」展开全文的回复节点 id 集合。
  final Set<String> _expandedIds = {};

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
  /// 自己的头像/昵称在提供 onOpenSelf 时走回调（如切换到「我的」页，与修学主页
  /// 左上角头像一致）；否则仍进个人主页空间。
  void _openUser(BuildContext context, PlazaNote note) {
    if (note.ownerUserId.isEmpty) return;
    final me = AuthService.instance.currentUser.value;
    final cachedUid = AuthService.instance.cachedUserId;
    final isSelf = (me != null && note.ownerUserId == me.id) ||
        (cachedUid != null && note.ownerUserId == cachedUid);
    if (isSelf && widget.onOpenSelf != null) {
      widget.onOpenSelf!();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => UserSpacePage(
              userId: note.ownerUserId, userName: note.authorName)),
    );
  }

  /// 一个节点：左侧头像 + 向下竖线（最后一个节点不画线，连线两端留距），右侧内容。
  Widget _node(BuildContext context, PlazaNote note,
      {required bool connectDown, required double textMaxWidth}) {
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
              if (connectDown) ...[
                const SizedBox(height: 6),
                Expanded(
                  child: Container(width: 1, color: _connector),
                ),
              ],
            ],
          ),
          const SizedBox(width: 10),
          Expanded(child: _body(context, note, textMaxWidth: textMaxWidth)),
        ],
      ),
    );
  }

  /// 置顶回复的头部：`回复@账户 + 已置顶标签 + 三点菜单`（时间戳在内容下方）。
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
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppPalette.p.textSec),
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
              padding: EdgeInsets.all(4),
              child: Icon(Icons.more_horiz, size: 22, color: Color(0xFF8C8C8C)),
            ),
          ),
        ],
      ],
    );
  }

  /// 点击回复节点内容/时间：进入该回复自己的详情页（原贴在上 + 该回复在下），
  /// 它的直接回复列在下方——层级清晰：点 b 看 b 的回复（c），点 c 看的是 c 的回复。
  void _openDetail(BuildContext context, PlazaNote note) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NoteDetailPage(noteId: note.id),
      ),
    );
  }

  Widget _body(BuildContext context, PlazaNote note,
      {required double textMaxWidth}) {
    final content = NoteSutraLinks.plainText(note.content);
    final pinned = widget.pinnedIds.contains(note.id);
    final parentAccount = widget.parentAccounts[note.repostOf] ?? '';
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
                            style: TextStyle(
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
                              final me =
                                  AuthService.instance.currentUser.value;
                              final cachedUid =
                                  AuthService.instance.cachedUserId;
                              final isSelf =
                                  (me != null &&
                                          note.ownerUserId == me.id) ||
                                      (cachedUid != null &&
                                          note.ownerUserId == cachedUid);
                              if (isSelf && widget.onOpenSelf != null) {
                                widget.onOpenSelf!();
                                return;
                              }
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
                      // 阅藏进度百分比：灰色（与账户名同色系）。
                      const SizedBox(width: 3),
                      Text('·',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF8C8C8C))),
                      const SizedBox(width: 2),
                      Text(postPct,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF8C8C8C))),
                    ],
                  ],
                ),
              ),
              if (widget.onMore != null) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onMore!(note),
                  // 与原贴 PostBlock 头部同款（Padding 2 + 图标 18）：
                  // 行高一致，昵称行到正文的间距才与原贴相同。
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.more_horiz,
                        size: 18, color: Color(0xFF8C8C8C)),
                  ),
                ),
              ],
            ],
          ),
        // 内容 + 时间戳整块可点击进入详情：从昵称行下方到指标行上方的区域。
        // SizedBox 撑满整行，帖子字数少时点击留白同样可进入。
        SizedBox(
          width: double.infinity,
          child: InkWell(
            onTap: () => _openDetail(context, note),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (content.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  // 内容默认折叠为 8 行，超长时出现「显示更多」；点击进入笔记详情。
                  // 注意：不能用 LayoutBuilder 测宽——节点外层是 IntrinsicHeight，
                  // LayoutBuilder 不支持返回固有尺寸，会导致布局异常（发现页空白）。
                  // 宽度在 build 顶层 LayoutBuilder 算好传入（见 [build]）。
                  ..._expandedContent(content, note, textMaxWidth),
                ],
                // 发布时间：内容与指标行之间。
                const SizedBox(height: 6),
                PostTimeLink(
                  text: _time(note.createdAt),
                  onTap: () => _openDetail(context, note),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _metrics(note),
        // 头像连线上下帖子之间留出更大间距。
        const SizedBox(height: 14),
      ],
    );
  }

  /// 折叠/展开的回复内容 + 「显示更多/收起」按钮。
  /// [textMaxWidth] 为内容区实际可用宽度（build 顶层算好传入），用于测溢出。
  List<Widget> _expandedContent(String content, PlazaNote note, double textMaxWidth) {
    final expanded = _expandedIds.contains(note.id);
    final tp = TextPainter(
      text: TextSpan(
        text: content,
        style: TextStyle(fontSize: 15, color: _text, height: 1.6),
      ),
      maxLines: 8,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: textMaxWidth);
    final overflow = tp.didExceedMaxLines;
    return [
      Text(content,
          maxLines: expanded ? null : 8,
          overflow: expanded ? null : TextOverflow.ellipsis,
          style: TextStyle(fontSize: 15, color: _text, height: 1.6)),
      if (overflow && !expanded)
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expandedIds.add(note.id)),
          child: const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('显示更多',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF70867A))),
          ),
        ),
      if (expanded)
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expandedIds.remove(note.id)),
          child: const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('收起',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF70867A))),
          ),
        ),
    ];
  }

  Widget _metrics(PlazaNote note) {
    // 实时监听指标广播，详情页操作后数字立即刷新。
    return ListenableBuilder(
      listenable: NoteStatsCenter.instance,
      builder: (context, _) {
        final n = NoteStatsCenter.instance.latest(note.id) ?? note;
        final liked = CloudNotesService.instance.likedNoteIds.contains(n.id);
        // 与个人主页帖子同款：第一个指标与内容左对齐，其余固定间距；
        // 数字较多时单元格内等比缩小，避免溢出或间距被挤压。
        return Row(
          children: [
            _cell(
              Image.asset('assets/images/ic_comment.png',
                  width: 16, height: 16),
              '${n.commentCount}',
              onTap: widget.onComment == null ? null : () => widget.onComment!(note),
            ),
            const SizedBox(width: 48),
            _cell(
              Icon(Icons.repeat_rounded, size: 16, color: _textSec),
              '${n.repostCount}',
              onTap: widget.onRepost == null ? null : () => widget.onRepost!(note),
            ),
            const SizedBox(width: 48),
            _cell(
              Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  size: 16, color: liked ? _gold : _textSec),
              '${n.likeCount}',
              onTap: widget.onLike == null ? null : () => widget.onLike!(note),
            ),
            const SizedBox(width: 48),
            _cell(
              Image.asset('assets/images/ic_view.png', width: 16, height: 16),
              '${n.viewCount}',
            ),
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
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(text,
                maxLines: 1,
                style: TextStyle(fontSize: 13, color: _textSec)),
          ),
        ),
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
    // 顶层 LayoutBuilder 获取本组件可用宽度：节点内头像列宽 44 + 间距 10 = 54，
    // 其余为内容区宽度，用于折叠文本的溢出检测。LayoutBuilder 不能放进
    // IntrinsicHeight（不支持返回固有尺寸），故在此统一测宽再下传。
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final textMaxWidth = w.isFinite ? (w < 54 ? 0.0 : w - 54) : 0.0;
        return Column(
          children: [
            for (var i = 0; i < widget.replies.length; i++) ...[
              _node(context, widget.replies[i],
                  connectDown: i < widget.replies.length - 1,
                  textMaxWidth: textMaxWidth),
              if (i < widget.replies.length - 1)
                const SizedBox(height: 6),
            ],
          ],
        );
      },
    );
  }
}
