import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'app_state.dart';

/// 是否正在跟手露出 DeepSeek（即「下拉露出手势」接管中）。
///
/// 由 [PullRevealTracker] 维护，[PullRevealLockPhysics] 实时读取：接管期间
/// 屏蔽手指拖动对底层列表滚动偏移的影响，使主页/经藏页内容彻底「钉死」，
/// 只有 DeepSeek 页跟手滑出。
bool pullRevealScrollLocked = false;

/// 与 [AlwaysScrollableScrollPhysics] 叠加使用，露出期间冻结底层列表。
class PullRevealLockPhysics extends ScrollPhysics {
  const PullRevealLockPhysics({super.parent});

  @override
  PullRevealLockPhysics applyTo(ScrollPhysics? ancestor) {
    return PullRevealLockPhysics(parent: buildParent(ancestor));
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    // 露出期间不接受手指位移：列表原地不动。
    if (pullRevealScrollLocked) return 0.0;
    return super.applyPhysicsToUserOffset(position, offset);
  }

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    // 露出期间松手不产生惯性滚动，避免内容在 DeepSeek 收起时乱窜。
    if (pullRevealScrollLocked) return null;
    return super.createBallisticSimulation(position, velocity);
  }
}

/// DeepSeek「下拉逐渐露出」手势追踪器：主页、菩提空间、经藏页共用。
///
/// 直接把页面的指针事件转发给 [onPointerDown] / [onPointerMove] /
/// [onPointerUp] / [onPointerCancel]：
/// - 手势开始且列表在顶部（[canStart] 为真）时接管；
/// - 顶边继续下拉：累计位移，越过 [startThreshold] 后实时写入 [homeRevealScrub]，
///   DeepSeek 页面跟手逐渐露出，同时冻结底层列表（内容不动）；
/// - 反向上拖：位移回落，露出量随之收回（回到 0 即完全不显示 DeepSeek）；
/// - 松手：进度过半才置 [homeReveal] 完全展开，否则把进度归零收合。
///
/// 页面不可用时（搜索态、抽屉展开等）由 [canStart] 拦住；[reset] 归零，
/// 避免卡在半露出状态。
class PullRevealTracker {
  PullRevealTracker({this.canStart});

  /// 手势开始时是否允许接管（页面态：素白、非搜索、抽屉收起、列表在顶部）。
  final bool Function()? canStart;

  /// 下拉超过该距离后才开始露出（之前只累计、不露出），小滑动不触发。
  static const double startThreshold = 48;

  /// 越过起始阈值后再拖满该距离即完全露出。
  static const double revealDistance = 260;

  /// 松手时超过该进度才完全展开，否则收回。
  static const double commitProgress = 0.5;

  /// 最大累计位移（超出则钳位）。
  static double get _maxAcc => startThreshold + revealDistance;

  /// 小于该进度一律视为 0：下拉往返的浮点残差不该被当成「仍在露出」，
  /// 否则手指其实已拉回原位时还会去挂载 WebView。
  static const double _deadzone = 1e-3;

  /// 已累计的有效下拉位移（像素，已扣除触摸 slop）。
  double _acc = 0;

  /// 本次指针序列的纵向累计位移（下正、上负，未扣 slop）。
  double _cumulative = 0;

  /// 本次指针序列的横向累计位移（用于判定横向滑动、不误接管）。
  double _cumulativeX = 0;

  double _lastX = 0;
  double _lastY = 0;

  /// 当前接管的主指针；为空表示未在跟踪。
  int? _pointer;

  /// 是否已进入「露出接管」状态（底层列表被冻结）。
  bool _engaged = false;

  /// 立即中止当前下拉：位移与露出进度归零（页面收合交给展示层）。
  void reset() {
    _pointer = null;
    _engaged = false;
    _cumulative = 0;
    _cumulativeX = 0;
    _acc = 0;
    if (homeRevealScrub.value != 0) homeRevealScrub.value = 0;
    if (pullRevealScrollLocked) pullRevealScrollLocked = false;
  }

  void onPointerDown(PointerDownEvent e) {
    if (_pointer != null) return;
    if (homeReveal.value) return;
    if (pullRevealScrollLocked) return;
    if (canStart != null && !canStart!()) return;
    _pointer = e.pointer;
    _lastX = e.position.dx;
    _lastY = e.position.dy;
    _cumulative = 0;
    _cumulativeX = 0;
    _acc = 0;
    _engaged = false;
  }

  void onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    _cumulative += e.position.dy - _lastY;
    _cumulativeX += e.position.dx - _lastX;
    _lastX = e.position.dx;
    _lastY = e.position.dy;

    if (!_engaged) {
      // 横向占优：交给横向滑动，本次手势不再接管。
      if (_cumulativeX.abs() > _cumulative.abs() &&
          _cumulativeX.abs() > kTouchSlop) {
        _pointer = null;
        return;
      }
      // 确认纵向下拉前，列表保持正常滚动。
      if (_cumulative <= kTouchSlop) return;
      _engaged = true;
      pullRevealScrollLocked = true;
    }

    _acc = (_cumulative - kTouchSlop).clamp(0.0, _maxAcc);
    if (_acc <= 0) {
      // 已完全收回：解冻列表，后续上拖可正常滚动。
      _engaged = false;
      pullRevealScrollLocked = false;
    }
    _publish();
  }

  void onPointerUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _finish();
  }

  void onPointerCancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _finish();
  }

  void _finish() {
    final wasEngaged = _engaged;
    final progress = _progress();
    _pointer = null;
    _engaged = false;
    _cumulative = 0;
    _cumulativeX = 0;
    _acc = 0;
    if (pullRevealScrollLocked) {
      // 推迟到本次事件分发结束再解冻，确保松手产生的空挡不被列表惯性滚动利用。
      scheduleMicrotask(() {
        if (_pointer == null) pullRevealScrollLocked = false;
      });
    }
    if (!wasEngaged) return;
    if (progress >= commitProgress) {
      // 展开：先置 homeReveal（展示层从当前露出量补完余下动画并挂载 WebView），
      // 再归零 scrub —— 展示层此时忽略归零，不会触发收合。
      homeReveal.value = true;
      if (homeRevealScrub.value != 0) homeRevealScrub.value = 0;
    } else if (homeRevealScrub.value != 0) {
      // 未过半：收回（展示层播收合动画，动画走完释放 WebView）。
      homeRevealScrub.value = 0;
    }
  }

  double _progress() {
    if (_acc < startThreshold) return 0.0;
    final travel = _acc - startThreshold;
    if (travel <= 0) return 0.0;
    final p = (travel / revealDistance).clamp(0.0, 1.0);
    return p < _deadzone ? 0.0 : p;
  }

  bool _publish() {
    final p = _progress();
    if (p != homeRevealScrub.value) homeRevealScrub.value = p;
    return false;
  }
}
