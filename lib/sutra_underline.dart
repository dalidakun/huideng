import 'dart:ui' show BoxHeightStyle, BoxWidthStyle;

import 'package:flutter/material.dart';

/// 画线文字的「每行点线」：文字正常排版，随后在每一行的字形底部下方
/// [gap] 像素处绘制一条与文字宽度一致的点线，与读经页「画线」的点线
/// 视觉一致，且点线不与汉字笔画底部重叠。
///
/// Flutter 自带的 `TextDecoration.underline` 固定在文字基线处、无法调整
/// 与文字的距离（中文字形底部恰在基线，导致点线压在笔画上），因此这里
/// 用 TextPainter 逐行取字形包围盒（`getBoxesForSelection`）定位，每行
/// 各自画一条从该行首字到末字的点线，杜绝行与行之间错位或划满整行。
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);

        // 逐行取字形包围盒：left/right 决定点线长度，bottom 决定点线高度。
        final lines = <({double left, double right, double bottom})>[];
        var pos = 0;
        while (pos < text.length) {
          final b = painter.getLineBoundary(TextPosition(offset: pos));
          if (b.isCollapsed) break;
          final boxes = painter.getBoxesForSelection(
            TextSelection(baseOffset: b.start, extentOffset: b.end),
            boxHeightStyle: BoxHeightStyle.tight,
            boxWidthStyle: BoxWidthStyle.tight,
          );
          if (boxes.isNotEmpty) {
            var left = boxes.first.left;
            var right = boxes.first.right;
            var bottom = boxes.first.bottom;
            for (final box in boxes) {
              if (box.left < left) left = box.left;
              if (box.right > right) right = box.right;
              if (box.bottom > bottom) bottom = box.bottom;
            }
            lines.add((left: left, right: right, bottom: bottom));
          }
          pos = b.end;
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