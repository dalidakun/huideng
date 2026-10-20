import 'dart:math' as math;

import 'package:flutter/material.dart';

final TextSelectionControls readerSelectionControls = ReaderSelectionControls();

class ReaderSelectionControls extends TextSelectionControls
    with TextSelectionHandleControls {
  ReaderSelectionControls();

  static const double _hitSize = 48.0;
  static const double _dropSize = 22.0;
  static const double _dropTop = _hitSize - _dropSize;

  @override
  Size getHandleSize(double textLineHeight) => const Size(_hitSize, _hitSize);

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) {
    return switch (type) {
      TextSelectionHandleType.left => const Offset(_hitSize, _dropTop),
      TextSelectionHandleType.right => const Offset(0, _dropTop),
      TextSelectionHandleType.collapsed =>
        const Offset(_hitSize / 2, _dropTop - 4),
    };
  }

  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textLineHeight, [
    VoidCallback? onTap,
  ]) {
    final Color color = TextSelectionTheme.of(context).selectionHandleColor ??
        Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: _hitSize,
      height: _hitSize,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        child: CustomPaint(
          painter: _ReaderSelectionHandlePainter(type: type, color: color),
        ),
      ),
    );
  }
}

class _ReaderSelectionHandlePainter extends CustomPainter {
  _ReaderSelectionHandlePainter({required this.type, required this.color});

  final TextSelectionHandleType type;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double drop = ReaderSelectionControls._dropSize;
    const double hit = ReaderSelectionControls._hitSize;
    final double r = drop / 2;

    final Path shape = Path()
      ..addOval(Rect.fromCircle(center: Offset(r, r), radius: r))
      ..addRect(Rect.fromLTWH(0, 0, r, r));
    final Paint paint = Paint()
      ..color = color
      ..isAntiAlias = true;

    final (double ox, double oy, double angle) = switch (type) {
      TextSelectionHandleType.right => (0, hit - drop, 0.0),
      TextSelectionHandleType.left => (hit - drop, hit - drop, math.pi / 2),
      TextSelectionHandleType.collapsed =>
        ((hit - drop) / 2, hit - drop, math.pi / 4),
    };

    canvas.save();
    canvas.translate(ox + r, oy + r);
    canvas.rotate(angle);
    canvas.translate(-r, -r);
    canvas.drawPath(shape, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ReaderSelectionHandlePainter oldDelegate) =>
      oldDelegate.type != type || oldDelegate.color != color;
}
