import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_palette.dart';
import 'cloud_notes_service.dart';
import 'note_sutra_links.dart';
import 'reading_page.dart';
import 'sutra_asset_path.dart';
import 'sutra_downloader.dart';

/// 经文总榜：所有经书按讨论热度长期累积排行，榜单稳定。
/// 点击任意经文直接进入阅读界面；右侧「火把 x」表示讨论数量。
class HotRankingPage extends StatefulWidget {
  final List<HotDiscussionItem> items;
  final Map<String, String> displayNames;
  final Map<String, String> subtitles;

  const HotRankingPage({
    super.key,
    required this.items,
    required this.displayNames,
    required this.subtitles,
  });

  @override
  State<HotRankingPage> createState() => _HotRankingPageState();
}

class _HotRankingPageState extends State<HotRankingPage> {
  late List<HotDiscussionItem> _items;
  static const int _pageStep = 50;
  int _visibleCount = _pageStep;
  final ScrollController _scroll = ScrollController();
  bool _showBackToTop = false;
  // 下载中的经书进度：id -> 0.0~1.0，下载时火把左侧显示小圈圈。
  final Map<String, double> _downloadProgress = {};

  bool get _isPlain => AppPalette.instance.isPlain;

  // 前三名奖牌色：米黄外观用米黄金色系，素白外观用偏绿色系。
  List<Color> get _medalColors => _isPlain
      ? const [Color(0xFF5B7D5A), Color(0xFF71867A), Color(0xFF8FA98E)]
      : const [Color(0xFFC6A063), Color(0xFFBA9B6E), Color(0xFFB89E7A)];

  Color get _ink => const Color(0xFF1A1A1A);
  Color get _subInk => const Color(0xFF8E887F);

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.items);
    _scroll.addListener(() {
      final show = _scroll.offset > 400;
      if (show != _showBackToTop) setState(() => _showBackToTop = show);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // ─────────────── 打开阅读 ───────────────

  Future<bool> _assetExists(String path) async {
    try {
      await rootBundle.load(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _openReading(String title, String filePath) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingPage(title: title, filePath: filePath),
      ),
    );
  }

  Future<void> _open(HotDiscussionItem it) async {
    final link = NoteSutraCatalog.cachedTitleMap?[it.name];
    final title = widget.displayNames[it.name] ?? it.name;
    final filePath = link?.filePath ?? '';
    final id = SutraDownloader.extractId(title, filePath);
    if (id == null) {
      _openReading(title, filePath);
      return;
    }
    if (await SutraDownloader.isDownloaded(id)) {
      _openReading(title,
          SutraAssetPath.resolve(title: title, filePath: filePath));
      return;
    }
    final assetPath = SutraAssetPath.resolve(title: title, filePath: filePath);
    if (await _assetExists(assetPath)) {
      _openReading(title, assetPath);
      return;
    }
    if (!mounted) return;
    final shouldDownload = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppPalette.p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('经文尚未下载',
            style: TextStyle(
                color: AppPalette.p.text,
                fontSize: 18,
                fontWeight: FontWeight.w600)),
        content: Text('《$title》的正文尚未下载，是否现在下载？下载完成即可阅读。',
            style: TextStyle(color: AppPalette.p.textSec)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:
                  Text('取消', style: TextStyle(color: AppPalette.p.textSec))),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppPalette.p.readingAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('下载',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (shouldDownload != true || !mounted) return;
    setState(() {
      _downloadProgress[id] = 0;
    });
    try {
      await SutraDownloader.download(id, onProgress: (received, total) {
        if (!mounted) return;
        final p = total > 0 ? received / total : 0.0;
        final prev = _downloadProgress[id] ?? 0;
        if (p < 1.0 && (p - prev).abs() < 0.02) return;
        setState(() {
          _downloadProgress[id] = p;
        });
      });
      if (!mounted) return;
      setState(() {
        _downloadProgress.remove(id);
      });
      _openReading(title,
          SutraAssetPath.resolve(title: title, filePath: filePath));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloadProgress.remove(id);
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('下载失败：$e')));
    }
  }

  // ─────────────── Build ───────────────

  @override
  Widget build(BuildContext context) {
    final visibleCount = _items.length.clamp(0, _visibleCount);
    final canLoadMore = visibleCount < _items.length;

    return Scaffold(
      backgroundColor: AppPalette.p.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: Text('暂无经文榜单数据',
                          style: TextStyle(
                              color: AppPalette.p.textSec, fontSize: 14)),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(0, 4, 0, 80),
                      itemCount: visibleCount + (canLoadMore ? 1 : 0),
                      itemBuilder: (ctx, i) {
                        if (i == visibleCount) return _buildLoadMore();
                        final it = _items[i];
                        if (i < 3) return _buildTopCard(it, i);
                        return _buildRow(it, i);
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: _showBackToTop
          ? FloatingActionButton.small(
              backgroundColor: AppPalette.p.card,
              onPressed: () => _scroll.animateTo(0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic),
              child: Icon(Icons.keyboard_arrow_up, color: AppPalette.p.text),
            )
          : null,
    );
  }

  /// 顶部标题区：样式与「大家都在学」页一致。
  Widget _buildHeader() {
    return Container(
      color: AppPalette.p.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 20, 16),
        child: Row(
          children: [
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: Icon(Icons.arrow_back_ios_new, color: _ink, size: 19),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '经文总榜',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: _ink,
                        letterSpacing: 1.2),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '所有经书的总热度排行',
                    style: TextStyle(
                        fontSize: 11, color: _subInk, letterSpacing: 0.4),
                  ),
                ],
              ),
            ),
            Text(
              '${_items.length} 部',
              style:
                  TextStyle(fontSize: 12, color: _subInk, letterSpacing: 0.3),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadMore() {
    return InkWell(
      onTap: () => setState(() => _visibleCount += _pageStep),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            '查看更多',
            style: TextStyle(
              color: AppPalette.p.readingAccent,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  /// 名次徽章：前三名用主题奖牌色圆底 + 白色数字，其余灰色数字。
  Widget _rankBadge(int index) {
    if (index < 3) {
      final color = _medalColors[index];
      final size = index == 0 ? 30.0 : (index == 1 ? 27.0 : 24.0);
      final fontSize = index == 0 ? 15.0 : (index == 1 ? 14.0 : 13.0);
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          '${index + 1}',
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      );
    }
    return SizedBox(
      width: 30,
      child: Text(
        '${index + 1}',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: AppPalette.p.textSec,
        ),
      ),
    );
  }

  /// 「火把 x」讨论数：无背景色包裹；下载中时火把左侧显示进度小圈圈。
  Widget _fireCount(HotDiscussionItem it) {
    final link = NoteSutraCatalog.cachedTitleMap?[it.name];
    final title = widget.displayNames[it.name] ?? it.name;
    final id = SutraDownloader.extractId(title, link?.filePath ?? '');
    final progress = id != null ? _downloadProgress[id] : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (progress != null && progress < 1.0) ...[
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: progress > 0 ? progress : null,
              color: AppPalette.p.readingAccent,
            ),
          ),
          const SizedBox(width: 5),
        ],
        Image.asset('assets/images/fire.png', width: 15, height: 15),
        const SizedBox(width: 3),
        Text(
          '${it.posts}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppPalette.p.textSec,
          ),
        ),
      ],
    );
  }

  /// 前三名：奖牌徽章 + 经名 + 部类副标题 + 火把数 + 右箭头。
  Widget _buildTopCard(HotDiscussionItem it, int index) {
    final medalColor = _medalColors[index];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              medalColor.withValues(alpha: 0.12),
              medalColor.withValues(alpha: 0.04),
            ],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _open(it),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                _rankBadge(index),
                const SizedBox(width: 12),
                Expanded(child: _nameBlock(it)),
                const SizedBox(width: 8),
                _fireCount(it),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right,
                    size: 18, color: AppPalette.p.textHint),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 第 4 名起：紧凑行。
  Widget _buildRow(HotDiscussionItem it, int index) {
    return InkWell(
      onTap: () => _open(it),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _rankBadge(index),
            const SizedBox(width: 12),
            Expanded(child: _nameBlock(it)),
            const SizedBox(width: 8),
            _fireCount(it),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 18, color: AppPalette.p.textHint),
          ],
        ),
      ),
    );
  }

  Widget _nameBlock(HotDiscussionItem it) {
    final subtitle = widget.subtitles[it.name];
    final displayName = widget.displayNames[it.name] ?? it.name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppPalette.p.text,
          ),
        ),
        if (subtitle != null && subtitle.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: AppPalette.p.textSec),
          ),
        ],
      ],
    );
  }
}
