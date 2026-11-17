import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'article_store.dart';
import 'article_web_page.dart';
import 'video_catalog.dart';
import 'video_player_page.dart';

/// 善知识菜单页（底部菜单第 4 格）的「影音」页。
///
/// 上半屏是当前最新的讲经视频大卡（封面 + 标题 + 时长），下面是简介与
/// 全部视频列表；点任意一条进入 [VideoPlayerPage] 播放。
///
/// 视频文件放在 Cloudflare R2 上，App 只读云端 `catalog.json`：
/// 以后在 master 目录加片、跑一次上传脚本，这里就会自动多出新的视频，
/// 不需要发新版。清单拉不到时用本地兜底清单，页面不会空白。
class ShanZhiShiVideoPage extends StatefulWidget {
  /// 底部菜单当前索引：切回本页时按需刷新一次云端清单。
  final ValueListenable<int>? activeTab;

  /// 本页在主页页面列表里的索引（善知识 = 7）。
  final int tabIndex;

  const ShanZhiShiVideoPage({
    super.key,
    this.activeTab,
    this.tabIndex = 7,
  });

  @override
  State<ShanZhiShiVideoPage> createState() => _ShanZhiShiVideoPageState();
}

class _ShanZhiShiVideoPageState extends State<ShanZhiShiVideoPage>
    with WidgetsBindingObserver {
  final VideoCatalogStore _store = VideoCatalogStore.instance;
  final ArticleStore _articles = ArticleStore.instance;
  DateTime? _lastAutoRefresh;

  /// 本次进程里已经预热过的视频 id（避免每次进页面都重复拉片）。
  final Set<String> _warmed = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store.addListener(_onStoreChanged);
    _articles.addListener(_onArticlesChanged);
    widget.activeTab?.addListener(_onTabChanged);
    // 文章清单很小，进页面时静默加载（无网时用缓存/内置）。
    unawaited(_articles.load());
    // 不在 App 冷启动时探测：等第一次切到本页再拉片单，
    // 避免给启动多一个网络请求（切页时由 _onTabChanged 触发）。
    if (widget.activeTab != null &&
        widget.activeTab!.value == widget.tabIndex) {
      unawaited(_store.load(force: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store.removeListener(_onStoreChanged);
    _articles.removeListener(_onArticlesChanged);
    widget.activeTab?.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onArticlesChanged() {
    if (mounted) setState(() {});
  }

  /// 回到前台重新探测一次：用户可能刚开/关了网络加速。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;
    if (widget.activeTab != null &&
        widget.activeTab!.value != widget.tabIndex) {
      return;
    }
    unawaited(_store.load(force: true));
  }

  void _onStoreChanged() {
    if (!mounted) return;
    setState(() {});
    _maybeWarm();
  }

  /// 切回本页时重新探测一次网络（超过 1 分钟），决定显示视频还是「不可用」。
  void _onTabChanged() {
    final active = widget.activeTab?.value == widget.tabIndex;
    if (!active) return;
    _maybeWarm();
    final last = _lastAutoRefresh;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 1)) {
      return;
    }
    _lastAutoRefresh = DateTime.now();
    unawaited(_store.load(force: true));
  }

  /// 本页可见时预热首部片：把 HLS 列表与前两片先拉一遍，点播放更快。
  void _maybeWarm() {
    if (widget.activeTab != null &&
        widget.activeTab!.value != widget.tabIndex) {
      return;
    }
    final videos = _store.catalog.videos;
    if (videos.isEmpty) return;
    final first = videos.first;
    if (!_warmed.add(first.id)) return;
    unawaited(_store.prewarm(first));
  }

  Future<void> _refresh() async {
    _lastAutoRefresh = DateTime.now();
    await _store.load(force: true);
  }

  Future<void> _openVideo(VideoItem video) async {
    if (!video.playable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('这部视频暂时没有可播放的源', style: TextStyle(fontSize: 13)),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VideoPlayerPage(video: video)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    // 还没探测过（第一次进本页）：先显示一个短暂的检测中，避免先露出可能播不了的视频。
    if (!_store.loaded && _store.cloudReachable == null) {
      return _buildDetecting(p);
    }
    // 拉不到云端片单 = 当前网络访问不了视频云，直接隐藏视频区。
    if (_store.cloudReachable == false) return _buildRestricted(p);
    final videos = _store.catalog.videos;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final featured = videos.isNotEmpty ? videos.first : null;
    final rest = videos.length > 1 ? videos.sublist(1) : const <VideoItem>[];

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: p.accent,
          backgroundColor: p.card,
          onRefresh: _refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(child: _buildHeader(p, videos.length)),
              if (_store.usingFallback && videos.isNotEmpty)
                SliverToBoxAdapter(child: _buildOfflineHint(p)),
              if (featured == null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _buildEmpty(p),
                )
              else ...[
                SliverToBoxAdapter(child: _buildHero(p, featured)),
                if (featured.description.isNotEmpty)
                  SliverToBoxAdapter(child: _buildIntro(p, featured)),
                SliverToBoxAdapter(
                  child: _buildSectionTitle(p, videos.length),
                ),
                if (rest.isEmpty)
                  SliverToBoxAdapter(child: _buildComingSoon(p))
                else
                  SliverList.builder(
                    itemCount: rest.length,
                    itemBuilder: (context, index) =>
                        _buildItem(p, rest[index]),
                  ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 26, 22, 0),
                    child: _buildArticleSection(p),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding:
                        EdgeInsets.fromLTRB(20, 10, 20, bottomInset + 22),
                    child: Center(
                      child: Text(
                        '视频存放于云端 · 观看需联网',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: p.textHint,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 第一次进本页时的短暂检测态（最多 4 秒），不阻塞其他页面。
  Widget _buildDetecting(PaletteData p) {
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(p, 0),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: p.textHint,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '正在检测网络…',
                      style: TextStyle(fontSize: 12, color: p.textHint),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前网络访问不了视频云时显示的页面：不展示视频，只给一句说明和重试。
  Widget _buildRestricted(PaletteData p) {
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(p, 0),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                      decoration: BoxDecoration(
                        color: p.card,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: p.borderSoft, width: 0.8),
                      ),
                      child: Column(
                        children: [
                          Icon(Icons.wifi_off_rounded,
                              size: 30, color: p.textHint),
                          const SizedBox(height: 10),
                          Text(
                            '当前网络下视频暂不可用',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: p.text,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '视频存放在云端，需要网络加速才能加载。\n下面这些文章不受影响。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.8,
                              color: p.textSec,
                            ),
                          ),
                          const SizedBox(height: 14),
                          GestureDetector(
                            onTap: _store.refreshing
                                ? null
                                : () => unawaited(_refresh()),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 9),
                              decoration: BoxDecoration(
                                color: p.tintBg,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: _store.refreshing
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.6,
                                        color: p.textHint,
                                      ),
                                    )
                                  : Text(
                                      '重新检测',
                                      style: TextStyle(
                                          fontSize: 12.5, color: p.textSec),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    _buildArticleSection(p, showEmpty: true),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────────────── 文章 ─────────────────────────────

  /// 文章列表：标题 + 来源，点开用 App 内 WebView 阅读。
  Widget _buildArticleSection(PaletteData p, {bool showEmpty = false}) {
    final items = _articles.items;
    if (items.isEmpty && !showEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '延伸阅读',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: p.text,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${items.length} 篇',
              style: TextStyle(fontSize: 10.5, color: p.textHint),
            ),
            const Spacer(),
            GestureDetector(
              onTap: _addArticle,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 14, color: p.textHint),
                  const SizedBox(width: 2),
                  Text('添加',
                      style: TextStyle(fontSize: 11.5, color: p.textHint)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        if (items.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            decoration: BoxDecoration(
              color: p.tintBg.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '还没有文章。点右上角「添加」，贴一个微信公众号 / 知乎链接就能在 App 里阅读。',
              style: TextStyle(fontSize: 11.5, color: p.textHint, height: 1.6),
            ),
          )
        else
          for (final a in items.take(20)) _buildArticleTile(p, a),
      ],
    );
  }

  Widget _buildArticleTile(PaletteData p, ArticleItem a) {
    final source = a.source.isNotEmpty ? a.source : articleSourceOf(a.url);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => _openArticle(a),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: p.borderSoft, width: 0.8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.title.isEmpty ? source : a.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      a.date.isEmpty ? source : '$source · ${a.date}',
                      style: TextStyle(fontSize: 10.5, color: p.textHint),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: p.textHint),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openArticle(ArticleItem a) async {
    if (a.url.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArticleWebPage(
          title: a.title.isEmpty ? articleSourceOf(a.url) : a.title,
          url: a.url,
        ),
      ),
    );
  }

  /// 本机添加一篇文章（贴链接即可，标题可留空自动推断）。
  Future<void> _addArticle() async {
    final urlCtrl = TextEditingController();
    final titleCtrl = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppPalette.p.card,
          title: Text('添加文章',
              style: TextStyle(fontSize: 16, color: AppPalette.p.text)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                autofocus: true,
                keyboardType: TextInputType.url,
                style: TextStyle(fontSize: 13, color: AppPalette.p.text),
                decoration: const InputDecoration(
                  labelText: '文章链接',
                  hintText: 'https://mp.weixin.qq.com/s/...',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: titleCtrl,
                style: TextStyle(fontSize: 13, color: AppPalette.p.text),
                decoration: const InputDecoration(
                  labelText: '标题（可留空）',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('添加'),
            ),
          ],
        );
      },
    );
    if (saved == true) {
      final url = urlCtrl.text.trim();
      if (url.isNotEmpty) {
        final title = titleCtrl.text.trim();
        await _articles.add(ArticleItem(
          title: title.isEmpty ? articleSourceOf(url) : title,
          url: url,
          source: articleSourceOf(url),
        ));
      }
    }
    urlCtrl.dispose();
    titleCtrl.dispose();
  }

  // ───────────────────────────── 头部 ─────────────────────────────

  Widget _buildHeader(PaletteData p, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '善知识',
                      style: TextStyle(
                        fontSize: 23,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2.5),
                      decoration: BoxDecoration(
                        color: p.accent.withValues(alpha: 0.13),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        '影音',
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.2,
                          color: p.accentDeep,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  count > 0 ? '以影像闻法 · 共 $count 部' : '以影像闻法',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: p.textHint,
                    letterSpacing: 0.7,
                  ),
                ),
              ],
            ),
          ),
          _buildRefreshButton(p),
        ],
      ),
    );
  }

  Widget _buildRefreshButton(PaletteData p) {
    return GestureDetector(
      onTap: _store.refreshing ? null : () => unawaited(_refresh()),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: p.tintBg,
        ),
        child: _store.refreshing
            ? Padding(
                padding: const EdgeInsets.all(10),
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: p.textHint,
                ),
              )
            : Icon(Icons.refresh_rounded, size: 18, color: p.textSec),
      ),
    );
  }

  /// 云端片单连续多次拉不到时的一行轻提示：不挡内容，点一下重试。
  /// 这时候看到的是 App 里写死的「内置片单」，视频照样能播。
  Widget _buildOfflineHint(PaletteData p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: GestureDetector(
        onTap: () => unawaited(_refresh()),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: p.tintBg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(Icons.cloud_off_rounded, size: 14, color: p.textHint),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '云端片单暂时没连上，先显示内置片单（不影响播放）',
                  style: TextStyle(fontSize: 11.5, color: p.textSec),
                ),
              ),
              Text('重试',
                  style: TextStyle(fontSize: 11.5, color: p.accentDeep)),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────────────────── 最新一部 ─────────────────────────────

  Widget _buildHero(PaletteData p, VideoItem video) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: GestureDetector(
        onTap: () => unawaited(_openVideo(video)),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.11),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _cover(p, video),
                  // 底部压暗，保证白色标题在任何封面上都看得清。
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [0.38, 1.0],
                        colors: [Color(0x00000000), Color(0xB3000000)],
                      ),
                    ),
                  ),
                  Center(child: _buildPlayBadge()),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 13,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          video.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 19,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            letterSpacing: 0.8,
                            shadows: [
                              Shadow(
                                color: Color(0x66000000),
                                blurRadius: 8,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _metaLine(video),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xCCFFFFFF),
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayBadge() {
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.94),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        size: 34,
        color: Color(0xFF1C1C1C),
      ),
    );
  }

  String _metaLine(VideoItem video) {
    final parts = <String>[
      if (video.duration > Duration.zero) formatVideoDuration(video.duration),
      if (video.qualityLabel.isNotEmpty) video.qualityLabel,
      if (video.subtitle.isNotEmpty) video.subtitle,
    ];
    return parts.join('  ·  ');
  }

  // ───────────────────────────── 简介 ─────────────────────────────

  Widget _buildIntro(PaletteData p, VideoItem video) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 15, 20, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: p.borderSoft, width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_stories_outlined, size: 15, color: p.accent),
                const SizedBox(width: 6),
                Text(
                  '内容简介',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              video.description,
              style: TextStyle(
                fontSize: 13,
                height: 1.75,
                color: p.textSec,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (video.duration > Duration.zero)
                  _infoChip(p, '时长 ${formatVideoDuration(video.duration)}'),
                if (video.qualityLabel.isNotEmpty)
                  _infoChip(p, '最高 ${video.qualityLabel}'),
                _infoChip(p, '中英字幕'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoChip(PaletteData p, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: p.tintBg,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10.5, color: p.textSec, letterSpacing: 0.3),
      ),
    );
  }

  // ───────────────────────────── 列表 ─────────────────────────────

  Widget _buildSectionTitle(PaletteData p, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '全部视频',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: p.text,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 1),
            child: Text(
              '$count 部',
              style: TextStyle(fontSize: 11, color: p.textHint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(PaletteData p, VideoItem video) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 11),
      child: GestureDetector(
        onTap: () => unawaited(_openVideo(video)),
        child: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: p.borderSoft, width: 0.8),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: SizedBox(
                  width: 126,
                  height: 71,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _cover(p, video),
                      if (video.duration > Duration.zero)
                        Positioned(
                          right: 5,
                          bottom: 5,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.62),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              formatVideoDuration(video.duration),
                              style: const TextStyle(
                                fontSize: 9.5,
                                color: Colors.white,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      video.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      video.subtitle.isEmpty ? '讲经影音' : video.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: p.textHint),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (video.qualityLabel.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              border:
                                  Border.all(color: p.border, width: 0.8),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              video.qualityLabel,
                              style:
                                  TextStyle(fontSize: 9, color: p.textSec),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          '共 ${video.sources.length} 个清晰度',
                          style: TextStyle(fontSize: 10, color: p.textHint),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded, size: 18, color: p.textHint),
            ],
          ),
        ),
      ),
    );
  }

  /// 目前只有一部片时的占位提示：告诉用户后续会陆续上线。
  Widget _buildComingSoon(PaletteData p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        decoration: BoxDecoration(
          color: p.tintBg.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(Icons.video_library_outlined, size: 17, color: p.textHint),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '更多讲经影音正在整理，上传后会出现在这里',
                style:
                    TextStyle(fontSize: 11.5, color: p.textHint, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(PaletteData p) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.video_library_outlined, size: 34, color: p.textHint),
          const SizedBox(height: 12),
          Text('影音内容准备中',
              style: TextStyle(fontSize: 13.5, color: p.textSec)),
          const SizedBox(height: 6),
          Text('云端清单读取失败时，下拉可以重试',
              style: TextStyle(fontSize: 11, color: p.textHint)),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => unawaited(_refresh()),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: p.tintBg,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text('重新加载',
                  style: TextStyle(fontSize: 12, color: p.textSec)),
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────── 封面 ─────────────────────────────

  Widget _cover(PaletteData p, VideoItem video) {
    if (video.coverUrl.isEmpty) return _coverPlaceholder(p);
    return Image.network(
      video.coverUrl,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => _coverPlaceholder(p),
    );
  }

  Widget _coverPlaceholder(PaletteData p) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p.gradTop, p.gradBot],
        ),
      ),
      child: Center(
        child: Icon(Icons.movie_outlined, size: 22, color: p.muted),
      ),
    );
  }
}
