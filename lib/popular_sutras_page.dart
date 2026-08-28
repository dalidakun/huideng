import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'cloud_notes_service.dart';
import 'note_sutra_links.dart';
import 'sutra_list_page.dart';

// ──────── 精确定色（暖米白外观） ────────
const Color _pageBg = Color(0xFFF8F5F1);
const Color _topBg = Color(0xFFF9F2EC);        // 前三名背景
const Color _restBg = Color(0xFFFBF6F0);       // 第4名起背景
const Color _champagneGold = Color(0xFFC6A063);
const Color _goldFaded = Color(0xFFBA9B6E);   // 02 色
const Color _goldSoft = Color(0xFFB89E7A);     // 03 色
const Color _inkBlack = Color(0xFF1A1A1A);
const Color _warmGray = Color(0xFF8E887F);
const Color _fireActive = Color(0xFFB56A5A);
const Color _fireInactive = Color(0xFFD6CFC6);
const Color _hairline = Color(0xFFE6E1DA);
const Color _chevronColor = Color(0xFFC8C2BA);

/// 大家都在读：全平台锁定精读经书热度榜 — 禅意极简版 v3。
class PopularSutrasPage extends StatefulWidget {
  final SutraListPageState? parent;

  const PopularSutrasPage({super.key, this.parent});

  @override
  State<PopularSutrasPage> createState() => _PopularSutrasPageState();
}

class _PopularSutrasPageState extends State<PopularSutrasPage> {
  List<PopularSutraItem> _items = [];
  bool _loading = true;
  bool _refreshing = false;

  static const int _pageStep = 50;
  static const int _maxDisplay = 30;
  int _visibleCount = _pageStep;

  bool get _isWarm => AppPalette.instance.mode == AppearanceMode.warm;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await NoteSutraCatalog.load();
      final items = await CloudNotesService.instance.getPopularSutras();
      if (!mounted) return;
      setState(() {
        _items = items;
        _refreshing = false;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _refreshing = false;
        _loading = false;
      });
    }
  }

  void _open(PopularSutraItem item) {
    final titleMap = NoteSutraCatalog.cachedTitleMap;
    final stripped = _stripIdSuffix(item.title);
    final entry = titleMap?[item.title] ?? titleMap?[stripped];
    final filePath = entry?.filePath ?? item.filePath;
    widget.parent?.openRecentSutra(item.title, filePath);
  }

  void _onLongPress(PopularSutraItem item) {
    final parent = widget.parent;
    if (parent == null) return;
    final sutra = parent.findSutra(item.title);
    if (sutra != null) {
      parent.showSutraMenu(context, sutra, showPin: true);
    }
  }

  String _displayTitle(String title) =>
      widget.parent?.displayTitle(title) ??
      sutraDisplayNameWithVolume(title,
          multiVolumeBases: NoteSutraCatalog.cachedMultiVolumeBases);

  static final RegExp _idSuffixRe = RegExp(r'T\d+n[0-9A-Za-z]+_\d+$');
  String _stripIdSuffix(String title) => title.replaceAll(_idSuffixRe, '');

  // ──────── 页面背景 ────────
  Color get _bg => _isWarm ? _pageBg : AppPalette.p.bg;
  Color get _topBgColor => _isWarm ? _topBg : AppPalette.p.card;
  Color get _restBgColor => _isWarm ? _restBg : AppPalette.p.card;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  // ─────────────── Header ───────────────

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      color: _bg,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 20, 16),
            child: Row(
              children: [
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back_ios_new, color: _inkBlack, size: 19),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '大家都在学',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: _inkBlack, letterSpacing: 1.2),
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      '锁定精读越多越靠前',
                      style: TextStyle(fontSize: 11, color: _warmGray, letterSpacing: 0.4),
                    ),
                  ],
                ),
              ),
              Text(
                '${_items.length} 部',
                style: const TextStyle(fontSize: 12, color: _warmGray, letterSpacing: 0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────── Body ───────────────

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 1.2, color: _warmGray)),
      );
    }
    if (_items.isEmpty) return _buildEmpty();

    final total = math.min(_items.length, _maxDisplay);
    final visibleCount = _visibleCount < total ? _visibleCount : total;
    final hasMore = visibleCount < total;
    return RefreshIndicator(
      onRefresh: _refresh,
      color: _warmGray,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 48),
        itemCount: visibleCount + (hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index < visibleCount) {
            final item = _items[index];
            if (index < 3) return _buildTopThreeItem(item, index);
            return _buildListItem(item, index);
          }
          return _buildLoadMore(visibleCount);
        },
      ),
    );
  }

  // ─────────────── 空态 ───────────────

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CustomPaint(
            size: const Size(56, 56),
            painter: _EnsoPainter(color: _warmGray.withValues(alpha: 0.25), strokeWidth: 1.2),
          ),
          const SizedBox(height: 20),
          const Text('暂无数据', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w400, color: _inkBlack, letterSpacing: 1.0)),
          const SizedBox(height: 8),
          const Text('锁定精读经书后\n热门经书会出现在这里', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: _warmGray, height: 1.6, letterSpacing: 0.3)),
        ],
      ),
    );
  }

  // ─────────────── 前三名 ───────────────

  Widget _buildTopThreeItem(PopularSutraItem item, int index) {
    // 排名颜色：素白外观统一用青灰 #6F877A，米黄外观用金色系
    Color rankColor;
    double rankSize;
    if (!_isWarm) {
      // 素白外观：统一颜色
      rankColor = const Color(0xFF6F877A);
      rankSize = index == 0 ? 31 : (index == 1 ? 27 : 23);
    } else {
      // 米黄外观：金色系
      if (index == 0) {
        rankColor = _champagneGold;
        rankSize = 31;
      } else if (index == 1) {
        rankColor = _goldFaded;
        rankSize = 27;
      } else {
        rankColor = _goldSoft;
        rankSize = 23;
      }
    }

    return Container(
      color: _topBgColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: InkWell(
          onTap: () => _open(item),
          onLongPress: () => _onLongPress(item),
          splashColor: Colors.transparent,
          highlightColor: _topBgColor,
            child: Container(
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: index < 2
                ? const BoxDecoration(border: Border(bottom: BorderSide(color: _hairline, width: 0.5)))
                : null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 排名数字 + 莲花图标
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Column(
                    children: [
                      Text(
                        _rankLabel(index),
                        style: TextStyle(
                          fontSize: rankSize,
                          fontWeight: FontWeight.w700,
                          color: rankColor,
                          letterSpacing: 2,
                          height: 1.0,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Image.asset(
                        _isWarm ? 'assets/images/${_rankLabel(index)}.png' : 'assets/images/04.png',
                        width: 20,
                        height: 20,
                      ),
                    ],
                  ),
                ),
                // 经文名称 + 人数
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _displayTitle(item.title),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _inkBlack, height: 1.4, letterSpacing: 0.5),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${item.count}人精读',
                          style: const TextStyle(fontSize: 11.5, color: _warmGray, letterSpacing: 0.3),
                        ),
                      ],
                    ),
                  ),
                ),
                // 火把（右侧边缘，与"人精读"对齐）
                _buildFireIcons(index),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────── 第4名起 · 杂志目录式列表 ───────────────

  Widget _buildListItem(PopularSutraItem item, int index) {
    return Container(
      color: _restBgColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: InkWell(
          onTap: () => _open(item),
          onLongPress: () => _onLongPress(item),
          splashColor: Colors.transparent,
          highlightColor: _restBgColor,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _hairline, width: 0.5)),
            ),
            child: Row(
              children: [
                // 排名
                SizedBox(
                  width: 36,
                  child: Text(
                    _rankLabel(index),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w300, color: _warmGray, letterSpacing: 1),
                  ),
                ),
                const SizedBox(width: 8),
                // 经文名称
                Expanded(
                  child: Text(
                    _displayTitle(item.title),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400, color: _inkBlack, letterSpacing: 0.3),
                  ),
                ),
                const SizedBox(width: 10),
                // 人数
                Text(
                  '${item.count}人精读',
                  style: const TextStyle(fontSize: 11, color: _warmGray, letterSpacing: 0.2),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 14, color: _chevronColor),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────── 加载更多 ───────────────

  Widget _buildLoadMore(int visibleCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 16),
      child: GestureDetector(
        onTap: () => setState(() => _visibleCount = visibleCount + _pageStep),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(width: 32, height: 0.5, color: _hairline),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text('查看更多', style: TextStyle(fontSize: 12, color: _warmGray.withValues(alpha: 0.7), letterSpacing: 0.8)),
            ),
            Container(width: 32, height: 0.5, color: _hairline),
          ],
        ),
      ),
    );
  }

  // ─────────────── 排名标签 ───────────────

  String _rankLabel(int index) {
    return (index + 1).toString().padLeft(2, '0');
  }

  // ─────────────── 火把（仅前三名） ───────────────

  /// 火把：固定5枚，仅前三名显示。按 index 决定点亮数。
  Widget _buildFireIcons(int index) {
    final litCount = 5 - index; // 0→5, 1→4, 2→3
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final active = i < litCount;
        return Icon(
          active ? Icons.local_fire_department : Icons.local_fire_department_outlined,
          size: 14,
          color: active ? _fireActive : _fireInactive,
        );
      }),
    );
  }
}

// ─────────────── 圆相 · 水墨禅意元素 ───────────────

class _EnsoPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;

  _EnsoPainter({required this.color, this.strokeWidth = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - strokeWidth;

    final path = Path();
    path.addArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi * 0.15,
      math.pi * 1.65,
    );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _EnsoPainter oldDelegate) =>
      color != oldDelegate.color || strokeWidth != oldDelegate.strokeWidth;
}
