import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 「核心经典 ⟷ xx社区」左右切换条。
///
/// 整条是一颗连通的胶囊：两段文字并排共用同一个圆角外框，中间既不挖空也不画线
/// （原先那条竖着的 S 形波浪既抢眼又显脏），整块也不描边。
/// 当前停在哪一侧由容器内部一枚**滑动的实心填充**说明——填充贴着外框内侧停靠，
/// 切过去时横移过中线，于是两半天然是一体的，而不是两个独立胶囊摆在一起。
/// 每段只写字，不带图标。
///
/// 胶囊本体不挂横向手势：左右滑动由页面外层的 [PageView] 承担，两半内容整页互换。
/// 这里只做点选——若胶囊自己也认领横向拖拽，它会先赢下手势竞技场，页面就滑不动了。
/// 配色交给 [tone]（社区本色），两种外观各自协调。
class SectSwitch extends StatelessWidget {
  const SectSwitch({
    super.key,
    required this.index,
    required this.onChanged,
    required this.leftLabel,
    required this.rightLabel,
    required this.tone,
  });

  /// 0 = 核心经典（左），1 = xx社区（右）。
  final int index;

  /// 点左段 / 点右段时回调新下标。
  final ValueChanged<int> onChanged;

  final String leftLabel;
  final String rightLabel;

  /// 社区本色。
  final Color tone;

  static const double height = 44;

  /// 滑动填充相对外框的内缩，留出一圈淡底的余地。
  static const double _inset = 3;

  /// 两段文字各自的定位键，测试按它量几何（确认中间没有空当）。
  static const Key leftKey = ValueKey('sect_switch_left');
  static const Key rightKey = ValueKey('sect_switch_right');

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          // 连体容器：对半切，两段文字各占一半，中线就是接缝。
          final slotW = w / 2;
          return Semantics(
            container: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _select(d.localPosition.dx < slotW ? 0 : 1),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 连体外框：只留一层很淡的本色底，不描边——这一块不要实体线框框。
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: tone.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(height / 2),
                    ),
                  ),
                  // 选中态：容器内部那枚滑动填充，贴着一侧停靠，横移过中线去另一侧。
                  AnimatedAlign(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    alignment: index == 0
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                    child: FractionallySizedBox(
                      widthFactor: 0.5,
                      heightFactor: 1,
                      child: Padding(
                        padding: const EdgeInsets.all(_inset),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: tone,
                            borderRadius: BorderRadius.circular(
                                (height - _inset * 2) / 2),
                            boxShadow: [
                              BoxShadow(
                                color: tone.withValues(alpha: 0.28),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  _label(leftLabel, index == 0, 0, slotW),
                  _label(rightLabel, index == 1, slotW, slotW),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _select(int i) {
    if (i == index) return;
    onChanged(i);
  }

  /// 一段文字：在自己那半区里居中，左右各内缩 10 让字不贴边。
  /// 只写文字，不带图标。
  /// 文字用 [IgnorePointer] 兜住，点击统一交给外层按坐标判断左右。
  Widget _label(String text, bool active, double left, double slotW) {
    final p = AppPalette.p;
    // 选中段压在实心填充上，用白字反白；未选中段用次级字色。
    final fg = active ? Colors.white : p.textSec;
    return Positioned(
      key: left == 0 ? leftKey : rightKey,
      left: left,
      width: slotW,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: fg,
                letterSpacing: 0.8,
              ),
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}