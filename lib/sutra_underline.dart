import 'package:flutter/material.dart';

/// 画线文字的「每行点线」：文字正常排版，随后在每一行的字形底部下方
/// [gap] 像素处绘制一条与文字宽度一致的点线，与读经页「画线」的点线
/// 视觉一致，且点线不与汉字笔画底部重叠。
///
/// Flutter 自带的 `TextDecoration.underline` 固定在文字基线处、无法调整
/// 与文字的距离（中文字形底部恰在基线，导致点线压在笔画上），因此这里
/// 用 TextPainter 逐行取行度量（`computeLineMetrics`，整体 O(n) 线性耗时），
/// 每行各自画一条从该行首字到末字的点线，杜绝行与行之间错位或划满整行。
/// 不使用逐行 `getBoxesForSelection`（每次调用 O(文本长度)、逐行调用累计
/// 为 O(n²)）：紧连段簇合并出几百行的画线文本时能卡死界面，本实现从根源
/// 上避免该问题，任何规模都只做线性布局。
class SutraUnderlineText extends StatelessWidget {
  const SutraUnderlineText({
    super.key,
    required this.text,
    required this.style,
    required this.lineColor,
    this.gap = 4,
    this.thickness = 1.3,
  });

  final String text;
  final TextStyle style;

  /// 点线颜色（建议带透明度，如 accent.withValues(alpha: 0.8)）。
  final Color lineColor;

  /// 字形底部到点线的垂直间距。
  final double gap;

  /// 点线粗细。
  final double thickness;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);

        // 逐行取行度量：left/width 决定点线长度，baseline 决定点线高度
        //（中文字形底端落在基线上，点线从基线再往下 gap 处绘制）。
        final lines = <({double left, double right, double bottom})>[];
        for (final m in painter.computeLineMetrics()) {
          if (m.width <= 0) continue;
          lines.add((
            left: m.left,
            right: m.left + m.width,
            bottom: m.baseline,
          ));
        }

        return SizedBox(
          width: constraints.maxWidth,
          height: painter.height + gap + thickness,
          child: CustomPaint(
            painter: _PerLineDottedPainter(
              textPainter: painter,
              lines: lines,
              color: lineColor,
              gap: gap,
              thickness: thickness,
            ),
          ),
        );
      },
    );
  }
}

class _PerLineDottedPainter extends CustomPainter {
  _PerLineDottedPainter({
    required this.textPainter,
    required this.lines,
    required this.color,
    required this.gap,
    required this.thickness,
  });

  final TextPainter textPainter;
  final List<({double left, double right, double bottom})> lines;
  final Color color;
  final double gap;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    textPainter.paint(canvas, Offset.zero);
    final paint = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;
    const dot = 1.2;
    const space = 2.0;
    for (final line in lines) {
      final y = line.bottom + gap + thickness / 2;
      for (var x = line.left; x < line.right; x += dot + space) {
        canvas.drawCircle(Offset(x + dot / 2, y), dot / 2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PerLineDottedPainter old) =>
      old.textPainter != textPainter ||
      old.color != color ||
      old.gap != gap ||
      old.thickness != thickness;
}