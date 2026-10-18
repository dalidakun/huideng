import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 球面铺排：斐波那契螺旋把名号均匀撒满整个球面（极点附近也不挤），
/// 相邻序号在球面上彼此相邻，横着滑就是顺着名单走。
///
/// 纬度压缩到 ±68°，保证每一位都能被滑到球心（俯仰角不超限）。
class SphereLayout {
  final int n;
  final List<({double x, double y, double z})> points;

  const SphereLayout({required this.n, required this.points});

  static const SphereLayout empty =
      SphereLayout(n: 0, points: []);
}

/// 按名号数量计算球面铺排（纯函数，便于单测）。
SphereLayout computeSphereLayout(int n) {
  if (n <= 0) return SphereLayout.empty;
  // 黄金角螺旋：均匀无极点拥挤。
  final golden = math.pi * (3 - math.sqrt(5));
  // 纬度可达范围：|y| ≤ sin(68°)，配合俯仰限位每一位都能转到正中心。
  final yMax = math.sin(68 * math.pi / 180);
  final points = List<({double x, double y, double z})>.filled(
    n,
    (x: 0.0, y: 0.0, z: 1.0),
  );
  for (var i = 0; i < n; i++) {
    final t = (i + 0.5) / n;
    final y = yMax * (1 - 2 * t);
    final r = math.sqrt(math.max(0.0, 1 - y * y));
    final theta = golden * i;
    points[i] = (x: r * math.cos(theta), y: y, z: r * math.sin(theta));
  }
  return SphereLayout(n: n, points: points);
}

/// 绕 Y 轴（yaw）再绕 X 轴（pitch）旋转单位球面上的一点，得到相机空间坐标：
/// x 右、y 上、z 朝向观察者。
({double x, double y, double z}) rotateSpherePoint(
  double x,
  double y,
  double z,
  double yaw,
  double pitch,
) {
  final cy = math.cos(yaw);
  final sy = math.sin(yaw);
  final cp = math.cos(pitch);
  final sp = math.sin(pitch);
  final x1 = x * cy + z * sy;
  final z1 = -x * sy + z * cy;
  return (x: x1, y: y * cp - z1 * sp, z: y * sp + z1 * cp);
}

/// 把球面上一点转到正前方中心（0,0,1）所需的 yaw / pitch。
({double yaw, double pitch}) sphereAimAngles(
  double x,
  double y,
  double z,
) {
  return (
    yaw: math.atan2(-x, z),
    pitch: math.atan2(y, math.sqrt(x * x + z * z)),
  );
}

/// 相机距离（单位：球半径的倍数）。越小透视越强、越「球」。
const double _cameraDistFactor = 2.4;

/// 父级持有的球体控制器：把指定位次的名号转到球心、读取当前位次。
class ShanZhiSphereController {
  _ShanZhiSphereState? _state;

  int get currentIndex => _state?._current ?? -1;

  void animateToIndex(int index) => _state?.animateToIndex(index);
}

/// 可任意方向滑动的名号球（虚空星图）：
/// - 虚空中一颗看不见的球：不画球体/网格/投影，只有名号浮在球面上，
///   背面名号被球体挡住不可见，近大远小、字号随距离连续变化；
/// - 正对球心的名号原地放大着主色；松手有惯性，停稳后磁吸；
/// - 页面可见（spinEnabled）时进入有一次入场转正 + 短暂缓速自转。
class ShanZhiShiSphere extends StatefulWidget {
  final List<String> names;
  final ShanZhiSphereController? controller;

  /// 是否允许入场动画与缓速自转（仅当前 Tab 页开启，省电）。
  final bool spinEnabled;

  /// 中心名号变化时回调（拖动/自转过程中实时触发）。
  final ValueChanged<int>? onCurrentChanged;

  /// 点按中心当前名号（触发编辑）。
  final VoidCallback? onCurrentTap;

  /// 惯性停稳 / 转动动画落定后回调（适合播一次点击音）。
  final ValueChanged<int>? onSettled;

  const ShanZhiShiSphere({
    super.key,
    required this.names,
    this.controller,
    this.spinEnabled = false,
    this.onCurrentChanged,
    this.onCurrentTap,
    this.onSettled,
  });

  @override
  State<ShanZhiShiSphere> createState() => _ShanZhiSphereState();
}

class _PanSample {
  final Offset p;
  final DateTime t;
  const _PanSample(this.p, this.t);
}

class _ShanZhiSphereState extends State<ShanZhiShiSphere>
    with SingleTickerProviderStateMixin {
  static const double _pitchLimit = 70.0 * math.pi / 180.0;

  /// 每像素滑动对应的弧度放大系数（使用时除以球半径）。
  static const double _rotPerPx = 1.35;

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  SphereLayout _layout = SphereLayout.empty;
  double _yaw = 0;
  double _pitch = 0;
  int _current = -1;

  Size _size = Size.zero;
  double _radius = 0;

  bool _inertia = false;
  bool _animating = false;
  bool _repeatOn = false;
  double _inertiaYawV = 0;
  double _inertiaPitchV = 0;
  DateTime _lastTick = DateTime.now();

  /// 入场后允许缓速自转的截止时间（过点即停，不打扰阅读）。
  DateTime? _driftUntil;
  bool _entered = false;
  bool _driftAfterAnim = false;

  Offset? _lastFocal;
  final List<_PanSample> _samples = [];

  double _fromYaw = 0;
  double _fromPitch = 0;
  double _toYaw = 0;
  double _toPitch = 0;

  /// TextPainter 缓存挂在 State 上，跨帧复用（画家实例每帧新建）。
  final Map<String, Map<String, TextPainter>> _tpCache = {};

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _ctrl.addListener(_onTick);
    _layout = computeSphereLayout(widget.names.length);
    _aimInitial();
  }

  @override
  void didUpdateWidget(covariant ShanZhiShiSphere oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.controller?._state = this;
    if (!identical(oldWidget.names, widget.names) &&
        oldWidget.names.length != widget.names.length) {
      _layout = computeSphereLayout(widget.names.length);
      _tpCache.clear();
      _current = -1;
      _updateCurrent(notify: false);
    }
    if (widget.spinEnabled && !oldWidget.spinEnabled) {
      _playEntrance();
    }
    if (!widget.spinEnabled && oldWidget.spinEnabled) {
      _driftUntil = null;
    }
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    _ctrl.dispose();
    for (final inner in _tpCache.values) {
      for (final tp in inner.values) {
        tp.dispose();
      }
    }
    _tpCache.clear();
    super.dispose();
  }

  /// 初始朝向：离正前方最近的那一位。
  void _aimInitial() {
    if (_layout.n == 0) return;
    var best = 0;
    var bestZ = double.negativeInfinity;
    for (var i = 0; i < _layout.n; i++) {
      final p = _layout.points[i];
      if (p.z > bestZ) {
        bestZ = p.z;
        best = i;
      }
    }
    final p = _layout.points[best];
    final aim = sphereAimAngles(p.x, p.y, p.z);
    _yaw = aim.yaw;
    _pitch = aim.pitch.clamp(-_pitchLimit, _pitchLimit).toDouble();
    _current = best;
  }

  /// 入场：从一个倾斜的侧上方视角缓缓转正，再缓速自转几秒后停住。
  void _playEntrance() {
    if (_layout.n == 0 || _entered) return;
    _entered = true;
    _fromYaw = _yaw - 1.15;
    _fromPitch = 0.42;
    _toYaw = _yaw;
    _toPitch = _pitch;
    _yaw = _fromYaw;
    _pitch = _fromPitch;
    _animating = true;
    _ctrl.forward(from: 0);
  }

  // ─────────────── 手势 ───────────────

  void _onPanStart(DragStartDetails d) {
    _ctrl.stop();
    _inertia = false;
    _animating = false;
    _driftUntil = null;
    _lastFocal = d.localPosition;
    _samples
      ..clear()
      ..add(_PanSample(d.localPosition, DateTime.now()));
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final last = _lastFocal;
    if (last == null) return;
    final delta = d.localPosition - last;
    _lastFocal = d.localPosition;
    final r = _radius > 10 ? _radius : 120.0;
    setState(() {
      _yaw += delta.dx * _rotPerPx / r;
      _pitch = (_pitch + delta.dy * _rotPerPx / r)
          .clamp(-_pitchLimit, _pitchLimit)
          .toDouble();
    });
    _samples.add(_PanSample(d.localPosition, DateTime.now()));
    if (_samples.length > 6) _samples.removeAt(0);
    _updateCurrent();
  }

  void _onPanEnd(DragEndDetails d) {
    double vx = 0;
    double vy = 0;
    if (_samples.length >= 2) {
      final a = _samples.first;
      final b = _samples.last;
      final dt = b.t.difference(a.t).inMicroseconds / 1e6;
      if (dt > 0.005) {
        vx = (b.p.dx - a.p.dx) / dt;
        vy = (b.p.dy - a.p.dy) / dt;
      }
    }
    final r = _radius > 10 ? _radius : 120.0;
    _inertiaYawV = (vx * _rotPerPx / r).clamp(-12.0, 12.0).toDouble();
    _inertiaPitchV = (vy * _rotPerPx / r).clamp(-12.0, 12.0).toDouble();
    if (_inertiaYawV.abs() < 0.2 && _inertiaPitchV.abs() < 0.2) {
      _snapToNearest();
      return;
    }
    _inertia = true;
    _animating = false;
    _startRepeat();
  }

  void _onTapUp(TapUpDetails d) {
    final hit = _hitTest(d.localPosition);
    if (hit < 0) return;
    if (hit == _current) {
      widget.onCurrentTap?.call();
    } else {
      animateToIndex(hit);
    }
  }

  /// 触点最近且足够近的正面名号位次；没有则 -1。
  int _hitTest(Offset pos) {
    if (_layout.n == 0 || _radius <= 0) return -1;
    final cx = _size.width / 2;
    final cy = _size.height / 2;
    final r = _radius;
    final d = _cameraDistFactor * r;
    var best = -1;
    var bestD = 56.0;
    for (var i = 0; i < _layout.n; i++) {
      final p = _layout.points[i];
      final q = rotateSpherePoint(p.x, p.y, p.z, _yaw, _pitch);
      if (q.z < 0.05) continue;
      final persp = d / (d - q.z * r);
      final dist =
          (Offset(cx + q.x * r * persp, cy - q.y * r * persp) - pos).distance;
      if (dist < bestD) {
        bestD = dist;
        best = i;
      }
    }
    return best;
  }

  // ─────────────── 转动 / 惯性 / 磁吸 / 自转 ───────────────

  void animateToIndex(int index) {
    if (index < 0 || index >= _layout.n) return;
    final p = _layout.points[index];
    final aim = sphereAimAngles(p.x, p.y, p.z);
    _fromYaw = _yaw;
    _fromPitch = _pitch;
    _toYaw = _nearestAngle(_yaw, aim.yaw);
    _toPitch = aim.pitch.clamp(-_pitchLimit, _pitchLimit).toDouble();
    _inertia = false;
    _driftUntil = null;
    _animating = true;
    _stopRepeat();
    _ctrl.forward(from: 0);
  }

  static double _nearestAngle(double from, double target) {
    var t = target;
    while (t - from > math.pi) {
      t -= 2 * math.pi;
    }
    while (t - from < -math.pi) {
      t += 2 * math.pi;
    }
    return t;
  }

  void _snapToNearest() {
    if (_current >= 0) {
      animateToIndex(_current);
    }
  }

  void _startRepeat() {
    if (_repeatOn) return;
    _repeatOn = true;
    _lastTick = DateTime.now();
    _ctrl.repeat(period: const Duration(milliseconds: 16));
  }

  void _stopRepeat() {
    if (!_repeatOn) return;
    _repeatOn = false;
    _ctrl.stop();
  }

  void _onTick() {
    if (_inertia) {
      final now = DateTime.now();
      final dt = ((now.difference(_lastTick).inMicroseconds / 1e3) / 1000)
          .clamp(0.0, 0.05)
          .toDouble();
      _lastTick = now;
      final decay = math.pow(0.93, dt * 60).toDouble();
      setState(() {
        _yaw += _inertiaYawV * dt;
        _pitch = (_pitch + _inertiaPitchV * dt)
            .clamp(-_pitchLimit, _pitchLimit)
            .toDouble();
        _inertiaYawV *= decay;
        _inertiaPitchV *= decay;
      });
      _updateCurrent();
      if (_inertiaYawV.abs() < 0.25 && _inertiaPitchV.abs() < 0.25) {
        _inertia = false;
        _stopRepeat();
        _snapToNearest();
      }
    } else if (_animating) {
      final t = Curves.easeOutCubic.transform(_ctrl.value);
      setState(() {
        _yaw = _fromYaw + (_toYaw - _fromYaw) * t;
        _pitch = _fromPitch + (_toPitch - _fromPitch) * t;
      });
      _updateCurrent();
      if (_ctrl.status == AnimationStatus.completed) {
        _animating = false;
        widget.onSettled?.call(_current);
        // 入场动画落定后，再缓速自转几秒，让球感立住后停住不打扰阅读；
        // 用户主动触发的转动（点按/搜索/随机）落定后不自转。
        if (widget.spinEnabled && _driftAfterAnim) {
          _driftAfterAnim = false;
          _driftUntil = DateTime.now().add(const Duration(seconds: 4));
          _startRepeat();
        } else {
          _stopRepeat();
        }
      }
    } else {
      final until = _driftUntil;
      if (until != null && DateTime.now().isBefore(until)) {
        final now = DateTime.now();
        final dt = ((now.difference(_lastTick).inMicroseconds / 1e3) / 1000)
            .clamp(0.0, 0.05)
            .toDouble();
        _lastTick = now;
        setState(() {
          _yaw += 0.085 * dt;
        });
        _updateCurrent();
      } else {
        _driftUntil = null;
        _stopRepeat();
      }
    }
  }

  void _updateCurrent({bool notify = true}) {
    if (_layout.n == 0) return;
    var best = 0;
    var bestZ = double.negativeInfinity;
    for (var i = 0; i < _layout.n; i++) {
      final p = _layout.points[i];
      final q = rotateSpherePoint(p.x, p.y, p.z, _yaw, _pitch);
      if (q.z > bestZ) {
        bestZ = q.z;
        best = i;
      }
    }
    if (best != _current) {
      _current = best;
      if (notify) widget.onCurrentChanged?.call(best);
    }
  }

  // ─────────────── 视图 ───────────────

  @override
  Widget build(BuildContext context) {
    widget.controller?._state = this;
    // 首次挂载时页面已是当前 Tab：直接播入场。
    if (widget.spinEnabled && !_entered && !_animating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.spinEnabled) _playEntrance();
      });
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(constraints.maxWidth, constraints.maxHeight);
        _radius = math.min(_size.width, _size.height) / 2 - 14;
        final names = widget.names;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onTapUp: names.isEmpty ? null : _onTapUp,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _SpherePainter(
                layout: _layout,
                names: names,
                yaw: _yaw,
                pitch: _pitch,
                current: _current,
                palette: AppPalette.p,
                tpCache: _tpCache,
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

/// 球面渲染的一个名号：屏幕坐标、深度、透视系数、横向压扁、字号与是否选中。
/// 纯几何数据（不含文字画笔），便于单测「一屏能看到多少名号」。
class SphereRenderItem {
  final int index;
  final double sx;
  final double sy;
  final double z;
  final double persp;
  final double squash;
  final double f;
  final double alpha;
  final bool isCur;
  final bool isText;

  const SphereRenderItem({
    required this.index,
    required this.sx,
    required this.sy,
    required this.z,
    required this.persp,
    required this.squash,
    required this.f,
    required this.alpha,
    required this.isCur,
    required this.isText,
  });

  SphereRenderItem copyWith({bool? isText}) => SphereRenderItem(
        index: index,
        sx: sx,
        sy: sy,
        z: z,
        persp: persp,
        squash: squash,
        f: f,
        alpha: alpha,
        isCur: isCur,
        isText: isText ?? this.isText,
      );
}

/// 一帧球面渲染的结果：全体名号（含背面），按深度从远到近排好。
class SphereRenderResult {
  final List<SphereRenderItem> items;

  const SphereRenderResult(this.items);

  List<SphereRenderItem> get texts =>
      items.where((e) => e.isText).toList(growable: false);
  List<SphereRenderItem> get dots =>
      items.where((e) => !e.isText).toList(growable: false);
}

/// 名号字号随深度连续变化：远处小字，越靠球心越大（但不夸张）。
/// 注意它只是「世界字号」，最终还要乘透视与缩放。
double _fontSizeOf(double z) {
  final zn = ((z + 1) / 2).clamp(0.0, 1.0).toDouble();
  return (6.5 + 3.5 * zn).toDouble();
}

/// 深度透明度：正面清晰、背面明显更淡但仍可见——「密密麻麻」的星空感。
double _depthAlpha(double z) {
  if (z >= 0) {
    return (0.45 + 0.55 * math.pow(z.clamp(0.0, 1.0), 0.7)).toDouble();
  }
  // 背面：从边缘 0.32 渐隐到球心 0.14。
  final b = (-z).clamp(0.0, 1.0);
  return (0.32 - 0.18 * b).toDouble();
}

/// 按字符数估算单行文字宽度（CJK 约一字等于一个字号宽）。
double _estimateTextWidth(String name, double f) => name.length * (f + 0.4);

/// 两个矩形的交叠面积。
double _overlapAreaOf(Rect a, Rect b) {
  final i = a.intersect(b);
  if (i.width <= 0 || i.height <= 0) return 0;
  return i.width * i.height;
}

/// 计算某一朝向 / 缩放下的球面名号布局（纯函数，便于单测）：
/// - 正面背面都画，背面更淡更小，形成「立体星空」；
/// - 字号随深度连续变化，长名号自动缩号；
/// - 缩得越小（zoom 小）名号越小、能同时看清的越多，越密；
/// - 与更近的名号重叠过多的才退成星点。
SphereRenderResult computeSphereRender({
  required SphereLayout layout,
  required List<String> names,
  required double yaw,
  required double pitch,
  required int current,
  required double width,
  required double height,
  double zoom = 1.0,
}) {
  const empty = SphereRenderResult([]);
  final baseR = math.min(width, height) / 2 - 14;
  final r = baseR * zoom;
  if (r < 12 || layout.n == 0 || names.isEmpty) return empty;
  final cx = width / 2;
  final cy = height / 2;
  final cam = _cameraDistFactor * r;

  // 旋转 + 透视投影：全部名号（含背面）都参与，背面更小更淡。
  final pts = <SphereRenderItem>[];
  for (var i = 0; i < layout.n && i < names.length; i++) {
    final p = layout.points[i];
    final q = rotateSpherePoint(p.x, p.y, p.z, yaw, pitch);
    final persp = cam / (cam - q.z * r);
    final isCur = i == current;
    final name = names[i];
    final baseF = isCur ? 12.0 : _fontSizeOf(q.z);
    // 单个名号最宽不超过球面宽的 0.5（长名如「师子奋迅俱足万行如来」自动缩小）。
    final maxLayoutW = (r * 0.5) / persp;
    final fitF = name.length <= 1 ? baseF : maxLayoutW / name.length;
    final f = math.min(baseF, fitF).clamp(isCur ? 8.0 : 4.0, baseF).toDouble();
    pts.add(SphereRenderItem(
      index: i,
      sx: cx + q.x * r * persp,
      sy: cy - q.y * r * persp,
      z: q.z,
      persp: persp,
      // 越靠边缘横向压扁（前后半球同样按 |z|），贴球面的立体感。
      squash: isCur ? 1.0 : math.max(0.22, q.z.abs()),
      f: f,
      alpha: isCur ? 1.0 : _depthAlpha(q.z),
      isCur: isCur,
      isText: true,
    ));
  }
  if (pts.isEmpty) return empty;
  // 从近到远依次占位（近的优先完整显示）。
  pts.sort((a, b) => b.z.compareTo(a.z));

  final placed = <Rect>[];
  final out = <SphereRenderItem>[];
  for (final v in pts) {
    final w = _estimateTextWidth(names[v.index], v.f) * v.persp * v.squash;
    final h = v.f * v.persp;
    final rect = Rect.fromCenter(
      center: Offset(v.sx, v.sy),
      width: w + 4,
      height: h * 1.15 + 2,
    );
    final crowded = !v.isCur &&
        placed.any((q) =>
            _overlapAreaOf(q, rect) > rect.width * rect.height * 0.4);
    if (crowded) {
      out.add(v.copyWith(isText: false));
    } else {
      placed.add(rect);
      out.add(v);
    }
  }
  // 绘制顺序：从远到近（先画背面，正面压上面）。
  out.sort((a, b) => a.z.compareTo(b.z));
  return SphereRenderResult(out);
}

class _SpherePainter extends CustomPainter {
  final SphereLayout layout;
  final List<String> names;
  final double yaw;
  final double pitch;
  final int current;
  final PaletteData palette;
  final Map<String, Map<String, TextPainter>> tpCache;

  _SpherePainter({
    required this.layout,
    required this.names,
    required this.yaw,
    required this.pitch,
    required this.current,
    required this.palette,
    required this.tpCache,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (layout.n == 0 || names.isEmpty) return;
    final res = computeSphereRender(
      layout: layout,
      names: names,
      yaw: yaw,
      pitch: pitch,
      current: current,
      width: size.width,
      height: size.height,
    );

    // 被挤掉的名号退成小星点（近大远小、近浓远淡），仍清晰可见。
    final dotPaint = Paint();
    for (final v in res.dots) {
      dotPaint.color = palette.textSec
          .withValues(alpha: (0.2 + 0.45 * math.pow(v.z, 1.2)).toDouble());
      canvas.drawCircle(
        Offset(v.sx, v.sy),
        (1.1 + 1.5 * v.z) * v.persp,
        dotPaint,
      );
    }

    final r = math.min(size.width, size.height) / 2 - 14;
    for (final v in res.texts) {
      final tp = _tp(names[v.index], v.f, v.isCur ? 1 : _alphaOfZ(v.z), v.isCur,
          (r * 1.4) / v.persp);
      if (v.isCur) {
        // 当前名号：背后一团柔光，标识「球心落点」。
        final glowR = v.f * v.persp * 2.0;
        canvas.drawCircle(
          Offset(v.sx, v.sy),
          glowR,
          Paint()
            ..shader = RadialGradient(
              colors: [
                palette.accent.withValues(alpha: 0.17),
                palette.accent.withValues(alpha: 0),
              ],
            ).createShader(
                Rect.fromCircle(center: Offset(v.sx, v.sy), radius: glowR)),
        );
      }
      canvas.save();
      canvas.translate(v.sx, v.sy);
      canvas.scale(v.persp * v.squash, v.persp);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }
  }

  TextPainter _tp(String name, double f, double alpha, bool isCur,
      double maxWidth) {
    // 透明度按 5 档量化进缓存键：既保留「由浓到淡」，又不让缓存爆掉。
    final alphaStep = isCur ? 5 : (alpha * 4).round().clamp(0, 5);
    final bucket = '${f.round()}|$alphaStep|${isCur ? 1 : 0}';
    final inner = tpCache.putIfAbsent(name, () => {});
    final hit = inner[bucket];
    if (hit != null) return hit;
    if (inner.isEmpty && tpCache.length > 3000) {
      for (final e in tpCache.values) {
        for (final tp in e.values) {
          tp.dispose();
        }
      }
      tpCache.clear();
    }
    final tp = TextPainter(
      text: TextSpan(
        text: name,
        style: TextStyle(
          color: (isCur ? palette.primary : palette.textSec)
              .withValues(alpha: alphaStep / 5),
          fontSize: f.roundToDouble(),
          fontWeight: isCur ? FontWeight.w700 : FontWeight.w400,
          letterSpacing: 0.4,
          height: 1.15,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    inner[bucket] = tp;
    return tp;
  }

  @override
  bool shouldRepaint(covariant _SpherePainter old) =>
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.current != current ||
      old.layout != layout ||
      old.names != names ||
      old.palette != palette;
}
