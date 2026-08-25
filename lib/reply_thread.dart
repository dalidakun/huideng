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
Color get _gold => AppPalette.p.accent;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _border => AppPalette.p.border;
Color get _primaryLight => AppPalette.p.textSec;
const Color _connector = Color(0xFFC9C9C9);

/// 连贴中的单个节点：左侧头像（可选向下延伸连接线）+ 昵称行 + 内容 + 指标。
/// 既由 [ReplyThread] 组合使用，也供详情页拆分布局直接使用
/// （详情页把原帖节点与回复节点放进 CustomScrollView 的不同 sliver，
/// 参考 X：祖先只存 id+文本摘要，不作为完整帖子渲染在回复上下文里）。
class ReplyThreadNode extends StatefulWidget {
  final PlazaNote note;

  /// 头像下方是否向下延伸连接线（连贴中的非最后节点为 true）。
  final bool connectDown;

  /// 头像上方是否延伸连接线段（详情页焦点帖用：衔接藏在上方负偏移区的
  /// 祖先链连线）。与头像同宽居中绘制，和节点自身连线完全同一条 x 直线。
  final bool connectUp;

  /// 点击上方连接线段的回调（如打开紧邻父帖详情）。
  final VoidCallback? onConnectUpTap;

  /// 头像上方留出 6px 空隙（无 connectUp 段时用）：上一个节点的连线直达行底，
  /// 这里撑开连线端点与本节点头像的间距（与首页连线端点风格一致）。
  final bool spaceAbove;

  /// 是否按「可带三点菜单」的节点处理；同时决定 pinned 时是否使用置顶头部。
  final bool showMenu;

  /// 是否渲染指标行（评论/转发/点赞/阅读）。详情页回复帖下方统一渲染一排
  /// 更完整的操作行（含收藏/分享），此时传 false 避免两排指标。
  final bool showMetrics;

  /// 置顶样式头（回复@账号 · 已置顶标签），仅在 [showMenu] 为 true 时生效。
  final bool pinned;

  /// 非空时在昵称行下方渲染「回复@账号」紧凑提示行（X 式祖先预览：
  /// 祖先帖不全渲染时给出的上下文线索），点击走 [onAncestorTap]。
  final String? ancestorAccount;
  final VoidCallback? onAncestorTap;

  final void Function(PlazaNote note)? onComment;
  final void Function(PlazaNote note)? onLike;
  final void Function(PlazaNote note)? onRepost;
  final void Function(PlazaNote note)? onMore;

  /// 点击自己的头像/昵称时的回调（如切换到「我的」页）；为空时仍进入个人主页空间。
  final VoidCallback? onOpenSelf;

  /// 点击帖子内容时的回调（如跳转到该帖自己的详情页）。为空时内容不可点
  /// （保持外层手势处理，避免与 feed 的整卡点击冲突）。
  final void Function(PlazaNote note)? onOpenDetail;

  const ReplyThreadNode({
    super.key,
    required this.note,
    this.connectDown = false,
    this.connectUp = false,
    this.onConnectUpTap,
    this.spaceAbove = false,
    this.showMenu = false,
    this.showMetrics = true,
    this.pinned = false,
    this.ancestorAccount,
    this.onAncestorTap,
    this.onComment,
    this.onLike,
    this.onRepost,
    this.onMore,
    this.onOpenSelf,
    this.onOpenDetail,
  });

  @override
  State<ReplyThreadNode> createState() => _ReplyThreadNodeState();
}

class _ReplyThreadNodeState extends State<ReplyThreadNode> {
  /// 已点「显示更多」展开全文的节点内容 id。
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
                      style: TextStyle(
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
        // 三点菜单（提供 onMore 且节点声明 showMenu 时），尺寸与下方评论行一致。
        if (widget.showMenu && widget.onMore != null) ...[
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
    final parentAccount = widget.ancestorAccount ?? '';
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

  Widget _body(PlazaNote note,
      {required bool showMenu, required double textMaxWidth}) {
    final content = NoteSutraLinks.plainText(note.content);
    final pinnedHeader = showMenu && widget.pinned;
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
        if (pinnedHeader)
          _pinnedHeader(note)
        else
          _header(note),
        // X 式紧凑祖先提示：祖先帖不全渲染时给出「回复@账号」线索。
        // 置顶头部本身已含「回复@」，不再重复。
        if (!pinnedHeader && widget.ancestorAccount != null) ...[
          const SizedBox(height: 3),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onAncestorTap,
            child: Row(
              children: [
                const Text('回复@',
                    style:
                        TextStyle(fontSize: 13, color: Color(0xFF8C8C8C))),
                Flexible(
                  child: Text(
                    widget.ancestorAccount!.isEmpty
                        ? '同修'
                        : widget.ancestorAccount!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _textSec),
                  ),
                ),
              ],
            ),
          ),
        ],
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

  @override
  Widget build(BuildContext context) {
    // 顶层 LayoutBuilder 获取本组件可用宽度：节点内头像列宽 44 + 间距 10 = 54，
    // 其余为内容区宽度，用于折叠文本的溢出检测。LayoutBuilder 不能放进
    // IntrinsicHeight（不支持返回固有尺寸），故在此统一测宽再下传。
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final textMaxWidth = w.isFinite ? (w < 54 ? 0.0 : w - 54) : 0.0;
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Column(
                children: [
                  if (widget.connectUp) ...[
                    // 上方线段：与头像同宽(44)居中，和 connectDown 线完全同一 x；
                    // 顶端紧贴上一节点的连线末端（直达行底），底端与头像留 6px。
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onConnectUpTap,
                      child: SizedBox(
                        width: 44,
                        height: 16,
                        child:
                            Center(child: Container(width: 1, color: _connector)),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ] else if (widget.spaceAbove)
                    // 无线段可衔接时同样保持「线上端点—头像」6px 间距。
                    const SizedBox(height: 6),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openUser(widget.note),
                    child:
                        UserAvatar(userId: widget.note.ownerUserId, radius: 22),
                  ),
                  if (widget.connectDown) ...[
                    const SizedBox(height: 6),
                    Expanded(
                      child: Container(width: 1, color: _connector),
                    ),
                  ],
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _body(widget.note,
                    showMenu: widget.showMenu, textMaxWidth: textMaxWidth),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 原帖作者被屏蔽时原帖节点的占位渲染：保留头像连线结构，
/// 内容替换为「已屏蔽用户」，点击占位可进入该用户主页取消屏蔽。
Widget blockedOriginalRow(BuildContext context, PlazaNote original) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Column(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: Color(0x1A8B6B5A),
            child: Icon(Icons.block, size: 22, color: AppPalette.p.textSec),
          ),
          // 固定长度下延线段：占位卡只有一行字、比头像列矮，若用 Expanded
          // 撑满行高会被压缩到不可见；固定高度保证与下一级头像始终有可见连线，
          // 末端再留 6px 到下一级头像（与首页连线端点风格一致）。
          const SizedBox(height: 6),
          Container(width: 1, height: 20, color: _connector),
          const SizedBox(height: 6),
        ],
      ),
      const SizedBox(width: 10),
      Expanded(
        // 卡片与头像顶部对齐（不再整体下移）。
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
              color: AppPalette.p.bg,
            ),
            child: Row(
              children: [
                Icon(Icons.block, size: 16, color: _textSec),
                const SizedBox(width: 8),
                Text('已屏蔽用户',
                    style: TextStyle(fontSize: 14, color: _textSec)),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

/// 祖先帖已被删除时的占位节点：保留头像连线结构（连线下延到下一级回复），
/// 提示用户这是对一个已删除帖子的回复；内容不可见，不做点击跳转。
Widget deletedOriginalRow() {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Column(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: Color(0x1A8B6B5A),
            child: Icon(Icons.delete_outline, size: 22, color: AppPalette.p.textSec),
          ),
          // 固定长度下延线段：占位卡只有一行字、比头像列矮，若用 Expanded
          // 撑满行高会被压缩到不可见；固定高度保证与下一级头像始终有可见连线，
          // 末端再留 6px 到下一级头像（与首页连线端点风格一致）。
          const SizedBox(height: 6),
          Container(width: 1, height: 20, color: _connector),
          const SizedBox(height: 6),
        ],
      ),
      const SizedBox(width: 10),
      Expanded(
        // 卡片与头像顶部对齐（不再整体下移）。
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(color: _border),
            borderRadius: BorderRadius.circular(8),
            color: AppPalette.p.bg,
          ),
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 16, color: _textSec),
              const SizedBox(width: 8),
              Text('这个帖子已删除',
                  style: TextStyle(fontSize: 14, color: _textSec)),
            ],
          ),
        ),
      ),
    ],
  );
}

/// 回复连贴：原帖在上、回复在下，两侧头像用竖线连接。
/// 原帖与回复均为完整帖子样式：头像、昵称、@账号、时间戳、内容、四个指标。
/// 传入 onComment/onLike/onRepost 后，对应指标按钮可点击（回调参数为该节点帖子）。
/// 传入 onMore 后，回复节点右侧显示三点菜单；pinned=true 时回复节点显示置顶样式
/// （回复@原帖作者账户 · 时间 + 已置顶标签 + 三点菜单）。
///
/// 详情页不使用本组件组合：详情页需要「回复节点贴顶、原帖藏在上方负偏移区」
/// 的拆分布局（见 note_detail_page 的 `_buildReplyThreadBody`），
/// 直接用 [ReplyThreadNode] 分别构建两个节点放入不同 sliver。
class ReplyThread extends StatefulWidget {
  final PlazaNote replyNote;
  final void Function(PlazaNote note)? onComment;
  final void Function(PlazaNote note)? onLike;
  final void Function(PlazaNote note)? onRepost;
  final void Function(PlazaNote note)? onMore;
  final bool pinned;

  /// 详情页等场景已预取的原帖数据：传入后不再内部拉取，首帧即「原帖+回复」
  /// 完整布局。为空时仍走内部拉取。
  final PlazaNote? initialOriginal;

  /// 点击自己的头像/昵称时的回调（如切换到「我的」页）；为空时仍进入个人主页空间。
  final VoidCallback? onOpenSelf;

  /// 是否渲染指标行（评论/转发/点赞/阅读）。
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
    this.initialOriginal,
    this.onOpenSelf,
    this.showMetrics = true,
    this.onOpenDetail,
  });

  @override
  State<ReplyThread> createState() => _ReplyThreadState();
}

class _ReplyThreadState extends State<ReplyThread> {
  PlazaNote? _original;

  @override
  void initState() {
    super.initState();
    // 外部已预取原帖时直接使用，首帧即完整布局。
    _original = widget.initialOriginal;
    _fetch();
  }

  Future<void> _fetch() async {
    if (_original == null && widget.replyNote.repostOf.isNotEmpty) {
      try {
        final n = await CloudNotesService.instance
            .getNoteById(widget.replyNote.repostOf);
        if (!mounted) return;
        setState(() => _original = n);
      } catch (_) {
        // 原帖已删除/隐藏：仅显示回复本身。
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final original = _original;
    final originalBlocked = original != null &&
        CloudNotesService.instance.blockedUserIds.contains(original.ownerUserId);
    final parentAccount = original?.authorAccount ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (original != null)
          originalBlocked
              ? blockedOriginalRow(context, original)
              : ReplyThreadNode(
                  note: original,
                  connectDown: true,
                  // 与旧版一致：原贴与回复节点都可带三点菜单（图标受 onMore 控制）。
                  showMenu: true,
                  showMetrics: widget.showMetrics,
                  onOpenDetail: widget.onOpenDetail,
                  onOpenSelf: widget.onOpenSelf,
                ),
        // 原帖与回复节点之间留 6px 间距，作为连线底部到回复头像的间隔。
        if (original != null) const SizedBox(height: 6),
        ReplyThreadNode(
          note: widget.replyNote,
          // 与旧版一致：回复节点始终按「可带菜单」处理（图标仍受 onMore 控制），
          // pinned 样式因此与 onMore 是否提供无关。
          showMenu: true,
          showMetrics: widget.showMetrics,
          pinned: widget.pinned,
          // 祖先账号仅供置顶头部文案使用；feed 卡片已有连线链路可视化，
          // 不再额外渲染「回复@」提示行（详情页拆分布局才显式传入）。
          ancestorAccount:
              widget.pinned && parentAccount.isNotEmpty ? parentAccount : null,
          onComment: widget.onComment,
          onLike: widget.onLike,
          onRepost: widget.onRepost,
          onMore: widget.onMore,
          onOpenSelf: widget.onOpenSelf,
          onOpenDetail: widget.onOpenDetail,
        ),
      ],
    );
  }
}
