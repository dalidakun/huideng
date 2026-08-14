import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';
import 'my_page.dart';
import 'note_detail_page.dart';
import 'note_sutra_links.dart';
import 'post_time_link.dart';
import 'reading_badges.dart';
import 'reading_page.dart';
import 'sutra_downloader.dart';
import 'text_input_sheet.dart';
import 'user_avatar.dart';
import 'user_space_page.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _border = Color(0xFFEBE1D6);

/// 渲染帖子正文：识别并渲染三类可点击标记——
/// `[@账号](user:用户ID)` 提及用户、`$经书名` 引用经文、`#话题名` 话题；
/// 兼容旧式 `[@经名](路径)` 与 `@经书名`。
Widget buildPostRichText(
  String text, {
  required TextStyle style,
  required Map<String, NoteSutraLink> library,
  required void Function(String userId) onUserTap,
  required void Function(String title, String filePath) onSutraTap,
  required void Function(String topic) onTopicTap,
  Color linkColor = const Color(0xFF70867A),
  int? maxLines,
  TextOverflow? overflow,
}) {
  final userTokenRe = RegExp(r'\[@([^\]]+)\]\(user:([^)]+)\)');
  final topicRe = RegExp(r'#([^\s#，。！？,;:!?（）()]+)');

  WidgetSpan linkSpan(String label, VoidCallback onTap) {
    final linkStyle = style.copyWith(
      color: linkColor,
      fontWeight: FontWeight.w600,
    );
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Text(label, style: linkStyle),
      ),
    );
  }

  String? sutraTitleAt(int from) {
    if (text[from] != r'$' && text[from] != '@') return null;
    var best = '';
    for (final t in library.keys) {
      if (t.length <= best.length) continue;
      if (text.startsWith(t, from + 1)) best = t;
    }
    return best.isEmpty ? null : best;
  }

  final spans = <InlineSpan>[];
  var i = 0;
  var litStart = 0;
  void flushLit() {
    if (litStart < i) spans.add(TextSpan(text: text.substring(litStart, i)));
  }

  while (i < text.length) {
    // 用户提及 [@账号](user:ID) —— 必须先于旧式经文标记匹配。
    if (text[i] == '[' && i + 1 < text.length && text[i + 1] == '@') {
      final m = userTokenRe.matchAsPrefix(text, i);
      if (m != null) {
        flushLit();
        final label = '@${m.group(1)}';
        final uid = m.group(2)!;
        spans.add(linkSpan(label, () => onUserTap(uid)));
        i = m.end;
        litStart = i;
        continue;
      }
    }
    // 旧式 [@经名](路径)
    if (text[i] == '[' && i + 1 < text.length && text[i + 1] == '@') {
      final legacy = RegExp(r'\[@([^\]]+)\]\(([^)]+)\)').matchAsPrefix(text, i);
      if (legacy != null) {
        flushLit();
        final title = legacy.group(1)!;
        final path = legacy.group(2)!;
        spans.add(linkSpan('@$title', () => onSutraTap(title, path)));
        i = legacy.end;
        litStart = i;
        continue;
      }
    }
    // $经书名 / @经书名（旧式）
    if ((text[i] == r'$' || text[i] == '@') && i + 1 < text.length) {
      final t = sutraTitleAt(i);
      if (t != null) {
        flushLit();
        spans.add(
            linkSpan(text[i] + t, () => onSutraTap(t, library[t]!.filePath)));
        i += 1 + t.length;
        litStart = i;
        continue;
      }
    }
    // #话题名
    if (text[i] == '#') {
      final m = topicRe.matchAsPrefix(text, i);
      if (m != null && m.group(1)!.isNotEmpty) {
        flushLit();
        final topic = m.group(1)!;
        spans.add(linkSpan('#$topic', () => onTopicTap(topic)));
        i = m.end;
        litStart = i;
        continue;
      }
    }
    i++;
  }
  flushLit();

  return Text.rich(
    TextSpan(children: spans, style: style),
    maxLines: maxLines,
    overflow: overflow,
  );
}

/// 经书讨论页：上方为经书入口（经藏菜单样式：下载状态 + 阅读按钮），下方为讨论区。
class SutraDiscussionPage extends StatefulWidget {
  final String title;
  final String filePath;
  const SutraDiscussionPage({
    super.key,
    required this.title,
    required this.filePath,
  });

  @override
  State<SutraDiscussionPage> createState() => _SutraDiscussionPageState();
}

class _SutraDiscussionPageState extends State<SutraDiscussionPage>
    with WidgetsBindingObserver {
  /// 云端讨论列表（最新在前），每条为 {id, content, name, userId, account,
  /// verified, likeCount, at} 结构，所有用户共享。
  List<Map<String, dynamic>> _comments = [];
  bool _loading = true;
  bool _commentsLoading = true;
  bool _downloaded = false;
  bool _downloading = false;

  /// 每条讨论独立的本地点赞/收藏状态（按云端讨论 id 记录）。
  final Set<String> _likedCommentIds = {};
  final Set<String> _favCommentIds = {};

  /// 广场上引用该经书（$经名 / @经名）的帖子：与讨论混排在统一列表里。
  List<PlazaNote> _relatedNotes = [];

  /// 相关帖子的本地点藏状态（按帖子 id 记录）。
  final Set<String> _relatedFavIds = {};

  /// 经书目录映射：渲染相关帖子里的 $经名/@经名 链接。
  Map<String, NoteSutraLink> _sutraLibrary = const {};

  /// 新讨论提醒：后台静默统计新讨论数量，只更新「显示X帖子」提醒条与悬浮按钮，
  /// 不自动刷新列表，点击提醒或下拉才手动刷出，避免浏览时被打断。
  final ScrollController _scroll = ScrollController();
  final GlobalKey _topSectionKey = GlobalKey();
  double _topSectionHeight = 0;
  bool _showNewPostPill = false;
  Timer? _newPostTimer;
  bool _newPostChecking = false;
  bool _appActive = true;
  int _newPostCount = 0;
  static const Duration _newPostCheckInterval = Duration(seconds: 30);
  static const int _pageSize = 50;

  @override
  void initState() {
    super.initState();
    _checkDownload();
    _loadComments();
    _loadRelatedNotes();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    _newPostTimer =
        Timer.periodic(_newPostCheckInterval, (_) => _checkNewPosts());
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureTopSection());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 只暂停/恢复新讨论数量统计，不自动刷新列表。
    _appActive = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _newPostTimer?.cancel();
    _newPostTimer = null;
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    _measureTopSectionOnce();
    _updateNewPostPill();
  }

  void _measureTopSectionOnce() {
    if (_topSectionHeight > 0) return;
    final ctx = _topSectionKey.currentContext;
    final box = ctx?.findRenderObject();
    if (box is RenderBox && box.size.height > 0) {
      _topSectionHeight = box.size.height;
    }
  }

  void _measureTopSection() {
    final ctx = _topSectionKey.currentContext;
    final box = ctx?.findRenderObject();
    if (box is RenderBox && box.size.height > 0) {
      _topSectionHeight = box.size.height;
    }
  }

  /// 计算悬浮「显示X帖子」按钮是否可见：有新讨论且已滚动到顶部区域被隐藏。
  void _updateNewPostPill() {
    final show = _newPostCount > 0 &&
        _topSectionHeight > 0 &&
        _scroll.hasClients &&
        _scroll.offset >= _topSectionHeight + 60;
    if (show != _showNewPostPill) {
      setState(() => _showNewPostPill = show);
    }
  }

  /// 后台静默统计本经书的新讨论数量：只更新「显示X帖子」提醒，不刷新列表。
  Future<void> _checkNewPosts() async {
    if (!mounted || !_appActive || _newPostChecking) return;
    if (_comments.isEmpty || _commentsLoading) return;
    _newPostChecking = true;
    try {
      final (list, _) = await CloudNotesService.instance
          .getSutraDiscussions(sutraTitle: widget.title, pageSize: _pageSize);
      if (!mounted) return;
      final known =
          _comments.map((c) => c['id']?.toString()).whereType<String>().toSet();
      final count = list
          .where((c) =>
              (c['id']?.toString() ?? '').isNotEmpty &&
              !known.contains(c['id']?.toString()))
          .length;
      if (count > 0 && count != _newPostCount) {
        setState(() => _newPostCount = count);
        _updateNewPostPill();
      }
    } catch (_) {
      // 静默失败，下一轮再试。
    } finally {
      _newPostChecking = false;
    }
  }

  /// 点击提醒条 / 悬浮按钮：回到讨论顶部，同时刷新出新讨论。
  Future<void> _refreshFromPill() async {
    if (_scroll.hasClients) {
      await _scroll.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
    await _loadComments();
  }

  /// 「显示X帖子」提醒条：仅一行文字，点击立即刷新出这些新讨论。
  Widget _buildNewPostBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: InkWell(
        onTap: _refreshFromPill,
        child: Text(
          '显示$_newPostCount帖子',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF70867A)),
        ),
      ),
    );
  }

  /// 悬浮的新讨论按钮：白字 + 70867A 纯色椭圆胶囊，滚动后顶部落出屏幕时展示。
  Widget _buildNewPostPill() {
    return Center(
      child: Material(
        color: const Color(0xFF70867A),
        borderRadius: BorderRadius.circular(999),
        elevation: 4,
        child: InkWell(
          onTap: _refreshFromPill,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.arrow_upward, size: 15, color: Colors.white),
                const SizedBox(width: 5),
                Text('显示$_newPostCount帖子',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 检测经文是否已下载（本地副本优先，其次按 ID 判断下载目录）。
  Future<void> _checkDownload() async {
    var ok = false;
    final path = widget.filePath;
    try {
      if (path.startsWith('assets/sutras_ascii/')) {
        final local = await SutraDownloader.localFileForAssetPath(path);
        ok = local != null;
      }
      if (!ok) {
        final id = SutraDownloader.extractId(widget.title, widget.filePath);
        if (id != null && id.isNotEmpty) {
          ok = await SutraDownloader.isDownloaded(id);
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _downloaded = ok;
      _loading = false;
    });
  }

  /// 未下载时点击弹出下载确认；已下载不弹出。
  Future<void> _onTapCard() async {
    if (_loading || _downloading || _downloaded) return;
    final shouldDownload = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('经文尚未下载',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Text('《${widget.title}》的正文尚未下载，是否现在下载？下载完成即可阅读。',
            style: const TextStyle(color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: _textSec)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _gold),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    if (shouldDownload == true && mounted) {
      await _downloadSutra();
    }
  }

  /// 下载经文，完成后仅切换为对号图标，不自动打开正文。
  Future<void> _downloadSutra() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final id = SutraDownloader.extractId(widget.title, widget.filePath);
      if (id == null || id.isEmpty) {
        throw Exception('无法解析经文');
      }
      await SutraDownloader.download(id);
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$e')),
      );
    }
  }

  /// 点击「阅读」进入经书阅读界面，而不是停留在讨论页。
  void _openRead() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ReadingPage(title: widget.title, filePath: widget.filePath),
      ),
    );
  }

  Future<void> _loadComments() async {
    try {
      final (list, _) = await CloudNotesService.instance
          .getSutraDiscussions(sutraTitle: widget.title, pageSize: _pageSize);
      if (!mounted) return;
      setState(() {
        _comments = list;
        _commentsLoading = false;
        _newPostCount = 0;
      });
      _updateNewPostPill();
    } catch (_) {
      if (!mounted) return;
      setState(() => _commentsLoading = false);
    }
    _migrateLocalComments();
  }

  /// 拉取广场上引用本经书的帖子（$经名 / @经名），与讨论混排在统一列表里。
  Future<void> _loadRelatedNotes() async {
    try {
      if (_sutraLibrary.isEmpty) {
        _sutraLibrary = await NoteSutraCatalog.titleMap();
      }
      final (list, _) = await CloudNotesService.instance
          .getPlazaNotes(page: 1, pageSize: 100);
      if (!mounted) return;
      setState(() {
        _relatedNotes = list
            .where(
                (n) => NoteSutraLinks.referencesSutra(n.content, widget.title))
            .toList();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _relatedNotes = [];
      });
    }
  }

  /// 下拉刷新：讨论与「广场相关帖子」一起刷新。
  Future<void> _refreshAll() async {
    await Future.wait([_loadComments(), _loadRelatedNotes()]);
  }

  /// 合并「广场相关帖子」与「讨论」为单一列表：两种来源的帖子混排展示，
  /// 按时间倒序（最新在前），沿用各自的行样式（两者与主页帖子同款）。
  List<(PlazaNote?, Map<String, dynamic>?)> _mergedRows() {
    final rows = <(PlazaNote?, Map<String, dynamic>?)>[];
    for (final n in _relatedNotes) {
      rows.add((n, null));
    }
    for (final c in _comments) {
      rows.add((null, c));
    }
    rows.sort((a, b) {
      final ta = a.$1?.createdAt ?? (a.$2?['at'] as num?)?.toInt() ?? 0;
      final tb = b.$1?.createdAt ?? (b.$2?['at'] as num?)?.toInt() ?? 0;
      return tb.compareTo(ta);
    });
    return rows;
  }

  /// 一次性迁移：把旧版本存在本地的讨论上传到云端（仅自己的帖子），
  /// 让历史发言也能被其他同修看到；全部尝试完成后清空本地并标记已迁移。
  Future<void> _migrateLocalComments() async {
    if (!AuthService.instance.isLoggedIn) return;
    final prefs = await SharedPreferences.getInstance();
    final migratedKey = 'sutra_discussion_${widget.title}_migrated';
    if (prefs.getBool(migratedKey) ?? false) return;
    final raw = prefs.getString('sutra_discussion_${widget.title}') ?? '[]';
    List<Map<String, dynamic>> local;
    try {
      local = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (_) {
      local = [];
    }
    if (local.isEmpty) {
      await prefs.setBool(migratedKey, true);
      return;
    }
    for (final c in local) {
      final content = c['content']?.toString() ?? '';
      if (content.trim().isEmpty) continue;
      try {
        await CloudNotesService.instance.createSutraDiscussion(
          sutraTitle: widget.title,
          content: content,
        );
      } catch (_) {
        // 单条失败不中断，尽量多迁移；全部尝试完成后本地照常清空，避免重复上传。
      }
    }
    await prefs.remove('sutra_discussion_${widget.title}');
    await prefs.setBool(migratedKey, true);
    if (mounted) {
      await _loadComments();
    }
  }

  Future<void> _postComment(String content) async {
    if (content.isEmpty) return;
    try {
      await CloudNotesService.instance.createSutraDiscussion(
        sutraTitle: widget.title,
        content: content,
      );
      if (!mounted) return;
      await _loadComments();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发布失败：$e')),
      );
    }
  }

  void _promptLogin() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  @override
  Widget build(BuildContext context) {
    final rows = _mergedRows();
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: Text('${widget.title} · 讨论',
            style: const TextStyle(
                color: _text, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                RefreshIndicator(
                  onRefresh: _refreshAll,
                  color: _gold,
                  child: ListView(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: [
                      // 经书入口：经藏菜单样式（书名 + 下载状态 + 阅读按钮）。
                      GestureDetector(
                        key: _topSectionKey,
                        behavior: HitTestBehavior.opaque,
                        onTap: _onTapCard,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                          decoration: BoxDecoration(
                            color: _card,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: _border),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF70867A)
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(9),
                                    ),
                                    child: const Icon(Icons.menu_book_rounded,
                                        size: 19, color: Color(0xFF70867A)),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(widget.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                            color: _text)),
                                  ),
                                  if (_loading)
                                    const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: _gold),
                                    )
                                  else if (_downloading)
                                    const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: _gold),
                                    )
                                  else
                                    Icon(
                                        _downloaded
                                            ? Icons.check_circle_rounded
                                            : Icons.download_rounded,
                                        size: 20,
                                        color: _downloaded
                                            ? const Color(0xFF8FBC8F)
                                            : const Color(0xFFB08878)),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (_loading)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 10),
                                  child: Center(
                                    child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: _gold),
                                    ),
                                  ),
                                )
                              else if (!_downloaded)
                                Row(
                                  children: [
                                    const Icon(
                                        Icons.download_for_offline_outlined,
                                        size: 15,
                                        color: Color(0xFFB08878)),
                                    const SizedBox(width: 6),
                                    const Expanded(
                                      child: Text('经文尚未下载，点击下载后即可阅读',
                                          style: TextStyle(
                                              fontSize: 12, color: _textSec)),
                                    ),
                                    const SizedBox(width: 8),
                                    FilledButton.icon(
                                      onPressed:
                                          _downloading ? null : _onTapCard,
                                      icon: _downloading
                                          ? const SizedBox(
                                              width: 15,
                                              height: 15,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Colors.white))
                                          : const Icon(Icons.download,
                                              size: 16),
                                      label: Text(
                                          _downloading ? '下载中…' : '下载经文',
                                          style: const TextStyle(fontSize: 13)),
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            const Color(0xFF70867A),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 14, vertical: 9),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12)),
                                      ),
                                    ),
                                  ],
                                )
                              else
                                Row(
                                  children: [
                                    const Icon(Icons.check_circle_rounded,
                                        size: 15, color: Color(0xFF8FBC8F)),
                                    const SizedBox(width: 6),
                                    const Expanded(
                                      child: Text('经文已下载',
                                          style: TextStyle(
                                              fontSize: 12, color: _textSec)),
                                    ),
                                    const SizedBox(width: 8),
                                    FilledButton.icon(
                                      onPressed: _openRead,
                                      icon: const Icon(Icons.menu_book_rounded,
                                          size: 16),
                                      label: const Text('阅读',
                                          style: TextStyle(fontSize: 13)),
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            const Color(0xFF70867A),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 18, vertical: 9),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12)),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                      // 统一列表：广场相关帖子与讨论合并展示，按时间倒序（最新在前）。
                      const SizedBox(height: 16),
                      if (_newPostCount > 0) _buildNewPostBanner(),
                      const SizedBox(height: 16),
                      if (_commentsLoading && _comments.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: _gold),
                            ),
                          ),
                        )
                      else if (rows.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text('还没有讨论，来分享你的体会吧',
                                style: const TextStyle(
                                    fontSize: 13, color: _textHint)),
                          ),
                        )
                      else
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0)
                            const Divider(
                                height: 1,
                                thickness: 0.6,
                                color: Color(0xFFD8CCBC)),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: rows[i].$1 != null
                                ? _buildRelatedNote(rows[i].$1!)
                                : _buildCommentRow(rows[i].$2!),
                          ),
                        ],
                    ],
                  ),
                ),
                // 滚动后顶部提醒条被隐藏时的悬浮按钮：回到顶部并刷新出新讨论。
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    ignoring: !_showNewPostPill,
                    child: _showNewPostPill ? _buildNewPostPill() : null,
                  ),
                ),
              ],
            ),
          ),
          // 讨论输入：点击打开与笔记详情页同款大输入框（500 字）。
          Container(
            color: _card,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: SafeArea(
              top: false,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openComposeSheet,
                child: Container(
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: _bg,
                    borderRadius: BorderRadius.circular(21),
                  ),
                  alignment: Alignment.centerLeft,
                  child: const Text(
                    '说说你的体会…',
                    style: TextStyle(color: _textHint, fontSize: 14),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 打开与笔记详情页同款的大输入弹层（SheetTextInput，500 字、多行）。
  void _openComposeSheet() {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const SheetTextInput(
        title: '讨论',
        hint: '说说你的体会…',
        maxLength: 500,
        minLines: 3,
        maxLines: 10,
        confirmText: '发表',
      ),
    ).then((content) {
      if (content != null && content.isNotEmpty) _postComment(content);
    });
  }

  /// 讨论行：与主页帖子同款（头像 + 昵称/认证/@账号，内容下方时间 + 四个指标）。
  Widget _buildCommentRow(Map<String, dynamic> c) {
    final userId = c['userId']?.toString() ?? '';
    final account = c['account']?.toString() ?? '';
    final verified = c['verified'] == true;
    // 阅藏进度百分比：自己的讨论用本地实时统计，他人的用云端数据（与主页帖子一致）。
    final me = AuthService.instance.currentUser.value;
    final pct = postCanonPercent(
      isSelf: me != null && userId.isNotEmpty && me.id == userId,
      cloudRead: (c['canonRead'] as num?)?.toInt() ?? 0,
      cloudTotal: (c['canonTotal'] as num?)?.toInt() ?? 0,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UserAvatar(userId: userId.isNotEmpty ? userId : null, radius: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(c['name']?.toString() ?? '同修',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
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
                            // 点击 @账号 进入该用户个人主页（青色提示可点击）。
                            child: AccountLink(
                              account: account,
                              onTap: () {
                                if (userId.isNotEmpty) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            UserSpacePage(userId: userId)),
                                  );
                                }
                              },
                            ),
                          ),
                          // 阅藏进度百分比：灰色（时间戳同色），前后各一个圆点分隔（与主页帖子同款）。
                          const SizedBox(width: 3),
                          Text('·',
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF8C8C8C))),
                          const SizedBox(width: 2),
                          Text(pct,
                              maxLines: 1,
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF8C8C8C))),
                        ],
                      ],
                    ),
                  ),
                  // 右侧三点菜单：与主页帖子一致（自己的讨论可删除，他人的可关注/屏蔽）。
                  if (AuthService.instance.isLoggedIn)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _showCommentMenu(c),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.more_horiz,
                            size: 18, color: Color(0xFF8C8C8C)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(c['content']?.toString() ?? '',
                  style:
                      const TextStyle(fontSize: 15, color: _text, height: 1.6)),
              // 发布时间：放在内容和指标行之间（与主页帖子同款）。
              const SizedBox(height: 6),
              Text(
                _fmtTime((c['at'] as num?)?.toInt() ?? 0),
                style: const TextStyle(fontSize: 12, color: Color(0xFF8C8C8C)),
              ),
              const SizedBox(height: 10),
              _buildCommentMetricRow(c),
            ],
          ),
        ),
      ],
    );
  }

  /// 讨论的四个指标：评论/转发/点赞/阅读（与笔记详情页操作行同款样式）。
  /// 收藏与分享已移至讨论右上角三点菜单。
  Widget _buildCommentMetricRow(Map<String, dynamic> c) {
    final id = c['id']?.toString() ?? '';
    final liked = id.isNotEmpty && _likedCommentIds.contains(id);
    return buildStatsRow(
      commentCount: 0,
      repostCount: 0,
      likeCount: (c['likeCount'] as num?)?.toInt() ?? 0,
      viewCount: 0,
      liked: liked,
      onLike: () => setState(() {
        final likeCount =
            ((c['likeCount'] as num?)?.toInt() ?? 0) + (liked ? -1 : 1);
        c['likeCount'] = likeCount < 0 ? 0 : likeCount;
        if (id.isEmpty) return;
        if (!_likedCommentIds.remove(id)) _likedCommentIds.add(id);
      }),
    );
  }

  /// 广场相关帖子行：与话题页帖子同款（头像 + 昵称/认证/@账号/时间 + 正文 + 指标），
  /// 点击进入笔记详情（点赞/评论等互动在详情页完成）。
  Widget _buildRelatedNote(PlazaNote n) {
    final liked = CloudNotesService.instance.likedNoteIds.contains(n.id);
    // 阅藏进度百分比：自己的帖子用本地实时统计，他人的用云端数据（与主页帖子一致）。
    final me = AuthService.instance.currentUser.value;
    final pct = postCanonPercent(
      isSelf: me != null && me.id == n.ownerUserId,
      cloudRead: n.canonRead,
      cloudTotal: n.canonTotal,
    );
    return InkWell(
      onTap: () => _openRelatedDetail(n),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UserAvatar(userId: n.ownerUserId, radius: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(n.authorName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: _text)),
                            ),
                            if (n.authorVerified) ...[
                              const SizedBox(width: 3),
                              const Icon(Icons.verified,
                                  size: 14, color: Color(0xFF70867A)),
                            ],
                            if (n.authorAccount.isNotEmpty) ...[
                              const SizedBox(width: 3),
                              Flexible(
                                // 点击 @账号 进入该用户个人主页（青色提示可点击）。
                                child: AccountLink(
                                  account: n.authorAccount,
                                  onTap: () {
                                    if (n.ownerUserId.isNotEmpty) {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => UserSpacePage(
                                                userId: n.ownerUserId)),
                                      );
                                    }
                                  },
                                ),
                              ),
                              // 阅藏进度百分比：灰色（时间戳同色），前后各一个圆点分隔（与主页帖子同款）。
                              const SizedBox(width: 3),
                              Text('·',
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF8C8C8C))),
                              const SizedBox(width: 2),
                              Text(pct,
                                  maxLines: 1,
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF8C8C8C))),
                            ],
                          ],
                        ),
                      ),
                      // 右侧三点菜单：与主页帖子一致（自己的帖子可编辑/删除，他人的可关注/屏蔽）。
                      if (AuthService.instance.isLoggedIn)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _showRelatedMenu(n),
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.more_horiz,
                                size: 18, color: Color(0xFF8C8C8C)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  buildPostRichText(
                    n.content,
                    style: const TextStyle(
                        fontSize: 15, color: _text, height: 1.6),
                    library: _sutraLibrary,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    onUserTap: (uid) {
                      if (uid.isNotEmpty) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => UserSpacePage(userId: uid)),
                        );
                      }
                    },
                    onSutraTap: (title, path) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => SutraDiscussionPage(
                                title: title, filePath: path)),
                      ).then((_) {
                        if (mounted) _loadRelatedNotes();
                      });
                    },
                    onTopicTap: (topic) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => TopicPage(topic: topic)),
                      ).then((_) {
                        if (mounted) _loadRelatedNotes();
                      });
                    },
                  ),
                  // 发布时间：放在内容和指标行之间（与主页帖子同款）。
                  const SizedBox(height: 6),
                  Text(_fmtTime(n.createdAt),
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF8C8C8C))),
                  const SizedBox(height: 10),
                  // 四个指标：评论/转发/点赞/阅读（与笔记详情页操作行同款样式）。
                  // 收藏与分享已移至帖子右上角三点菜单。
                  buildStatsRow(
                    commentCount: n.commentCount,
                    repostCount: n.repostCount,
                    likeCount: n.likeCount,
                    viewCount: n.viewCount,
                    liked: liked,
                    onComment: () => _openRelatedDetail(n),
                    onRepost: () => _openRelatedDetail(n),
                    onLike: () => _openRelatedDetail(n),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开相关帖子的详情页，返回后刷新列表（互动数据可能变化）。
  void _openRelatedDetail(PlazaNote n) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: n.id)),
    ).then((_) {
      if (mounted) _loadRelatedNotes();
    });
  }

  /// 收藏/取消收藏相关帖子（本地状态即时切换，云端同步）。
  Future<void> _toggleRelatedFavorite(PlazaNote n) async {
    if (!AuthService.instance.isLoggedIn) {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }
    try {
      final on = !_relatedFavIds.contains(n.id);
      setState(() {
        if (on) {
          _relatedFavIds.add(n.id);
        } else {
          _relatedFavIds.remove(n.id);
        }
      });
      await CloudNotesService.instance.toggleNoteFavorite(n.id);
      await CloudNotesService.instance.refreshFavoriteNoteIds();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (_relatedFavIds.contains(n.id)) {
          _relatedFavIds.remove(n.id);
        } else {
          _relatedFavIds.add(n.id);
        }
      });
    }
  }

  /// 讨论右侧三点菜单：收藏/分享讨论 + 自己的讨论可删除，他人的可关注/屏蔽
  /// （与笔记详情页评论三点菜单同款样式）。
  Future<void> _showCommentMenu(Map<String, dynamic> c) async {
    final me = AuthService.instance.currentUser.value;
    final userId = c['userId']?.toString() ?? '';
    final name = c['name']?.toString() ?? '同修';
    if (me == null) {
      _promptLogin();
      return;
    }
    final id = c['id']?.toString() ?? '';
    final favorited = id.isNotEmpty && _favCommentIds.contains(id);
    final isOwn = userId.isNotEmpty && me.id == userId;
    final following =
        CloudNotesService.instance.followingUserIds.contains(userId);
    final blocked = CloudNotesService.instance.blockedUserIds.contains(userId);
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
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            const Divider(height: 1, color: _border),
            _menuItem(
                ctx,
                'favorite',
                favorited
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                favorited ? '取消收藏' : '收藏讨论'),
            _menuItem(ctx, 'share', Icons.share_rounded, '分享讨论'),
            if (isOwn)
              _menuItem(ctx, 'delete', Icons.delete_outline, '删除讨论')
            else if (userId.isNotEmpty) ...[
              _menuItem(ctx, following ? 'unfollow' : 'follow',
                  Icons.person_add_alt, following ? '取消关注' : '关注该用户'),
              _menuItem(ctx, blocked ? 'unblock' : 'block',
                  Icons.block_outlined, blocked ? '取消屏蔽' : '屏蔽该用户'),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'favorite') {
      setState(() {
        if (id.isEmpty) return;
        if (!_favCommentIds.remove(id)) _favCommentIds.add(id);
      });
      return;
    }
    if (choice == 'share') {
      await _shareComment(c);
      return;
    }
    if (choice == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('删除讨论',
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
          content: const Text('删除后该讨论将从本经书的讨论区移除，无法恢复。确定删除吗？',
              style: TextStyle(fontSize: 14, color: _textSec)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: _textSec)),
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
        await CloudNotesService.instance
            .deleteSutraDiscussion(c['id']?.toString() ?? '');
        if (!mounted) return;
        _showToast('已删除');
        await _loadComments();
      } catch (e) {
        if (!mounted) return;
        _showToast('删除失败：$e');
      }
      return;
    }
    try {
      if (choice == 'follow' || choice == 'unfollow') {
        final ok = await CloudNotesService.instance.toggleFollow(userId);
        if (!mounted) return;
        _showToast(ok ? '已关注' : '已取消关注');
      } else if (choice == 'block') {
        final ok = await CloudNotesService.instance.toggleBlockUser(userId);
        if (!mounted) return;
        _showToast(ok ? '已屏蔽，该用户帖子不再展示' : '已取消屏蔽');
      } else if (choice == 'unblock') {
        final ok = await CloudNotesService.instance.toggleBlockUser(userId);
        if (!mounted) return;
        _showToast(ok ? '已屏蔽' : '已取消屏蔽');
      }
    } catch (e) {
      if (!mounted) return;
      _showToast(e.toString());
    }
  }

  /// 相关帖子右侧三点菜单：收藏/分享帖子 + 自己的帖子可编辑/删除，他人的可关注/屏蔽
  /// （与笔记详情页回复三点菜单同款样式）。
  Future<void> _showRelatedMenu(PlazaNote n) async {
    final me = AuthService.instance.currentUser.value;
    if (me == null) {
      _promptLogin();
      return;
    }
    final favorited = _relatedFavIds.contains(n.id);
    if (me.id == n.ownerUserId) {
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
                child: Text(n.authorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _text)),
              ),
              const Divider(height: 1, color: _border),
              _menuItem(
                  ctx,
                  'favorite',
                  favorited
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  favorited ? '取消收藏' : '收藏帖子'),
              _menuItem(ctx, 'share', Icons.share_rounded, '分享帖子'),
              _menuItem(ctx, 'edit', Icons.edit_outlined, '编辑帖子'),
              _menuItem(ctx, 'delete', Icons.delete_outline, '删除帖子'),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (choice == 'favorite') {
        await _toggleRelatedFavorite(n);
      } else if (choice == 'share') {
        await _shareNote(n);
      } else if (choice == 'edit') {
        await _editRelatedNote(n);
      } else if (choice == 'delete') {
        await _deleteRelatedNote(n);
      }
      return;
    }
    // 他人的帖子：收藏/分享 + 关注/屏蔽。
    final following =
        CloudNotesService.instance.followingUserIds.contains(n.ownerUserId);
    final blocked =
        CloudNotesService.instance.blockedUserIds.contains(n.ownerUserId);
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
              child: Text(n.authorName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            const Divider(height: 1, color: _border),
            _menuItem(
                ctx,
                'favorite',
                favorited
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                favorited ? '取消收藏' : '收藏帖子'),
            _menuItem(ctx, 'share', Icons.share_rounded, '分享帖子'),
            _menuItem(ctx, following ? 'unfollow' : 'follow',
                Icons.person_add_alt, following ? '取消关注' : '关注该用户'),
            _menuItem(ctx, blocked ? 'unblock' : 'block', Icons.block_outlined,
                blocked ? '取消屏蔽' : '屏蔽该用户'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'favorite') {
      await _toggleRelatedFavorite(n);
      return;
    }
    if (choice == 'share') {
      await _shareNote(n);
      return;
    }
    try {
      if (choice == 'follow' || choice == 'unfollow') {
        final ok = await CloudNotesService.instance.toggleFollow(n.ownerUserId);
        if (!mounted) return;
        _showToast(ok ? '已关注' : '已取消关注');
      } else if (choice == 'block') {
        final ok =
            await CloudNotesService.instance.toggleBlockUser(n.ownerUserId);
        if (!mounted) return;
        _showToast(ok ? '已屏蔽，该用户帖子不再展示' : '已取消屏蔽');
        if (ok) _loadRelatedNotes();
      } else if (choice == 'unblock') {
        final ok =
            await CloudNotesService.instance.toggleBlockUser(n.ownerUserId);
        if (!mounted) return;
        _showToast(ok ? '已屏蔽' : '已取消屏蔽');
      }
    } catch (e) {
      if (!mounted) return;
      _showToast(e.toString());
    }
  }

  /// 编辑自己发布的相关帖子内容。
  Future<void> _editRelatedNote(PlazaNote n) async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SheetTextInput(
        title: '编辑帖子',
        hint: '写下新的内容…',
        initialText: n.content,
        maxLength: 2000,
        minLines: 3,
        maxLines: 6,
        confirmText: '保存',
      ),
    );
    if (saved == null || saved.trim().isEmpty || !mounted) return;
    try {
      await CloudNotesService.instance
          .updateSharedNote(cloudId: n.id, content: saved.trim());
      if (!mounted) return;
      _showToast('已更新');
      await _loadRelatedNotes();
    } catch (e) {
      if (mounted) _showToast(e.toString());
    }
  }

  /// 删除自己发布的相关帖子。
  Future<void> _deleteRelatedNote(PlazaNote n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除帖子',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: const Text('删除后帖子将从菩提空间移除，且无法恢复。确定删除吗？',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: _textSec)),
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
      await CloudNotesService.instance.deleteCloudNote(n.id);
      if (!mounted) return;
      _showToast('已删除');
      await _loadRelatedNotes();
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
            Text(label, style: const TextStyle(fontSize: 15, color: _text)),
          ],
        ),
      ),
    );
  }

  void _showToast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 1800),
        behavior: SnackBarBehavior.floating,
      ));
  }

  /// 分享一条讨论到系统分享面板（与笔记详情页 _share 同款文案模板）。
  Future<void> _shareComment(Map<String, dynamic> c) async {
    final content = (c['content']?.toString() ?? '').trim();
    final name = c['name']?.toString() ?? '同修';
    final plain = NoteSutraLinks.plainText(content);
    final text =
        '${plain.length > 120 ? '${plain.substring(0, 120)}…' : plain}\n'
        '———来自【燃灯】App · $name 的经书讨论分享\n'
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

  /// 分享一条广场相关帖子到系统分享面板。
  Future<void> _shareNote(PlazaNote n) async {
    final plain = NoteSutraLinks.plainText(n.content);
    final text =
        '${plain.length > 120 ? '${plain.substring(0, 120)}…' : plain}\n'
        '———来自【燃灯】App · ${n.authorName} 的笔记分享\n'
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

  String _fmtTime(int ms) {
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

/// 话题页：展示含该话题的所有帖子。
class TopicPage extends StatefulWidget {
  final String topic;
  const TopicPage({super.key, required this.topic});

  @override
  State<TopicPage> createState() => _TopicPageState();
}

class _TopicPageState extends State<TopicPage> with WidgetsBindingObserver {
  List<PlazaNote> _notes = [];
  bool _loading = true;

  /// 话题发起人帖子的 id（置顶展示并标注「发起人」）。
  String _pinnedId = '';

  /// 新帖提醒：后台静默统计本话题新帖数量，只更新「显示X帖子」提醒条与悬浮按钮，
  /// 不自动刷新列表，点击提醒或下拉才手动刷出，避免浏览时被打断。
  final ScrollController _scroll = ScrollController();
  final GlobalKey _topSectionKey = GlobalKey();
  double _topSectionHeight = 0;
  bool _showNewPostPill = false;
  Timer? _newPostTimer;
  bool _newPostChecking = false;
  bool _appActive = true;
  int _newPostCount = 0;
  static const Duration _newPostCheckInterval = Duration(seconds: 30);
  static const int _pageSize = 100;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    _newPostTimer =
        Timer.periodic(_newPostCheckInterval, (_) => _checkNewPosts());
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureTopSection());
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 只暂停/恢复新帖数量统计，不自动刷新列表。
    _appActive = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _newPostTimer?.cancel();
    _newPostTimer = null;
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    _measureTopSectionOnce();
    _updateNewPostPill();
  }

  void _measureTopSectionOnce() {
    if (_topSectionHeight > 0) return;
    final ctx = _topSectionKey.currentContext;
    final box = ctx?.findRenderObject();
    if (box is RenderBox && box.size.height > 0) {
      _topSectionHeight = box.size.height;
    }
  }

  void _measureTopSection() {
    final ctx = _topSectionKey.currentContext;
    final box = ctx?.findRenderObject();
    if (box is RenderBox && box.size.height > 0) {
      _topSectionHeight = box.size.height;
    }
  }

  /// 计算悬浮「显示X帖子」按钮是否可见：有新帖且已滚动到顶部提醒条被隐藏。
  void _updateNewPostPill() {
    final show = _newPostCount > 0 &&
        _topSectionHeight > 0 &&
        _scroll.hasClients &&
        _scroll.offset >= _topSectionHeight + 60;
    if (show != _showNewPostPill) {
      setState(() => _showNewPostPill = show);
    }
  }

  /// 后台静默统计本话题的新帖数量：只更新「显示X帖子」提醒，不刷新列表。
  Future<void> _checkNewPosts() async {
    if (!mounted || !_appActive || _newPostChecking) return;
    if (_notes.isEmpty || _loading) return;
    _newPostChecking = true;
    try {
      final tag = '#${widget.topic}';
      final (list, _) = await CloudNotesService.instance
          .getPlazaNotes(page: 1, pageSize: _pageSize);
      if (!mounted) return;
      final known = _notes.map((n) => n.id).toSet();
      final count = list
          .where((n) => n.content.contains(tag) && !known.contains(n.id))
          .length;
      if (count > 0 && count != _newPostCount) {
        setState(() => _newPostCount = count);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _measureTopSection();
          _updateNewPostPill();
        });
      }
    } catch (_) {
      // 静默失败，下一轮再试。
    } finally {
      _newPostChecking = false;
    }
  }

  /// 点击提醒条 / 悬浮按钮：回到帖子顶部，同时刷新出新帖。
  Future<void> _refreshFromPill() async {
    if (_scroll.hasClients) {
      await _scroll.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
    await _load();
  }

  /// 「显示X帖子」提醒条：仅一行文字，点击立即刷新出这些新帖。
  Widget _buildNewPostBanner({Key? key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: InkWell(
        onTap: _refreshFromPill,
        child: Text(
          '显示$_newPostCount帖子',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF70867A)),
        ),
      ),
    );
  }

  /// 悬浮的新帖按钮：白字 + 70867A 纯色椭圆胶囊，滚动后顶部落出屏幕时展示。
  Widget _buildNewPostPill() {
    return Center(
      child: Material(
        color: const Color(0xFF70867A),
        borderRadius: BorderRadius.circular(999),
        elevation: 4,
        child: InkWell(
          onTap: _refreshFromPill,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.arrow_upward, size: 15, color: Colors.white),
                const SizedBox(width: 5),
                Text('显示$_newPostCount帖子',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _load() async {
    try {
      final (list, _) = await CloudNotesService.instance
          .getPlazaNotes(page: 1, pageSize: _pageSize);
      final tag = '#${widget.topic}';
      if (!mounted) return;
      setState(() {
        final tagged = list.where((n) => n.content.contains(tag)).toList();
        _pinnedId = '';
        if (tagged.isNotEmpty) {
          // 发起人帖子置顶：最早发布该话题帖子的用户。
          var first = tagged.first;
          for (final n in tagged) {
            if (n.createdAt < first.createdAt) first = n;
          }
          _pinnedId = first.id;
          _notes = [first, ...tagged.where((n) => n.id != first.id)];
        } else {
          _notes = tagged;
        }
        _loading = false;
        _newPostCount = 0;
      });
      _updateNewPostPill();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notes = [];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: Text('#${widget.topic}',
            style: const TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      // 底部输入框：直接发布带 #话题 的帖子（与经书讨论页同款）。
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _gold))
                    : RefreshIndicator(
                        onRefresh: _load,
                        color: _gold,
                        child: _notes.isEmpty
                            ? ListView(
                                controller: _scroll,
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding:
                                    const EdgeInsets.fromLTRB(16, 40, 16, 16),
                                children: [
                                  if (_newPostCount > 0)
                                    _buildNewPostBanner(key: _topSectionKey),
                                  const SizedBox(height: 24),
                                  const Center(
                                    child: Text('还没有该话题的帖子',
                                        style: TextStyle(
                                            fontSize: 14, color: _textHint)),
                                  ),
                                ],
                              )
                            : ListView.separated(
                                controller: _scroll,
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding:
                                    const EdgeInsets.fromLTRB(16, 10, 16, 16),
                                itemCount:
                                    _notes.length + (_newPostCount > 0 ? 1 : 0),
                                separatorBuilder: (_, index) {
                                  // 「显示X帖子」提醒条在置顶帖子之后、其余讨论之前：
                                  // 索引 0 是置顶帖子↔提醒条，索引 1 是提醒条↔下一条讨论。
                                  if (_newPostCount > 0 && index <= 1) {
                                    return const SizedBox(height: 10);
                                  }
                                  // 发起置顶帖子与下一条之间不画分割线（白色卡片自带区分）。
                                  final noteIndex =
                                      index - (_newPostCount > 0 ? 1 : 0);
                                  if (noteIndex == 0 &&
                                      _notes.isNotEmpty &&
                                      _notes.first.id == _pinnedId) {
                                    return const SizedBox.shrink();
                                  }
                                  return const Divider(
                                      height: 1,
                                      thickness: 0.6,
                                      color: Color(0xFFD8CCBC));
                                },
                                itemBuilder: (context, index) {
                                  // 提醒条位于索引 1：置顶帖子之后、下面讨论帖子之前。
                                  if (_newPostCount > 0 && index == 1) {
                                    return _buildNewPostBanner(
                                        key: _topSectionKey);
                                  }
                                  final n = _notes[
                                      index - (_newPostCount > 0 && index > 1 ? 1 : 0)];
                                  final me =
                                      AuthService.instance.currentUser.value;
                                  final isSelf =
                                      me != null && n.ownerUserId == me.id;
                                  final liked = CloudNotesService
                                      .instance.likedNoteIds
                                      .contains(n.id);
                                  // 阅藏进度百分比：自己的帖子用本地实时统计，他人的用云端数据（与首页帖子一致）。
                                  final pct = postCanonPercent(
                                    isSelf: isSelf,
                                    cloudRead: n.canonRead,
                                    cloudTotal: n.canonTotal,
                                  );
                                  // 与主页帖子同款：头像 + 昵称/@账号/认证 + 阅藏进度 + 三点菜单 + 内容 + 时间 + 四个指标。
                                  final content = InkWell(
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              NoteDetailPage(noteId: n.id)),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 10),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              UserAvatar(
                                                  userId: n.ownerUserId,
                                                  radius: 22),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .center,
                                                      children: [
                                                        Expanded(
                                                          child: Row(
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .center,
                                                            children: [
                                                              Flexible(
                                                                child: Text(
                                                                    n
                                                                        .authorName,
                                                                    maxLines: 1,
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                    style: const TextStyle(
                                                                        fontSize:
                                                                            15,
                                                                        fontWeight:
                                                                            FontWeight
                                                                                .w600,
                                                                        color:
                                                                            _text)),
                                                              ),
                                                              if (n
                                                                  .authorVerified) ...[
                                                                const SizedBox(
                                                                    width: 3),
                                                                const Icon(
                                                                    Icons
                                                                        .verified,
                                                                    size: 14,
                                                                    color: Color(
                                                                        0xFF70867A)),
                                                              ],
                                                              if (n
                                                                  .authorAccount
                                                                  .isNotEmpty) ...[
                                                                const SizedBox(
                                                                    width: 3),
                                                                Flexible(
                                                                  // 点击 @账户名 进入该用户个人主页（青色提示可点击）。
                                                                  child:
                                                                      AccountLink(
                                                                    account: n
                                                                        .authorAccount,
                                                                    onTap: () {
                                                                      if (n
                                                                          .ownerUserId
                                                                          .isNotEmpty) {
                                                                        Navigator
                                                                            .push(
                                                                          context,
                                                                          MaterialPageRoute(
                                                                              builder: (_) => UserSpacePage(userId: n.ownerUserId)),
                                                                        );
                                                                      }
                                                                    },
                                                                  ),
                                                                ),
                                                                // 阅藏进度百分比：灰色（时间戳同色），前后各一个圆点分隔。
                                                                const SizedBox(
                                                                    width: 3),
                                                                const Text('·',
                                                                    style: TextStyle(
                                                                        fontSize:
                                                                            12,
                                                                        color: Color(
                                                                            0xFF8C8C8C))),
                                                                const SizedBox(
                                                                    width: 2),
                                                                // 空间不足时可省略，避免昵称行右侧溢出。
                                                                Flexible(
                                                                  child: Text(
                                                                      pct,
                                                                      maxLines:
                                                                          1,
                                                                      overflow:
                                                                          TextOverflow
                                                                              .ellipsis,
                                                                      style: const TextStyle(
                                                                          fontSize:
                                                                              12,
                                                                          color:
                                                                              Color(0xFF8C8C8C))),
                                                                ),
                                                                const SizedBox(
                                                                    width: 3),
                                                              ],
                                                            ],
                                                          ),
                                                        ),
                                                        if (n.id ==
                                                            _pinnedId) ...[
                                                          // 发起人：d3a069 包裹色小标签，白色字符。
                                                          Container(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                                    horizontal:
                                                                        6,
                                                                    vertical:
                                                                        2),
                                                            decoration:
                                                                BoxDecoration(
                                                              color: const Color(
                                                                  0xFFD3A069),
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                          4),
                                                            ),
                                                            child: const Text(
                                                                '发起人',
                                                                style: TextStyle(
                                                                    fontSize:
                                                                        11,
                                                                    color: Colors
                                                                        .white,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w600)),
                                                          ),
                                                          const SizedBox(
                                                              width: 8),
                                                        ],
                                                        // 三点菜单：每条帖子昵称行右侧都有（自己的可编辑/删除，他人的可关注/屏蔽）。
                                                        if (me != null) ...[
                                                          const SizedBox(
                                                              width: 2),
                                                          GestureDetector(
                                                            behavior:
                                                                HitTestBehavior
                                                                    .opaque,
                                                            onTap: () =>
                                                                _showUserMenu(
                                                                    n),
                                                            child:
                                                                const Padding(
                                                              padding:
                                                                  EdgeInsets
                                                                      .all(2),
                                                              child: Icon(
                                                                  Icons
                                                                      .more_horiz,
                                                                  size: 18,
                                                                  color: Color(
                                                                      0xFF8C8C8C)),
                                                            ),
                                                          ),
                                                        ],
                                                      ],
                                                    ),
                                                    const SizedBox(height: 4),
                                                    buildPostRichText(
                                                      n.content,
                                                      style: const TextStyle(
                                                          fontSize: 15,
                                                          color: _text,
                                                          height: 1.6),
                                                      library: const {},
                                                      maxLines: 4,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      onUserTap: (uid) {
                                                        if (uid.isNotEmpty) {
                                                          Navigator.push(
                                                            context,
                                                            MaterialPageRoute(
                                                                builder: (_) =>
                                                                    UserSpacePage(
                                                                        userId:
                                                                            uid)),
                                                          );
                                                        }
                                                      },
                                                      onSutraTap:
                                                          (title, path) {
                                                        Navigator.push(
                                                          context,
                                                          MaterialPageRoute(
                                                              builder: (_) =>
                                                                  SutraDiscussionPage(
                                                                      title:
                                                                          title,
                                                                      filePath:
                                                                          path)),
                                                        );
                                                      },
                                                      onTopicTap: (topic) {
                                                        Navigator.push(
                                                          context,
                                                          MaterialPageRoute(
                                                              builder: (_) =>
                                                                  TopicPage(
                                                                      topic:
                                                                          topic)),
                                                        );
                                                      },
                                                    ),
                                                    // 发布时间：放在内容和指标行之间（与主页帖子同款）。
                                                    const SizedBox(height: 6),
                                                    Text(_fmt(n.createdAt),
                                                        style: const TextStyle(
                                                            fontSize: 12,
                                                            color: Color(
                                                                0xFF8C8C8C))),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                          // 四个指标：评论/转发/点赞/阅读。
                                          // 与笔记详情页操作行一致：操作行在头像行下方整行通栏，
                                          // 左缩进 52 对齐内容左缘（单元格内含 2px 水平内边距，外层减掉该值），上下留 8px。
                                          // 收藏与分享已移至帖子右上角三点菜单。
                                          Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                                52, 8, 0, 8),
                                            child: buildStatsRow(
                                              commentCount: n.commentCount,
                                              repostCount: n.repostCount,
                                              likeCount: n.likeCount,
                                              viewCount: n.viewCount,
                                              liked: liked,
                                              onComment: () => _openDetail(n),
                                              onRepost: () => _openDetail(n),
                                              onLike: () => _toggleLike(n),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                  // 发起置顶（发起人）的帖子用白色卡片包裹与下面帖子区分。
                                  if (n.id == _pinnedId) {
                                    return Container(
                                      margin: const EdgeInsets.symmetric(
                                          vertical: 2),
                                      padding: const EdgeInsets.fromLTRB(
                                          10, 2, 10, 4),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: content,
                                    );
                                  }
                                  return content;
                                },
                              ),
                      ),
                // 滚动后顶部提醒条被隐藏时的悬浮按钮：回到顶部并刷新出新帖。
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    ignoring: !_showNewPostPill,
                    child: _showNewPostPill ? _buildNewPostPill() : null,
                  ),
                ),
              ],
            ),
          ),
          // 底部输入：点击打开与笔记详情页同款大输入框（500 字），直接发布带 #话题 的帖子。
          Container(
            color: _card,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: SafeArea(
              top: false,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openComposeSheet,
                child: Container(
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: _bg,
                    borderRadius: BorderRadius.circular(21),
                  ),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '发布带 #${widget.topic} 的帖子…',
                    style: const TextStyle(color: _textHint, fontSize: 14),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 打开与笔记详情页同款的大输入弹层（SheetTextInput，500 字、多行）。
  void _openComposeSheet() {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SheetTextInput(
        title: '发布帖子',
        hint: '发布带 #${widget.topic} 的帖子…',
        maxLength: 500,
        minLines: 3,
        maxLines: 10,
        confirmText: '发表',
      ),
    ).then((content) {
      if (content != null && content.isNotEmpty) _publish(content);
    });
  }

  void _openDetail(PlazaNote n) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: n.id)),
    ).then((_) {
      if (mounted) _load();
    });
  }

  /// 分享一条帖子到系统分享面板（与笔记详情页 _share 同款文案模板）。
  Future<void> _shareNote(PlazaNote n) async {
    final plain = NoteSutraLinks.plainText(n.content);
    final text =
        '${plain.length > 120 ? '${plain.substring(0, 120)}…' : plain}\n'
        '———来自【燃灯】App · ${n.authorName} 的笔记分享\n'
        '燃一盏灯，看见自己，照亮别人\n'
        '点击进入八千大藏经世界\n'
        '下载链接：';
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('分享失败：$e')),
      );
    }
  }

  void _promptLogin() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  /// 直接发布一条带 #话题 的帖子到广场。
  Future<void> _publish(String content) async {
    try {
      await CloudNotesService.instance
          .publishNote(title: '', content: '#${widget.topic} $content');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已发布')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发布失败：$e')),
      );
    }
  }

  Future<void> _toggleLike(PlazaNote n) async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    try {
      final (liked, count) = await CloudNotesService.instance.toggleLike(n.id);
      if (!mounted) return;
      setState(() {
        final idx = _notes.indexWhere((x) => x.id == n.id);
        if (idx >= 0) {
          _notes[idx] = _copyWith(n, likeCount: count);
        }
      });
    } catch (_) {}
  }

  Future<void> _toggleFavorite(PlazaNote n) async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    try {
      await CloudNotesService.instance.toggleNoteFavorite(n.id);
      await CloudNotesService.instance.refreshFavoriteNoteIds();
      if (!mounted) return;
      setState(() {});
    } catch (_) {}
  }

  /// 编辑自己发布的话题帖子内容。
  Future<void> _editTopicNote(PlazaNote n) async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SheetTextInput(
        title: '编辑帖子',
        hint: '写下新的内容…',
        initialText: n.content,
        maxLength: 2000,
        minLines: 3,
        maxLines: 6,
        confirmText: '保存',
      ),
    );
    if (saved == null || saved.trim().isEmpty || !mounted) return;
    try {
      await CloudNotesService.instance
          .updateSharedNote(cloudId: n.id, content: saved.trim());
      if (!mounted) return;
      _showUserToast('已更新');
      await _load();
    } catch (e) {
      if (mounted) _showUserToast(e.toString());
    }
  }

  /// 删除自己发布的话题帖子。
  Future<void> _deleteTopicNote(PlazaNote n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除帖子',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: const Text('删除后帖子将从菩提空间移除，且无法恢复。确定删除吗？',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: _textSec)),
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
      await CloudNotesService.instance.deleteCloudNote(n.id);
      if (!mounted) return;
      _showUserToast('已删除');
      await _load();
    } catch (e) {
      if (mounted) _showUserToast(e.toString());
    }
  }

  /// 帖子右侧三点菜单：收藏/分享帖子 + 自己的帖子可编辑/删除，他人的可关注/屏蔽
  /// （与笔记详情页回复三点菜单同款样式）。
  Future<void> _showUserMenu(PlazaNote n) async {
    final me = AuthService.instance.currentUser.value;
    if (me == null) {
      _promptLogin();
      return;
    }
    final favorited =
        CloudNotesService.instance.favoriteNoteIds.contains(n.id);
    if (me.id == n.ownerUserId) {
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(n.authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: _text)),
                    ),
                    if (n.authorVerified) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.verified,
                          size: 15, color: Color(0xFF70867A)),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1, color: _border),
              _userMenuItem(
                  ctx,
                  'favorite',
                  favorited
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  favorited ? '取消收藏' : '收藏帖子'),
              _userMenuItem(ctx, 'share', Icons.share_rounded, '分享帖子'),
              _userMenuItem(ctx, 'edit', Icons.edit_outlined, '编辑帖子'),
              _userMenuItem(ctx, 'delete', Icons.delete_outline, '删除帖子'),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (choice == 'favorite') {
        await _toggleFavorite(n);
      } else if (choice == 'share') {
        await _shareNote(n);
      } else if (choice == 'edit') {
        await _editTopicNote(n);
      } else if (choice == 'delete') {
        await _deleteTopicNote(n);
      }
      return;
    }
    final following =
        CloudNotesService.instance.followingUserIds.contains(n.ownerUserId);
    final blocked =
        CloudNotesService.instance.blockedUserIds.contains(n.ownerUserId);
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(n.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _text)),
                  ),
                  if (n.authorVerified) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.verified,
                        size: 15, color: Color(0xFF70867A)),
                  ],
                ],
              ),
            ),
            const Divider(height: 1, color: _border),
            _userMenuItem(
                ctx,
                'favorite',
                favorited
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                favorited ? '取消收藏' : '收藏帖子'),
            _userMenuItem(ctx, 'share', Icons.share_rounded, '分享帖子'),
            _userMenuItem(
              ctx,
              following ? 'unfollow' : 'follow',
              Icons.person_add_alt,
              following ? '取消关注' : '关注该用户',
            ),
            _userMenuItem(
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
      await _toggleFavorite(n);
      return;
    }
    if (choice == 'share') {
      await _shareNote(n);
      return;
    }
    try {
      if (choice == 'follow' || choice == 'unfollow') {
        final ok = await CloudNotesService.instance.toggleFollow(n.ownerUserId);
        if (!mounted) return;
        _showUserToast(ok ? '已关注' : '已取消关注');
      } else if (choice == 'block') {
        final ok =
            await CloudNotesService.instance.toggleBlockUser(n.ownerUserId);
        if (!mounted) return;
        _showUserToast(ok ? '已屏蔽，该用户帖子不再展示' : '已取消屏蔽');
        if (ok) _load();
      } else if (choice == 'unblock') {
        final ok =
            await CloudNotesService.instance.toggleBlockUser(n.ownerUserId);
        if (!mounted) return;
        _showUserToast(ok ? '已屏蔽' : '已取消屏蔽');
      }
    } catch (e) {
      if (!mounted) return;
      _showUserToast(e.toString());
    }
  }

  Widget _userMenuItem(
      BuildContext ctx, String value, IconData icon, String label) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 18, color: _textSec),
            const SizedBox(width: 12),
            Text(label, style: const TextStyle(fontSize: 15, color: _text)),
          ],
        ),
      ),
    );
  }

  void _showUserToast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 1800),
        behavior: SnackBarBehavior.floating,
      ));
  }

  PlazaNote _copyWith(PlazaNote n, {int? likeCount}) {
    return PlazaNote(
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
      commentCount: n.commentCount,
      viewCount: n.viewCount,
      repostCount: n.repostCount,
      repostOf: n.repostOf,
      repostSourceAuthor: n.repostSourceAuthor,
      repostKind: n.repostKind,
      quoteContent: n.quoteContent,
      quoteOfTitle: n.quoteOfTitle,
      quoteOfContent: n.quoteOfContent,
      createdAt: n.createdAt,
      updatedAt: n.updatedAt,
    );
  }

  String _fmt(int ms) {
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
