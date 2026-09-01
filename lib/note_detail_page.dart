import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'loading_widgets.dart';
import 'login_page.dart';
import 'my_page.dart';
import 'note_stats_center.dart';
import 'note_sutra_links.dart';
import 'quote_box.dart';
import 'reading_badges.dart';
import 'reading_note_post.dart';
import 'reply_thread.dart';
import 'text_input_sheet.dart';
import 'post_time_link.dart';
import 'post_rich_content.dart';
import 'user_avatar.dart';
import 'user_space_page.dart';

import 'app_palette.dart';
Color get _primary => AppPalette.p.primary;
Color get _primaryLight => AppPalette.p.textSec;
Color get _gold => AppPalette.p.accent;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _border => AppPalette.p.border;
/// 最长显示 10 秒自动消失；点击「点击查看」立即关闭并进入帖子详情页，点 X 仅关闭。
/// [noteId] 为空时（如回复帖创建失败只留评论）不显示跳转入口，点击仅关闭。
void showPostPublishedToast(BuildContext context, String noteId) {
  final canOpen = noteId.isNotEmpty;
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  Timer? autoHide;
  void dismiss() {
    autoHide?.cancel();
    if (entry.mounted) entry.remove();
  }

  entry = OverlayEntry(
    builder: (ctx) {
      final bottomInset = MediaQuery.of(ctx).padding.bottom;
      return Positioned(
        left: 16,
        right: 16,
        bottom: bottomInset + 84,
        child: Material(
          color: _primary,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              dismiss();
              if (!canOpen) return;
              Navigator.of(ctx).push(
                MaterialPageRoute(
                    builder: (_) => NoteDetailPage(noteId: noteId)),
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        text: '已发表，',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                        children: [
                          if (canOpen)
                            TextSpan(
                              text: '点击查看',
                              style: const TextStyle(
                                color: Color(0xFF70867A),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: dismiss,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close,
                          size: 16, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  overlay.insert(entry);
  // 10 秒后自动消失，避免一直挂着、用户忘记关闭。
  autoHide = Timer(const Duration(seconds: 10), dismiss);
}

class NoteDetailPage extends StatefulWidget {
  final String noteId;

  /// 从评论贴时间戳进入时，打开后滚动定位到该评论贴位置。
  final String? scrollToReplyId;

  /// 入口明确是公告（公告栏点击进入）时置 true：即使云端旧数据缺 kind 字段，
  /// 详情页也按公告帖渲染（白色圆角卡片包裹 + 右上角「公告」标签）。
  final bool isAnnouncement;
  const NoteDetailPage({
    super.key,
    required this.noteId,
    this.scrollToReplyId,
    this.isAnnouncement = false,
  });

  @override
  State<NoteDetailPage> createState() => _NoteDetailPageState();
}

class _NoteDetailPageState extends State<NoteDetailPage> {
  PlazaNote? _note;
  List<PlazaComment> _comments = [];
  Map<String, NoteSutraLink> _sutraLib = const {};
  bool _loading = true;
  bool _error = false;
  bool _liking = false;
  bool _favoriting = false;
  bool _reposting = false;
  bool _sendingComment = false;

  /// 每条评论独立的点赞点亮状态（云端持久化，_load 时用服务端状态恢复）。
  final Set<String> _likedCommentIds = {};

  /// 正在提交点赞的评论 id（防止连点重复请求）。
  final Set<String> _commentLiking = {};

  /// 评论作者资料缓存（authorId → 账号/认证，服务端缺失时用于补齐显示）。
  final Map<String, UserProfile> _commentAuthorProfiles = {};
  String _myAccount = '';
  bool _myVerified = false;

  /// 本帖的回复帖列表（评论与回复作为同一类消息统一展示）。
  List<PlazaNote> _replies = [];
  bool _repliesLoading = false;

  /// 评论列表是否展开全部（默认只显示前两条评论，可「显示更多」展开）。
  bool _commentsShowAll = false;

  /// 去重映射：回复流程会同时生成「评论 + 回复帖」两条记录，展示时保留回复帖；
  /// 此映射把被合并的评论 id 指向对应的回复帖 id（用于从评论进入时排到第一条）。
  final Map<String, String> _commentToReplyId = {};

  /// 回复帖模式布局锚点：CustomScrollView 的 center sliver。
  /// center 之前的 sliver 位于「负滚动偏移区」——原帖（a）放在那里，
  /// 回复节点（b/c）所在的 sliver 天生就是屏幕顶部，无需测量/跳转，
  /// 与网络时机、内容高度完全无关（参考 X：祖先只存 id+文本，不全渲染在回复上下文里）。
  final GlobalKey _bCenterKey = GlobalKey();
  late final ScrollController _detailScroll = ScrollController();

  /// 回复帖模式的完整祖先链（紧邻父帖在前，如 d 页为 [c, b, a]）：
  /// 整体渲染在 center 锚点之前的负偏移区，下滑可见，节点间用连接线相连。
  /// 元素为 null 表示该级帖子已被删除/不可见——渲染为「已删除帖子」占位
  /// 并保持连线（X 的 tombstone 同理），其上更早祖先因引用关系不可知而截断。
  final List<PlazaNote?> _threadAncestors = [];

  /// 已展开全文（长内容点「显示更多」）的评论/回复条目 id。
  final Set<String> _expandedContentIds = {};

  /// 根帖长内容是否已展开全文。
  bool _noteContentExpanded = false;

  /// 置顶帖/回复的 id 集合（与「我的」页共用同一份本地记录）。
  final Set<String> _pinnedIds = {};
  static const String _pinnedKey = 'my_pinned_note_ids';

  @override
  void initState() {
    super.initState();
    _loadPinnedIds();
    _load();
  }

  @override
  void dispose() {
    _detailScroll.dispose();
    super.dispose();
  }

  /// 是否按「回复连贴」布局渲染：正常回复帖；或父帖被删后
  /// 携带 tombstoneAncestorIds 的帖子（repostKind 已被改为 quote 但
  /// 仍需展示「已删除帖子」占位与连线）。
  bool _isReplyThreadNote(PlazaNote n) =>
      n.repostKind == 'reply' || n.tombstoneAncestorIds.isNotEmpty;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      // 预热类操作（点赞列表/关注态/经书目录）改为后台并行，
      // 不阻塞主帖渲染。原实现串行 await 这些操作累计 1~3 秒，
      // 是「进入详情页长时间转圈」的原因之一。
      unawaited(CloudNotesService.instance.refreshFavoriteNoteIds());
      unawaited(CloudNotesService.instance.refreshFollowStates());
      // 浏览量+1 失败不影响阅读：纯 fire-and-forget，不更新 UI 数字。
      unawaited(CloudNotesService.instance.incView(widget.noteId).catchError((_) => 0));
      // 经书目录后台并行加载，得到后立刻刷一次，让 $经名 链接可用。
      NoteSutraCatalog.titleMap().then((lib) {
        if (!mounted) return;
        setState(() => _sutraLib = lib);
      }).catchError((_) {});

      // 主帖与评论并行拿：原实现串行依次 await，2 倍延迟合并为 1。
      final results = await Future.wait([
        CloudNotesService.instance.getNoteById(widget.noteId),
        CloudNotesService.instance.getComments(widget.noteId),
      ]);
      final note = results[0] as PlazaNote;
      final comments = results[1] as List<PlazaComment>;

      // 回复链上溯（X 式 tombstone 模型）：祖先关系一旦写下就不改写指向，
      // 中间节点被删时服务端把子回复重挂到祖父并把被删 id 记进
      // tombstoneAncestorIds。因此自下而上收集：先焦点帖自身墓碑，
      // 再真实父帖；每个真实祖先自带的墓碑紧跟其后（位于它与它的父帖之间），
      // 最后反转为自上而下展示序。null = 「已删除帖子」占位（连线保持贯通）。
      final collected = <PlazaNote?>[];
      if (_isReplyThreadNote(note)) {
        void addTombstones(List<String> ids) {
          for (final _ in ids) {
            if (collected.length >= 24) return;
            collected.add(null);
          }
        }

        addTombstones(note.tombstoneAncestorIds);
        final svc = CloudNotesService.instance;
        var cursor = note.repostOf;
        final visited = <String>{note.id};
        while (cursor.isNotEmpty &&
            !visited.contains(cursor) &&
            collected.length < 24) {
          visited.add(cursor);
          // 四重守卫统一按「已删除」处理：
          // 本机删除墓碑 / 服务端软删隐藏（作者本人仍可取回）/ 幽灵脏数据 / 硬删异常。
          if (svc.locallyDeletedNoteIds.contains(cursor)) {
            collected.add(null);
            break;
          }
          try {
            final n = await svc.getNoteById(cursor);
            final ghost = n.ownerUserId.isEmpty && n.content.isEmpty;
            if (n.status != 'normal' || ghost) {
              collected.add(null);
              break;
            }
            collected.add(n);
            // 该级自带的墓碑位于它与它的父帖之间，紧随其后入列。
            addTombstones(n.tombstoneAncestorIds);
            cursor = n.repostOf;
          } catch (_) {
            collected.add(null);
            break;
          }
        }
      }
      final threadAncestors = collected.reversed.toList(growable: false);

      // 评论作者资料后台拉取，先用已有信息渲染，到位后再 setState 一次补齐账号/认证。
      final authorIds = <String>{
        for (final c in comments)
          if (c.authorId.isNotEmpty) c.authorId,
      };
      if (authorIds.isNotEmpty) {
        unawaited(_fetchCommentProfiles(authorIds));
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        _myAccount = prefs.getString('user_account_name') ?? '';
        _myVerified = prefs.getBool('user_verified') ?? false;
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _threadAncestors
          ..clear()
          ..addAll(threadAncestors);
        _note = PlazaNote(
          id: note.id,
          ownerUserId: note.ownerUserId,
          title: note.title,
          content: note.content,
          authorName: note.authorName,
          authorAccount: note.authorAccount,
          authorVerified: note.authorVerified,
          visibility: note.visibility,
          status: note.status,
          likeCount: note.likeCount,
          commentCount: note.commentCount,
          viewCount: note.viewCount,
          repostCount: note.repostCount,
          repostOf: note.repostOf,
          repostSourceAuthor: note.repostSourceAuthor,
          repostKind: note.repostKind,
          tombstoneAncestorIds: note.tombstoneAncestorIds,
          kind: note.kind,
          quoteContent: note.quoteContent,
          quoteOfTitle: note.quoteOfTitle,
          quoteOfContent: note.quoteOfContent,
          createdAt: note.createdAt,
          updatedAt: note.updatedAt,
        );
        _comments = comments;
        // 用服务端返回的点赞状态恢复每条评论的点亮。
        _likedCommentIds
          ..clear()
          ..addAll(comments.where((c) => c.likedByMe).map((c) => c.id));
        _loading = false;
      });
      // 阅读量等指标广播给 Feed，返回后列表数字立即更新。
      NoteStatsCenter.instance.report(_note!);
      // 回复帖列表：详情页折叠展示，拉取失败不影响页面。
      _loadReplies();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  Future<void> _toggleLike() async {
    final note = _note;
    if (note == null) return;
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    if (_liking) return;
    setState(() => _liking = true);
    try {
      final (liked, count) =
          await CloudNotesService.instance.toggleLike(note.id);
      if (!mounted) return;
      setState(() {
        _note = PlazaNote(
          id: note.id,
          ownerUserId: note.ownerUserId,
          title: note.title,
          content: note.content,
          authorName: note.authorName,
          authorAccount: note.authorAccount,
          authorVerified: note.authorVerified,
          visibility: note.visibility,
          status: note.status,
          likeCount: count,
          commentCount: note.commentCount,
          viewCount: note.viewCount,
          repostCount: note.repostCount,
          repostOf: note.repostOf,
          repostSourceAuthor: note.repostSourceAuthor,
          repostKind: note.repostKind,
          quoteContent: note.quoteContent,
          quoteOfTitle: note.quoteOfTitle,
          quoteOfContent: note.quoteOfContent,
          createdAt: note.createdAt,
          updatedAt: note.updatedAt,
        );
        _liking = false;
      });
      NoteStatsCenter.instance.report(_note!);
    } catch (e) {
      if (!mounted) return;
      setState(() => _liking = false);
      _showToast(e.toString());
    }
  }

  void _openCommentSheet() {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    // 统一使用大弹层输入（minLines 3 / maxLines 10），长内容编辑体验更好。
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const SheetTextInput(
        title: '评论',
        hint: '说点什么…',
        maxLength: 500,
        minLines: 3,
        maxLines: 10,
        confirmText: '发表',
      ),
    ).then((content) {
      if (content != null && content.isNotEmpty) _submitComment(content);
    });
  }

  Future<void> _submitComment(String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty || _sendingComment) return;
    setState(() => _sendingComment = true);
    try {
      // 双写：评论（评论量/通知）+ 回复帖（头像连线链，服务端对
      // kind='reply' 不计转发量），与「帖子下方回复按钮」口径一致。
      final comment = await CloudNotesService.instance
          .createComment(widget.noteId, trimmed);
      var replyId = '';
      try {
        replyId = await CloudNotesService.instance
            .repostNote(widget.noteId, quote: trimmed, kind: 'reply');
      } catch (_) {
        // 回复帖创建失败不影响评论本身展示。
      }
      if (!mounted) return;
      setState(() {
        _comments.add(comment);
        _sendingComment = false;
        _note = _note == null
            ? null
            : PlazaNote(
                id: _note!.id,
                ownerUserId: _note!.ownerUserId,
                title: _note!.title,
                content: _note!.content,
                authorName: _note!.authorName,
                authorAccount: _note!.authorAccount,
                authorVerified: _note!.authorVerified,
                visibility: _note!.visibility,
                status: _note!.status,
                likeCount: _note!.likeCount,
                commentCount: _note!.commentCount + 1,
                viewCount: _note!.viewCount,
                repostCount: _note!.repostCount,
                repostOf: _note!.repostOf,
                repostSourceAuthor: _note!.repostSourceAuthor,
                repostKind: _note!.repostKind,
                quoteContent: _note!.quoteContent,
                quoteOfTitle: _note!.quoteOfTitle,
                quoteOfContent: _note!.quoteOfContent,
                createdAt: _note!.createdAt,
                updatedAt: _note!.updatedAt,
              );
      });
      NoteStatsCenter.instance.report(_note!);
      // 重新拉取回复帖，让新回复出现在回复树里（与评论去重合并展示）。
      unawaited(_loadReplies());
      // 广播给发现/关注流：返回列表时回复已连线挂在原帖下方。
      if (replyId.isNotEmpty) {
        broadcastReplyPosted(
          replyId: replyId,
          parentId: widget.noteId,
          parent: _note,
          content: trimmed,
        );
        showPostPublishedToast(context, replyId);
      } else {
        showPostPublishedToast(context, '');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendingComment = false);
      _showToast(e.toString());
    }
  }

  Future<void> _deleteComment(PlazaComment comment) async {
    final note = _note;
    final me = AuthService.instance.currentUser.value;
    if (me == null) return;
    if (comment.authorId != me.id && note?.ownerUserId != me.id) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除评论',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Text('确定删除这条评论吗？', style: TextStyle(color: _textSec)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('取消', style: TextStyle(color: _textSec))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除',
                  style: TextStyle(
                      color: Colors.red, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await CloudNotesService.instance.deleteComment(comment.id);
      if (!mounted) return;
      setState(() {
        _comments.removeWhere((c) => c.id == comment.id);
        if (_note != null) {
          final note = _note!;
          _note = PlazaNote(
            id: note.id,
            ownerUserId: note.ownerUserId,
            title: note.title,
            content: note.content,
            authorName: note.authorName,
            authorAccount: note.authorAccount,
            authorVerified: note.authorVerified,
            visibility: note.visibility,
            status: note.status,
            likeCount: note.likeCount,
            commentCount: note.commentCount > 0
                ? note.commentCount - 1
                : 0,
            viewCount: note.viewCount,
            repostCount: note.repostCount,
            repostOf: note.repostOf,
            repostSourceAuthor: note.repostSourceAuthor,
            repostKind: note.repostKind,
            quoteContent: note.quoteContent,
            quoteOfTitle: note.quoteOfTitle,
            quoteOfContent: note.quoteOfContent,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
          );
        }
      });
      NoteStatsCenter.instance.report(_note!);
    } catch (e) {
      if (!mounted) return;
      _showToast(e.toString());
    }
  }

  void _promptLogin() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  Future<void> _toggleFavorite() async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    if (_favoriting) return;
    setState(() => _favoriting = true);
    try {
      final favorited =
          await CloudNotesService.instance.toggleNoteFavorite(widget.noteId);
      if (!mounted) return;
      setState(() => _favoriting = false);
      _showToast(favorited ? '已收藏' : '已取消收藏');
    } catch (e) {
      if (!mounted) return;
      setState(() => _favoriting = false);
      _showToast(e.toString());
    }
  }

  /// 是否自己的内容：优先用 currentUser，会话恢复竞态窗口（currentUser 暂为 null）
  /// 时用本地缓存 uid 兜底，避免自己的帖子误显示「关注/屏蔽」菜单。
  bool _isOwn(String? ownerUserId) {
    if (ownerUserId == null || ownerUserId.isEmpty) return false;
    final me = AuthService.instance.currentUser.value;
    if (me != null && ownerUserId == me.id) return true;
    final cachedUid = AuthService.instance.cachedUserId;
    return cachedUid != null && ownerUserId == cachedUid;
  }

  /// 从本地读取置顶帖/回复 id 列表（与「我的」页共用同一份记录）。
  Future<void> _loadPinnedIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _pinnedIds
          ..clear()
          ..addAll(prefs.getStringList(_pinnedKey) ?? const []);
      });
    } catch (_) {}
  }

  /// 置顶/取消置顶（本地保存，重启后仍生效）。
  Future<void> _togglePin(PlazaNote note) async {
    final wasPinned = _pinnedIds.contains(note.id);
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_pinnedKey) ?? [];
      if (wasPinned) {
        list.remove(note.id);
        _pinnedIds.remove(note.id);
      } else {
        list.add(note.id);
        _pinnedIds.add(note.id);
      }
      await prefs.setStringList(_pinnedKey, list);
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
    _showToast(wasPinned ? '已取消置顶' : '已置顶');
  }

  Future<void> _repost() async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    if (_reposting) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text('转发到菩提空间',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            Divider(height: 1, color: _border),
            _repostItem(
                ctx, 'direct', Icons.repeat_rounded, '直接转发', '原样分享这条笔记'),
            _repostItem(ctx, 'quote', Icons.format_quote_rounded, '引用转发',
                '写下你的感想，并带上原笔记'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'quote') {
      await _quoteRepost();
    } else {
      await _doRepost('');
    }
  }

  Widget _repostItem(BuildContext ctx, String value, IconData icon,
      String title, String subtitle) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: _primaryLight),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 15, color: _text)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(fontSize: 12, color: _textHint)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _quoteRepost() async {
    final quote = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const SheetTextInput(
        title: '引用转发',
        hint: '写点自己的感想…',
        maxLength: 500,
        minLines: 2,
        maxLines: 3,
        confirmText: '转发',
      ),
    );
    if (quote == null || !mounted) return;
    await _doRepost(quote);
  }

  Future<void> _doRepost(String quote) async {
    if (_reposting) return;
    setState(() => _reposting = true);
    try {
      await CloudNotesService.instance.repostNote(widget.noteId,
          quote: quote, kind: quote.isEmpty ? 'forward' : 'quote');
      if (!mounted) return;
      // 转发成功后本地立即 +1 并广播，详情页与 Feed 数字同步刷新。
      setState(() {
        _reposting = false;
        if (_note != null) {
          final note = _note!;
          _note = PlazaNote(
            id: note.id,
            ownerUserId: note.ownerUserId,
            title: note.title,
            content: note.content,
            authorName: note.authorName,
            authorAccount: note.authorAccount,
            authorVerified: note.authorVerified,
            visibility: note.visibility,
            status: note.status,
            likeCount: note.likeCount,
            commentCount: note.commentCount,
            viewCount: note.viewCount,
            repostCount: note.repostCount + 1,
            repostOf: note.repostOf,
            repostSourceAuthor: note.repostSourceAuthor,
            repostKind: note.repostKind,
            quoteContent: note.quoteContent,
            quoteOfTitle: note.quoteOfTitle,
            quoteOfContent: note.quoteOfContent,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
          );
        }
      });
      NoteStatsCenter.instance.report(_note!);
      // 转发后停留在当前笔记详情页，不跳转到转发后的新笔记。
      _showToast(quote.isEmpty ? '已转发到菩提空间' : '已引用转发到菩提空间');
    } catch (e) {
      if (!mounted) return;
      setState(() => _reposting = false);
      _showToast(e.toString());
    }
  }

  Future<void> _share() async {
    final note = _note;
    if (note == null) return;
    final plain = NoteSutraLinks.plainText(note.content);
    final text =
        '${plain.length > 120 ? '${plain.substring(0, 120)}…' : plain}\n'
        '———来自【燃灯】App · ${note.authorName} 的笔记分享\n'
        '燃一盏灯，看见自己，照亮别人\n'
        '点击进入八千大藏经世界\n'
        '下载链接：';
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (e) {
      if (!mounted) return;
      _showToast('分享失败：$e');
    }
  }

  void _showToast(String text) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final topInset = MediaQuery.of(ctx).padding.top;
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: EdgeInsets.only(top: topInset + kToolbarHeight + 10),
            child: Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: _primary,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (entry.mounted) entry.remove();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: Text('笔记详情',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      body: _buildBody(),
      // 右下角评论浮动按钮：与主页「新建」同款尺寸（素白为黑底），白色评论图标。
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 62),
        child: SizedBox(
          width: 42,
          height: 42,
          child: FloatingActionButton(
            onPressed: _openCommentSheet,
            heroTag: 'detail_comment_fab',
            // 素白外观下改黑色底；暖黄保持青绿。
            backgroundColor: AppPalette.instance.isPlain
                ? const Color(0xFF1A1A1A)
                : const Color(0xFF71867A),
            elevation: 8,
            highlightElevation: 12,
            shape: const CircleBorder(),
            child: ColorFiltered(
              colorFilter:
                  const ColorFilter.mode(Colors.white, BlendMode.srcIn),
              child: Image.asset('assets/images/ic_comment.png',
                  width: 21, height: 21),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const AppLoadingIndicator(
        message: '正在加载帖子...',
      );
    }
    if (_error || _note == null) {
      return AppLoadError(
        onRetry: _load,
      );
    }
    final note = _note!;
    final liked = CloudNotesService.instance.likedNoteIds.contains(note.id);
    // 评论与回复统一列表（回复流程双写时按同作者/同内容/时间相近去重）。
    final entries = _buildDetailEntries();
    final showAll = _commentsShowAll || entries.length <= 2;
    final visibleEntries =
        showAll ? entries : entries.sublist(0, 2);
    // 回复帖模式：独立 CustomScrollView 布局——回复节点所在 sliver 设为
    // center 锚点（滚动零点），祖先链放在锚点之前的负偏移区：进入即回复贴顶，
    // 祖先下滑才可见；不依赖测量/跳转，网络时机与内容高度都不会破坏定位。
    if (_isReplyThreadNote(note)) {
      return _buildReplyThreadBody(
        note: note,
        liked: liked,
        entries: entries,
        visibleEntries: visibleEntries,
        showAll: showAll,
      );
    }
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: _detailScroll,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            children: [
              // 头像在左，昵称/角标/内容/引用框都在头像右侧，与首页帖子对齐。
              // 公告帖：与话题页「发起人」帖同款，顶部帖子用圆角卡片
              // 包裹（右上角已带「公告」标签）。
              _wrapAnnouncementPost(
                  note,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // X 式转发角标（最顶部，与内容列对齐）
                      if (note.repostOf.isNotEmpty &&
                          note.repostKind != 'reply') ...[
                        Padding(
                          padding: const EdgeInsets.only(left: 32),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.repeat, size: 12, color: Color(0xFF8C8C8C)),
                              const SizedBox(width: 4),
                              Text('你已转帖',
                                  style: TextStyle(
                                      fontSize: 12, color: Color(0xFF8C8C8C))),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                      Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        final uid = note.ownerUserId;
                        if (uid.isNotEmpty) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => UserSpacePage(
                                    userId: uid,
                                    userName: note.authorName)),
                          );
                        }
                      },
                      child: UserAvatar(userId: note.ownerUserId, radius: 22),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildUserNameRow(note),
                          if (note.content.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            // 读经笔记分享帖：结构化渲染。
                            if (ReadingNotePost.isReadingNote(note.content))
                              ReadingNotePostView(
                                note: ReadingNotePost.parse(note.content)!,
                                noteId: note.id,
                                sutraLibrary: _sutraLib,
                              )
                            else
                            // 根帖长内容折叠：默认 8 行，超长时「显示更多」展开。
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final noteExpanded = _noteContentExpanded;
                                final tp = TextPainter(
                                  text: TextSpan(
                                    text: note.content,
                                    style: TextStyle(
                                        fontSize: 16,
                                        color: _text,
                                        height: 1.75),
                                  ),
                                  maxLines: 8,
                                  ellipsis: '…',
                                  textDirection: TextDirection.ltr,
                                )..layout(maxWidth: constraints.maxWidth);
                                final overflow = tp.didExceedMaxLines;
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    buildPostRichText(
                                      note.content,
                                      style: TextStyle(
                                          fontSize: 16,
                                          color: _text,
                                          height: 1.75),
                                      library: _sutraLib,
                                      multiVolumeBases: NoteSutraCatalog
                                          .cachedMultiVolumeBases,
                                      onUserTap: (uid) {
                                        if (uid.isNotEmpty) {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                                builder: (_) =>
                                                    UserSpacePage(
                                                        userId: uid)),
                                          );
                                        }
                                      },
                                      onSutraTap: (title, filePath) {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) =>
                                                  SutraDiscussionPage(
                                                      title: title,
                                                      filePath: filePath)),
                                        );
                                      },
                                      onTopicTap: (topic) {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) =>
                                                  TopicPage(topic: topic)),
                                        );
                                      },
                                      maxLines: noteExpanded ? null : 8,
                                      overflow: noteExpanded
                                          ? null
                                          : TextOverflow.ellipsis,
                                    ),
                                    if (overflow && !noteExpanded)
                                      GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: _toggleNoteContent,
                                        child: const Padding(
                                          padding: EdgeInsets.only(top: 4),
                                          child: Text('显示更多',
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  color: Color(0xFF70867A))),
                                        ),
                                      ),
                                    if (noteExpanded)
                                      GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: _toggleNoteContent,
                                        child: const Padding(
                                          padding: EdgeInsets.only(top: 4),
                                          child: Text('收起',
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  color: Color(0xFF70867A))),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ],
                          // 与首页帖子同款时间戳：内容与引用框之间。
                          const SizedBox(height: 6),
                          Text(_feedTime(note.createdAt),
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF8C8C8C))),
                          if (note.repostOf.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            QuoteBox(note: note),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                      // 公告帖：四个指标（讨论/转发/喜欢/阅读）一并收进白色卡片内。
                      if (_isAnnouncementNote(note)) ...[
                        const SizedBox(height: 10),
                        _buildActionsRow(note, liked),
                      ],
                    ],
                  ),
                ),
              // 普通帖：操作行保持卡片外原样式；公告帖已在白卡内渲染，避免重复两排。
              if (!_isAnnouncementNote(note)) ...[
                const SizedBox(height: 8),
                _buildActionsRow(note, liked),
              ],
              // 原贴（含操作行）与下面的评论用分割线分开；评论区两种布局共用。
              ..._buildCommentsWidgets(
                  entries: entries,
                  visibleEntries: visibleEntries,
                  showAll: showAll),
            ],
          ),
        ),
      ],
    );
  }

  /// 分割线以下的评论区部件：普通帖（ListView）与回复帖（CustomScrollView）
  /// 两种详情布局共用同一份，保证样式一致。
  List<Widget> _buildCommentsWidgets({
    required List<_DetailEntry> entries,
    required List<_DetailEntry> visibleEntries,
    required bool showAll,
  }) {
    return [
      const SizedBox(height: 12),
      Divider(height: 1, color: _border),
      const SizedBox(height: 14),
      Row(
        children: [
          Text('评论',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: _text)),
          const SizedBox(width: 4),
          Text('${entries.length}条',
              style: TextStyle(fontSize: 13, color: AppPalette.p.textSec)),
        ],
      ),
      const SizedBox(height: 10),
      if (visibleEntries.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Text('还没有评论，来说两句吧',
                style: TextStyle(fontSize: 13, color: _textHint)),
          ),
        )
      else
        for (var i = 0; i < visibleEntries.length; i++) ...[
          // 评论之间的分割线：配合每行上下内边距留出呼吸感，不拥挤。
          if (i > 0)
            Divider(height: 1, thickness: 0.5, color: AppPalette.p.divider),
          _buildDetailRow(visibleEntries[i]),
        ],
      if (!showAll)
        InkWell(
          onTap: () => setState(() => _commentsShowAll = true),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text('显示更多评论（${entries.length - 2}）',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF70867A))),
            ),
          ),
        ),
    ];
  }

  /// 回复帖详情布局（X 式「焦点帖贴顶」）：
  /// CustomScrollView 把回复节点（d）所在的 sliver 设为 [CustomScrollView.center]
  /// ——它就是滚动零点，天生贴住视口顶部；完整祖先链（c→b→a）放在锚点之前的
  /// 负偏移区，从上到下按 a→b→c 排列、节点间头像竖线相连，进入页面时整条链
  /// 都在屏幕外，向下滑动才逐渐露出（先 c，再连着上面 a 的 b…），
  /// 链条一路连接到 d 头顶的连接线残端。
  /// 定位由视口结构本身保证：不做任何测量/跳转，网络快慢、图片占位、
  /// 内容高度都不会破坏效果（此前 jumpTo 方案在真机上反复失效的根因即在此）。
  Widget _buildReplyThreadBody({
    required PlazaNote note,
    required bool liked,
    required List<_DetailEntry> entries,
    required List<_DetailEntry> visibleEntries,
    required bool showAll,
  }) {
    final ancestors = _threadAncestors;
    // 祖先链中最近一个被屏蔽的节点：该节点渲染为屏蔽占位，其上更早祖先不再渲染。
    // null（已删除占位）没有作者信息，不参与屏蔽判断。
    var chainEnd = ancestors.length;
    for (var i = 0; i < ancestors.length; i++) {
      final anc = ancestors[i];
      if (anc != null &&
          CloudNotesService.instance.blockedUserIds
              .contains(anc.ownerUserId)) {
        chainEnd = i + 1;
        break;
      }
    }
    final hasAbove = chainEnd > 0;
    final parent = hasAbove ? ancestors.first : null;

    // 首个渲染节点是否为占位行（null=已删除；链被截断处=已屏蔽）。
    // 占位行的尾线自带「端点—头像」6px 间距，焦点帖无需再画衔接段。
    final firstRenderedIsPlaceholder = hasAbove &&
        (ancestors.first == null || (chainEnd == 1 && ancestors.length > 1));
    // 首个渲染节点是真实帖：其连线直达行底，焦点帖用上方线段无缝续接。
    final focusConnectUp = hasAbove && !firstRenderedIsPlaceholder;

    // 祖先链 sliver：上溯结果已是自上而下（最老祖先在前），正序发射。
    // prevFlushLine 记录上一渲染节点的连线是否直达行底（真实帖）：
    // 是则本节点需 spaceAbove 撑出「线端点—头像」6px 间距；占位行自带。
    final ancestorSlivers = <Widget>[];
    var prevFlushLine = false;
    for (var i = 0; i < chainEnd; i++) {
      final anc = ancestors[i];
      final Widget row;
      if (anc == null) {
        row = deletedOriginalRow();
        prevFlushLine = false;
      } else if (i == chainEnd - 1 && chainEnd < ancestors.length) {
        row = blockedOriginalRow(context, anc);
        prevFlushLine = false;
      } else {
        row = ReplyThreadNode(
          note: anc,
          connectDown: true,
          showMetrics: true,
          spaceAbove: prevFlushLine,
          onMore: _showUserMenu,
          onOpenDetail: _openThreadNoteDetail,
        );
        prevFlushLine = true;
      }
      ancestorSlivers.add(SliverToBoxAdapter(
        child: Padding(
          // 首行留 12px 呼吸；其余上下零缝：连线端点/占位尾线的 6px 间距
          // 都在节点内部处理，跨 sliver 才能精确衔接。
          padding: EdgeInsets.fromLTRB(16, i == 0 ? 12 : 0, 16, 0),
          child: row,
        ),
      ));
    }
    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            controller: _detailScroll,
            center: _bCenterKey,
            slivers: [
              // —— 负偏移区：祖先链。offset=0 时完全在屏幕外，下滑可见。——
              ...ancestorSlivers,
              // —— 零点：回复节点（d）所在 sliver，天生贴住视口顶部。——
              SliverToBoxAdapter(
                key: _bCenterKey,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, hasAbove ? 0 : 12, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ReplyThreadNode(
                        note: note,
                        showMenu: true,
                        showMetrics: false,
                        // 上方线段：衔接上一真实节点的直达行底连线（段顶端贴线、
                        // 与头像留 6px）；上一节点是占位行时其尾线已自带间距，
                        // 不画段。点击打开紧邻父帖详情。
                        connectUp: focusConnectUp,
                        onConnectUpTap: focusConnectUp && parent != null
                            ? () => _openThreadNoteDetail(parent)
                            : null,
                        // X 式紧凑祖先预览：「回复@父帖账号」，点击直达父帖详情。
                        ancestorAccount: parent?.authorAccount,
                        onAncestorTap: parent == null
                            ? null
                            : () => _openThreadNoteDetail(parent),
                        onMore: (n) => n.id == note.id
                            ? _showReplyNodeMenu(n)
                            : _showUserMenu(n),
                        onOpenDetail: (n) {
                          if (n.id != note.id) _openThreadNoteDetail(n);
                        },
                      ),
                      // 回复帖不会是公告：操作行保持卡片外原样式。
                      const SizedBox(height: 8),
                      _buildActionsRow(note, liked),
                    ],
                  ),
                ),
              ),
              // —— 正偏移区：分割线 + 评论区。——
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ..._buildCommentsWidgets(
                          entries: entries,
                          visibleEntries: visibleEntries,
                          showAll: showAll),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 打开连贴中另一篇帖子（原帖 a 或父回复 b）的详情页。
  void _openThreadNoteDetail(PlazaNote n) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: n.id)),
    );
  }

  /// 拉取本帖的回复帖列表（与评论合并统一展示）。
  /// 服务端 getNoteReplies 递归返回所有后代；本页只展示直接回复，
  /// 更深层级在各自回复的详情页查看（c 在 b 的详情页，不与 b 同级）。
  Future<void> _loadReplies() async {
    if (_repliesLoading) return;
    _repliesLoading = true;
    try {
      final (list, _) = await CloudNotesService.instance
          .getNoteReplies(widget.noteId, pageSize: 100);
      if (!mounted) return;
      setState(() => _replies = list);
      // 回复作者资料后台拉取（账号/认证/阅藏进度），补齐服务端缺失的字段。
      final authorIds = <String>{
        for (final r in list)
          if (r.ownerUserId.isNotEmpty) r.ownerUserId,
      };
      final newIds = authorIds
          .where((id) => !_commentAuthorProfiles.containsKey(id))
          .toList();
      if (newIds.isNotEmpty) {
        unawaited(_fetchCommentProfiles(newIds.toSet()));
      }
    } catch (_) {
      // 拉取失败静默：评论仍正常展示。
    } finally {
      _repliesLoading = false;
    }
  }

  /// 拉取评论/回复作者资料（账号/认证/阅藏进度），合并进 [_commentAuthorProfiles]。
  /// 后台预取：不阻塞首屏。服务端 getUserProfiles 要扫 notes 表算加入时间，
  /// 数据多时可能超过默认 8 秒超时，这里放宽到 25 秒并带一次失败重试，
  /// 保证最终能补齐账号，避免 @账号 一直不显示。
  Future<void> _fetchCommentProfiles(Set<String> ids) async {
    if (ids.isEmpty) return;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final profiles = await CloudNotesService.instance
            .getUserProfiles(ids.toList(),
                timeout: const Duration(seconds: 25));
        if (!mounted) return;
        setState(() {
          // 合并而非清空：_loadReplies 也会往此 Map 写入回复作者资料，
          // clear 会清掉回复作者数据导致回复帖账号再次丢失。
          _commentAuthorProfiles
              .addAll({for (final p in profiles) p.id: p});
        });
        return;
      } catch (_) {
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 700));
        }
      }
    }
  }

  /// 评论与回复合并为统一列表（按时间正序，位置稳定不跳动）：
  /// 回复流程会同时生成「评论 + 回复帖」两条记录，同作者/同内容/3 秒内的
  /// 视为同一条消息，保留信息更全的回复帖。
  /// 只合并直接回复；对回复的回复（c 回复 b）不在本页展示，
  /// 点击该回复进入它的详情页查看（层级：a 页看 b，b 页看 c）。
  List<_DetailEntry> _buildDetailEntries() {
    _commentToReplyId.clear();
    // 后代映射：repostOf -> 子回复（本页只展示直接回复，深层在各自详情页）。
    final children = <String, List<PlazaNote>>{};
    for (final r in _replies) {
      children.putIfAbsent(r.repostOf, () => []).add(r);
    }
    // 去重：评论与同作者/同内容/3 秒内的直接回复视为同一条消息。
    final direct = children[widget.noteId] ?? const <PlazaNote>[];
    final dupedComments = <String>{};
    for (final c in _comments) {
      for (final r in direct) {
        if (r.ownerUserId == c.authorId &&
            r.content == c.content &&
            (r.createdAt - c.createdAt).abs() <= 3000) {
          dupedComments.add(c.id);
          _commentToReplyId[c.id] = r.id;
          break;
        }
      }
    }
    final entries = <_DetailEntry>[
      for (final c in _comments)
        if (!dupedComments.contains(c.id)) _DetailEntry.fromComment(c),
      for (final r in direct) _DetailEntry.fromReply(r),
    ];
    entries.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    // 从通知进入时：把目标评论/回复排到列表第一条。
    final target = widget.scrollToReplyId;
    if (target != null) {
      final idx = entries.indexWhere(
          (e) => e.id == target || _commentToReplyId[target] == e.id);
      if (idx > 0) {
        final e = entries.removeAt(idx);
        entries.insert(0, e);
      }
    }
    return entries;
  }


  /// 展开/收起某条评论/回复的长内容全文。
  void _toggleContent(String entryId) {
    setState(() {
      if (!_expandedContentIds.remove(entryId)) {
        _expandedContentIds.add(entryId);
      }
    });
  }

  /// 展开/收起根帖长内容全文。
  void _toggleNoteContent() {
    setState(() => _noteContentExpanded = !_noteContentExpanded);
  }

  /// 评论/回复内容行：默认折叠为 5 行，超长时出现「显示更多」。
  /// [maxWidth] 为内容区实际宽度（调用处 LayoutBuilder 提供），用于测溢出。
  Widget _buildCommentContent(String content, _DetailEntry e,
      TextStyle contentStyle, double maxWidth) {
    final expanded = _expandedContentIds.contains(e.id);
    final tp = TextPainter(
      text: TextSpan(text: content, style: contentStyle),
      maxLines: 5,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    final overflow = tp.didExceedMaxLines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(content,
            maxLines: expanded ? null : 5,
            overflow: expanded ? null : TextOverflow.ellipsis,
            style: contentStyle),
        if (overflow && !expanded)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggleContent(e.id),
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
            onTap: () => _toggleContent(e.id),
            child: const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('收起',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF70867A))),
            ),
          ),
      ],
    );
  }

  /// 评论节点三点菜单：收藏笔记/分享笔记（作用于原贴）；自己或帖主可删除，他人可关注/屏蔽。
  Future<void> _showCommentMenu(PlazaComment c) async {
    final me = AuthService.instance.currentUser.value;
    if (me == null || c.authorId.isEmpty) return;
    final favorited = _note != null &&
        CloudNotesService.instance.favoriteNoteIds.contains(_note!.id);
    final canDelete = _isOwn(c.authorId) || _isOwn(_note?.ownerUserId);
    // 展示昵称优先用预取资料（存储的 authorName 可能是"同修"或已过期）。
    final p = _commentAuthorProfiles[c.authorId];
    final menuName = (c.authorName.isEmpty || c.authorName == '同修')
        ? ((p?.name.isNotEmpty ?? false) ? p!.name : c.authorName)
        : c.authorName;
    if (!canDelete) {
      await _showNoteActionsAndUserMenu(
        userId: c.authorId,
        nickname: menuName,
        favorited: favorited,
        onFavorite: _toggleFavorite,
        onShare: _share,
      );
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text(menuName,
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            Divider(height: 1, color: _border),
            postMenuItem(
                ctx,
                'favorite',
                favorited
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                favorited ? '取消收藏' : '收藏笔记'),
            postMenuItem(ctx, 'share', Icons.share_rounded, '分享笔记'),
            postMenuItem(ctx, 'delete', Icons.delete_outline, '删除评论'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'favorite') {
      await _toggleFavorite();
    } else if (choice == 'share') {
      await _share();
    } else if (choice == 'delete') {
      await _deleteComment(c);
    }
  }

  /// 他人帖子/评论/回复的三点菜单：收藏笔记 + 分享笔记 + 关注/屏蔽该用户。
  /// 收藏与分享的目标由调用方通过回调指定（评论作用于原贴，回复作用于该回复帖）。
  Future<void> _showNoteActionsAndUserMenu({
    required String userId,
    required String nickname,
    required bool favorited,
    required VoidCallback onFavorite,
    required VoidCallback onShare,
  }) async {
    final me = AuthService.instance.currentUser.value;
    if (me == null || userId.isEmpty || _isOwn(userId)) return;
    final following =
        CloudNotesService.instance.followingUserIds.contains(userId);
    final blocked =
        CloudNotesService.instance.blockedUserIds.contains(userId);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text(nickname,
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            Divider(height: 1, color: _border),
            postMenuItem(
                ctx,
                'favorite',
                favorited
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                favorited ? '取消收藏' : '收藏笔记'),
            postMenuItem(ctx, 'share', Icons.share_rounded, '分享笔记'),
            postMenuItem(ctx, following ? 'unfollow' : 'follow',
                Icons.person_add_alt, following ? '取消关注' : '关注该用户'),
            postMenuItem(ctx, blocked ? 'unblock' : 'block', Icons.block_outlined,
                blocked ? '取消屏蔽' : '屏蔽该用户'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'favorite') {
      onFavorite();
      return;
    }
    if (choice == 'share') {
      onShare();
      return;
    }
    try {
      if (choice == 'follow' || choice == 'unfollow') {
        final ok = await CloudNotesService.instance.toggleFollow(userId);
        if (!mounted) return;
        setState(() {});
        _showToast(ok ? '已关注' : '已取消关注');
      } else if (choice == 'block') {
        final ok = await CloudNotesService.instance.toggleBlockUser(userId);
        if (!mounted) return;
        _showToast(ok ? '已屏蔽，该用户笔记不再展示' : '已取消屏蔽');
        if (ok) Navigator.pop(context);
      } else if (choice == 'unblock') {
        final ok = await CloudNotesService.instance.toggleBlockUser(userId);
        if (!mounted) return;
        setState(() {});
        _showToast(ok ? '已屏蔽' : '已取消屏蔽');
      }
    } catch (e) {
      if (!mounted) return;
      _showToast(e.toString());
    }
  }

  /// 评论行：头像 + 昵称/认证/@账户/阅藏进度 + 内容 + 时间 + 四个指标 + 三点菜单
  /// （收藏/分享已并入三点菜单）。
  /// 嵌套回复不在此展示：点击评论/回复内容进入它自己的详情页查看其子回复
  /// （b 的子回复 c 在 b 的详情页，层级逐级展开）。
  Widget _buildDetailRow(_DetailEntry e) {
    final me = AuthService.instance.currentUser.value;
    final comment = e.comment;
    final reply = e.reply;
    // 补齐评论/回复作者账号/认证/阅藏进度（服务端缺失时用预取资料 / 自己的本地数据）。
    // 评论与回复统一用 authorId 查预取资料，避免回复帖丢失账号兜底。
    final profile = _commentAuthorProfiles[e.authorId];
    final isOwn = me != null && e.authorId == me.id;
    final verified = e.verified ||
        (profile?.verified ?? false) ||
        (isOwn && _myVerified);
    final account = e.account.isNotEmpty
        ? e.account
        : ((profile?.account.isNotEmpty ?? false)
            ? profile!.account
            : (isOwn ? _myAccount : ''));
    // 展示昵称：存储名是"同修"/空占位时，用云端预取资料里的真实昵称纠正
    // （历史评论存的是默认占位符；真实存储名保持不变）。
    final displayName = (e.authorName.isEmpty || e.authorName == '同修')
        ? ((profile?.name.isNotEmpty ?? false) ? profile!.name : e.authorName)
        : e.authorName;
    // 阅藏进度百分比：自己的用本地实时统计，他人的用云端数据（评论取预取资料，
    // 回复帖优先取帖子自带数据）。
    final pct = postCanonPercent(
      isSelf: isOwn,
      cloudRead: reply != null
          ? reply.canonRead
          : (profile?.canonRead ?? 0),
      cloudTotal: reply != null
          ? reply.canonTotal
          : (profile?.canonTotal ?? 0),
    );
    final contentStyle = TextStyle(fontSize: 15, color: _text, height: 1.6);
    return Padding(
      // 上下各 12px：与评论间分割线配合，间距舒适不拥挤。
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              final uid = e.authorId;
              if (uid.isNotEmpty) {
                Navigator.push(
                  context,
                    MaterialPageRoute(
                        builder: (_) => UserSpacePage(
                            userId: uid, userName: displayName)),
                );
              }
            },
            child: UserAvatar(userId: e.authorId, radius: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 昵称行：昵称 + 认证 + @账户名 + 阅藏进度（时间戳在内容下方）。
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: _text)),
                          ),
                          if (verified) ...[
                            const SizedBox(width: 3),
                            const Icon(Icons.verified,
                                size: 14, color: Color(0xFF70867A)),
                          ],
                          if (account.isNotEmpty) ...[
                            const SizedBox(width: 3),
                            Flexible(
                              // 点击 @账户名 进入该用户个人主页（按下时变暗）。
                              child: AccountLink(
                                account: account,
                                onTap: () {
                                  if (e.authorId.isNotEmpty) {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => UserSpacePage(
                                              userId: e.authorId,
                                              userName: displayName)),
                                    );
                                  }
                                },
                              ),
                            ),
                          ],
                          if (pct.isNotEmpty) ...[
                            const SizedBox(width: 3),
                            const Text('·',
                                style: TextStyle(
                                    fontSize: 12, color: Color(0xFF8C8C8C))),
                            const SizedBox(width: 2),
                            Flexible(
                              child: Text(pct,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF8C8C8C))),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // 每条评论/回复统一三点菜单（与上方帖子右侧对齐）。
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => reply != null
                          ? _showReplyNodeMenu(reply)
                          : _showCommentMenu(comment!),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.more_horiz,
                            size: 22, color: Color(0xFF8C8C8C)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // 内容 + 时间戳整块（昵称行下方到指标行上方）可点击，
                // 进入该评论/回复自己的详情页；指标行有各自按钮，不在此区域内。
                // SizedBox 撑满整行，评论字数少时点击留白同样可进入。
                SizedBox(
                  width: double.infinity,
                  child: InkWell(
                    onTap: () => _openEntryDetail(e),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 长内容折叠 + 「显示更多」展开（内容区宽度由 LayoutBuilder 提供）。
                        LayoutBuilder(
                          builder: (context, constraints) =>
                              _buildCommentContent(e.content, e, contentStyle,
                                  constraints.maxWidth),
                        ),
                        // 时间戳：点击同样进入该条目自己的详情页。
                        const SizedBox(height: 6),
                        PostTimeLink(
                          text: _feedTime(e.createdAt),
                          onTap: () => _openEntryDetail(e),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                reply != null
                    ? _buildReplyActionsRow(reply)
                    : _buildCommentActionsRow(comment!),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 评论的操作行：与个人主页帖子同款四个指标（评论/转发/点赞/阅读），
  /// 第一个指标与内容左对齐，间距固定；收藏与分享已移至评论右上角三点菜单。
  Widget _buildCommentActionsRow(PlazaComment c) {
    final liked = _likedCommentIds.contains(c.id);
    return buildStatsRow(
      commentCount: 0,
      repostCount: 0,
      likeCount: c.likeCount,
      viewCount: 0,
      liked: liked,
      onComment: () => replyToThisNote(),
      onRepost: _reposting ? null : _repost,
      onLike: _commentLiking.contains(c.id) ? null : () => _toggleCommentLike(c),
    );
  }

  /// 点击回复节点的操作行：与个人主页帖子同款四个指标，实时监听指标广播。
  /// 评论按钮对「该回复」发起回复：新回复挂到它下方（它的详情页内展示），
  /// 不与本回复同级显示。
  Widget _buildReplyActionsRow(PlazaNote reply) {
    return ListenableBuilder(
      listenable: NoteStatsCenter.instance,
      builder: (context, _) {
        final n = NoteStatsCenter.instance.latest(reply.id) ?? reply;
        final liked = CloudNotesService.instance.likedNoteIds.contains(n.id);
        return buildStatsRow(
          commentCount: n.commentCount,
          repostCount: n.repostCount,
          likeCount: n.likeCount,
          viewCount: n.viewCount,
          liked: liked,
          onComment: () => replyToNote(context, n, (_) => _loadReplies()),
          onRepost: () => forwardNote(context, n, (_) => _loadReplies()),
          onLike: () => _toggleReplyLike(n),
        );
      },
    );
  }

  /// 点击评论内容/时间戳进入该条目自己的详情页：
  /// 回复帖有自己的连贴详情页（原贴在上 + 回复在下 + 它的直接子回复）；
  /// 普通评论进入本帖详情并把它排到第一条。
  void _openEntryDetail(_DetailEntry e) {
    final replyNote = e.reply;
    final noteId = replyNote != null ? replyNote.id : _note?.id;
    if (noteId == null || noteId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NoteDetailPage(
          noteId: noteId,
          scrollToReplyId: replyNote != null ? null : e.id,
        ),
      ),
    );
  }

  /// 对当前详情页的帖子发起回复（评论行指标按钮入口）：
  /// 与右下角浮动按钮同口径——在本页输入，回复作为本帖的直接回复展示。
  void replyToThisNote() {
    final note = _note;
    if (note == null) return;
    replyToNote(context, note, (_) async {
      await _loadReplies();
      // 本帖评论量 +1（回复双写会增加评论量），同步刷新指标行。
      if (!mounted) return;
      setState(() {
        _note = _copyNote(note, commentCount: note.commentCount + 1);
      });
      NoteStatsCenter.instance.report(_note!);
    });
  }

  /// 回复节点三点菜单：收藏笔记/分享笔记（作用于该回复）；自己可置顶/编辑/删除，他人可关注/屏蔽。
  Future<void> _showReplyNodeMenu(PlazaNote note) async {
    final me = AuthService.instance.currentUser.value;
    // 展示昵称优先用预取资料（存储的 authorName 可能是"同修"或已过期）。
    final p = _commentAuthorProfiles[note.ownerUserId];
    final menuName = (note.authorName.isEmpty || note.authorName == '同修')
        ? ((p?.name.isNotEmpty ?? false) ? p!.name : note.authorName)
        : note.authorName;
    if (!_isOwn(note.ownerUserId)) {
      if (me != null && note.ownerUserId.isNotEmpty) {
        final favorited =
            CloudNotesService.instance.favoriteNoteIds.contains(note.id);
        await _showNoteActionsAndUserMenu(
          userId: note.ownerUserId,
          nickname: menuName,
          favorited: favorited,
          onFavorite: () => _toggleReplyFavorite(note),
          onShare: () => _shareReply(note),
        );
        if (mounted) _loadReplies();
      }
      return;
    }
    final favorited =
        CloudNotesService.instance.favoriteNoteIds.contains(note.id);
    final pinned = _pinnedIds.contains(note.id);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text(menuName,
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            Divider(height: 1, color: _border),
            postMenuItem(
                ctx,
                'favorite',
                favorited
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                favorited ? '取消收藏' : '收藏笔记'),
            postMenuItem(ctx, 'share', Icons.share_rounded, '分享笔记'),
            postMenuItem(ctx, 'pin', Icons.push_pin_outlined,
                pinned ? '取消置顶' : '置顶'),
            postMenuItem(ctx, 'edit', Icons.edit_outlined, '编辑'),
            postMenuItem(ctx, 'delete', Icons.delete_outline, '删除'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'favorite') {
      await _toggleReplyFavorite(note);
    } else if (choice == 'share') {
      await _shareReply(note);
    } else if (choice == 'pin') {
      await _togglePin(note);
    } else if (choice == 'edit') {
      await _editReplyNote(note);
    } else if (choice == 'delete') {
      await _deleteReplyNote(note);
    }
  }

  /// 编辑自己发布的回复内容。
  Future<void> _editReplyNote(PlazaNote note) async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SheetTextInput(
        title: '编辑回复',
        hint: '写下新的内容…',
        initialText: note.content,
        maxLength: 2000,
        minLines: 3,
        maxLines: 6,
        confirmText: '保存',
      ),
    );
    if (saved == null || saved.trim().isEmpty || !mounted) return;
    try {
      await CloudNotesService.instance
          .updateSharedNote(cloudId: note.id, content: saved.trim());
      if (!mounted) return;
      _showToast('已更新');
      await _loadReplies();
    } catch (e) {
      if (mounted) _showToast(e.toString());
    }
  }

  /// 删除自己发布的回复。云端会自动把它的子回复重挂到父帖，保持链路连通。
  Future<void> _deleteReplyNote(PlazaNote note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除回复',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: Text('删除后回复将从菩提空间移除，且无法恢复。确定删除吗？',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: _textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除',
                style: TextStyle(
                    color: Color(0xFFC0392B), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await CloudNotesService.instance.deleteCloudNote(note.id);
      if (!mounted) return;
      _showToast('已删除');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) _showToast(e.toString());
    }
  }

  /// 收藏/取消收藏回复帖：云端持久化，点亮状态随收藏列表刷新。
  Future<void> _toggleReplyFavorite(PlazaNote reply) async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    try {
      await CloudNotesService.instance.toggleNoteFavorite(reply.id);
      await CloudNotesService.instance.refreshFavoriteNoteIds();
      if (!mounted) return;
      setState(() {});
    } catch (_) {}
  }

  /// 分享回复帖内容。
  Future<void> _shareReply(PlazaNote reply) async {
    final plain = NoteSutraLinks.plainText(reply.content);
    final text =
        '${plain.length > 120 ? '${plain.substring(0, 120)}…' : plain}\n'
        '———来自【燃灯】App · ${reply.authorName} 的评论\n'
        '燃一盏灯，看见自己，照亮别人\n'
        '点击进入八千大藏经世界\n'
        '下载链接：';
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (e) {
      if (!mounted) return;
      _showToast('分享失败：$e');
    }
  }

  /// 点赞/取消点赞回复帖：云端持久化，点亮状态与数字随服务端返回更新。
  Future<void> _toggleReplyLike(PlazaNote reply) async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    try {
      final (liked, count) =
          await CloudNotesService.instance.toggleLike(reply.id);
      if (!mounted) return;
      final updated = _copyNote(reply, likeCount: count);
      NoteStatsCenter.instance.report(updated);
      setState(() {});
    } catch (e) {
      if (mounted) _showToast(e.toString());
    }
  }

  PlazaNote _copyNote(PlazaNote n, {int? likeCount, int? commentCount}) =>
      PlazaNote(
        id: n.id,
        ownerUserId: n.ownerUserId,
        title: n.title,
        content: n.content,
        authorName: n.authorName,
        authorAccount: n.authorAccount,
        authorVerified: n.authorVerified,
        visibility: n.visibility,
        status: n.status,
        likeCount: likeCount ?? n.likeCount,
        commentCount: commentCount ?? n.commentCount,
        viewCount: n.viewCount,
        repostCount: n.repostCount,
        repostOf: n.repostOf,
        repostSourceAuthor: n.repostSourceAuthor,
        repostSourceUserId: n.repostSourceUserId,
        repostKind: n.repostKind,
        quoteContent: n.quoteContent,
        quoteOfTitle: n.quoteOfTitle,
        quoteOfContent: n.quoteOfContent,
        createdAt: n.createdAt,
        updatedAt: n.updatedAt,
      );


  /// 点赞/取消点赞评论：云端持久化，点赞数与点亮状态随服务端返回更新。
  Future<void> _toggleCommentLike(PlazaComment c) async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    if (_commentLiking.contains(c.id)) return;
    setState(() => _commentLiking.add(c.id));
    try {
      final (liked, count) =
          await CloudNotesService.instance.toggleCommentLike(c.id);
      if (!mounted) return;
      setState(() {
        _commentLiking.remove(c.id);
        final idx = _comments.indexWhere((x) => x.id == c.id);
        if (idx >= 0) {
          _comments[idx] = c.copyWith(likeCount: count, likedByMe: liked);
        }
        if (liked) {
          _likedCommentIds.add(c.id);
        } else {
          _likedCommentIds.remove(c.id);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _commentLiking.remove(c.id));
      _showToast(e.toString());
    }
  }

  /// 是否公告帖：入口标记或云端 kind 字段任一命中即可。
  bool _isAnnouncementNote(PlazaNote note) =>
      widget.isAnnouncement || note.kind == 'announcement';

  /// 公告帖包裹：与话题页「发起人」帖同款圆角卡片（卡片底色，非纯白）；普通帖原样返回。
  /// 内边距上下放宽（14/12），避免帖子内容贴着卡片边缘显得被截断。
  Widget _wrapAnnouncementPost(PlazaNote note, Widget post) {
    if (!_isAnnouncementNote(note)) return post;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: post,
    );
  }

  /// 昵称行（不含头像）：昵称 + 认证 + @账户名 + 阅藏进度 + 三点菜单
  /// （时间戳在内容下方，与首页帖子一致；任一元素都不换行）。
  Widget _buildUserNameRow(PlazaNote note) {
    final me = AuthService.instance.currentUser.value;
    final isSelf = me != null && note.ownerUserId == me.id;
    // 阅藏进度百分比：自己的帖子用本地实时统计，他人的用云端数据（0% 也显示）。
    final postPct = postCanonPercent(
      isSelf: isSelf,
      cloudRead: note.canonRead,
      cloudTotal: note.canonTotal,
    );
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(isSelf ? me.displayName : note.authorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _text)),
              ),
              if (note.authorVerified) ...[
                const SizedBox(width: 3),
                const Icon(Icons.verified, size: 14, color: Color(0xFF70867A)),
              ],
              if (note.authorAccount.isNotEmpty) ...[
                const SizedBox(width: 3),
                Flexible(
                  // 点击 @账户名 进入该用户个人主页（按下时变暗）。
                  child: AccountLink(
                    account: note.authorAccount,
                    onTap: () {
                      if (note.ownerUserId.isNotEmpty) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => UserSpacePage(
                                  userId: note.ownerUserId,
                                  userName: note.authorName)),
                        );
                      }
                    },
                  ),
                ),
                // 阅藏进度百分比：灰色（与账户名同色系）。
                const SizedBox(width: 3),
                Text('·',
                    style: const TextStyle(
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
        // 公告帖：与话题页「发起人」标签同款样式（D3A069 包裹色 + 白字）。
        if (_isAnnouncementNote(note)) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppPalette.p.accent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('公告',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.white,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
        ],
        // 每个帖子都有三点菜单：自己的可编辑/删除，他人的可关注/屏蔽。
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _showUserMenu(note),
          child: Padding(
            padding: EdgeInsets.all(4),
            child: Icon(Icons.more_horiz, size: 22, color: _textSec),
          ),
        ),
      ],
    );
  }

  Future<void> _showUserMenu(PlazaNote note) async {
    final me = AuthService.instance.currentUser.value;
    if (me == null) {
      _promptLogin();
      return;
    }
    final favorited =
        CloudNotesService.instance.favoriteNoteIds.contains(note.id);
    if (_isOwn(note.ownerUserId)) {
      // 自己的帖子：收藏/分享 + 置顶/取消置顶 + 编辑/删除（不显示关注/屏蔽）。
      final pinned = _pinnedIds.contains(note.id);
      final choice = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: _card,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(note.authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: _text)),
                    ),
                    if (note.authorVerified) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.verified,
                          size: 15, color: Color(0xFF70867A)),
                    ],
                  ],
                ),
              ),
              Divider(height: 1, color: _border),
              _menuItem(
                  ctx,
                  'favorite',
                  favorited
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  favorited ? '取消收藏' : '收藏笔记'),
              _menuItem(ctx, 'share', Icons.share_rounded, '分享笔记'),
              _menuItem(ctx, 'pin', Icons.push_pin_outlined,
                  pinned ? '取消置顶' : '置顶'),
              _menuItem(ctx, 'edit', Icons.edit_outlined, '编辑'),
              _menuItem(ctx, 'delete', Icons.delete_outline, '删除'),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'favorite') {
        await _toggleFavorite();
      } else if (choice == 'share') {
        await _share();
      } else if (choice == 'pin') {
        await _togglePin(note);
      } else if (choice == 'edit') {
        await _editRootNote(note);
      } else if (choice == 'delete') {
        await _deleteRootNote(note);
      }
      return;
    }
    final following =
        CloudNotesService.instance.followingUserIds.contains(note.ownerUserId);
    final blocked =
        CloudNotesService.instance.blockedUserIds.contains(note.ownerUserId);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(note.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _text)),
                  ),
                  if (note.authorVerified) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.verified,
                        size: 15, color: Color(0xFF70867A)),
                  ],
                ],
              ),
            ),
            Divider(height: 1, color: _border),
            _menuItem(
                ctx,
                'favorite',
                favorited
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                favorited ? '取消收藏' : '收藏笔记'),
            _menuItem(ctx, 'share', Icons.share_rounded, '分享笔记'),
            _menuItem(
              ctx,
              following ? 'unfollow' : 'follow',
              Icons.person_add_alt,
              following ? '取消关注' : '关注该用户',
            ),
            _menuItem(
              ctx,
              blocked ? 'unblock' : 'block',
              Icons.block_outlined,
              blocked ? '取消屏蔽' : '屏蔽该用户',
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'favorite') {
      await _toggleFavorite();
      return;
    }
    if (choice == 'share') {
      await _share();
      return;
    }
    try {
      if (choice == 'follow' || choice == 'unfollow') {
        final ok =
            await CloudNotesService.instance.toggleFollow(note.ownerUserId);
        if (!mounted) return;
        setState(() {});
        _showToast(ok ? '已关注' : '已取消关注');
      } else if (choice == 'block') {
        final ok =
            await CloudNotesService.instance.toggleBlockUser(note.ownerUserId);
        if (!mounted) return;
        _showToast(ok ? '已屏蔽，该用户笔记不再展示' : '已取消屏蔽');
        if (ok) Navigator.pop(context);
      } else if (choice == 'unblock') {
        final ok =
            await CloudNotesService.instance.toggleBlockUser(note.ownerUserId);
        if (!mounted) return;
        setState(() {});
        _showToast(ok ? '已屏蔽' : '已取消屏蔽');
      }
    } catch (e) {
      if (!mounted) return;
      _showToast(e.toString());
    }
  }

  /// 编辑自己发布的帖子内容。
  Future<void> _editRootNote(PlazaNote note) async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SheetTextInput(
        title: '编辑帖子',
        hint: '写下新的内容…',
        initialText: note.content,
        maxLength: 2000,
        minLines: 3,
        maxLines: 6,
        confirmText: '保存',
      ),
    );
    if (saved == null || saved.trim().isEmpty || !mounted) return;
    try {
      await CloudNotesService.instance
          .updateSharedNote(cloudId: note.id, content: saved.trim());
      if (!mounted) return;
      _showToast('已更新');
      _load();
    } catch (e) {
      if (mounted) _showToast(e.toString());
    }
  }

  /// 删除自己发布的帖子。
  Future<void> _deleteRootNote(PlazaNote note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除帖子',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: Text('删除后帖子将从菩提空间移除，且无法恢复。确定删除吗？',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: _textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除',
                style: TextStyle(
                    color: Color(0xFFC0392B), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await CloudNotesService.instance.deleteCloudNote(note.id);
      if (!mounted) return;
      _showToast('已删除');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) _showToast(e.toString());
    }
  }

  Widget _menuItem(
      BuildContext ctx, String value, IconData icon, String label) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 18, color: _textSec),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontSize: 15, color: _text)),
          ],
        ),
      ),
    );
  }

  Widget _buildActionsRow(PlazaNote note, bool liked) {
    // 与个人主页帖子同款：第一个指标与内容左对齐，其余按固定间距排布。
    // 外层左缩进 54 = 头像 44 + 间距 10（与内容左缘一致，兼容单元格 2px 内边距）。
    return Padding(
      padding: const EdgeInsets.only(left: 54),
      child: buildStatsRow(
        commentCount: _comments.length,
        repostCount: note.repostCount,
        likeCount: note.likeCount,
        viewCount: note.viewCount,
        liked: liked,
        onComment: _openCommentSheet,
        onRepost: _reposting ? null : _repost,
        onLike: _liking ? null : _toggleLike,
      ),
    );
  }

  /// 与首页帖子同款时间格式：今天「今日x时」，今年「x月x日x时」，往年「x年x月x日x时」。
  String _feedTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '今日${t.hour}时';
    }
    if (t.year == now.year) return '${t.month}月${t.day}日${t.hour}时';
    return '${t.year}年${t.month}月${t.day}日${t.hour}时';
  }
}

/// 详情页评论/回复统一条目：评论与回复作为同一类消息统一展示。
class _DetailEntry {
  final String id;
  final String authorId;
  final String authorName;
  final bool verified;
  final String account;
  final String content;
  final int createdAt;
  final PlazaComment? comment;

  /// 回复帖条目（非空时该行按回复渲染：可点赞/回复/进入它的详情页）。
  final PlazaNote? reply;

  const _DetailEntry({
    required this.id,
    required this.authorId,
    required this.authorName,
    this.verified = false,
    this.account = '',
    required this.content,
    required this.createdAt,
    this.comment,
    this.reply,
  });

  factory _DetailEntry.fromComment(PlazaComment c) => _DetailEntry(
        id: c.id,
        authorId: c.authorId,
        authorName: c.authorName,
        verified: c.authorVerified,
        account: c.authorAccount,
        content: c.content,
        createdAt: c.createdAt,
        comment: c,
      );

  factory _DetailEntry.fromReply(PlazaNote n) => _DetailEntry(
        id: n.id,
        authorId: n.ownerUserId,
        authorName: n.authorName,
        verified: n.authorVerified,
        account: n.authorAccount,
        content: n.content,
        createdAt: n.createdAt,
        reply: n,
      );
}
