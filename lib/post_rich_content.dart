import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';
import 'note_detail_page.dart';
import 'note_edit_page.dart';
import 'note_sutra_links.dart';
import 'post_time_link.dart';
import 'reading_page.dart';
import 'sutra_downloader.dart';
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

class _SutraDiscussionPageState extends State<SutraDiscussionPage> {
  List<Map<String, dynamic>> _comments = [];
  final TextEditingController _input = TextEditingController();
  bool _loading = true;
  bool _downloaded = false;
  bool _downloading = false;

  /// 每条讨论独立的本地点赞/收藏状态（讨论为本地数据，无云端指标）。
  final Set<int> _likedCommentIds = {};
  final Set<int> _favCommentIds = {};

  @override
  void initState() {
    super.initState();
    _checkDownload();
    _loadComments();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
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
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('sutra_discussion_${widget.title}') ?? '[]';
    try {
      final list =
          (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
      setState(() => _comments = list);
    } catch (_) {
      setState(() => _comments = []);
    }
  }

  Future<void> _postComment(String content) async {
    if (content.isEmpty) return;
    final me = AuthService.instance.currentUser.value;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('sutra_discussion_${widget.title}') ?? '[]';
    List<Map<String, dynamic>> list;
    try {
      list = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (_) {
      list = <Map<String, dynamic>>[];
    }
    list.insert(0, {
      'content': content,
      'name': me?.displayName ?? '同修',
      'userId': me?.id ?? '',
      'account': prefs.getString('user_account_name') ?? '',
      'verified': prefs.getBool('user_verified') ?? false,
      'likeCount': 0,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    await prefs.setString('sutra_discussion_${widget.title}', jsonEncode(list));
    if (!mounted) return;
    setState(() => _comments = list);
  }

  @override
  Widget build(BuildContext context) {
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
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                // 经书入口：经藏菜单样式（书名 + 下载状态 + 阅读按钮）。
                GestureDetector(
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
                              const Icon(Icons.download_for_offline_outlined,
                                  size: 15, color: Color(0xFFB08878)),
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
                                    : const Icon(Icons.download, size: 16),
                                label: Text(_downloading ? '下载中…' : '下载经文',
                                    style:
                                        const TextStyle(fontSize: 13)),
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFF70867A),
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
                                  backgroundColor: const Color(0xFF70867A),
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
                const SizedBox(height: 16),
                Text('讨论 ${_comments.length}',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _text)),
                const SizedBox(height: 8),
                if (_comments.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('还没有讨论，来分享你的体会吧',
                          style:
                              const TextStyle(fontSize: 13, color: _textHint)),
                    ),
                  )
                else
                  for (var i = 0; i < _comments.length; i++)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 讨论之间用分割线隔开（与主页帖子一致）。
                        if (i > 0)
                          const Divider(
                              height: 1,
                              thickness: 0.6,
                              color: Color(0xFFD8CCBC)),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: _buildCommentRow(_comments[i], i),
                        ),
                      ],
                    ),
              ],
            ),
          ),
          // 讨论输入
          Container(
            color: _card,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 42,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: _bg,
                        borderRadius: BorderRadius.circular(21),
                      ),
                      child: TextField(
                        controller: _input,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        style: const TextStyle(fontSize: 14, color: _text),
                        decoration: const InputDecoration(
                          hintText: '说说你的体会…',
                          hintStyle: TextStyle(color: _textHint),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: _send,
                    icon: const Icon(Icons.send_rounded,
                        color: Color(0xFF70867A), size: 22),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _send() {
    final content = _input.text.trim();
    if (content.isEmpty) return;
    _input.clear();
    _postComment(content);
  }

  /// 讨论行：与主页帖子同款（头像 + 昵称/认证/@账号/时间 + 内容 + 六个指标）。
  Widget _buildCommentRow(Map<String, dynamic> c, int index) {
    final userId = c['userId']?.toString() ?? '';
    final account = c['account']?.toString() ?? '';
    final verified = c['verified'] == true;
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
                  ],
                  const SizedBox(width: 6),
                  Text(
                    _fmtTime((c['at'] as num?)?.toInt() ?? 0),
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF8C8C8C)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(c['content']?.toString() ?? '',
                  style: const TextStyle(
                      fontSize: 15, color: _text, height: 1.6)),
              const SizedBox(height: 10),
              _buildCommentMetricRow(c, index),
            ],
          ),
        ),
      ],
    );
  }

  /// 讨论的六个指标：评论/转发/点赞/阅读 + 收藏/分享（与笔记详情页评论操作行一致）。
  Widget _buildCommentMetricRow(Map<String, dynamic> c, int index) {
    final liked = _likedCommentIds.contains(index);
    final favorited = _favCommentIds.contains(index);
    return Row(
      children: [
        Image.asset('assets/images/ic_comment.png', width: 16, height: 16),
        const SizedBox(width: 28),
        Icon(Icons.repeat_rounded, size: 16, color: _textSec),
        const SizedBox(width: 28),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() {
            final likeCount = ((c['likeCount'] as num?)?.toInt() ?? 0) +
                (liked ? -1 : 1);
            c['likeCount'] = likeCount < 0 ? 0 : likeCount;
            if (!_likedCommentIds.remove(index)) _likedCommentIds.add(index);
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                    liked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    size: 16,
                    color: liked ? _gold : _textSec),
                const SizedBox(width: 3),
                Text('${c['likeCount'] ?? 0}',
                    style: TextStyle(
                        fontSize: 13, color: liked ? _gold : _textSec)),
              ],
            ),
          ),
        ),
        const SizedBox(width: 28),
        Image.asset('assets/images/ic_view.png', width: 16, height: 16),
        const Spacer(),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() {
            if (!_favCommentIds.remove(index)) _favCommentIds.add(index);
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Icon(
                favorited
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                size: 16,
                color: favorited ? _gold : _textSec),
          ),
        ),
        const SizedBox(width: 20),
        Icon(Icons.share_rounded, size: 16, color: _textSec),
      ],
    );
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (t.year == now.year) return '${t.month}月${t.day}日';
    return '${t.year}年${t.month}月${t.day}日';
  }
}

/// 话题页：展示含该话题的所有帖子。
class TopicPage extends StatefulWidget {
  final String topic;
  const TopicPage({super.key, required this.topic});

  @override
  State<TopicPage> createState() => _TopicPageState();
}

class _TopicPageState extends State<TopicPage> {
  List<PlazaNote> _notes = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final (list, _) = await CloudNotesService.instance
          .getPlazaNotes(page: 1, pageSize: 100);
      final tag = '#${widget.topic}';
      if (!mounted) return;
      setState(() {
        _notes = list.where((n) => n.content.contains(tag)).toList();
        _loading = false;
      });
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
      // 右下角新建按钮：在此新建自动带上 #话题。
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(
          width: 48,
          height: 48,
          child: FloatingActionButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => NoteEditPage(fixedTopic: widget.topic)),
            ).then((_) => _load()),
            heroTag: 'topic_fab_${widget.topic}',
            backgroundColor: const Color(0xFF71867A),
            elevation: 8,
            highlightElevation: 12,
            shape: const CircleBorder(),
            child: const Icon(Icons.add, color: Colors.white, size: 24),
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(strokeWidth: 2, color: _gold))
          : _notes.isEmpty
              ? const Center(
                  child: Text('还没有该话题的帖子',
                      style: TextStyle(fontSize: 14, color: _textHint)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
                  itemCount: _notes.length,
                  separatorBuilder: (_, __) => const Divider(
                      height: 1, thickness: 0.6, color: Color(0xFFD8CCBC)),
                  itemBuilder: (context, index) {
                    final n = _notes[index];
                    final liked =
                        CloudNotesService.instance.likedNoteIds.contains(n.id);
                    final fav = CloudNotesService.instance.favoriteNoteIds
                        .contains(n.id);
                    // 与主页帖子同款：头像 + 昵称/@账号/认证/时间 + 内容 + 六个指标。
                    return InkWell(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => NoteDetailPage(noteId: n.id)),
                      ),
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
                                          // 点击 @账户名 进入该用户个人主页（青色提示可点击）。
                                          child: AccountLink(
                                            account: n.authorAccount,
                                            onTap: () {
                                              if (n.ownerUserId.isNotEmpty) {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                      builder: (_) =>
                                                          UserSpacePage(
                                                              userId: n
                                                                  .ownerUserId)),
                                                );
                                              }
                                            },
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: 3),
                                      Text(_fmt(n.createdAt),
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFF8C8C8C))),
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
                                    overflow: TextOverflow.ellipsis,
                                    onUserTap: (uid) {
                                      if (uid.isNotEmpty) {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) =>
                                                  UserSpacePage(userId: uid)),
                                        );
                                      }
                                    },
                                    onSutraTap: (title, path) {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => SutraDiscussionPage(
                                                title: title, filePath: path)),
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
                                  ),
                                  const SizedBox(height: 8),
                                  // 六个指标：评论/转发/点赞/阅读/收藏/分享。
                                  // 相对位置与笔记详情页的操作行一致：前四项均匀分布，收藏/分享靠右。
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            _buildActionCell(
                                                Image.asset(
                                                    'assets/images/ic_comment.png',
                                                    width: 18,
                                                    height: 18),
                                                _textSec,
                                                '${n.commentCount}',
                                                () => _openDetail(n)),
                                            _buildActionCell(
                                                const Icon(
                                                    Icons.repeat_rounded,
                                                    size: 18,
                                                    color: _textSec),
                                                _textSec,
                                                '${n.repostCount}',
                                                () => _openDetail(n)),
                                            _buildActionCell(
                                                Icon(
                                                    liked
                                                        ? Icons
                                                            .favorite_rounded
                                                        : Icons
                                                            .favorite_border_rounded,
                                                    size: 18,
                                                    color: liked
                                                        ? _gold
                                                        : _textSec),
                                                liked ? _gold : _textSec,
                                                '${n.likeCount}',
                                                () => _toggleLike(n)),
                                            _buildActionCell(
                                                Image.asset(
                                                    'assets/images/ic_view.png',
                                                    width: 18,
                                                    height: 18),
                                                _textSec,
                                                '${n.viewCount}',
                                                null),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 36),
                                      _buildActionCell(
                                          Icon(
                                              fav
                                                  ? Icons.bookmark_rounded
                                                  : Icons.bookmark_border_rounded,
                                              size: 18,
                                              color: fav ? _gold : _textSec),
                                          fav ? _gold : _textSec,
                                          '',
                                          () => _toggleFavorite(n)),
                                      const SizedBox(width: 6),
                                      _buildActionCell(
                                          const Icon(Icons.share_rounded,
                                              size: 18, color: _textSec),
                                          _textSec,
                                          '',
                                          () => _openDetail(n)),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  /// 与笔记详情页同款的操作单元格：图标 + 数字，数字过大时自动缩放。
  Widget _buildActionCell(Widget icon, Color color, String text,
      VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 18, height: 18, child: icon),
            if (text.isNotEmpty) ...[
              const SizedBox(width: 3),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(text,
                      style: TextStyle(fontSize: 15, height: 1, color: color)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openDetail(PlazaNote n) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: n.id)),
    ).then((_) {
      if (mounted) _load();
    });
  }

  void _promptLogin() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  Future<void> _toggleLike(PlazaNote n) async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    try {
      final (liked, count) =
          await CloudNotesService.instance.toggleLike(n.id);
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
    if (t.year == now.year) return '${t.month}月${t.day}日';
    return '${t.year}年${t.month}月${t.day}日';
  }
}
