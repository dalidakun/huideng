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
const Color _connector = Color(0xFFC9C9C9);

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

  /// 点击自己的头像/昵称时的回调（如切换到「我的」页）；为空时仍进入个人主页空间。
  final VoidCallback? onOpenSelf;

  /// 是否渲染指标行（评论/转发/点赞/阅读）。详情页回复帖下方会统一渲染
  /// 一排更完整的操作行（含收藏/分享），此时传 false 避免出现两排指标。
  final bool showMetrics;

  /// 点击帖子内容时的回调（如跳转到该帖自己的详情页）。为空时内容不可点
  /// （保持外层手势处理，避免与 feed 的整卡点击冲突）。
  final void Function(PlazaNote note)? onOpenDetail;

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
    this.onOpenSelf,
    this.showMetrics = true,
    this.onOpenDetail,
  });

  @override
  State<ReplyThread> createState() => _ReplyThreadState();
}

class _ReplyThreadState extends State<ReplyThread> {
  PlazaNote? _original;

  /// 已点「显示更多」展开全文的节点 id 集合。
  final Set<String> _expandedIds = {};

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
  /// 自己的头像/昵称在提供 onOpenSelf 时走回调（如切换到「我的」页，与修学主页
  /// 左上角头像一致）；否则仍进个人主页空间。
  void _openUser(PlazaNote note) {
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

  Widget _header(PlazaNote note) {
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
        // 昵称区用 Expanded 撑满，三点菜单推到右缘，与下方评论行对齐。
        Expanded(
          child: Row(
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
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _text)),
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
                        final me = AuthService.instance.currentUser.value;
                        final cachedUid = AuthService.instance.cachedUserId;
                        final isSelf =
                            (me != null && note.ownerUserId == me.id) ||
                                (cachedUid != null &&
                                    note.ownerUserId == cachedUid);
                        if (isSelf && widget.onOpenSelf != null) {
                          widget.onOpenSelf!();
                          return;
                        }
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
        // 原贴与回复都带三点菜单（提供 onMore 时），尺寸与下方评论行一致。
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
              padding: EdgeInsets.all(4),
              child: Icon(Icons.more_horiz, size: 22, color: Color(0xFF8C8C8C)),
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
        // 与个人主页帖子同款：第一个指标与内容左对齐，其余固定间距；
        // 数字较多时单元格内等比缩小，避免溢出或间距被挤压。
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
                style: const TextStyle(fontSize: 13, color: _textSec)),
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

  Widget _body(PlazaNote note,
      {required bool showMenu, required double textMaxWidth}) {
    final content = NoteSutraLinks.plainText(note.content);
    // 内容 + 时间戳整块（昵称行下方到指标行上方）：提供 onOpenDetail 时整块
    // 可点击进入该帖详情页；指标行有各自按钮，不在此区域内。
    final openArea = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (content.isNotEmpty) ...[
          const SizedBox(height: 4),
          // 内容默认折叠为 8 行，超长时出现「显示更多」。
          // 注意：不能用 LayoutBuilder 测宽——节点外层是 IntrinsicHeight，
          // LayoutBuilder 不支持返回固有尺寸，会导致布局异常。宽度由 build
          // 顶层 LayoutBuilder 算好传入（见 [build]）。
          ..._expandedContent(content, note, textMaxWidth),
        ],
        // 发布时间：内容与指标行之间。
        const SizedBox(height: 6),
        PostTimeLink(
          text: _time(note.createdAt),
          onTap: () => _openPost(note, showMenu: showMenu),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showMenu && widget.pinned)
          _pinnedHeader(note)
        else
          _header(note),
        if (widget.onOpenDetail != null)
          // SizedBox 撑满整行，帖子字数少时点击留白同样可进入。
          SizedBox(
            width: double.infinity,
            child: InkWell(
              onTap: () => widget.onOpenDetail!(note),
              child: openArea,
            ),
          )
        else
          openArea,
        const SizedBox(height: 8),
        if (widget.showMetrics) _metrics(note),
        // 头像连线上下帖子之间留出间距，与 ReplyChain 保持一致。
        const SizedBox(height: 14),
      ],
    );
  }

  /// 点击帖子内容/时间：有 [onOpenDetail] 时走回调；否则直接打开该帖详情页。
  void _openPost(PlazaNote note, {required bool showMenu}) {
    final cb = widget.onOpenDetail;
    if (cb != null) {
      cb(note);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => NoteDetailPage(
                noteId: note.id,
                // 评论贴打开时定位到评论贴位置。
                scrollToReplyId: showMenu ? note.id : null,
              )),
    );
  }

  /// 折叠/展开的节点内容 + 「显示更多/收起」按钮。
  /// [textMaxWidth] 为内容区实际可用宽度（build 顶层算好传入），用于测溢出。
  List<Widget> _expandedContent(
      String content, PlazaNote note, double textMaxWidth) {
    final expanded = _expandedIds.contains(note.id);
    final tp = TextPainter(
      text: TextSpan(
        text: content,
        style: const TextStyle(fontSize: 15, color: _text, height: 1.6),
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
          style: const TextStyle(fontSize: 15, color: _text, height: 1.6)),
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

  /// 一个节点：左侧头像 + 竖线（非最后节点向下延伸，两端各留 6px 间距），右侧内容。
  Widget _nodeRow(PlazaNote note,
      {required bool connectDown,
      required bool showMenu,
      required double textMaxWidth}) {
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
              if (connectDown) ...[
                const SizedBox(height: 6),
                Expanded(
                  child: Container(width: 1, color: _connector),
                ),
              ],
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
              child: _body(note, showMenu: showMenu, textMaxWidth: textMaxWidth)),
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
              // 连线通到底，与下方回复头像衔接（线上端距头像 6px）。
              const SizedBox(height: 6),
              Expanded(
                child: Container(width: 1, color: _connector),
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
    // 顶层 LayoutBuilder 获取本组件可用宽度：节点内头像列宽 44 + 间距 10 = 54，
    // 其余为内容区宽度，用于折叠文本的溢出检测。LayoutBuilder 不能放进
    // IntrinsicHeight（不支持返回固有尺寸），故在此统一测宽再下传。
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final textMaxWidth = w.isFinite ? (w < 54 ? 0.0 : w - 54) : 0.0;
        final replyNode = _nodeRow(widget.replyNote,
            connectDown: false, showMenu: true, textMaxWidth: textMaxWidth);
        final replyKey = widget.replyNodeKey;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (original != null)
              _originalBlocked
                  ? _blockedOriginalNode(original)
                  : _nodeRow(original,
                      connectDown: true, showMenu: false, textMaxWidth: textMaxWidth),
            // 原帖与回复节点之间留 6px 间距，作为连线底部到回复头像的间隔。
            if (original != null)
              const SizedBox(height: 6),
            replyKey == null
                ? replyNode
                : KeyedSubtree(key: replyKey, child: replyNode),
          ],
        );
      },
    );
  }
}
