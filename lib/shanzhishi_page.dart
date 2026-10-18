import 'dart:async';
import 'dart:math' show pi;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_palette.dart';
import 'note_sutra_links.dart';
import 'shanzhishi_edit_sheet.dart';
import 'shanzhishi_search_page.dart';
import 'shanzhishi_sphere.dart';
import 'shanzhishi_store.dart';
import 'sutra_downloader.dart';
import 'ui_sound.dart';

/// 善知识页（底部菜单第 4 格）：
///
/// 整页是一颗立体的名号星球（竖立橄榄形椭球、正背面全点、连续字号、缩放）；
/// 点名号后从底部拉出与经藏页「全部经典」同款的上拉面板，显示该名号
/// 与关联经文，点经文展开关联段落。
///
/// 名号由用户自己录入（右上角 +），本地持久化，越聚越多。
class ShanZhiShiPage extends StatefulWidget {
  /// 底部菜单当前索引：仅当等于 [tabIndex] 时球体才播入场/自转（省电）。
  final ValueListenable<int>? activeTab;

  /// 本页在主页页面列表里的索引（善知识 = 7）。
  final int tabIndex;

  const ShanZhiShiPage({super.key, this.activeTab, this.tabIndex = 7});

  @override
  State<ShanZhiShiPage> createState() => ShanZhiShiPageState();
}

class ShanZhiShiPageState extends State<ShanZhiShiPage>
    with SingleTickerProviderStateMixin {
  final ShanZhiShiStore _store = ShanZhiShiStore.instance;
  final ShanZhiSphereController _sphereCtrl = ShanZhiSphereController();

  /// 当前选中的名号位次；null = 底部面板不显示（点名号后才出现）。
  int? _selected;

  /// 当前展开的经文（null = 无展开）。
  String? _expandedSutra;

  /// 经文段落缓存：key = "sutra\u0000name"，value = 关联段落列表。
  final Map<String, Future<List<String>>> _paraFutures = {};

  // ── 底部上拉面板（与经藏页「全部经典」同款） ──
  static const double _shelfHeaderH = 50;
  static const double _shelfOpenTopExtra = 12;
  static const double _shelfTopGap = 10;
  static const double _shelfTopRadius = 16;
  static const double _shelfShadowReach = 14;
  bool _shelfExpanded = false;
  late final AnimationController _shelfController;

  /// 仅在明确挂了 [activeTab] 且轮到本页时才允许球体入场/自转。
  bool get _isActive =>
      widget.activeTab != null && widget.activeTab!.value == widget.tabIndex;

  @override
  void initState() {
    super.initState();
    _shelfController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _store.addListener(_onStoreChanged);
    widget.activeTab?.addListener(_onTabChanged);
    unawaited(_store.load());
    unawaited(NoteSutraCatalog.load());
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    widget.activeTab?.removeListener(_onTabChanged);
    _shelfController.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    final sel = _selected;
    if (sel != null) {
      if (_store.length == 0) {
        _selected = null;
      } else if (sel >= _store.length) {
        _selected = _store.length - 1;
      }
    }
    setState(() {});
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  // ─────────────── 动作 ───────────────

  Future<void> _openSearch() async {
    unawaited(UiSound.instance.playClick());
    final idx = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => ShanZhiShiSearchPage(entries: _store.entries),
      ),
    );
    if (idx == null || !mounted) return;
    setState(() {
      _selected = idx;
      _expandedSutra = null;
    });
    _sphereCtrl.animateToIndex(idx);
    _openShelf();
  }

  Future<void> _openAdd() async {
    unawaited(UiSound.instance.playClick());
    final saved = await ShanZhiShiEditSheet.show(context);
    if (saved == null || !mounted) return;
    setState(() {
      _selected = saved;
      _expandedSutra = null;
    });
    _openShelf();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sphereCtrl.animateToIndex(saved);
    });
  }

  void _onNameTapped(int idx) {
    unawaited(UiSound.instance.playClick());
    setState(() {
      _selected = idx;
      _expandedSutra = null;
    });
    _openShelf();
  }

  // ─────────────── 上拉面板开合 ───────────────

  /// 面板内容区（不含 header）的最大高度：展开到顶停在 AppBar 下方留一点间隔。
  double _shelfContentMaxHeight() {
    final mq = MediaQuery.of(context);
    final available =
        mq.size.height - (mq.padding.top + kToolbarHeight) - mq.padding.bottom;
    return available - _shelfHeaderH - _shelfOpenTopExtra - _shelfTopGap;
  }

  void _openShelf() {
    _shelfExpanded = true;
    _shelfController.forward();
  }

  /// 点 header 收起：整块滑出屏幕下沿后卸载（动画中重开则不卸载）。
  void _closeShelf() {
    unawaited(UiSound.instance.playClick());
    _collapseShelf();
  }

  /// 静默收起面板（侧滑返回用，不播点击音）。
  void _collapseShelf() {
    _shelfExpanded = false;
    _shelfController.reverse().whenComplete(() {
      if (!_shelfExpanded && mounted) setState(() => _selected = null);
    });
  }

  /// 根路由侧滑返回：面板展开时先收起面板（回到星图）。
  /// 返回是否消费了本次返回，避免系统直接最小化应用。
  bool collapseShelfIfOpen() {
    if (_selected == null) return false;
    _collapseShelf();
    return true;
  }

  /// 纵向拖 header 时按手指位移实时擦洗展开比例（向下拖收起，向上拖展开）。
  void _onShelfDragUpdate(DragUpdateDetails d) {
    final maxH = _shelfContentMaxHeight();
    final delta = d.primaryDelta ?? 0;
    if (maxH <= 0 || delta == 0) return;
    _shelfController.value -= delta / maxH;
  }

  /// 松手吸附：甩动够快按甩动方向，否则吸到离得最近的一端。
  void _onShelfDragEnd(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    final open = velocity.abs() > 350
        ? velocity < 0
        : _shelfController.value >= 0.5;
    if (open) {
      _openShelf();
    } else {
      _closeShelf();
    }
  }

  // ─────────────── 经文段落加载 ───────────────

  Future<List<String>> _loadRelatedParagraphs(String sutra, String name) async {
    final link = ShanZhiShiStore.resolveSutra(sutra);
    final filePath = link?.filePath ?? '';
    if (filePath.isEmpty) return const [];
    String? content;
    // 优先编辑版，再原始打包版。
    if (filePath.startsWith('assets/sutras_ascii/')) {
      final rel = filePath.substring('assets/sutras_ascii/'.length);
      try {
        content = await rootBundle.loadString('assets/sutras_edited/$rel');
      } catch (_) {}
    }
    content ??= await _tryLoadAsset(filePath);
    content ??= await _tryLoadLocalFile(filePath);
    if (content == null || content.isEmpty) return const [];
    return _extractParagraphs(content, name);
  }

  Future<String?> _tryLoadAsset(String path) async {
    try {
      return await rootBundle.loadString(path);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _tryLoadLocalFile(String assetPath) async {
    try {
      final f = await SutraDownloader.localFileForAssetPath(assetPath);
      if (f != null && await f.exists()) return await f.readAsString();
    } catch (_) {}
    return null;
  }

  /// 从经文原文中抽取提到 [name] 的段落（简化版分段：按行 + 去常见标记）。
  List<String> _extractParagraphs(String content, String name) {
    if (name.isEmpty) return const [];
    final out = <String>[];
    for (final raw in content.split('\n')) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      // 去常见标记：分段/遮挡/加粗/备注。
      line = line.replaceAll('。。。', '');
      line = line.replaceAll('///', '');
      line = line.replaceAll('／／／', '');
      line = line.replaceAll(RegExp(r'^[bB]{3}'), '');
      line = line.replaceAll(RegExp(r'[bB]{3}$'), '');
      line = line.replaceAll('@@', '');
      line = line.trim();
      if (line.isEmpty) continue;
      if (line.contains(name)) {
        out.add(line);
        if (out.length >= 30) break;
      }
    }
    return out;
  }

  Future<List<String>> _paragraphsFor(String sutra, String name) {
    final key = '$sutra\u0000$name';
    return _paraFutures.putIfAbsent(
      key,
      () => _loadRelatedParagraphs(sutra, name),
    );
  }

  // ─────────────── 视图 ───────────────

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final names = [for (final e in _store.entries) e.name];
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: '添加',
            onPressed: _openAdd,
            icon: Icon(Icons.add_circle_outline, size: 21, color: p.text),
          ),
          IconButton(
            tooltip: '搜索',
            onPressed: _openSearch,
            icon: Icon(Icons.search, size: 21, color: p.text),
          ),
        ],
      ),
      body: Builder(builder: (context) {
        final entry = () {
          final idx = _selected;
          if (idx == null || !_store.loaded) return null;
          return (idx >= 0 && idx < _store.length) ? _store[idx] : null;
        }();
        return Stack(
          children: [
            // 球体铺满整页（面板浮在其上）。
            Positioned.fill(
              child: ShanZhiShiSphere(
                names: names,
                controller: _sphereCtrl,
                spinEnabled: _isActive,
                onNameTapped: _onNameTapped,
                onSettled: (_) => unawaited(UiSound.instance.playClick()),
              ),
            ),
            if (!_store.loaded)
              Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.4, color: p.textHint),
                ),
              )
            else if (names.isEmpty) _buildEmptySphere(p),
            if (entry != null) _buildShelf(p, entry),
          ],
        );
      }),
    );
  }

  Widget _buildEmptySphere(PaletteData p) {
    return IgnorePointer(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 90),
            Text(
              '球面还没有名号',
              style: TextStyle(fontSize: 14, color: p.textSec, letterSpacing: 1),
            ),
            const SizedBox(height: 6),
            Text(
              '点右上角「＋」记录第一位佛菩萨',
              style: TextStyle(fontSize: 12, color: p.textHint),
            ),
          ],
        ),
      ),
    );
  }

  /// 底部上拉面板（与经藏页「全部经典」同款）：
  /// 折叠态是贴在屏幕下沿的一条 header（名号 + N部经），
  /// 上拖/单击展开后铺开该名号的关联经文与经文卡片。
  Widget _buildShelf(PaletteData p, ShanyishiEntry entry) {
    final mq = MediaQuery.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: mq.padding.bottom,
      child: AnimatedBuilder(
        animation: _shelfController,
        builder: (context, _) {
          final open = _shelfController.value;
          final contentH = _shelfContentMaxHeight() * open;
          // 收起时整块滑出屏幕下沿（连手势条一起让开），完全不残留。
          final slide = (1 - open) *
              (_shelfHeaderH + _shelfOpenTopExtra + mq.padding.bottom);
          return Transform.translate(
            offset: Offset(0, slide),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  clipBehavior: Clip.antiAlias,
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(_shelfTopRadius)),
                  child: Container(
                    color: p.card,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildShelfHeader(p, entry),
                        if (contentH > 0)
                          SizedBox(
                            height: contentH,
                            child: _buildShelfContent(p, entry),
                          ),
                      ],
                    ),
                  ),
                ),
                // 上边界阴影：只画在面板之外，不压暗面板底色。
                Positioned(
                  left: 0,
                  right: 0,
                  top: -_shelfShadowReach,
                  height: _shelfShadowReach + _shelfTopRadius + 6,
                  child: _TopEdgeShadow(
                    radius: _shelfTopRadius,
                    reach: _shelfShadowReach,
                    blur: 2.5,
                    color: Colors.black.withValues(alpha: 0.1),
                  ),
                ),
                // 上边界细线：沿左右圆角连续描边。
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _ShelfTopBorderPainter(
                        radius: _shelfTopRadius,
                        color: p.borderSoft,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 面板 header：横杠 + 名号 + 「·N部经」。单击收起、上下拖擦洗开合。
  Widget _buildShelfHeader(PaletteData p, ShanyishiEntry entry) {
    final openExtra = _shelfOpenTopExtra * _shelfController.value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _closeShelf,
      onVerticalDragUpdate: _onShelfDragUpdate,
      onVerticalDragEnd: _onShelfDragEnd,
      child: SizedBox(
        height: _shelfHeaderH + openExtra,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8 + openExtra, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: p.textHint,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Spacer(),
                  Flexible(
                    child: Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: p.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  if (entry.sutras.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    const Text(
                      '·',
                      style: TextStyle(
                        color: Color(0xFF9E9588),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${entry.sutras.length}部经',
                      style: TextStyle(
                        color: p.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const Spacer(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 面板内容：关联经文胶囊行 + 分隔线 + 经文卡片（点卡片展开关联段落）。
  Widget _buildShelfContent(PaletteData p, ShanyishiEntry entry) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _labelChip(p, '关联经文'),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                entry.sutras.isEmpty ? '—' : entry.sutras.join('、'),
                style: TextStyle(
                  fontSize: 13,
                  color: p.textSec,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(height: 1, color: p.divider),
        const SizedBox(height: 8),
        if (entry.sutras.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Center(
              child: Text(
                '尚未记录出现经文',
                style:
                    TextStyle(fontSize: 12.5, color: p.textHint, height: 1.7),
              ),
            ),
          )
        else
          for (final s in entry.sutras) _sutraTile(p, s, entry.name),
      ],
    );
  }

  /// 彩色标签胶囊：「名号」「关联经文」等小标签。
  Widget _labelChip(PaletteData p, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: p.tintBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: p.accentDeep,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _sutraTile(PaletteData p, String sutra, String name) {
    final expanded = _expandedSutra == sutra;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: expanded ? p.accent : p.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              unawaited(UiSound.instance.playClick());
              setState(() {
                _expandedSutra = expanded ? null : sutra;
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: p.textHint,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      sutra,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        color: p.text,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: _RelatedParagraphs(
                future: _paragraphsFor(sutra, name),
                palette: p,
              ),
            ),
        ],
      ),
    );
  }
}

/// 展开的关联段落小面板：加载中 / 段落列表 / 无匹配。
class _RelatedParagraphs extends StatelessWidget {
  final Future<List<String>> future;
  final PaletteData palette;

  const _RelatedParagraphs({required this.future, required this.palette});

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return FutureBuilder<List<String>>(
      future: future,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 1.4, color: p.textHint),
              ),
            ),
          );
        }
        final paras = snap.data ?? const [];
        if (paras.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              '未在正文中找到相关段落',
              style: TextStyle(fontSize: 12, color: p.textHint),
            ),
          );
        }
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: p.tintBg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < paras.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                Text(
                  paras[i],
                  style: TextStyle(
                    fontSize: 13,
                    color: p.text,
                    height: 1.7,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 面板顶边阴影：只画在面板之外，不压暗面板底色（与经藏页上拉面板同款）。
class _TopEdgeShadow extends StatelessWidget {
  const _TopEdgeShadow({
    required this.radius,
    required this.reach,
    required this.blur,
    required this.color,
  });

  final double radius;
  final double reach;
  final double blur;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _TopEdgeShadowPainter(
          radius: radius,
          reach: reach,
          blur: blur,
          color: color,
        ),
      ),
    );
  }
}

class _TopEdgeShadowPainter extends CustomPainter {
  const _TopEdgeShadowPainter({
    required this.radius,
    required this.reach,
    required this.blur,
    required this.color,
  });

  final double radius;
  final double reach;
  final double blur;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 面板顶边位于 y = reach；左右圆角落在 [reach, reach + radius]，层高需覆盖到那里。
    final top = reach;
    final r = radius;
    final w = size.width;
    if (w <= r * 2 || size.height <= top + r) return;

    // 沿面板顶边描一条与轮廓完全重合的路径：直线 + 左右圆角。
    final edge = Path()
      ..moveTo(0, top + r)
      ..arcTo(
        Rect.fromCircle(center: Offset(r, top + r), radius: r),
        pi,
        pi / 2,
        false,
      )
      ..lineTo(w - r, top)
      ..arcTo(
        Rect.fromCircle(center: Offset(w - r, top + r), radius: r),
        3 * pi / 2,
        pi / 2,
        false,
      );

    // 面板本体：裁掉内侧，阴影只留在轮廓之外。
    final panel = Path()
      ..addRRect(RRect.fromRectAndCorners(
        Rect.fromLTWH(0, top, w, size.height - top),
        topLeft: Radius.circular(r),
        topRight: Radius.circular(r),
      ));
    final all = Path()
      ..addRect(Rect.fromLTWH(
        -w,
        -size.height,
        w * 3,
        size.height * 3,
      ));
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, w, top + r));
    canvas.clipPath(Path.combine(PathOperation.difference, all, panel));
    canvas.drawPath(
      edge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = reach / 4
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TopEdgeShadowPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.reach != reach ||
      oldDelegate.blur != blur ||
      oldDelegate.color != color;
}

/// 面板顶边细线：从左边往上、沿左圆角、横过顶边、再沿右圆角往下收尾，
/// 一整条连续描边（BoxDecoration.border 圆角段会被 ClipRRect 裁掉）。
class _ShelfTopBorderPainter extends CustomPainter {
  const _ShelfTopBorderPainter({
    required this.radius,
    required this.color,
  });

  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = radius;
    final w = size.width;
    if (w <= r * 2 || size.height <= r) return;
    final path = Path()
      ..moveTo(0, r)
      ..arcTo(
          Rect.fromCircle(center: Offset(r, r), radius: r), pi, pi / 2, false)
      ..lineTo(w - r, 0)
      ..arcTo(
        Rect.fromCircle(center: Offset(w - r, r), radius: r),
        3 * pi / 2,
        pi / 2,
        false,
      );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_ShelfTopBorderPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.color != color;
}
