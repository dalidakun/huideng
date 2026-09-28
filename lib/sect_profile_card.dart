import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'sect_profiles.dart';

/// 宗派/法门介绍卡：核心思想 / 重要祖师 / 修行方式 / 历史地位。
///
/// 正文太长时默认只露一屏，其余折在「展开全文」后面——
/// 收起与展开用的是同一套排版，字号行距一个字都不改。四节一次铺开要占掉小半屏，
/// 往下翻经典之前先得滚过它，所以宁可先收着。正文行距比卷行松，因为这段是读的。
class SectProfileCard extends StatefulWidget {
  const SectProfileCard({
    super.key,
    required this.profile,
    this.title = '宗派介绍',
  });

  final SectProfile profile;

  /// 卡片标题：宗门是「宗派介绍」，法门是「法门介绍」。
  final String title;

  @override
  State<SectProfileCard> createState() => _SectProfileCardState();
}

class _SectProfileCardState extends State<SectProfileCard> {
  /// 正文未截断时的真实高度。第一次按自然高度排版，量到之后才决定要不要收。
  final GlobalKey _bodyKey = GlobalKey();
  double _naturalHeight = 0;

  /// 超长时是否已展开全文。
  bool _expanded = false;

  /// 正文高过这个值就默认收起，只露出这一屏，剩下半截折在「展开全文」后面。
  /// 14 号字、1.85 行距一行约 26，240 相当于九行：核心思想的半段读完了，
  /// 想接着读或看祖师/修行/历史再展开。
  static const double _kCollapseLimit = 240;

  @override
  void didUpdateWidget(SectProfileCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换栏目（profile 实例随之不同）时重新量，别把上一门的高度与展开状态带过来。
    if (!identical(oldWidget.profile, widget.profile)) {
      _naturalHeight = 0;
      _expanded = false;
    }
  }

  /// 量一次正文自然高度。收起时正文照样按自然高度布局（只是被裁到一屏），
  /// 所以量到的永远是完整高度。
  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = _bodyKey.currentContext?.findRenderObject() as RenderBox?;
      if (!mounted || box == null || !box.hasSize) return;
      final h = box.size.height;
      if (h <= 0 || (h - _naturalHeight).abs() < 0.5) return;
      setState(() => _naturalHeight = h);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final profile = widget.profile;
    // 量到高度之前先按「太长」处理：首帧就已经是收起的样子，不会先铺开再收一下。
    // 二十栏正文都过一屏，量完还是收起，中间没有任何视觉变化。
    _scheduleMeasure();
    final tooLong = _naturalHeight == 0 || _naturalHeight > _kCollapseLimit;
    final clipped = tooLong && !_expanded;

    final body = KeyedSubtree(
      key: _bodyKey,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _block(p, '核心思想', text: profile.idea),
            _block(p, '重要祖师', lines: profile.masters),
            _block(p, '修行方式', text: profile.practice),
            _block(p, '历史地位', text: profile.history, last: true),
          ],
        ),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.borderSoft, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Row(
              children: [
                Icon(Icons.menu_book_outlined, size: 17, color: p.textHint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                // 禅宗没有别称，没有就不占位，标题照样贴左。
                if (profile.alias.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      profile.alias,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: p.textHint,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: p.borderSoft),
          // 收起时正文仍按自然高度布局，只是外层只画一屏：这样量到的就是完整高度，
          // 首帧不用先铺开再收，直接就是收起的样子。
          // 截断走「不可滚动的滚动视图」：直接 ConstrainedBox 会让 Column 溢出报错。
          if (clipped)
            ClipRect(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: _kCollapseLimit),
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: body,
                ),
              ),
            )
          else
            body,
          if (tooLong) _buildToggle(p),
        ],
      ),
    );
  }

  /// 卡片底部「展开全文 / 收起」：只在正文超长时才有，样式跟着小节标题走。
  Widget _buildToggle(PaletteData p) {
    final expanded = _expanded;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
        onTap: () => setState(() => _expanded = !expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 11),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                expanded ? '收起' : '展开全文',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: p.accentDeep,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 16,
                color: p.accentDeep,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一节：小标题用主色竖条（沿用译本小标题的语言，但换主色以示层级不同），
  /// 正文与祖师列表同字号，行距放宽到 1.85。
  Widget _block(
    PaletteData p,
    String label, {
    String? text,
    List<String>? lines,
    bool last = false,
  }) {
    final body = TextStyle(
      fontSize: 14,
      color: p.text,
      height: 1.85,
      letterSpacing: 0.4,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 3, height: 12, color: p.accent),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: p.accentDeep,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          if (lines != null)
            // 祖师逐人一条：圆点缩进，长句折行后仍与名字对齐。
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 8, right: 7),
                      child: Container(
                        width: 3,
                        height: 3,
                        decoration: BoxDecoration(
                          color: p.textHint,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Expanded(child: Text(line, style: body)),
                  ],
                ),
              )
          else
            Text(text ?? '', style: body),
        ],
      ),
    );
  }
}
