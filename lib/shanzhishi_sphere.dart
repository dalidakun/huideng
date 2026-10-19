import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 球面铺排的纬度上限（度）：名号铺到 ±84°，上下极区也基本铺满，
/// 尽量消除球顶/球底的空带；配合同样放宽的俯仰限位，每位都能转到球心。
const double kSphereLatitudeDeg = 84;

/// 球面铺排：斐波那契螺旋把名号均匀撒满整个球面（极点附近也不挤），
/// 相邻序号在球面上彼此相邻，横着滑就是顺着名单走。
///
/// 纬度铺到 ±[kSphereLatitudeDeg]，保证每一位都能被滑到球心（俯仰角不超限）。
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
  // 纬度可达范围：|y| ≤ sin(84°)，配合俯仰限位每一位都能转到正中心。
  final yMax = math.sin(kSphereLatitudeDeg * math.pi / 180);
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

/// 橄榄形椭球的横向半径：左右各留出约 12% 页宽的边距，保证贴边的名号
/// （透视前移 + 文字半宽）也完整落在页内，不被屏幕左右裁掉。
double ellipsoidRadiusFor(double width, double height) => width * 0.38;

/// 纵向拉伸倍数：屏幕 y 方向把圆球拉成竖立橄榄形（旋转时外形始终竖立）。
double ellipsoidStretchFor(double width, double height) {
  final r = ellipsoidRadiusFor(width, height);
  if (r <= 12) return 1.4;
  // 1.04 是「y × 透视」的放大余量：只留一点点，其余贴满上下。
  return ((height / 2 - 6) / (r * 1.04)).clamp(1.25, 2.6).toDouble();
}

/// 橄榄形剪影的超椭圆指数：2 = 纯椭圆（上下两头尖、四角留白多），
/// 越大上下顶点越宽、剪影越接近圆角矩形，四角越满。
/// 取较大值：橄榄形顶部那个「点」两侧不再留出大块空白，顶头更饱满。
const double kSilhouetteExponent = 3.2;

/// 把橄榄形投影坐标 (x, y) 做超椭圆化后再乘半径/拉伸：
/// |x|、|y| < 1 时向外鼓（两头变宽、四角变满），> 1（透视前移）时略收。
({double x, double y}) superellipseWarp(double x, double y) {
  const p = 2.0 / kSilhouetteExponent;
  return (
    x: x == 0 ? 0 : x.sign * math.pow(x.abs(), p).toDouble(),
    y: y == 0 ? 0 : y.sign * math.pow(y.abs(), p).toDouble(),
  );
}

/// 星图上的名号显示文案：把结尾的「摩诃萨」尊称尾缀去掉（数据层保留全称）。
/// 「观自在菩萨摩诃萨」在球面上只写「观自在菩萨」，避免长名号重复尊称占地方。
String sphereDisplayName(String name) {
  var n = name.trim();
  while (n.length > 3 && n.endsWith('摩诃萨')) {
    n = n.substring(0, n.length - 3);
  }
  return n;
}

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

  /// 初始朝向对准的位次（上次点选的名号）；null / 越界时退回球心正前方那一位。
  final int? initialIndex;

  /// 是否允许入场动画与缓速自转（仅当前 Tab 页开启，省电）。
  final bool spinEnabled;

  /// 只认竖向拖动（ pitch / 纵向后退），横向手势不参与（本页整页不做左右切页）。
  /// 默认 false = 平时两轴都跟手。
  final bool verticalOnly;

  /// 中心名号变化时回调（拖动/自转过程中实时触发）。
  final ValueChanged<int>? onCurrentChanged;

  /// 点按中心当前名号（触发编辑）。
  final VoidCallback? onCurrentTap;

  /// 点按球面任意名号（含非中心）时回调位次，用于「点名号 → 下方显示该名号」。
  final ValueChanged<int>? onNameTapped;

  /// 惯性停稳 / 转动动画落定后回调（适合播一次点击音）。
  final ValueChanged<int>? onSettled;

  const ShanZhiShiSphere({
    super.key,
    required this.names,
    this.controller,
    this.initialIndex,
    this.spinEnabled = false,
    this.verticalOnly = false,
    this.onCurrentChanged,
    this.onCurrentTap,
    this.onNameTapped,
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
  static const double _pitchLimit = 84.0 * math.pi / 180.0;

  /// 每像素滑动对应的弧度放大系数（使用时除以球半径）。
  /// 比此前更小：同样的拖动距离球转得更少，佛号移动更从容（约放慢三分之一）。
  static const double _rotPerPx = 0.85;

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
      // 名号从无到有（异步加载完成）：重新对准上次点选的那一位。
      if (oldWidget.names.isEmpty && widget.names.isNotEmpty) {
        _aimInitial();
      }
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

  /// 初始朝向：上次点选的那一位（[ShanZhiShiSphere.initialIndex]）；
  /// 没有记录或位次无效时，退回离正前方最近的那一位。
  void _aimInitial() {
    if (_layout.n == 0) return;
    var best = widget.initialIndex ?? -1;
    if (best < 0 || best >= _layout.n) {
      best = 0;
      var bestZ = double.negativeInfinity;
      for (var i = 0; i < _layout.n; i++) {
        final p = _layout.points[i];
        if (p.z > bestZ) {
          bestZ = p.z;
          best = i;
        }
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

  // ─────────────── 手势（拖动旋转，不缩放） ───────────────

  void _onScaleStart(ScaleStartDetails d) {
    _ctrl.stop();
    _inertia = false;
    _animating = false;
    _driftUntil = null;
    _lastFocal = d.localFocalPoint;
    _samples
      ..clear()
      ..add(_PanSample(d.localFocalPoint, DateTime.now()));
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final last = _lastFocal;
    final delta = last == null ? Offset.zero : d.localFocalPoint - last;
    _lastFocal = d.localFocalPoint;
    final r = _radius > 10 ? _radius : 120.0;
    setState(() {
      if (delta != Offset.zero) {
        _yaw += delta.dx * _rotPerPx / r;
        _pitch = (_pitch + delta.dy * _rotPerPx / r)
            .clamp(-_pitchLimit, _pitchLimit)
            .toDouble();
      }
    });
    if (delta != Offset.zero) {
      _samples.add(_PanSample(d.localFocalPoint, DateTime.now()));
      if (_samples.length > 6) _samples.removeAt(0);
      _updateCurrent();
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
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
      return;
    }
    _inertia = true;
    _animating = false;
    _startRepeat();
  }

  void _onTapUp(TapUpDetails d) {
    final hit = _hitTest(d.localPosition);
    if (hit < 0) return;
    widget.onNameTapped?.call(hit);
    if (hit == _current) {
      widget.onCurrentTap?.call();
    } else {
      animateToIndex(hit);
    }
  }

  // verticalOnly 时的竖向拖动适配：把手势折算进同一套旋转/惯性逻辑，
  // 只取 y 分量——横向位移一律忽略（本页整页不做左右切页）。
  void _onVerticalDragStart(DragStartDetails d) {
    _onScaleStart(ScaleStartDetails(localFocalPoint: d.localPosition));
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    _onScaleUpdate(ScaleUpdateDetails(
      localFocalPoint: d.localPosition,
      pointerCount: 1,
    ));
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    _onScaleEnd(ScaleEndDetails(
      velocity: d.velocity,
      scaleVelocity: 0,
      pointerCount: 1,
    ));
  }

  /// 触点最近且足够近的正面名号位次；没有则 -1。
  int _hitTest(Offset pos) {
    if (_layout.n == 0 || _radius <= 0) return -1;
    final cx = _size.width / 2;
    final cy = _size.height / 2;
    final r = _radius;
    final stretch =
        ellipsoidStretchFor(_size.width, _size.height);
    final d = _cameraDistFactor * r;
    var best = -1;
    var bestD = 56.0;
    for (var i = 0; i < _layout.n; i++) {
      final p = _layout.points[i];
      final q = rotateSpherePoint(p.x, p.y, p.z, _yaw, _pitch);
      if (q.z < 0.05) continue;
      final persp = d / (d - q.z * r);
      final w = superellipseWarp(q.x * persp, q.y * persp);
      final dist =
          (Offset(cx + w.x * r, cy - w.y * r * stretch) - pos).distance;
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
        _radius = ellipsoidRadiusFor(_size.width, _size.height);
        final names = [for (final n in widget.names) sphereDisplayName(n)];
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 普通模式：两轴都跟手（scale 手势）；verticalOnly：只认竖向拖动，
          // 横向手势不进竞技场（本页整页不做左右切页）。
          onScaleStart: widget.verticalOnly ? null : _onScaleStart,
          onScaleUpdate: widget.verticalOnly ? null : _onScaleUpdate,
          onScaleEnd: widget.verticalOnly ? null : _onScaleEnd,
          onVerticalDragStart:
              widget.verticalOnly ? _onVerticalDragStart : null,
          onVerticalDragUpdate:
              widget.verticalOnly ? _onVerticalDragUpdate : null,
          onVerticalDragEnd:
              widget.verticalOnly ? _onVerticalDragEnd : null,
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
/// 注意它只是「世界字号」，最终还要乘透视。
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

/// 星图上的展示名：去掉结尾的「摩诃萨」（如「文殊师利菩萨摩诃萨」
/// 在球面上显示为「文殊师利菩萨」）；名录与点选仍用全名，仅显示时缩短。
String shanZhiShortName(String name) {
  final s = name.trim();
  const suffix = '摩诃萨';
  if (s.length > suffix.length && s.endsWith(suffix)) {
    return s.substring(0, s.length - suffix.length);
  }
  return s;
}

/// 两个矩形的交叠面积。
double _overlapAreaOf(Rect a, Rect b) {
  final i = a.intersect(b);
  if (i.width <= 0 || i.height <= 0) return 0;
  return i.width * i.height;
}

/// 计算某一朝向下的球面名号布局（纯函数，便于单测）：
/// - 正面背面都画，背面更淡更小，形成「立体星空」；
/// - 字号随深度连续变化，长名号自动缩号；
/// - 与更近的名号重叠过多的才退成星点。
SphereRenderResult computeSphereRender({
  required SphereLayout layout,
  required List<String> names,
  required double yaw,
  required double pitch,
  required int current,
  required double width,
  required double height,
}) {
  const empty = SphereRenderResult([]);
  final r = ellipsoidRadiusFor(width, height);
  if (r < 12 || layout.n == 0 || names.isEmpty) return empty;
  final cx = width / 2;
  final cy = height / 2;
  // 屏幕 y 方向拉伸：圆球投影成竖立橄榄形，横向半径仍是 r。
  final stretch = ellipsoidStretchFor(width, height);
  final cam = _cameraDistFactor * r;

  // 旋转 + 透视投影：全部名号（含背面）都参与，背面更小更淡。
  final pts = <SphereRenderItem>[];
  // 球面上的文案用去掉「摩诃萨」的短名（名录、点选、面板仍是全名）。
  final labels = [for (final n in names) shanZhiShortName(n)];
  for (var i = 0; i < layout.n && i < names.length; i++) {
    final p = layout.points[i];
    final q = rotateSpherePoint(p.x, p.y, p.z, yaw, pitch);
    final persp = cam / (cam - q.z * r);
    final isCur = i == current;
    final name = labels[i];
    final baseF = isCur ? 12.0 : _fontSizeOf(q.z);
    // 单个名号最宽不超过球面宽的 0.5（长名如「师子奋迅俱足万行如来」自动缩小）。
    final maxLayoutW = (r * 0.5) / persp;
    final fitF = name.length <= 1 ? baseF : maxLayoutW / name.length;
    final f = math.min(baseF, fitF).clamp(isCur ? 8.0 : 4.0, baseF).toDouble();
    // 超椭圆化：橄榄形上下两头加宽，四角留白更少。
    final w = superellipseWarp(q.x * persp, q.y * persp);
    pts.add(SphereRenderItem(
      index: i,
      sx: cx + w.x * r,
      sy: cy - w.y * r * stretch,
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
    final w = _estimateTextWidth(labels[v.index], v.f) * v.persp * v.squash;
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
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = ellipsoidRadiusFor(size.width, size.height);
    final stretch = ellipsoidStretchFor(size.width, size.height);
    // 星云底景先画（球体尚未画任何名号时也保留一片星空，不显得空荡）。
    _paintNebulaBackdrop(canvas, size, cx, cy, r, stretch);
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

    final dotPaint = Paint();
    // items 已按从远到近排好：背面的名号先画、更淡更小，正面压在上面。
    for (final v in res.items) {
      if (!v.isText) {
        // 退成星点的名号：用点景色（金/绿），不再是灰点。
        dotPaint.color = palette.accent.withValues(alpha: v.alpha * 0.85);
        canvas.drawCircle(
          Offset(v.sx, v.sy),
          (0.9 + 1.4 * v.z.abs()) * v.persp,
          dotPaint,
        );
        continue;
      }
      final tp = _tp(shanZhiShortName(names[v.index]), v.f,
          v.isCur ? 1 : v.alpha, v.isCur, double.infinity);
      if (v.isCur) {
        // 当前名号：两层柔光标识「球心落点」。
        _glow(v.sx, v.sy, v.f * v.persp * 3.1, palette.accent, 0.09, canvas);
        _glow(v.sx, v.sy, v.f * v.persp * 1.8, palette.accent, 0.16, canvas);
      }
      // 名号本身不再垫星点（会压在字底影响阅读）。
      canvas.save();
      canvas.translate(v.sx, v.sy);
      canvas.scale(v.persp * v.squash, v.persp);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }
  }

  /// 一团径向渐变柔光（星云斑块 / 光晕共用）。
  void _glow(double x, double y, double radius, Color color, double alpha,
      Canvas canvas) {
    if (radius <= 0) return;
    canvas.drawCircle(
      Offset(x, y),
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: alpha),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(
          center: Offset(x, y),
          radius: radius,
        )),
    );
  }

  /// 星云底景（画在所有名号之下）：
  /// - 几团错落的主色/深色柔光，晕出整幅星云的底色层次；
  /// - 球体轮廓处一圈贴合橄榄形的椭圆光晕，把「看不见的球」托出来。
  void _paintNebulaBackdrop(
    Canvas canvas,
    Size size,
    double cx,
    double cy,
    double r,
    double stretch,
  ) {
    final accent = palette.accent;
    final deep = palette.accentDeep;
    final primary = palette.primary;

    // 1) 全幅底光：一大团极淡的暖色，把整个画面晕染进星云氛围。
    _glow(cx, cy * 0.92, math.max(size.width, size.height) * 0.72, accent,
        0.035, canvas);

    // 2) 两团错落的副晕：左上偏暖深色、右下偏主色，拉开层次。
    _glow(cx - r * 0.62, cy - r * 0.42 * stretch, r * 1.05, deep, 0.075,
        canvas);
    _glow(cx + r * 0.58, cy + r * 0.5 * stretch, r * 1.15, primary, 0.055,
        canvas);

    // 3) 球体椭圆光晕：沿橄榄形剪影一圈，中心略暖、向外消失，
    //    让「虚空中的球」有一点若隐若现的体积。
    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(1.0, stretch);
    final haloR = r * 1.14;
    canvas.drawCircle(
      Offset.zero,
      haloR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            accent.withValues(alpha: 0.10),
            accent.withValues(alpha: 0.03),
            accent.withValues(alpha: 0),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: haloR)),
    );
    canvas.restore();
  }

  TextPainter _tp(String name, double f, double alpha, bool isCur,
      double maxWidth) {
    // 透明度按 8 档量化进缓存键：既保留「由浓到淡」，又不让缓存爆掉。
    final alphaStep = isCur ? 8 : (alpha * 8).round().clamp(1, 8);
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
              .withValues(alpha: alphaStep / 8),
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
