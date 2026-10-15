import 'dart:async';
import 'dart:math' show pow;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';
import 'my_page.dart';
import 'note_detail_page.dart';
import 'note_sutra_links.dart';
import 'post_time_link.dart';
import 'reading_badges.dart';
import 'reading_note_post.dart';
import 'reading_page.dart';
import 'reading_sutra_notes_page.dart';
import 'sect_community_page.dart' show communityTone;
import 'sect_switch.dart';
import 'sutra_availability.dart';
import 'sutra_downloader.dart';
import 'sutra_list_page.dart';
import 'text_input_sheet.dart';
import 'user_avatar.dart';
import 'user_space_page.dart';

import 'app_palette.dart';

Color get _gold => AppPalette.p.accent;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _border => AppPalette.p.border;

/// 与云端 getPlazaNotes「hot」同款的热度衰减分：
/// (1 + 互动量) / (发帖小时龄 + 2)^1.3。
/// 热帖靠前但随时间下沉，新帖随时有机会浮上来。
/// 互动量权重与云端一致：阅读 + 赞×3 + 评论×5 + 转发×8；
/// 经书讨论没有阅读/评论计数，只按 赞×3 折算，让两路来源能用同一把尺子混排。
double discussionHotScore(int createdAt, int engagement) {
  final ageHours =
      ((DateTime.now().millisecondsSinceEpoch - createdAt) / 3600000)
          .clamp(0, double.infinity);
  return (1 + engagement) / pow(ageHours + 2, 1.3);
}

/// 经书讨论页「画线 / 备注 / 笔记」三个标签的归类。
enum SutraNoteKind { highlight, remark, note }

/// 把一条引用本经的帖子归入唯一一类（三个标签互斥、不重复）：
///   1. 画线分享帖（§§HS§§）            → [SutraNoteKind.highlight]
///   2. 按段感想 / 读经备注（§§TS§§ 或 单条「读经备注」分享）→ [SutraNoteKind.remark]
///   3. 读经笔记汇总帖（§§SN§§）        → [SutraNoteKind.note]
///   4. 其余（普通 $经名 引用帖等）      → [SutraNoteKind.note]
///
/// 注意判定顺序：画线帖与读经笔记汇总帖的正文也符合单条「读经备注」的形态，
/// 必须先按哨兵排除，否则它们会同时落进「备注」，造成三个标签串味。
SutraNoteKind classifySutraNote(String content) {
  if (SutraHighlightsPost.isHighlightsPost(content)) {
    return SutraNoteKind.highlight;
  }
  if (SutraThoughtsPost.isThoughtsPost(content)) {
    return SutraNoteKind.remark;
  }
  if (SutraNotesPost.isSutraNotesPost(content)) {
    return SutraNoteKind.note;
  }
  if (ReadingNotePost.isReadingNote(content)) {
    return SutraNoteKind.remark;
  }
  return SutraNoteKind.note;
}

/// `[@账号](user:用户ID)` 提及用户、`$经书名` 引用经文、`#话题名` 话题；
/// 兼容旧式 `[@经名](路径)` 与 `@经书名`。
///
/// [multiVolumeBases] 为多卷经书的基础经名集合：$引用只写了基础经名时，
/// 多卷经书统一补显「卷一」卷标（与热门榜/胶囊一致）；引用后紧跟的中文卷标
/// （如「$高僧传卷五」）会整体并入链接显示。
Widget buildPostRichText(
  String text, {
  required TextStyle style,
  required Map<String, NoteSutraLink> library,
  required void Function(String userId) onUserTap,
  required void Function(String title, String filePath) onSutraTap,
  required void Function(String topic) onTopicTap,
  Color linkColor = const Color(0xFF70867A),
  Color? topicColor,
  Set<String>? multiVolumeBases,
  int? maxLines,
  TextOverflow? overflow,
}) {
  final userTokenRe = RegExp(r'\[@([^\]]+)\]\(user:([^)]+)\)');
  final topicRe = RegExp(r'#([^\s#，。！？,;:!?（）()]+)');

  WidgetSpan linkSpan(String label, VoidCallback onTap, {Color? color}) {
    final linkStyle = style.copyWith(
      color: color ?? linkColor,
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
        // 引用后紧跟中文卷标（如「$高僧传卷五」）：整体并入链接显示；
        // 只写基础经名的多卷经书：统一补显「卷一」（与热门榜/胶囊一致）。
        final after = i + 1 + t.length;
        final volMatch = after < text.length
            ? chineseVolumePrefixRe.matchAsPrefix(text, after)
            : null;
        final trailing = volMatch?.group(0) ?? '';
        final supplement =
            trailing.isEmpty && (multiVolumeBases?.contains(t) ?? false)
                ? '卷一'
                : '';
        // 带卷标的引用定位到具体卷的正文路径（如「$高僧传卷十一」打开卷十一，
        // 而不是目录缓存的第一卷）；查不到该卷时回退到第一部路径。
        final trailingVolume =
            trailing.isEmpty ? 0 : parseChineseVolumeNumber(trailing);
        final tapPath = (trailingVolume > 0
                ? NoteSutraCatalog.cachedVolumePath(t, trailingVolume)
                : null) ??
            library[t]!.filePath;
        spans.add(linkSpan(
            text[i] + t + trailing + supplement, () => onSutraTap(t, tapPath)));
        i += 1 + t.length + trailing.length;
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
        spans.add(linkSpan('#$topic', () => onTopicTap(topic),
            color: topicColor ?? const Color(0xFFcf9e66)));
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
  bool _loading = true;
  bool _downloaded = false;
  bool _downloading = false;

  /// 广场上引用该经书（$经名 / @经名）的帖子：备注 / 笔记标签页的数据源。
  List<PlazaNote> _relatedNotes = [];

  /// 相关帖子（笔记/备注）是否正在加载。
  bool _relatedLoading = false;

  /// 本经「全站所有用户」的画线聚合（云端从各用户时间线聚合而来）。
  /// 与 [_relatedNotes] 里的「分享画线帖」并列展示在画线标签页：前者是每个人
  /// 各自画下的经文原句（自动同步、无需手动分享），后者是用户主动分享的汇总帖。
  List<SutraHighlightItem> _sutraHighlights = [];

  /// 全站画线是否正在加载。
  bool _highlightsLoading = false;

  /// 全站画线的作者资料（uid → 资料），用于在每条单独画线上显示用户名。
  Map<String, UserProfile> _highlightAuthors = const {};

  /// 相关帖子的本地点藏状态（按帖子 id 记录）。
  final Set<String> _relatedFavIds = {};

  /// 经书目录映射：渲染相关帖子里的 $经名/@经名 链接。
  Map<String, NoteSutraLink> _sutraLibrary = const {};

  /// 按卷区分相关帖子时用到的卷号（0 表示未知/无卷号）。
  int _discussionVolume = 0;

  /// 相关帖子的滚动控制器。
  final ScrollController _scroll = ScrollController();

  /// 当前选中的标签页：0=笔记，1=备注，2=画线。
  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    _checkDownload();
    // 经书目录（含多卷经名集合）就绪后计算按卷区分的卷号，再加载相关帖子：
    // 多卷经书的相关帖子按卷拆分，避免各卷混在一起。
    // 目录加载失败时也继续（退回基础经名），不能卡住页面。
    NoteSutraCatalog.load()
        .then((_) => _onCatalogReady(), onError: (_) => _onCatalogReady());
  }

  void _onCatalogReady() {
    if (!mounted) return;
    _initVolume();
    setState(() {});
    _loadRelatedNotes();
    _loadSutraHighlights();
  }

  /// 计算按卷区分的卷号：标题或 filePath 能定位具体卷时取其卷号，否则为 0。
  void _initVolume() {
    var t = widget.title;
    if (sutraVolumeOf(t) <= 0 && widget.filePath.isNotEmpty) {
      final id = SutraDownloader.extractId(null, widget.filePath);
      if (id != null) t = '${widget.title}$id';
    }
    _discussionVolume = sutraVolumeOf(t);
  }

  /// 经书展示名：从带卷标的链接进入时（filePath 指向具体卷）显示具体卷标；
  /// 其余情况按聚合规则——带卷号后缀显示具体卷标，仅基础经名的多卷经书补「卷一」。
  String get _displayTitle => sutraDiscussionDisplayName(widget.title,
      filePath: widget.filePath,
      multiVolumeBases: NoteSutraCatalog.cachedMultiVolumeBases);

  /// 本经元信息（部类 · N 字）：供「本经没有笔记」时的顶部卡片使用。
  /// 部类取编目里基础经名的部类；字数优先当前这一卷，取不到再退全书。
  String get _sutraMeta {
    var base = sutraBaseTitle(widget.title);
    var volume = sutraVolumeOf(widget.title);
    if (volume <= 0) {
      final m = chineseVolumeSuffixRe.firstMatch(base);
      if (m != null) {
        base = base.substring(0, m.start).trim();
        volume = parseChineseVolumeNumber(m.group(0)!);
      }
    }
    final parts = <String>[];
    final link = NoteSutraCatalog.cachedTitleMap?[base];
    if (link != null) {
      final dept = link.folder.replaceAll(RegExp(r'^T\d+'), '').trim();
      if (dept.isNotEmpty) parts.add(dept);
    }
    var chars = NoteSutraCatalog.cachedCharCountForRawTitle(widget.title);
    if (chars <= 0 && volume > 0) {
      chars = NoteSutraCatalog.cachedVolumeCharCount(base, volume);
    }
    if (chars <= 0) chars = NoteSutraCatalog.cachedCharCount(base);
    if (chars > 0) parts.add('$chars 字');
    return parts.join(' · ');
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 检测经文是否已下载：统一走 [isSutraDownloaded]，与经藏页/热门榜/收藏等
  /// 所有入口共用同一口径。只要任一入口下载过，这里都会显示「已下载」，
  /// 不再因入口不同（路径形式、是否只落盘编辑副本等）而误判成未下载。
  Future<void> _checkDownload() async {
    final ok = await isSutraDownloaded(
      title: widget.title,
      filePath: widget.filePath,
    );
    if (!mounted) return;
    setState(() {
      _downloaded = ok;
      _loading = false;
    });
  }

  /// 下载经文并在按钮上转圈；[thenRead] 为真时下载完成后直接进入阅读页。
  Future<void> _downloadSutra({bool thenRead = false}) async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final id = await resolveSutraId(
          title: widget.title, filePath: widget.filePath);
      if (id == null || id.isEmpty) {
        throw Exception('无法解析经文');
      }
      await SutraDownloader.download(id);
      await markSutraDownloaded(id);
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloaded = true;
      });
      if (thenRead) _openRead();
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

  /// 拉取广场上引用本经书的帖子（$经名 / @经名），与讨论混排在统一列表里。
  /// 能定位具体卷时只取引用本卷的帖子（卷一含只写基础经名的引用），
  /// 避免多卷经书各卷讨论页混在一起。
  Future<void> _loadRelatedNotes() async {
    if (mounted && !_relatedLoading) setState(() => _relatedLoading = true);
    try {
      if (_sutraLibrary.isEmpty) {
        _sutraLibrary = await NoteSutraCatalog.titleMap();
      }
      final (list, _) = await CloudNotesService.instance
          .getPlazaNotes(page: 1, pageSize: 100);
      if (!mounted) return;
      final base = sutraBaseTitle(widget.title);
      final vol = _discussionVolume;
      setState(() {
        _relatedNotes = list
            .where((n) => vol <= 0
                ? NoteSutraLinks.referencesSutra(n.content, base)
                : referencesSutraVolume(n.content, base, vol))
            .toList();
        _relatedLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _relatedNotes = [];
        _relatedLoading = false;
      });
    }
  }

  /// 拉取本经「全站所有用户」的画线（云端聚合）。每条是被画下的经文原句，
  /// 不去重；能定位具体卷时只留本卷的画线（卷一含只写基础经名的记录）。
  Future<void> _loadSutraHighlights() async {
    if (mounted && !_highlightsLoading) {
      setState(() => _highlightsLoading = true);
    }
    final base = sutraBaseTitle(widget.title);
    final vol = _discussionVolume;
    try {
      final all =
          await CloudNotesService.instance.getSutraHighlights(base);
      if (!mounted) return;
      final filtered = vol <= 0
          ? List<SutraHighlightItem>.of(all)
          : all
              .where((h) => referencesSutraVolume('\$${h.sutraKey}', base, vol))
              .toList();
      // 云端在缺索引时可能不排序：这里统一按时间倒序，最新画线在前。
      filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      // 单独画线要显示用户名：按去重后的作者 uid 批量取资料（一条画线不带昵称）。
      final ids = <String>{
        for (final h in filtered)
          if (h.ownerUserId.isNotEmpty) h.ownerUserId,
      }.take(100).toList();
      var authors = _highlightAuthors;
      if (ids.isNotEmpty) {
        try {
          final profiles =
              await CloudNotesService.instance.getUserProfiles(ids);
          if (!mounted) return;
          authors = {for (final p in profiles) p.id: p};
        } catch (_) {
          // 取不到资料就退回昵称占位（同修），不影响画线文字展示。
        }
      }
      if (!mounted) return;
      setState(() {
        _sutraHighlights = filtered;
        _highlightAuthors = authors;
        _highlightsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sutraHighlights = [];
        _highlightsLoading = false;
      });
    }
  }

  /// 下拉刷新：重新拉取「广场相关帖子」（备注 / 笔记数据源）。
  Future<void> _refreshAll() async {
    await Future.wait([_loadRelatedNotes(), _loadSutraHighlights()]);
  }

  void _promptLogin() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  @override
  Widget build(BuildContext context) {
    final hottest = _hottestNote;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        // 双击标题回到页面顶部。
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: _scrollToTop,
          child: Text(_displayTitle,
              style: TextStyle(
                  color: _text, fontSize: 17, fontWeight: FontWeight.w600)),
        ),
      ),
      // 右下角：进入本经阅读页（未下载时先下载并在按钮上转圈）。
      floatingActionButton: _buildReadFab(),
      // 左右滑动切换「笔记 / 备注 / 画线」。
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: _onHorizontalDragEnd,
        child: RefreshIndicator(
          onRefresh: _refreshAll,
          color: _gold,
          child: ListView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            // 底部留出悬浮按钮的高度，避免遮住最后一条。
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
            children: [
              // 顶部卡片：本经最热门的一条笔记（样式同宗门页顶部展示位）；
              // 本经没有笔记时改为展示经文标题 + 部类 · 字数，点击进入阅读。
              if (hottest != null) ...[
                _buildHottestCard(hottest),
                const SizedBox(height: 16),
              ] else ...[
                _buildSutraInfoCard(),
                const SizedBox(height: 16),
              ],
              // 三个入口：笔记 / 备注 / 画线（采用宗派法门页的连体切换条样式）。
              SegmentedSwitch(
                index: _currentTab,
                labels: const ['笔记', '备注', '画线'],
                onChanged: (i) => setState(() => _currentTab = i),
                tone: communityTone(AppPalette.instance.isPlain),
              ),
              // 内容区域
              const SizedBox(height: 16),
              if (_currentTab == 0)
                _buildNotesTab()
              else if (_currentTab == 1)
                _buildRemarksTab()
              else
                _buildHighlightsTab(),
            ],
          ),
        ),
      ),
    );
  }

  /// 左右滑动切换「笔记 / 备注 / 画线」标签页（与三个按钮联动）。
  void _onHorizontalDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v <= -200 && _currentTab < 2) {
      setState(() => _currentTab++);
    } else if (v >= 200 && _currentTab > 0) {
      setState(() => _currentTab--);
    }
  }

  /// 回到页面顶部（双击顶部经文标题触发）。
  void _scrollToTop() {
    if (_scroll.hasClients && _scroll.offset > 0) {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  /// 右下角按钮：进入本经阅读页。样式与「消息」菜单右下角的「继续阅读」按钮一致
  /// （素白黑底 / 米黄绿底 + yt.png 图标，42 圆）；未下载时先下载并在按钮上转圈。
  Widget _buildReadFab() {
    final busy = _loading || _downloading;
    final isPlain = AppPalette.instance.isPlain;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: SizedBox(
        width: 42,
        height: 42,
        child: FloatingActionButton(
          heroTag: 'sutra_discuss_read_fab',
          backgroundColor:
              isPlain ? const Color(0xFF1A1A1A) : const Color(0xFF71867A),
          elevation: 8,
          highlightElevation: 12,
          shape: const CircleBorder(),
          onPressed: _onTapReadFab,
          child: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: Colors.white),
                )
              : Image.asset('assets/images/yt.png', width: 21, height: 21),
        ),
      ),
    );
  }

  void _onTapReadFab() {
    if (_loading || _downloading) return;
    if (_downloaded) {
      _openRead();
    } else {
      _downloadSutra(thenRead: true);
    }
  }

  /// 本经相关帖子里的「笔记」中最热的一条（互动量与时间衰减口径同广场热榜）。
  /// 只从笔记里挑，不从画线 / 备注里挑（顶部展示位只展示笔记）。
  PlazaNote? get _hottestNote {
    PlazaNote? best;
    var bestScore = 0.0;
    for (final n in _relatedNotes) {
      if (!_isKind(n, SutraNoteKind.note)) continue;
      final s = discussionHotScore(
        n.createdAt,
        n.viewCount + n.likeCount * 3 + n.commentCount * 5 + n.repostCount * 8,
      );
      if (best == null || s > bestScore) {
        best = n;
        bestScore = s;
      }
    }
    return best;
  }

  /// 顶部卡片：把本经最热门的一条笔记做成展示位，样式同宗门页顶部展示位
  /// （淡墨远山铺底 + 火把 + 摘要 + 互动小字 + 右下角「查看笔记」）。
  Widget _buildHottestCard(PlazaNote n) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Material(
        color: _card,
        child: InkWell(
          onTap: () => _openHottestNote(n),
          child: Stack(
            children: [
              Positioned.fill(
                child: Opacity(
                  opacity: 0.2,
                  child: Image.asset(
                    'assets/menpai/mih.png',
                    fit: BoxFit.cover,
                    alignment: Alignment.bottomRight,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.local_fire_department,
                            size: 18, color: Color(0xFFD93B28)),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text('最热门笔记',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: _text,
                                  letterSpacing: 0.8)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${_hottestAuthor(n)}：${_hottestExcerpt(n)}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: _textSec,
                          height: 1.55,
                          letterSpacing: 0.2),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            _hottestMeta(n),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: _textSec,
                                height: 1.5,
                                letterSpacing: 0.2),
                          ),
                        ),
                        const SizedBox(width: 10),
                        _buildCardHint('查看笔记'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶部卡片（本经没有笔记时）：展示经文标题 + 部类 · 字数，点击进入阅读。
  /// 视觉与「最热门笔记」卡片同款（淡墨远山铺底 + 经文图标 + 元信息 + 右下角「阅读」）。
  Widget _buildSutraInfoCard() {
    final meta = _sutraMeta;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Material(
        color: _card,
        child: InkWell(
          onTap: _openRead,
          child: Stack(
            children: [
              Positioned.fill(
                child: Opacity(
                  opacity: 0.2,
                  child: Image.asset(
                    'assets/menpai/mih.png',
                    fit: BoxFit.cover,
                    alignment: Alignment.bottomRight,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.menu_book_rounded, size: 18, color: _gold),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(_displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: _text,
                                  letterSpacing: 0.8)),
                        ),
                      ],
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(meta,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: _textSec,
                              height: 1.55,
                              letterSpacing: 0.2)),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Spacer(),
                        _buildCardHint('阅读'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 卡片右下角「… ›」按钮：底色随外观切换（素白青绿 / 米黄暖金）。
  Widget _buildCardHint(String label) {
    final tone = communityTone(AppPalette.instance.isPlain);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: tone,
                  letterSpacing: 0.4)),
          Icon(Icons.chevron_right, size: 15, color: tone),
        ],
      ),
    );
  }

  String _hottestAuthor(PlazaNote n) {
    final name = n.authorName.trim();
    if (name.isNotEmpty) return name;
    final account = n.authorAccount.trim();
    if (account.isNotEmpty) return '@$account';
    return '同修';
  }

  String _hottestExcerpt(PlazaNote n) {
    final title = n.title.trim();
    final raw = title.isNotEmpty && title != '无标题' ? title : n.content;
    final text =
        NoteSutraLinks.plainText(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.isEmpty ? '（无正文）' : text;
  }

  String _hottestMeta(PlazaNote n) {
    final parts = <String>[
      if (n.createdAt > 0) _fmtTime(n.createdAt),
      if (n.likeCount > 0) '${n.likeCount} 赞',
      if (n.commentCount > 0) '${n.commentCount} 回复',
      if (n.viewCount > 0) '${n.viewCount} 阅读',
    ];
    return parts.join(' · ');
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
                                  style: TextStyle(
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
                  if (SutraThoughtsPost.isThoughtsPost(n.content))
                    SutraThoughtsPostView(
                      post: SutraThoughtsPost.parse(n.content)!,
                      noteId: n.id,
                      sutraLibrary: _sutraLibrary,
                      authorName: n.authorName,
                      ownerUserId: n.ownerUserId,
                    )
                  else if (SutraHighlightsPost.isHighlightsPost(n.content))
                    SutraHighlightsPostView(
                      post: SutraHighlightsPost.parse(n.content)!,
                      noteId: n.id,
                      sutraLibrary: _sutraLibrary,
                      authorName: n.authorName,
                      ownerUserId: n.ownerUserId,
                    )
                  else if (SutraNotesPost.isSutraNotesPost(n.content))
                    SutraNotesPostView(
                      post: SutraNotesPost.parse(n.content)!,
                      noteId: n.id,
                      sutraLibrary: _sutraLibrary,
                      authorName: n.authorName,
                      ownerUserId: n.ownerUserId,
                    )
                  else if (ReadingNotePost.isReadingNote(n.content))
                    ReadingNotePostView(
                      note: ReadingNotePost.parse(n.content)!,
                      noteId: n.id,
                      sutraLibrary: _sutraLibrary,
                      authorName: n.authorName,
                    )
                  else
                    buildPostRichText(
                      n.content,
                      style: TextStyle(fontSize: 15, color: _text, height: 1.6),
                      library: _sutraLibrary,
                      multiVolumeBases: NoteSutraCatalog.cachedMultiVolumeBases,
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

  /// 顶部卡片「查看笔记」：打开该笔记帖的「读经笔记」详情页（笔记详情），
  /// 而不是菩提空间的帖子详情页。帖子不是读经笔记帖时退回帖子详情。
  void _openHottestNote(PlazaNote n) {
    final post = SutraNotesPost.parse(n.content);
    if (post == null) {
      _openRelatedDetail(n);
      return;
    }
    final initialNotes = <Map<String, dynamic>>[
      for (final text in post.notes)
        {
          'id': '',
          'content': text,
          'updatedAt': DateTime.now().toIso8601String(),
          'shared': true,
          'cloudId': null,
        },
    ];
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingSutraNotesPage(
          title: post.sutraTitle,
          ownerUserId: n.ownerUserId,
          initialNotes: initialNotes,
          noteId: n.id,
          canDelete: false,
        ),
      ),
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
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _text)),
              ),
              Divider(height: 1, color: _border),
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
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            Divider(height: 1, color: _border),
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
            Text(label, style: TextStyle(fontSize: 15, color: _text)),
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

  /// 判断一条广场笔记是否是本经的「备注」（按段感想 / 单段笔记）：
  /// 「备注」标签页只展示同修的备注类分享。
  bool _isKind(PlazaNote n, SutraNoteKind kind) =>
      classifySutraNote(n.content) == kind;

  /// 相关帖子加载中的占位（备注 / 笔记标签页共用）。
  Widget _buildRelatedLoading() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: _gold)),
      ),
    );
  }

  /// 相关帖子空态占位。
  Widget _buildRelatedEmpty(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(text,
            style: TextStyle(fontSize: 13, color: _textHint)),
      ),
    );
  }

  /// 把一批相关帖子渲染为带分割线的列表。
  Widget _buildRelatedList(List<PlazaNote> notes) {
    return Column(
      children: [
        for (var i = 0; i < notes.length; i++) ...[
          if (i > 0) ...[
            const SizedBox(height: 8),
            Divider(height: 1, thickness: 0.5, color: AppPalette.p.divider),
            const SizedBox(height: 8),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: _buildRelatedNote(notes[i]),
          ),
        ],
      ],
    );
  }

  /// 「画线」标签页：本经所有用户画下的经文原句（自动聚合、无需手动分享）
  /// + 用户主动分享到菩提空间的画线汇总帖。与其他帖子行一样用分割线分隔，
  /// 单条画线不加边框卡片。
  Widget _buildHighlightsTab() {
    final loading = (_relatedLoading && _relatedNotes.isEmpty) ||
        (_highlightsLoading && _sutraHighlights.isEmpty);
    if (loading) {
      return _buildRelatedLoading();
    }
    final lines = _relatedNotes
        .where((n) => _isKind(n, SutraNoteKind.highlight))
        .toList();
    if (_sutraHighlights.isEmpty && lines.isEmpty) {
      return _buildRelatedEmpty('还没有同修画线');
    }
    return _buildDividedRows([
      // 全站画线：每个人各自画下的经文原句，重复画线也照显示（不去重）。
      for (final h in _sutraHighlights) _buildHighlightItem(h),
      for (final n in lines) _buildRelatedNote(n),
    ]);
  }

  /// 用与其他帖子一致的分割线列表渲染一批行（画线与分享帖混排共用）。
  Widget _buildDividedRows(List<Widget> rows) {
    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) ...[
            const SizedBox(height: 8),
            Divider(height: 1, thickness: 0.5, color: AppPalette.p.divider),
            const SizedBox(height: 8),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: rows[i],
          ),
        ],
      ],
    );
  }

  /// 一条全站画线：作者（头像 + 昵称/认证/@账号/阅藏百分比，同帖子行）+ 经文原句 + 时间。
  Widget _buildHighlightItem(SutraHighlightItem h) {
    final author = _highlightAuthors[h.ownerUserId];
    final name = (author?.name.isNotEmpty ?? false) ? author!.name : '同修';
    final account = author?.account ?? '';
    final verified = author?.verified ?? false;
    final me = AuthService.instance.currentUser.value;
    final pct = postCanonPercent(
      isSelf: me != null && me.id == h.ownerUserId,
      cloudRead: author?.canonRead ?? 0,
      cloudTotal: author?.canonTotal ?? 0,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UserAvatar(userId: h.ownerUserId, radius: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(name,
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
                      child: AccountLink(
                        account: account,
                        onTap: () {
                          if (h.ownerUserId.isNotEmpty) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => UserSpacePage(
                                      userId: h.ownerUserId)),
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 3),
                    const Text('·',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFF8C8C8C))),
                    const SizedBox(width: 2),
                    Text(pct,
                        maxLines: 1,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF8C8C8C))),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              // 画线经文：用读经页同款「每行点线」下划线标出（与真实画线一致）。
              SutraUnderlineText(
                text: h.text,
                style: TextStyle(fontSize: 15, color: _text, height: 1.7),
                lineColor: _gold.withValues(alpha: 0.8),
              ),
              // 画线时间：与帖子行同款（内容之后展示）。
              const SizedBox(height: 6),
              Text(_fmtTime(h.createdAt),
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF8C8C8C))),
            ],
          ),
        ),
      ],
    );
  }

  /// 「备注」标签页：该经文所有用户分享到菩提空间的备注（按段感想）。
  Widget _buildRemarksTab() {
    if (_relatedLoading && _relatedNotes.isEmpty) {
      return _buildRelatedLoading();
    }
    final remarks =
        _relatedNotes.where((n) => _isKind(n, SutraNoteKind.remark)).toList();
    if (remarks.isEmpty) {
      return _buildRelatedEmpty('还没有同修分享备注');
    }
    return _buildRelatedList(remarks);
  }

  /// 「笔记」标签页：该经文所有用户分享到菩提空间的笔记汇总。
  Widget _buildNotesTab() {
    if (_relatedLoading && _relatedNotes.isEmpty) {
      return _buildRelatedLoading();
    }
    final notes =
        _relatedNotes.where((n) => _isKind(n, SutraNoteKind.note)).toList();
    if (notes.isEmpty) {
      return _buildRelatedEmpty('还没有同修分享笔记');
    }
    return _buildRelatedList(notes);
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
/// 排序：发起人帖置顶（公告位）→ 我刚发布的帖子短暂置顶（30 分钟内，
/// 仅自己可见；历史帖不置顶）→ 其余按热度衰减分倒序（与「发现」同款）。
class TopicPage extends StatefulWidget {
  final String topic;
  const TopicPage({super.key, required this.topic});

  @override
  State<TopicPage> createState() => _TopicPageState();
}

class _TopicPageState extends State<TopicPage> with WidgetsBindingObserver {
  List<PlazaNote> _notes = [];
  bool _loading = true;

  /// 话题发起人帖子的 id（服务端权威查出的最早一条，置顶展示并标注「发起人」；
  /// 若超出分页范围不在结果集里，则不显示标签）。
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
      // 服务端按话题过滤后统计新帖 id，不再客户端筛 tag。
      final (list, _, _, _) = await CloudNotesService.instance
          .getTopicNotes(widget.topic, pageSize: _pageSize);
      if (!mounted) return;
      final known = _notes.map((n) => n.id).toSet();
      final count = list.where((n) => !known.contains(n.id)).length;
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
      // 服务端按 #话题 精确过滤 + 热度衰减分倒序返回，并附带发起人帖 id
      // （最早的含该话题帖子，不受分页截断影响）。
      final (list, _, firstId, _) = await CloudNotesService.instance
          .getTopicNotes(widget.topic, pageSize: _pageSize);
      if (!mounted) return;
      setState(() {
        _pinnedId = firstId;
        // 发起人帖（公告位，服务端权威查出的最早一条）。
        final initiator = _pinnedId.isEmpty
            ? const <PlazaNote>[]
            : list.where((n) => n.id == _pinnedId).toList();
        // 「我刚发布」的帖子短暂置顶（仅本次刚发的这一条、30 分钟内有效，
        // 历史帖一律不置顶），组内保持热度序。
        bool fresh(PlazaNote n) =>
            n.id != _pinnedId && CloudNotesService.isRecentlyPublished(n.id);
        final mine = list.where(fresh).toList();
        // 发起人帖已在最顶部展示，列表里排除避免重复显示。
        final others =
            list.where((n) => n.id != _pinnedId && !fresh(n)).toList();
        // 展示顺序：发起人帖 → 刚发布的帖子 → 其余帖子（云端热度序）。
        _notes = [
          ...initiator,
          ...mine,
          ...others,
        ];
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
            style: TextStyle(
                color: const Color(0xFFcf9e66),
                fontSize: 18,
                fontWeight: FontWeight.w600)),
      ),
      // 底部输入框：直接发布带 #话题 的帖子（与经书讨论页同款）。
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                _loading
                    ? Center(
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
                                  Center(
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
                                  // 发起置顶帖子与下一条之间不画分割线，
                                  // 但留出与经书讨论页一致的间隔（上下内边距 + 12 ≈ 32px）。
                                  final noteIndex =
                                      index - (_newPostCount > 0 ? 1 : 0);
                                  if (noteIndex == 0 &&
                                      _notes.isNotEmpty &&
                                      _notes.first.id == _pinnedId) {
                                    return const SizedBox(height: 12);
                                  }
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Divider(
                                        height: 1,
                                        thickness: 0.5,
                                        color: AppPalette.p.divider),
                                  );
                                },
                                itemBuilder: (context, index) {
                                  // 提醒条位于索引 1：置顶帖子之后、下面讨论帖子之前。
                                  if (_newPostCount > 0 && index == 1) {
                                    return _buildNewPostBanner(
                                        key: _topSectionKey);
                                  }
                                  final n = _notes[index -
                                      (_newPostCount > 0 && index > 1 ? 1 : 0)];
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
                                                                    style: TextStyle(
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
                                                          // 发起人：暖黄用 d3a069 包裹色小标签，素白改黑色底，白色字符。
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
                                                              color: AppPalette
                                                                      .instance
                                                                      .isPlain
                                                                  ? const Color(
                                                                      0xFF1A1A1A)
                                                                  : const Color(
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
                                                    if (SutraThoughtsPost
                                                        .isThoughtsPost(
                                                            n.content))
                                                      SutraThoughtsPostView(
                                                        post: SutraThoughtsPost
                                                            .parse(n.content)!,
                                                        noteId: n.id,
                                                        sutraLibrary: const {},
                                                        authorName:
                                                            n.authorName,
                                                        ownerUserId:
                                                            n.ownerUserId,
                                                      )
                                                    else if (SutraHighlightsPost
                                                        .isHighlightsPost(
                                                            n.content))
                                                      SutraHighlightsPostView(
                                                        post:
                                                            SutraHighlightsPost
                                                                .parse(
                                                                    n.content)!,
                                                        noteId: n.id,
                                                        sutraLibrary: const {},
                                                        authorName:
                                                            n.authorName,
                                                        ownerUserId:
                                                            n.ownerUserId,
                                                      )
                                                    else if (SutraNotesPost
                                                        .isSutraNotesPost(
                                                            n.content))
                                                      SutraNotesPostView(
                                                        post: SutraNotesPost
                                                            .parse(n.content)!,
                                                        noteId: n.id,
                                                        sutraLibrary: const {},
                                                        authorName:
                                                            n.authorName,
                                                        ownerUserId:
                                                            n.ownerUserId,
                                                      )
                                                    else if (ReadingNotePost
                                                        .isReadingNote(
                                                            n.content))
                                                      ReadingNotePostView(
                                                        note: ReadingNotePost
                                                            .parse(n.content)!,
                                                        noteId: n.id,
                                                        sutraLibrary: const {},
                                                        authorName:
                                                            n.authorName,
                                                      )
                                                    else
                                                      buildPostRichText(
                                                        n.content,
                                                        style: TextStyle(
                                                            fontSize: 15,
                                                            color: _text,
                                                            height: 1.6),
                                                        library: const {},
                                                        maxLines: 4,
                                                        overflow: TextOverflow
                                                            .ellipsis,
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
                                  // 发起置顶（发起人）的帖子用卡片底色包裹与下面帖子区分。
                                  if (n.id == _pinnedId) {
                                    return Container(
                                      margin: const EdgeInsets.symmetric(
                                          vertical: 2),
                                      padding: const EdgeInsets.fromLTRB(
                                          10, 2, 10, 4),
                                      decoration: BoxDecoration(
                                        color: _card,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: _border),
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
    final favorited = CloudNotesService.instance.favoriteNoteIds.contains(n.id);
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
                          style: TextStyle(
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
              Divider(height: 1, color: _border),
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
                        style: TextStyle(
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
            Divider(height: 1, color: _border),
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
            Text(label, style: TextStyle(fontSize: 15, color: _text)),
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
