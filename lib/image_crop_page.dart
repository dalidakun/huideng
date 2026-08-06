import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// 图片裁剪页：固定宽高比裁剪框，拖动/双指缩放图片选择区域。
///
/// 两种用法：
/// - 作为独立路由：`Navigator.push` 返回裁剪后的 JPEG 字节（最长边不超过
///   [maxOutput]）；用户取消或图片无法解码时返回 null。
/// - 内嵌到页面（不推路由）：提供 [onResult]/[onCancel] 回调，页面本体原地
///   切换为裁剪界面，避免路由弹跳导致「先回上一页再弹出裁剪页」。
class ImageCropPage extends StatefulWidget {
  /// 原始图片字节；与 [filePath] 二选一。
  final Uint8List? bytes;

  /// 原始图片文件路径（选图后立即进入本页，页内读取）。
  final String? filePath;

  /// 裁剪框宽高比（宽 / 高）：头像 1.0，横幅约 2.5。
  final double ratio;

  /// 输出最长边像素。
  final int maxOutput;

  /// 内嵌模式：确认裁剪后回调（不再 Navigator.pop）。
  final void Function(Uint8List bytes)? onResult;

  /// 内嵌模式：取消裁剪时回调（不再 Navigator.pop）。
  final VoidCallback? onCancel;

  const ImageCropPage({
    super.key,
    this.bytes,
    this.filePath,
    required this.ratio,
    this.maxOutput = 512,
    this.onResult,
    this.onCancel,
  }) : assert(bytes != null || filePath != null);

  @override
  State<ImageCropPage> createState() => _ImageCropPageState();
}

class _ImageCropPageState extends State<ImageCropPage> {
  final TransformationController _tc = TransformationController();

  /// 解码后的原图（含 EXIF 方向修正）；解码失败为 null。
  img.Image? _src;

  /// 实际使用的原始字节（bytes 参数或从文件读取）。
  Uint8List? _bytes;

  /// 从文件读取解码中（选图后立刻进页，页内加载）。
  bool _loading = false;
  Future<void>? _loadFuture;

  /// 图片初始（scale=1）展示尺寸：按原图比例 cover 铺满裁剪框。
  Size _childSize = Size.zero;

  /// 裁剪框尺寸（宽高比由 widget.ratio 决定）。
  Size _frameSize = Size.zero;

  /// 首帧布局后把图片居中到裁剪框（保证初始看到图片中间区域）。
  bool _needInitMatrix = true;

  @override
  void initState() {
    super.initState();
    final b = widget.bytes;
    if (b != null) {
      _bytes = b;
      _decode(b);
    } else if (widget.filePath != null) {
      _loading = true;
      _loadFuture = _loadFromFile(widget.filePath!);
    }
  }

  void _decode(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        _src = img.bakeOrientation(decoded);
      }
    } catch (_) {}
  }

  Future<void> _loadFromFile(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _decode(bytes);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _ensureChildSize() {
    final src = _src;
    if (src == null || _childSize != Size.zero) return;
    final fw = _frameSize.width;
    final fh = _frameSize.height;
    final ar = src.width / src.height;
    final fr = widget.ratio;
    // cover：原图按比例铺满裁剪框，短边对齐、长边溢出。
    final double w;
    final double h;
    if (ar >= fr) {
      h = fh;
      w = fh * ar;
    } else {
      w = fw;
      h = fw / ar;
    }
    _childSize = Size(w, h);
  }

  Future<void> _confirm() async {
    // 仍在加载时先等文件读取完成。
    if (_loading && _loadFuture != null) {
      await _loadFuture;
      if (!mounted) return;
    }
    final src = _src;
    if (src == null) {
      // 无法解码（如 HEIC）：不保存，交由调用方处理。
      _finish(null);
      return;
    }
    final fw = _frameSize.width;
    final fh = _frameSize.height;
    final cw = _childSize.width;
    final ch = _childSize.height;
    final m = _tc.value;
    final z = m.getMaxScaleOnAxis();
    if (z <= 0) {
      _finish(null);
      return;
    }
    final tx = m.getTranslation().x;
    final ty = m.getTranslation().y;

    // 可见区域在子坐标系（初始尺寸）中的位置。
    // 变换为 screen = local * z + t，故可见区域从 (-tx/z, -ty/z) 起，大小为 fw/z × fh/z。
    var x0 = -tx / z;
    var y0 = -ty / z;
    var w = fw / z;
    var h = fh / z;
    x0 = x0.clamp(0.0, math.max(0.0, cw - w));
    y0 = y0.clamp(0.0, math.max(0.0, ch - h));
    w = w.clamp(1.0, cw - x0);
    h = h.clamp(1.0, ch - y0);

    // 映射回原图像素坐标。
    var sx = x0 / cw * src.width;
    var sy = y0 / ch * src.height;
    var sw = w / cw * src.width;
    var sh = h / ch * src.height;
    sx = sx.clamp(0, src.width - 1);
    sy = sy.clamp(0, src.height - 1);
    sw = sw.clamp(1, src.width - sx);
    sh = sh.clamp(1, src.height - sy);

    try {
      var cropped = img.copyCrop(
        src,
        x: sx.round(),
        y: sy.round(),
        width: sw.round(),
        height: sh.round(),
      );
      final longest = math.max(cropped.width, cropped.height);
      if (longest > widget.maxOutput) {
        final scale = widget.maxOutput / longest;
        cropped = img.copyResize(
          cropped,
          width: (cropped.width * scale).round(),
          height: (cropped.height * scale).round(),
        );
      }
      final out = Uint8List.fromList(img.encodeJpg(cropped, quality: 88));
      if (mounted) _finish(out);
    } catch (_) {
      if (mounted) _finish(null);
    }
  }

  /// 结束裁剪：内嵌模式回调 onResult/onCancel，独立路由模式 pop 结果。
  void _finish(Uint8List? out) {
    final onResult = widget.onResult;
    if (onResult != null) {
      if (out != null) {
        onResult(out);
      } else {
        widget.onCancel?.call();
      }
      return;
    }
    Navigator.pop(context, out);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, cons) {
                  var fw = math.min(cons.maxWidth, cons.maxHeight * widget.ratio);
                  var fh = fw / widget.ratio;
                  _frameSize = Size(fw, fh);
                  _ensureChildSize();
                  if (_needInitMatrix && _childSize != Size.zero) {
                    _needInitMatrix = false;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _tc.value = Matrix4.identity()
                        ..translateByDouble(
                          (_frameSize.width - _childSize.width) / 2,
                          (_frameSize.height - _childSize.height) / 2,
                          0,
                          1,
                        );
                    });
                  }
                  return Center(child: _buildFrame());
                },
              ),
            ),
            _buildHint(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          TextButton(
            onPressed: () {
              final onCancel = widget.onCancel;
              if (onCancel != null) {
                onCancel();
              } else {
                Navigator.pop(context);
              }
            },
            child: const Text('取消',
                style: TextStyle(color: Colors.white, fontSize: 15)),
          ),
          const Spacer(),
          const Text(
            '移动 / 双指缩放\n选择范围',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.3),
          ),
          const Spacer(),
          TextButton(
            onPressed: _confirm,
            child: const Text('完成',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildFrame() {
    return SizedBox(
      width: _frameSize.width,
      height: _frameSize.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRect(
              child: _src == null
                  ? ColoredBox(
                      color: const Color(0xFF2A2A2A),
                      child: Center(
                        child: _loading
                            ? const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5, color: Colors.white54),
                              )
                            : const Text('无法预览该图片\n请换一张图片',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.white54, fontSize: 13)),
                      ),
                    )
                  : InteractiveViewer(
                      transformationController: _tc,
                      constrained: false,
                      minScale: 1.0,
                      maxScale: 5.0,
                      panEnabled: true,
                      scaleEnabled: true,
                      boundaryMargin: EdgeInsets.zero,
                      child: SizedBox(
                        width: _childSize.width,
                        height: _childSize.height,
                        child: Image.memory(
                          _bytes!,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
            ),
          ),
          IgnorePointer(child: CustomPaint(painter: _GridPainter())),
        ],
      ),
    );
  }

  Widget _buildHint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Text(
        widget.ratio > 1.05 ? '拖动图片选择横幅区域，双指缩放调整大小' : '拖动图片选择头像区域，双指缩放调整大小',
        style: const TextStyle(color: Colors.white54, fontSize: 12),
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// 裁剪框网格：白色边框 + 三分线。
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white70;
    canvas.drawRect(Offset.zero & size, border);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = Colors.white38;
    for (var i = 1; i < 3; i++) {
      final dx = size.width * i / 3;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), line);
      final dy = size.height * i / 3;
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), line);
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => false;
}
