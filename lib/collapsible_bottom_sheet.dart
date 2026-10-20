import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 收起后底部横条的高度（不含系统手势区）。
const double kCollapsibleSheetBarHeight = 50;

int _collapsibleSheetCount = 0;
final ValueNotifier<bool> _collapsibleSheetOpen = ValueNotifier<bool>(false);

/// 可收起面板是否已经收到底部横条状态。
///
/// 收起时阅读页可以重新长按选中文字并弹出复制菜单；展开或关闭时为 false。
final ValueNotifier<bool> collapsibleSheetCollapsed =
    ValueNotifier<bool>(false);

/// 复制成功等提示要显示在收起横条上方，不能被横条挡住。
void showCollapsibleAwareSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  if (!_collapsibleSheetOpen.value) {
    messenger.showSnackBar(
      SnackBar(content: Text(message), duration: duration),
    );
    return;
  }
  final safeBottom = MediaQuery.of(context).padding.bottom;
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      behavior: SnackBarBehavior.floating,
      margin: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        kCollapsibleSheetBarHeight + safeBottom + 8,
      ),
    ),
  );
}

/// 阅读页用的可收起底部面板。
///
/// 展开时和普通底部面板一样占屏幕大部分高度；向下拖动顶部横杠可收成底部
/// 一条横条，此时遮罩会让开指针，下面的阅读页可以继续选中、复制文字；
/// 再点横条或向上拖动即可回到原来的编辑状态（输入内容不会丢）。
Future<T?> showCollapsibleBottomSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  required String collapsedTitle,
  double heightFactor = 0.9,
}) {
  return Navigator.of(context).push<T>(
    _CollapsibleSheetRoute<T>(
      builder: builder,
      collapsedTitle: collapsedTitle,
      heightFactor: heightFactor,
    ),
  );
}

class _CollapsibleSheetRoute<T> extends PopupRoute<T> {
  _CollapsibleSheetRoute({
    required this.builder,
    required this.collapsedTitle,
    required this.heightFactor,
  });

  final WidgetBuilder builder;
  final String collapsedTitle;
  final double heightFactor;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  // 遮罩的拦截由页面里带动画的那层负责：收起后要能点到底下的阅读页。
  @override
  Widget buildModalBarrier() {
    return const IgnorePointer(
      child: ModalBarrier(color: Colors.transparent, dismissible: false),
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _CollapsibleSheetHost(
      builder: builder,
      collapsedTitle: collapsedTitle,
      heightFactor: heightFactor,
    );
  }
}

class _CollapsibleSheetHost extends StatefulWidget {
  const _CollapsibleSheetHost({
    required this.builder,
    required this.collapsedTitle,
    required this.heightFactor,
  });

  final WidgetBuilder builder;
  final String collapsedTitle;
  final double heightFactor;

  @override
  State<_CollapsibleSheetHost> createState() => _CollapsibleSheetHostState();
}

class _CollapsibleSheetHostState extends State<_CollapsibleSheetHost>
    with SingleTickerProviderStateMixin {
  static const double _headerHeight = kCollapsibleSheetBarHeight;
  static const double _dragSnapVelocity = 320;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );

  double _bodyHeight = 0;

  @override
  void initState() {
    super.initState();
    _collapsibleSheetCount++;
    _collapsibleSheetOpen.value = true;
    collapsibleSheetCollapsed.value = false;
    _controller.addListener(_syncCollapsedState);
  }

  @override
  void dispose() {
    _controller.removeListener(_syncCollapsedState);
    _collapsibleSheetCount--;
    if (_collapsibleSheetCount <= 0) {
      _collapsibleSheetCount = 0;
      _collapsibleSheetOpen.value = false;
    }
    collapsibleSheetCollapsed.value = false;
    _controller.dispose();
    super.dispose();
  }

  void _syncCollapsedState() {
    final collapsed = _controller.value <= 0.001;
    if (collapsibleSheetCollapsed.value != collapsed) {
      collapsibleSheetCollapsed.value = collapsed;
    }
  }

  bool get _expanded => _controller.value > 0.5;

  void _expand() {
    FocusManager.instance.primaryFocus?.unfocus();
    _controller.animateTo(1, curve: Curves.easeOutCubic);
  }

  void _collapse() {
    FocusManager.instance.primaryFocus?.unfocus();
    _controller.animateTo(0, curve: Curves.easeInCubic);
  }

  void _toggle() {
    if (_expanded) {
      _collapse();
    } else {
      _expand();
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_bodyHeight <= 0) return;
    final next = (_controller.value - details.delta.dy / _bodyHeight)
        .clamp(0.0, 1.0)
        .toDouble();
    _controller.value = next;
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > _dragSnapVelocity) {
      _collapse();
    } else if (velocity < -_dragSnapVelocity) {
      _expand();
    } else if (_controller.value >= 0.5) {
      _expand();
    } else {
      _collapse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final viewHeight = media.size.height;
    final topInset = media.padding.top;
    final bottomInset = media.padding.bottom;
    final maxTotal = (viewHeight - topInset - bottomInset - 8)
        .clamp(160.0, viewHeight)
        .toDouble();
    final maxBody =
        (maxTotal - _headerHeight).clamp(80.0, viewHeight).toDouble();
    final wantedBody = viewHeight * widget.heightFactor;
    final bodyHeight = wantedBody < maxBody ? wantedBody : maxBody;
    _bodyHeight = bodyHeight;
    final fullHeight = _headerHeight + bodyHeight;
    final content = widget.builder(context);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final totalHeight = _headerHeight + bodyHeight * t;
        return Stack(
          children: [
            Positioned.fill(
              key: const ValueKey('collapsible_sheet_dim'),
              child: IgnorePointer(
                ignoring: t <= 0.001,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).maybePop(),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.54 * t),
                  ),
                ),
              ),
            ),
            Positioned(
              key: const ValueKey('collapsible_sheet_panel'),
              left: 0,
              right: 0,
              bottom: bottomInset,
              child: Material(
                color: AppPalette.p.card,
                elevation: 18,
                shadowColor: Colors.black.withValues(alpha: 0.24),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  height: totalHeight,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topCenter,
                      minHeight: fullHeight,
                      maxHeight: fullHeight,
                      child: SizedBox(
                        width: double.infinity,
                        height: fullHeight,
                        child: Column(
                          children: [
                            _buildHeader(context, t),
                            Expanded(
                              child: IgnorePointer(
                                ignoring: t < 0.5,
                                child: Opacity(
                                  opacity: t.clamp(0.0, 1.0).toDouble(),
                                  child: content,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, double t) {
    final p = AppPalette.p;
    final titleOpacity = (1 - t).clamp(0.0, 1.0).toDouble();
    return SizedBox(
      height: _headerHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              key: const ValueKey('collapsible_sheet_handle'),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: p.textHint,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Opacity(
                opacity: titleOpacity,
                child: Center(
                  child: Text(
                    widget.collapsedTitle,
                    key: const ValueKey('collapsible_sheet_title'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: p.primary,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
