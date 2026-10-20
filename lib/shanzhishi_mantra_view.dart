import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'shanzhishi_mantra_store.dart';

/// 善知识「密咒」展示面：嵌在善知识主页（与佛号星图两屏常驻、由悬浮球「切换」互换），
/// 不是独立路由。每条密咒竖排成一条窄底色带，从左上角起横向一条条排，
/// 一行放满就换下一行继续排满；上下行留间距，底色块互不相连，密咒多时可上下滑动。
/// 点某条密咒暂不响应，后续再接持诵功能（搜索命中会高亮并滚到该条）。
class ShanZhiShiMantraView extends StatefulWidget {
  /// 点某条密咒时回调，参数是这条密咒的内部键（同名条目也能区分），
  /// 页面据此弹出详情：经文出处、神咒原文、人天利益。
  final ValueChanged<String>? onMantraTapped;

  const ShanZhiShiMantraView({super.key, this.onMantraTapped});

  /// 底部让出全局菜单栏（图标区约 46–51 + 安全区），内容不被盖住。
  static const double _bottomInset = 74;

  @override
  State<ShanZhiShiMantraView> createState() => ShanZhiShiMantraViewState();
}

class ShanZhiShiMantraViewState extends State<ShanZhiShiMantraView> {
  final ScrollController _scrollCtrl = ScrollController();

  /// 竖排字带的固定宽度：13 号字（约 14px）+ 左右各 5 的内衬 + 缓冲。
  static const double _stripWidth = 27;

  /// 同一行里左右两条密咒之间的水平间隔。
  static const double _columnGap = 14;

  /// 行与行之间的垂直间隔（把上下两行的底色块分开，界限清楚）；
  /// 约半个字高（13 号字一行 ≈ 19px → 6px），比水平间隔更紧。
  static const double _stripGap = 6;

  /// 每条密咒一个 GlobalKey：搜索命中后滚动定位用（SingleChildScrollView
  /// 是非懒加载，条目即使滑出视口也保持在树上，key 一定可解析）。
  final Map<int, GlobalKey> _stripKeys = {};

  /// 搜索命中时调用：把该条密咒滚到视口上部并高亮，一直亮着不自动消失，
  /// 直到用户点一下（点这条、或点别处）才去掉高亮。
  void revealMantra(String mantra) {
    final idx = ShanZhiShiMantraStore.instance.mantras.indexOf(mantra);
    if (idx < 0) return;
    setState(() => _highlightIndex = idx);
    final ctx = _stripKeys[idx]?.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final scroll = Scrollable.of(ctx);
    final viewportBox = scroll.context.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return;
    final delta = box.localToGlobal(Offset.zero).dy -
        viewportBox.localToGlobal(Offset.zero).dy -
        56;
    final pos = scroll.position;
    pos.animateTo(
      (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent).toDouble(),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  /// 搜索命中高亮的位次；null = 无高亮。
  int? _highlightIndex;

  /// 用户点一下任意位置（含高亮那条本身）就去掉高亮。
  void _clearHighlight() {
    if (_highlightIndex == null) return;
    setState(() => _highlightIndex = null);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _stripKeys.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final mq = MediaQuery.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _clearHighlight,
      child: ColoredBox(
        key: const ValueKey('shanzhishi_mantra_view'),
        color: p.bg,
        child: Stack(
          children: [
            // 与佛号星图同一族星云底光，两页观感统一。
            const Positioned.fill(
              child:
                  IgnorePointer(child: CustomPaint(painter: _MantraBackdrop())),
            ),
            // 顶部让出状态栏并再多留一截，与 toolbar 到底边都保有宽绰的呼吸感。
            // 列表随密咒 store 变化即时重建（添加后立即出现，不必等整页刷新）。
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 屏宽决定能放几列（列宽固定，左右各留 18 的页边）。
                  final availW = constraints.maxWidth - 36;
                  var n = ((availW + _columnGap) / (_stripWidth + _columnGap))
                      .floor();
                  if (n < 1) n = 1;
                  return ListenableBuilder(
                    listenable: ShanZhiShiMantraStore.instance,
                    builder: (context, _) {
                      final mantras = ShanZhiShiMantraStore.instance.mantras;
                      // 横向优先、逐列接续：按序号从左往右铺（先填满第一行的各列），
                      // 之后每条都补进当前最矮的一列——短密咒下面不留空档，
                      // 同列上下两条只隔 [_stripGap]，整页密实、不会出现成片留白。
                      final cols = List.generate(n, (_) => <int>[]);
                      final heights = List.filled(n, 0.0);
                      for (var i = 0; i < mantras.length; i++) {
                        var t = 0;
                        for (var c = 1; c < n; c++) {
                          if (heights[c] < heights[t] - 0.5) t = c;
                        }
                        final extra = cols[t].isEmpty ? 0.0 : _stripGap;
                        cols[t].add(i);
                        heights[t] += extra + _stripHeight(mantras[i]);
                      }
                      return SingleChildScrollView(
                        controller: _scrollCtrl,
                        padding: EdgeInsets.fromLTRB(
                          18,
                          mq.padding.top + 30,
                          18,
                          mq.padding.bottom + ShanZhiShiMantraView._bottomInset,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var c = 0; c < cols.length; c++) ...[
                              SizedBox(
                                width: _stripWidth,
                                child: Column(
                                  children: [
                                    for (var k = 0;
                                        k < cols[c].length;
                                        k++) ...[
                                      _strip(
                                          cols[c][k], mantras[cols[c][k]], p),
                                      if (k < cols[c].length - 1)
                                        const SizedBox(height: _stripGap),
                                    ],
                                  ],
                                ),
                              ),
                              if (c < cols.length - 1)
                                const SizedBox(width: _columnGap),
                            ],
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一条竖排密咒的预估高度：每字一行（13 号字、行高 1.46 ≈ 19px）
  /// + 上下内衬 6×2 + 描边 1.4×2——只用来挑选「最矮的一列」，不必精确。
  double _stripHeight(String text) =>
      text.characters.length * 13 * 1.46 + 12 + 2.8;

  /// 一条竖排密咒：躺在一条与字宽相近的窄底色带上（不留白、不套大卡片）。
  /// 固定宽度 [_stripWidth]，列宽即可预知，便于平铺分列。
  /// 搜索命中时改用强调色淡染 + 描边高亮，直到用户点一下才复原。
  Widget _strip(int index, String text, PaletteData p) {
    final chars = [for (final c in text.characters) c];
    final key = _stripKeys.putIfAbsent(index, () => GlobalKey());
    final entryKey = ShanZhiShiMantraStore.instance.keyAt(index) ?? text;
    final bool hit = index == _highlightIndex;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _clearHighlight();
        widget.onMantraTapped?.call(entryKey);
      },
      child: AnimatedContainer(
        key: ValueKey('shanzhishi_mantra_$index'),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
        width: _stripWidth,
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
        decoration: BoxDecoration(
          color: hit ? p.accent.withValues(alpha: 0.22) : p.tintBg,
          borderRadius: BorderRadius.circular(8),
          border: hit
              ? Border.all(color: p.accent, width: 1.4)
              : Border.all(color: Colors.transparent, width: 1.4),
        ),
        child: Text(
          key: key,
          chars.join('\n'),
          maxLines: chars.length,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: p.text,
            height: 1.46,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

/// 密咒页的星云底光：三团极淡的柔光，与佛号星图页同一族观感。
class _MantraBackdrop extends CustomPainter {
  const _MantraBackdrop();

  @override
  void paint(Canvas canvas, Size size) {
    final p = AppPalette.p;
    void glow(Offset c, double radius, Color color, double alpha) {
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: radius)),
      );
    }

    final accent = p.accent;
    glow(Offset(size.width * 0.5, size.height * 0.22), size.width * 0.75,
        accent, 0.05);
    glow(Offset(size.width * 0.2, size.height * 0.6), size.width * 0.6,
        p.accentDeep, 0.05);
    glow(Offset(size.width * 0.82, size.height * 0.8), size.width * 0.55,
        p.primary, 0.04);
  }

  @override
  bool shouldRepaint(_MantraBackdrop oldDelegate) => false;
}
