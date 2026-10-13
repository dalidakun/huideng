import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'reading_note_post.dart';

/// 单条备注的展示数据。
class _Thought {
  /// 云端备注 id；本地未分享备注为空串。
  final String noteId;
  final String text;

  /// 该备注针对的选中经文（可空，空表示针对整段）。
  final String quoted;

  /// 当前用户自己的这条备注（非空表示可编辑 / 删除）。
  final ParaNote? ownNote;

  /// 作者用户 id（仅用于合并当前用户自己的备注去重，不再展示）。
  final String authorUserId;

  const _Thought({
    required this.noteId,
    required this.text,
    this.quoted = '',
    this.ownNote,
    this.authorUserId = '',
  });

  factory _Thought.fromPlaza(PlazaNote n, String text, String quoted) => _Thought(
        noteId: n.id,
        text: text,
        quoted: quoted,
        authorUserId: n.ownerUserId,
      );

  _Thought withOwn(ParaNote note) => _Thought(
        noteId: noteId,
        text: text,
        quoted: quoted.isEmpty ? note.quoted : quoted,
        ownNote: note,
        authorUserId: authorUserId,
      );
}

/// 「段落备注」汇总底部弹层：列出该段经文下所有用户分享的备注，
/// 并附带当前用户自己在本段记录的备注（无论是否分享到菩提空间）。
///
/// 打开时从底部向上滑出，顶部只停在标题栏下方一个标题栏高度的位置
/// （`顶部安全区 + 2 倍标题栏高度`），且路由透明白色不遮挡：
/// 上方的经文仍清晰可见，也不会出现黑色蒙层。
/// 每条备注只展示「选中的经文字符 + 备注正文」；当前用户自己的备注
/// 额外提供「编辑 / 删除」入口。
class ParagraphThoughtsPage extends StatefulWidget {
  final String sutraTitle;
  final String paragraph;

  /// 经书 filePath（sutra key），用于拉取当前用户本段本地备注（回退用）。
  final String sutraKey;

  /// 当前段落在本经中的下标，用于匹配本地备注（回退用）。
  final int paragraphIndex;

  /// 当前用户本段全部备注的读取器（每次刷新重新读取，编辑后能反映最新）。
  final List<ParaNote> Function()? loadMyNotes;

  /// 编辑当前用户的一条备注（打开编辑页），返回后弹层会重新加载。
  final Future<void> Function(ParaNote note)? onEditNote;

  /// 删除当前用户的一条备注，返回后弹层会重新加载。
  final Future<void> Function(ParaNote note)? onDeleteNote;

  const ParagraphThoughtsPage({
    super.key,
    required this.sutraTitle,
    required this.paragraph,
    this.sutraKey = '',
    this.paragraphIndex = -1,
    this.loadMyNotes,
    this.onEditNote,
    this.onDeleteNote,
  });

  /// 打开该弹层时使用下滑渐显的过渡路由（底部抽屉效果）。
  /// 路由非不透明（opaque=false）、遮罩透明，顶部经文仍可见；
  /// 抽屉只占据到标题栏下方一个标题栏高度的位置。
  static Future<void> open(
    BuildContext context, {
    required String sutraTitle,
    required String paragraph,
    String sutraKey = '',
    int paragraphIndex = -1,
    List<ParaNote> Function()? loadMyNotes,
    Future<void> Function(ParaNote note)? onEditNote,
    Future<void> Function(ParaNote note)? onDeleteNote,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        barrierDismissible: true,
        pageBuilder: (_, __, ___) => ParagraphThoughtsPage(
          sutraTitle: sutraTitle,
          paragraph: paragraph,
          sutraKey: sutraKey,
          paragraphIndex: paragraphIndex,
          loadMyNotes: loadMyNotes,
          onEditNote: onEditNote,
          onDeleteNote: onDeleteNote,
        ),
        transitionsBuilder: (_, anim, __, child) {
          final topOffset =
              MediaQuery.of(context).padding.top + kToolbarHeight * 2;
          final full = MediaQuery.of(context).size.height;
          return Stack(
            children: [
              AnimatedBuilder(
                animation: anim,
                builder: (context, _) {
                  final t = Curves.easeOutCubic.transform(anim.value);
                  final top = topOffset + (full - topOffset) * (1 - t);
                  return Positioned(
                    left: 0,
                    right: 0,
                    top: top,
                    bottom: 0,
                    child: DecoratedBox(
                      // 顶部阴影与 AI 翻译弹层一致：黑色 18% 透明度、上抛 4px。
                      decoration: const BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                            top: Radius.circular(18)),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x2E000000),
                            blurRadius: 16,
                            offset: Offset(0, -4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(18)),
                        child: child,
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        },
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
      ),
    );
  }

  @override
  State<ParagraphThoughtsPage> createState() => _ParagraphThoughtsPageState();
}

class _ParagraphThoughtsPageState extends State<ParagraphThoughtsPage> {
  final List<_Thought> _thoughts = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  int _total = 0;
  String? _error;

  /// 折叠状态：key 为备注正文，true 表示展开全文。
  final Set<String> _expanded = {};

  /// 下拉关闭：手指向下拖动的距离。
  double _dragY = 0;

  @override
  void initState() {
    super.initState();
    _loadPage(reset: true);
  }

  List<ParaNote> _ownNotes() => widget.loadMyNotes?.call() ?? const <ParaNote>[];

  /// 解析读经笔记帖，仅保留「段原文」与当前段落一致的帖子。
  _Thought? _toThought(PlazaNote n) {
    final parsed = ReadingNotePost.parse(n.content);
    if (parsed == null || parsed.paragraph.trim() != widget.paragraph.trim()) {
      return null;
    }
    return _Thought.fromPlaza(
      n,
      parsed.noteText.isNotEmpty ? parsed.noteText : parsed.paragraph,
      parsed.paragraph,
    );
  }

  Future<void> _loadPage({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _page = 1;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final (list, hasMore, total) = await CloudNotesService.instance
          .getParagraphThoughts(widget.paragraph, page: _page, pageSize: 20);
      final thoughts = list.map(_toThought).whereType<_Thought>().toList();
      if (!mounted) return;

      final ownNotes = _ownNotes();
      setState(() {
        if (reset) {
          _thoughts
            ..clear()
            ..addAll(thoughts);
        } else {
          _thoughts.addAll(thoughts);
        }
        _mergeOwnNotes(ownNotes);
        _hasMore = hasMore;
        final localOwn = ownNotes
            .where((n) => n.text.trim().isNotEmpty && n.cloudId.isEmpty)
            .length;
        _total = total + localOwn;
        _page += 1;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (reset) {
          _error = e is CloudApiException
              ? e.message
              : (e.toString().replaceFirst('Exception: ', ''));
        }
      });
    }
  }

  /// 把当前用户自己的备注合并进列表：云端已有同 id / 同正文的标记为可编辑，
  /// 否则插入到最前（方便自己就近编辑）。
  void _mergeOwnNotes(List<ParaNote> ownNotes) {
    final me = AuthService.instance.currentUser.value;
    if (me == null) return;
    for (final n in ownNotes) {
      final text = n.text.trim();
      if (text.isEmpty) continue;
      final cloudId = n.cloudId;
      var idx = -1;
      if (cloudId.isNotEmpty) {
        idx = _thoughts.indexWhere((t) => t.noteId == cloudId);
      }
      if (idx < 0) {
        idx = _thoughts.indexWhere((t) =>
            t.authorUserId == me.id &&
            t.text.replaceAll(RegExp(r'\s'), '') ==
                text.replaceAll(RegExp(r'\s'), ''));
      }
      if (idx >= 0) {
        _thoughts[idx] = _thoughts[idx].withOwn(n);
      } else {
        _thoughts.insert(
          0,
          _Thought(
            noteId: cloudId,
            text: text,
            quoted: n.quoted,
            ownNote: n,
            authorUserId: me.id,
          ),
        );
      }
    }
  }

  Future<void> _editOwn(ParaNote note) async {
    final cb = widget.onEditNote;
    if (cb == null) return;
    await cb(note);
    if (!mounted) return;
    await _loadPage(reset: true);
  }

  Future<void> _deleteOwn(ParaNote note) async {
    final cb = widget.onDeleteNote;
    if (cb == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除这条备注？', style: TextStyle(fontSize: 16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(color: Color(0xFF666666))),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child:
                const Text('删除', style: TextStyle(color: Color(0xFFDD6B6B))),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await cb(note);
    if (!mounted) return;
    await _loadPage(reset: true);
  }

  void _close() {
    Navigator.of(context).pop();
  }

  void _onVerticalDragStart(DragStartDetails d) {
    _dragY = 0;
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    // 仅向下拖动生效（向上不跟随），避免与列表滚动冲突。
    final next = _dragY + d.delta.dy;
    setState(() => _dragY = next < 0 ? 0 : next);
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    if (_dragY > 120 || velocity > 600) {
      _close();
      return;
    }
    setState(() => _dragY = 0);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final headerHeight = kToolbarHeight * 0.9;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: _onVerticalDragStart,
      onVerticalDragUpdate: _onVerticalDragUpdate,
      onVerticalDragEnd: _onVerticalDragEnd,
      onVerticalDragCancel: () => setState(() => _dragY = 0),
      child: Transform.translate(
        offset: Offset(0, _dragY),
        child: Material(
          color: p.card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: SizedBox(
                  height: headerHeight,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppPalette.p.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '本段所有备注·$_total条',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: p.text,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(height: 1, thickness: 1, color: AppPalette.p.border),
              Expanded(child: SafeArea(top: false, child: _buildBody())),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final p = AppPalette.p;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 40, color: p.textHint),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: p.textSec)),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _loadPage(reset: true),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_thoughts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_stories_outlined, size: 40, color: p.textHint),
              const SizedBox(height: 12),
              Text(
                '还没有同修记录备注。\n选择文字，记录备注。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.6, color: p.textSec),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      itemCount: _thoughts.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 18),
      itemBuilder: (context, i) {
        if (i >= _thoughts.length) {
          if (_loadingMore) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: TextButton(
                onPressed: _loadPage,
                child: const Text('加载更多'),
              ),
            ),
          );
        }
        return _buildThoughtCard(_thoughts[i]);
      },
    );
  }

  Widget _buildThoughtCard(_Thought t) {
    final p = AppPalette.p;
    final own = t.ownNote;
    // 旧备注（未记录选中文字）没有 quoted，回退显示整段经文，保证每段都能看到「经文」。
    final quotedText =
        t.quoted.trim().isNotEmpty ? t.quoted.trim() : widget.paragraph.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1) 经文字符（无选中文字时回退为整段）：浅底圆角，与备注正文区分。
        if (quotedText.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              color: AppPalette.p.accent.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              quotedText,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                fontWeight: FontWeight.w600,
                color: p.textSec,
              ),
            ),
          ),
        // 2) 备注正文
        _buildCollapsibleText(t.text),
        // 3) 仅「自己的备注」显示编辑 / 删除（其他用户、菩提空间分享帖均不显示）。
        if (own != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _OwnAction(
                  icon: Icons.edit_outlined,
                  color: AppPalette.p.accentDeep,
                  onTap: () => _editOwn(own),
                ),
                const SizedBox(width: 4),
                _OwnAction(
                  icon: Icons.delete_outline,
                  color: const Color(0xFFDD6B6B),
                  onTap: () => _deleteOwn(own),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 备注正文，超过 5 行可折叠；点击「显示更多/收起」切换展开。
  Widget _buildCollapsibleText(String text) {
    final p = AppPalette.p;
    final expanded = _expanded.contains(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          maxLines: expanded ? null : 5,
          overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: TextStyle(fontSize: 15, height: 1.6, color: p.text),
        ),
        if (text.length > 80) ...[
          const SizedBox(height: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() {
                if (expanded) {
                  _expanded.remove(text);
                } else {
                  _expanded.add(text);
                }
              });
            },
            child: Text(
              expanded ? '收起' : '显示更多',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: p.accent,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 自己备注右下角的「编辑 / 删除」小图标按钮。
class _OwnAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _OwnAction({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}
