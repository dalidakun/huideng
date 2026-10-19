import 'dart:async';
import 'dart:math' show cos, exp, max, pi, sin;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'note_sutra_links.dart';
import 'reading_page.dart';
import 'shanzhishi_edit_sheet.dart';
import 'shanzhishi_mantra_edit_sheet.dart';
import 'shanzhishi_mantra_store.dart';
import 'shanzhishi_mantra_view.dart';
import 'shanzhishi_sphere.dart';
import 'shanzhishi_store.dart';
import 'ui_sound.dart';

/// 善知识页（底部菜单第 4 格）：
///
/// 整页是一颗立体的名号星球（竖立橄榄形椭球、正背面全点、连续字号）；
/// 点名号后从底部拉出与经藏页「全部经典」同款的上拉面板（占屏高 3/4），
/// 显示该名号与关联经文，点经文进入阅读页；右下角「编辑」可改名号、
/// 关联经文与人天利益。
///
/// 右下角是一颗与阅读页右下角同款的悬浮球：点开后沿弧线弹出「添加 / 搜索 /
/// 切换」三个子按钮；「搜索」在本页悬浮出搜索框与结果，点结果只把球转到
/// 该名号，不自动展开底部面板。
///
/// 名号由用户自己录入（悬浮球的「添加」），本地持久化，越聚越多。
class ShanZhiShiPage extends StatefulWidget {
  /// 底部菜单当前索引：仅当等于 [tabIndex] 时球体才播入场/自转（省电）。
  final ValueListenable<int>? activeTab;

  /// 本页在主页页面列表里的索引（善知识 = 7）。
  final int tabIndex;

  const ShanZhiShiPage({super.key, this.activeTab, this.tabIndex = 7});

  @override
  State<ShanZhiShiPage> createState() => ShanZhiShiPageState();
}

class ShanZhiShiPageState extends State<ShanZhiShiPage>
    with SingleTickerProviderStateMixin {
  final ShanZhiShiStore _store = ShanZhiShiStore.instance;
  final ShanZhiSphereController _sphereCtrl = ShanZhiSphereController();

  // ── 密咒展示面（第 2 页）同套交互 ──
  final ShanZhiShiMantraStore _mxStore = ShanZhiShiMantraStore.instance;
  bool _mxSearchOpen = false;
  final TextEditingController _mxSearchCtrl = TextEditingController();

  /// 密咒展示面（引用其 State：搜索命中后滚动定位到那条密咒）。
  /// 两屏常驻同一棵树，State 一直保留（滚动位置不重置）。
  final GlobalKey<ShanZhiShiMantraViewState> _mxPageKey = GlobalKey();

  /// 当前停在的那一屏（0 = 佛号星图，1 = 密咒竖排）。两屏不做左右滑动切换，
  /// 只由悬浮球的「切换」子按钮点选互换，所以这里就是一个状态位。
  /// 右下角悬浮球两页共用一颗、固定不随切页移动，仅按当前屏换键位与子按钮动作。
  int _pageIdx = 0;

  /// 当前选中的名号位次；null = 底部面板不显示（点名号后才出现）。
  int? _selected;

  /// 本 session 内通过「编辑 → 保存」动过的名号（createdAt）：
  /// 「恢复」按钮只对这些出现，其余时候一律不显示。
  final Set<int> _editedInSession = {};

  // ── 搜索（悬浮在本页，不跳新页面） ──
  bool _searchOpen = false;
  final TextEditingController _searchCtrl = TextEditingController();

  // ── 底部上拉面板（与经藏页「全部经典」同款） ──
  static const double _shelfHeaderH = 50;
  static const double _shelfOpenTopExtra = 12;
  static const double _shelfTopRadius = 16;
  static const double _shelfShadowReach = 14;

  /// 面板左右内边距：header 的名号与内容区共用，保证左对齐在同一条竖线上。
  static const double _shelfSidePad = 20;

  /// 展开后整块面板占可用高度的比例（与添加善知识面板一样大，接近满屏）。
  static const double _shelfOpenFraction = 0.9;

  bool _shelfExpanded = false;
  late final AnimationController _shelfController;

  /// 右下角悬浮球是否展开（展开后显示 添加 / 搜索 / 切换 三个子按钮）。
  bool _showFabMenu = false;

  /// 仅在明确挂了 [activeTab] 且轮到本页时才允许球体入场/自转。
  bool get _isActive =>
      widget.activeTab != null && widget.activeTab!.value == widget.tabIndex;

  @override
  void initState() {
    super.initState();
    _shelfController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _store.addListener(_onStoreChanged);
    _mxStore.addListener(_onMxStoreChanged);
    widget.activeTab?.addListener(_onTabChanged);
    unawaited(_store.load());
    unawaited(_mxStore.load());
    unawaited(NoteSutraCatalog.load());
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    _mxStore.removeListener(_onMxStoreChanged);
    widget.activeTab?.removeListener(_onTabChanged);
    _shelfController.dispose();
    _searchCtrl.dispose();
    _mxSearchCtrl.dispose();
    super.dispose();
  }

  /// 密咒库变化（添加/载入完成）：刷新密咒页。
  void _onMxStoreChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onStoreChanged() {
    if (!mounted) return;
    final sel = _selected;
    if (sel != null) {
      if (_store.length == 0) {
        // 最后一位被删掉：面板直接落下，不留一个空壳。
        _selected = null;
        _shelfExpanded = false;
        _shelfController.value = 0;
      } else if (sel >= _store.length) {
        _selected = _store.length - 1;
      }
    }
    setState(() {});
  }

  void _onTabChanged() {
    if (!mounted) return;
    // 切走时顺手收起悬浮菜单与两页的搜索浮层，回来看到的是干净页面。
    if (!_isActive && _showFabMenu) _showFabMenu = false;
    if (!_isActive && _searchOpen) _searchOpen = false;
    if (!_isActive && _mxSearchOpen) _mxSearchOpen = false;
    setState(() {});
  }

  // ─────────────── 动作 ───────────────

  /// 打开搜索浮层：搜索框与结果都悬浮在本页上方，不跳转新页面。
  void _openSearch() {
    unawaited(UiSound.instance.playClick());
    setState(() {
      _searchOpen = true;
      _searchCtrl.clear();
    });
  }

  void _closeSearch() {
    if (!_searchOpen) return;
    _searchCtrl.clear();
    setState(() => _searchOpen = false);
  }

  /// 右下角悬浮球的「切换」：直接换到另一屏（不做左右滑动的过场效果）。
  /// 两屏各自常驻，球面朝向与密咒滚动位置都留着，切回来还是原样。
  void _openSwitch() {
    final logical = _pageIdx == 0 ? 1 : 0;
    setState(() {
      _pageIdx = logical;
      // 另一屏的搜索浮层若还开着就先收起：树里同时留两个输入框会抢焦点，
      // 键盘可能一直弹不出来。
      if (logical != 0 && _searchOpen) _closeSearch();
      if (logical != 1 && _mxSearchOpen) _closeMxSearch();
    });
  }

  // ─────────────── 密咒页的动作 ───────────────

  /// 打开密咒搜索浮层（搜的是密咒名，不搜佛号）。
  void _openMxSearch() {
    unawaited(UiSound.instance.playClick());
    setState(() {
      _mxSearchOpen = true;
      _mxSearchCtrl.clear();
    });
  }

  void _closeMxSearch() {
    if (!_mxSearchOpen) return;
    _mxSearchCtrl.clear();
    setState(() => _mxSearchOpen = false);
  }

  /// 密咒搜索命中：前缀匹配优先、包含匹配其次。
  List<String> get _mxSearchHits {
    final q = _mxSearchCtrl.text.trim();
    if (q.isEmpty) return const [];
    final prefix = <String>[];
    final contains = <String>[];
    for (final m in _mxStore.mantras) {
      if (m.startsWith(q)) {
        prefix.add(m);
      } else if (m.contains(q)) {
        contains.add(m);
      }
    }
    return [...prefix, ...contains];
  }

  /// 点密咒搜索结果：收起浮层，并把名单滚到那条密咒（否则看不出它在哪）。
  void _onMxSearchHit(String mantra) {
    unawaited(UiSound.instance.playClick());
    _closeMxSearch();
    _mxPageKey.currentState?.revealMantra(mantra);
  }

  /// 新建密咒：上拉面板取名，保存进密咒库（重名面板内提示）。
  Future<void> _openMantraAdd() async {
    unawaited(UiSound.instance.playClick());
    await ShanZhiShiMantraEditSheet.show(context);
  }

  /// 前缀匹配优先、包含匹配其次（与经藏检索口径一致）。
  List<int> get _searchHits {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final prefix = <int>[];
    final contains = <int>[];
    for (var i = 0; i < _store.length; i++) {
      final t = _store[i]!.name.toLowerCase();
      if (t.startsWith(q)) {
        prefix.add(i);
      } else if (t.contains(q)) {
        contains.add(i);
      }
    }
    return [...prefix, ...contains];
  }

  /// 点搜索结果：只把球转到该名号（球心显示它），
  /// 不自动展开底部面板——面板由用户自己点球面名号时才出现。
  void _onSearchHit(int idx) {
    unawaited(UiSound.instance.playClick());
    _closeSearch();
    _rememberLastTapped(idx);
    _sphereCtrl.animateToIndex(idx);
  }

  Future<void> _openAdd() async {
    unawaited(UiSound.instance.playClick());
    final saved = await ShanZhiShiEditSheet.show(context);
    if (saved == null || !mounted) return;
    setState(() {
      _selected = saved;
    });
    _rememberLastTapped(saved);
    _openShelf();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sphereCtrl.animateToIndex(saved);
    });
  }

  void _onNameTapped(int idx) {
    unawaited(UiSound.instance.playClick());
    setState(() {
      _selected = idx;
    });
    _rememberLastTapped(idx);
    _openShelf();
  }

  /// 记住用户刚点的名号：下次进本页球心默认对准它（不再固定正中间）。
  void _rememberLastTapped(int idx) {
    final name = _store[idx]?.name;
    if (name != null) unawaited(_store.rememberLastTapped(name));
  }

  /// 面板右下角「编辑」：改名号、增删关联经文、维护人天利益。
  Future<void> _editEntry(ShanyishiEntry entry) async {
    final index = _selected;
    if (index == null) return;
    unawaited(UiSound.instance.playClick());
    final saved = await ShanZhiShiEditSheet.show(
      context,
      index: index,
      entry: entry,
    );
    if (!mounted) return;
    if (saved == null) return;
    // 编辑并保存过：这一位才有「恢复」（取消保存不出现）。
    final createdAt = _store[saved]?.createdAt;
    if (createdAt != null) _editedInSession.add(createdAt);
    setState(() {
      _selected = saved;
    });
    _rememberLastTapped(saved);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sphereCtrl.animateToIndex(saved);
    });
  }

  /// 打开一部关联经文的阅读页。
  ///
  /// 经藏目录里查得到就带上正文路径（正文未下载时由阅读页自己给下载入口），
  /// 查不到就提示一下，不打开空白的「暂无实际文件」页。
  Future<void> _openSutraReading(String sutra) async {
    unawaited(UiSound.instance.playClick());
    var link = ShanZhiShiStore.resolveSutra(sutra);
    if (link == null) {
      // 目录可能还没加载完：等它一次再解析。
      try {
        await NoteSutraCatalog.load();
      } catch (_) {
        // 目录读取失败就按「找不到」处理。
      }
      link = ShanZhiShiStore.resolveSutra(sutra);
    }
    if (!mounted) return;
    final resolved = link;
    if (resolved == null || resolved.filePath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('经藏里没有找到「$sutra」',
              style: const TextStyle(fontSize: 13)),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReadingPage(
          title: resolved.title,
          filePath: resolved.filePath,
        ),
      ),
    );
  }

  /// 面板右下角「恢复」：把这一位退回最近一次编辑前的版本（一步撤销）。
  ///
  /// 名号、关联经文、人天利益一起还原，防止误删；只在编辑保存过之后出现。
  Future<void> _restoreEntry() async {
    final index = _selected;
    if (index == null) return;
    unawaited(UiSound.instance.playClick());
    final createdAt = _store[index]?.createdAt;
    final ok = await _store.restoreLast(index);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('没有可恢复的版本', style: TextStyle(fontSize: 13)),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    // 快照已消费：撤掉「可恢复」标记，按钮随之消失。
    if (createdAt != null) _editedInSession.remove(createdAt);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已恢复到编辑前的版本', style: TextStyle(fontSize: 13)),
        duration: Duration(seconds: 2),
      ),
    );
  }

  // ─────────────── 上拉面板开合 ───────────────

  /// 面板内容区（不含 header）的最大高度：展开后整块面板占可用高度的 90%
  /// （与添加善知识面板一样大），上方只留一条窄边看球体。
  double _shelfContentMaxHeight() {
    final mq = MediaQuery.of(context);
    final available = mq.size.height - mq.padding.top - mq.padding.bottom;
    // header 展开时会多出 _shelfOpenTopExtra，先扣掉才是内容区高度。
    return max(
      0.0,
      available * _shelfOpenFraction - _shelfHeaderH - _shelfOpenTopExtra,
    );
  }

  void _openShelf() {
    _shelfExpanded = true;
    // 面板占了右下角：悬浮球先收起，免得压住面板。
    _showFabMenu = false;
    _shelfController.forward();
  }

  /// 点 header 收起：整块滑出屏幕下沿后卸载（动画中重开则不卸载）。
  void _closeShelf() {
    unawaited(UiSound.instance.playClick());
    _collapseShelf();
  }

  /// 静默收起面板（侧滑返回用，不播点击音）。
  void _collapseShelf() {
    _shelfExpanded = false;
    _shelfController.reverse().whenComplete(() {
      if (!_shelfExpanded && mounted) setState(() => _selected = null);
    });
  }

  /// 根路由侧滑返回：搜索浮层 → 悬浮球展开 → 面板展开，依次先收起（回到星图）。
  /// 返回是否消费了本次返回，避免系统直接最小化应用。
  bool collapseShelfIfOpen() {
    if (_searchOpen) {
      _closeSearch();
      return true;
    }
    if (_showFabMenu) {
      _closeFabMenu();
      return true;
    }
    if (_mxSearchOpen) {
      _closeMxSearch();
      return true;
    }
    // 密咒展示面还在：侧滑返回先切回佛号球面。
    if (_pageIdx == 1) {
      _openSwitch();
      return true;
    }
    if (_selected == null) return false;
    _collapseShelf();
    return true;
  }

  /// 纵向拖 header 时按手指位移实时擦洗展开比例（向下拖收起，向上拖展开）。
  void _onShelfDragUpdate(DragUpdateDetails d) {
    final maxH = _shelfContentMaxHeight();
    final delta = d.primaryDelta ?? 0;
    if (maxH <= 0 || delta == 0) return;
    _shelfController.value -= delta / maxH;
  }

  /// 松手吸附：甩动够快按甩动方向，否则吸到离得最近的一端。
  void _onShelfDragEnd(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    final open = velocity.abs() > 350
        ? velocity < 0
        : _shelfController.value >= 0.5;
    if (open) {
      _openShelf();
    } else {
      _closeShelf();
    }
  }

  // ─────────── 右下角悬浮球（与阅读页右下角那颗同款） ───────────

  /// 弧线半径 / 子按钮直径 / 悬浮球直径：与阅读页右下角悬浮球完全一致。
  static const double _fabRadius = 72;
  static const double _fabItemSize = 44;
  static const double _fabToggleSize = 46;

  /// 展开态主球与三个子按钮共用的深灰底（同色才像一组）。
  Color get _fabDeepBg => const Color(0xFF4A4A4A).withValues(alpha: 0.85);

  /// 右下角悬浮球层：铺满整页，按球心摆放主球与沿四分之一圆弧排开的子按钮。
  /// 两页共用这一颗（固定不随翻页滑动，观感如同一层恒定的操作球），
  /// 键位前缀与子按钮动作按当前屏切换：佛号屏「添加」开名号面板、搜索搜佛号；
  /// 密咒屏「添加」开密咒面板、搜索搜密咒。
  ///
  /// 子按钮方向为 0°（正前）/ 45° / 90°（正上）：球在右半屏就朝左展开、
  /// 在下半屏就朝上展开（靠近边缘时自动反向，弧线始终落在屏内）。
  String get _fabPrefix => _pageIdx == 0 ? 'shanzhishi_fab' : 'shanzhishi_mx_fab';

  Widget _buildFabLayer(MediaQueryData mq) {
    const double box =
        _fabRadius + _fabItemSize / 2 + _fabToggleSize / 2 + 4;
    final prefix = _fabPrefix;
    final bool onMantra = _pageIdx != 0;
    return Positioned.fill(
      key: ValueKey('${prefix}_layer'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final Size area = Size(constraints.maxWidth, constraints.maxHeight);
          // 球心：右边缘 16，底部让出菜单栏（含手势条）+ 20。
          final Offset ballCenter = _clampFabCenter(
            Offset(
              area.width - 16 - _fabToggleSize / 2,
              area.height - mq.padding.bottom - 20 - _fabToggleSize / 2,
            ),
            area,
          );
          final double signX = ballCenter.dx > area.width / 2 ? -1 : 1;
          final double signY = ballCenter.dy > area.height / 2 ? -1 : 1;
          final Offset ballInBox = Offset(
            signX < 0 ? box - _fabToggleSize / 2 : _fabToggleSize / 2,
            signY < 0 ? box - _fabToggleSize / 2 : _fabToggleSize / 2,
          );
          final Offset boxTopLeft = ballCenter - ballInBox;
          double dirX(double deg) => signX * cos(deg * pi / 180);
          double dirY(double deg) => signY * sin(deg * pi / 180);
          return Stack(
            children: [
              // 展开时点空白处收起（吞掉点击，避免顺带点到球面上的名号）。
              if (_showFabMenu)
                Positioned.fill(
                  key: ValueKey('${prefix}_overlay'),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeFabMenu,
                  ),
                ),
              Positioned(
                key: ValueKey('${prefix}_menu'),
                left: boxTopLeft.dx,
                top: boxTopLeft.dy,
                child: SizedBox(
                  width: box,
                  height: box,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 添加：佛号屏录入一位佛菩萨（只用一个加号，不再套圈）；
                      // 密咒屏新建一条密咒。
                      _buildFabItem(
                        key: ValueKey('${prefix}_add'),
                        open: _showFabMenu,
                        dirX: dirX(0),
                        dirY: dirY(0),
                        ballInBox: ballInBox,
                        tooltip: '添加',
                        heroTag: '${prefix}_add',
                        onTap: () => _runFabAction(
                            onMantra ? _openMantraAdd : _openAdd),
                        child: const Icon(Icons.add, size: 22),
                      ),
                      // 搜索：佛号屏搜名号，密咒屏搜密咒。
                      _buildFabItem(
                        key: ValueKey('${prefix}_search'),
                        open: _showFabMenu,
                        dirX: dirX(45),
                        dirY: dirY(45),
                        ballInBox: ballInBox,
                        tooltip: '搜索',
                        heroTag: '${prefix}_search',
                        onTap: () =>
                            _runFabAction(onMantra ? _openMxSearch : _openSearch),
                        child: const Icon(Icons.search, size: 20),
                      ),
                      // 切换：直接换到另一屏（两页同一个入口；当前屏与目标跟随 _pageIdx）。
                      _buildFabItem(
                        key: ValueKey('${prefix}_switch'),
                        open: _showFabMenu,
                        dirX: dirX(90),
                        dirY: dirY(90),
                        ballInBox: ballInBox,
                        tooltip: '切换',
                        heroTag: '${prefix}_switch',
                        onTap: () => _runFabAction(() {
                          unawaited(UiSound.instance.playClick());
                          _openSwitch();
                        }),
                        // 用左右双向箭头表示「切换」，与另外两个图标风格一致。
                        child: const Icon(Icons.swap_horiz, size: 22),
                      ),
                      Positioned(
                        left: ballInBox.dx - _fabToggleSize / 2,
                        top: ballInBox.dy - _fabToggleSize / 2,
                        child: _buildFabToggle(prefix: prefix),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 弧线上的单个子按钮：展开时沿弧线方向从主球向外滑出并淡入，收起反向缩回。
  /// [open] 控制是哪一页的悬浮球展开态（佛号页 / 密咒页各自持有开关）。
  Widget _buildFabItem({
    required Key key,
    required bool open,
    required double dirX,
    required double dirY,
    required Offset ballInBox,
    required String tooltip,
    required String heroTag,
    required VoidCallback onTap,
    required Widget child,
  }) {
    // 收起时相对主球圆心的像素位移。
    final Offset hidden = Offset(-dirX * _fabRadius, -dirY * _fabRadius);
    return Positioned(
      key: key,
      left: ballInBox.dx + _fabRadius * dirX - _fabItemSize / 2,
      top: ballInBox.dy + _fabRadius * dirY - _fabItemSize / 2,
      child: IgnorePointer(
        ignoring: !open,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: open ? 1 : 0),
          duration: const Duration(milliseconds: 480),
          curve: const _FabSpringCurve(),
          builder: (context, t, built) {
            // t=0 收回主球圆心；弹簧曲线会令 t 略大于 1（向外多探出一点再归位）。
            return Transform.translate(
              offset: hidden * (1 - t),
              // 淡入放慢到前 70%，与位移的回弹同步，观感更顺滑。
              child: Opacity(
                opacity: (t / 0.7).clamp(0.0, 1.0).toDouble(),
                child: built,
              ),
            );
          },
          child: SizedBox(
            width: _fabItemSize,
            height: _fabItemSize,
            child: _buildFloatingIcon(
              tooltip: tooltip,
              heroTag: heroTag,
              onTap: onTap,
              backgroundColor: _fabDeepBg,
              foregroundColor: Colors.white,
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  /// 圆形悬浮按钮：与阅读页同一套外观（圆形、阴影、图标色可指定）。
  Widget _buildFloatingIcon({
    required Widget child,
    required String tooltip,
    required String heroTag,
    required VoidCallback onTap,
    Color? backgroundColor,
    Color? foregroundColor,
  }) {
    return Tooltip(
      message: tooltip,
      child: FloatingActionButton(
        heroTag: heroTag,
        onPressed: onTap,
        backgroundColor: backgroundColor ?? AppPalette.p.card,
        elevation: 8,
        highlightElevation: 12,
        shape: const CircleBorder(),
        child: IconTheme(
          data: IconThemeData(color: foregroundColor ?? AppPalette.p.text),
          child: child,
        ),
      ),
    );
  }

  /// 主球：收起态是半透明灰底 + 白圈（类 iPhone 悬浮球），
  /// 展开后略微缩小，变成深灰底 + 白叉。
  /// [prefix] 键位前缀：佛号屏 = shanzhishi_fab，密咒屏 = shanzhishi_mx_fab。
  Widget _buildFabToggle({required String prefix}) {
    // 半透明灰底：透过它能看到球面上的佛号，不显突兀。
    final Color collapsedBg = const Color(0xFF9E9E9E).withValues(alpha: 0.30);
    final Color expandedBg = _fabDeepBg;
    return Tooltip(
      message: _showFabMenu ? '收起' : '更多功能',
      // 关闭长按气泡：长按留给球面自转，避免与手势冲突。
      triggerMode: TooltipTriggerMode.manual,
      child: SizedBox(
        width: _fabToggleSize,
        height: _fabToggleSize,
        child: AnimatedScale(
          // 展开后主球略微缩小，三个子按钮比它更大。
          scale: _showFabMenu ? 0.85 : 1.0,
          duration: const Duration(milliseconds: 480),
          curve: Curves.easeOut,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleFabMenu,
            // 用 AnimatedContainer 平滑过渡底色（FAB 无法动画背景色，会「跳闪」）；
            // 不用 InkWell，避免水波纹在透明圆上看起来像闪烁。
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 480),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _showFabMenu ? expandedBg : collapsedBg,
              ),
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, anim) => ScaleTransition(
                    scale: Tween<double>(begin: 0.6, end: 1.0).animate(anim),
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                  child: _showFabMenu
                      ? Icon(
                          Icons.close,
                          key: ValueKey('${prefix}_close'),
                          size: 18,
                          color: Colors.white,
                        )
                      : Container(
                          key: ValueKey('${prefix}_ring'),
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 把球心限制在页面内（贴近边缘时仍留出弧线反向的余地）。
  Offset _clampFabCenter(Offset c, Size area) {
    const double margin = 6;
    final double half = _fabToggleSize / 2;
    final double minX = half + margin;
    final double minY = half + margin;
    final double maxX = area.width - half - margin;
    final double maxY = area.height - half - margin;
    return Offset(
      c.dx.clamp(minX, max(minX, maxX)).toDouble(),
      c.dy.clamp(minY, max(minY, maxY)).toDouble(),
    );
  }

  void _toggleFabMenu() {
    setState(() => _showFabMenu = !_showFabMenu);
  }

  /// 收起悬浮菜单（点空白处 / 执行子按钮时统一调用）。
  void _closeFabMenu() {
    if (!_showFabMenu) return;
    setState(() => _showFabMenu = false);
  }

  /// 执行子按钮动作：先收起悬浮菜单，再执行回调。
  void _runFabAction(VoidCallback action) {
    setState(() => _showFabMenu = false);
    action();
  }

  /// 密咒搜索浮层：搜索框与结果悬浮在密咒页上方（与佛号页同款外观）。
  Widget _buildMxSearchOverlay(PaletteData p, MediaQueryData mq) {
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeMxSearch,
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            top: mq.padding.top + 8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Material(
                  key: const ValueKey('shanzhishi_mx_search_box'),
                  color: p.card,
                  elevation: 6,
                  shadowColor: Colors.black.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(Icons.search, size: 18, color: p.textHint),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('shanzhishi_mx_search_field'),
                          controller: _mxSearchCtrl,
                          autofocus: true,
                          style: TextStyle(fontSize: 15, color: p.text),
                          decoration: InputDecoration(
                            hintText: '搜索密咒',
                            hintStyle:
                                TextStyle(fontSize: 14, color: p.textHint),
                            border: InputBorder.none,
                            isCollapsed: true,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('shanzhishi_mx_search_close'),
                        icon: Icon(Icons.close, size: 18, color: p.textSec),
                        onPressed: _closeMxSearch,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // 结果浮层同佛号搜索：只随查询文本重建，不整页 setState。
                ListenableBuilder(
                  listenable: _mxSearchCtrl,
                  builder: (context, _) {
                    final query = _mxSearchCtrl.text.trim();
                    if (query.isEmpty) return const SizedBox.shrink();
                    return Material(
                      key: const ValueKey('shanzhishi_mx_search_results'),
                      color: p.card,
                      elevation: 6,
                      shadowColor: Colors.black.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(maxHeight: mq.size.height * 0.4),
                        child: _mxSearchHits.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 14),
                                child: Text(
                                  '没有找到「$query」',
                                  style: TextStyle(
                                      fontSize: 13.5, color: p.textSec),
                                ),
                              )
                            : Builder(builder: (context) {
                                final hits = _mxSearchHits;
                                return ListView.builder(
                                  shrinkWrap: true,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 4),
                                  itemCount: hits.length,
                                  itemBuilder: (_, i) {
                                    final mantra = hits[i];
                                    return InkWell(
                                      onTap: () => _onMxSearchHit(mantra),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 13),
                                        child: Text(
                                          mantra,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 15,
                                            color: p.text,
                                            letterSpacing: 0.8,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                );
                              }),
                        ),
                      );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────── 视图 ───────────────

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final names = [for (final e in _store.entries) e.name];
    return Scaffold(
      backgroundColor: p.bg,
      // 键盘悬浮在页面之上：弹输入法时整页布局不动，搜索框与球面不被顶起。
      resizeToAvoidBottomInset: false,
      // 不设 AppBar：球面名号铺到页面最顶端，顶部不再有一条被切割的感觉。
      body: Builder(builder: (context) {
        final entry = () {
          final idx = _selected;
          if (idx == null || !_store.loaded) return null;
          return (idx >= 0 && idx < _store.length) ? _store[idx] : null;
        }();
        final mq = MediaQuery.of(context);
        // 两屏（第 1 页佛号星图、第 2 页密咒竖排）常驻同一棵树，不做左右滑动切换，
        // 只由悬浮球的「切换」子按钮点选互换；切页没有过场动画。
        // 右下角悬浮球两页共用一颗、固定在屏幕上不随切页移动，
        // 搜索浮层也提到两屏之外（搜索开着时悬浮球必须压在它下面）。
        final bool showFab = _selected == null && !_shelfExpanded;
        return Stack(
          children: [
            IndexedStack(
              index: _pageIdx,
              sizing: StackFit.expand,
              children: [
                Stack(
                  children: [
                    // 球体铺满整页：顶部只让出状态栏本身，球的上边界到状态栏下沿，
                    // 与底部（球顶点探进底部菜单栏之下）留出一致的观感。
                    Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.only(top: mq.padding.top),
                        child: ShanZhiShiSphere(
                          names: names,
                          controller: _sphereCtrl,
                          initialIndex: _store.lastTappedIndex,
                          spinEnabled: _isActive,
                          verticalOnly: true,
                          onNameTapped: _onNameTapped,
                          // 转动落定不再配音：随球自转/磁吸落定会不定期冒
                          // 声，像气泡音；点选等主动操作的提示音保留。

                        ),
                      ),
                    ),
                    // 原右上角的「添加 / 搜索」已移入右下角悬浮球的子按钮。
                    if (!_store.loaded)
                      Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.4, color: p.textHint),
                        ),
                      )
                    else if (names.isEmpty) _buildEmptySphere(p),
                    if (entry != null) _buildShelf(p, entry),
                  ],
                ),
                // 密咒竖排展示面（含星云底光）；本页没有自己的悬浮球——
                // 悬浮球两页共用，固定在两屏之上。
                ShanZhiShiMantraView(key: _mxPageKey),
              ],
            ),
            // 右下角悬浮球（与阅读页右下角那颗同款）：底部面板展开时让位，
            // 避免压住面板右下角的「编辑」。
            if (showFab) _buildFabLayer(mq),
            // 佛号搜索浮层：压在悬浮球之上，搜索框与结果悬浮在本页。
            if (_searchOpen) _buildSearchOverlay(p, mq),
            // 密咒搜索浮层：同上，压在最上层。
            if (_mxSearchOpen) _buildMxSearchOverlay(p, mq),
          ],
        );
      }),
    );
  }

  Widget _buildEmptySphere(PaletteData p) {
    return IgnorePointer(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 90),
            Text(
              '球面还没有名号',
              style: TextStyle(fontSize: 14, color: p.textSec, letterSpacing: 1),
            ),
            const SizedBox(height: 6),
            Text(
              '点右下角悬浮球添加第一位佛菩萨',
              style: TextStyle(fontSize: 12, color: p.textHint),
            ),
          ],
        ),
      ),
    );
  }

  /// 搜索浮层：搜索框与结果都悬浮在本页上方（不跳新页面、不挤动星图）。
  Widget _buildSearchOverlay(PaletteData p, MediaQueryData mq) {
    return Positioned.fill(
      child: Stack(
        children: [
          // 点空白处收起（吞掉点击，避免顺带点到球面名号）。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeSearch,
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            top: mq.padding.top + 8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 搜索框。
                Material(
                  key: const ValueKey('shanzhishi_search_box'),
                  color: p.card,
                  elevation: 6,
                  shadowColor: Colors.black.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(Icons.search, size: 18, color: p.textHint),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('shanzhishi_search_field'),
                          controller: _searchCtrl,
                          autofocus: true,
                          style: TextStyle(fontSize: 15, color: p.text),
                          decoration: InputDecoration(
                            hintText: '搜索名号',
                            hintStyle:
                                TextStyle(fontSize: 14, color: p.textHint),
                            border: InputBorder.none,
                            isCollapsed: true,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('shanzhishi_search_close'),
                        icon: Icon(Icons.close, size: 18, color: p.textSec),
                        onPressed: _closeSearch,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // 结果浮层：输入关键字后才出现。只随查询文本变化重建，
                // 不整页 setState —— 球面不动，键盘也不因重负载弹不出来。
                ListenableBuilder(
                  listenable: _searchCtrl,
                  builder: (context, _) {
                    final query = _searchCtrl.text.trim();
                    if (query.isEmpty) return const SizedBox.shrink();
                    return Material(
                      key: const ValueKey('shanzhishi_search_results'),
                      color: p.card,
                      elevation: 6,
                      shadowColor: Colors.black.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(maxHeight: mq.size.height * 0.4),
                        child: _searchHits.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 14),
                                child: Text(
                                  '没有找到「$query」',
                                  style: TextStyle(
                                      fontSize: 13.5, color: p.textSec),
                                ),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                itemCount: _searchHits.length,
                                itemBuilder: (_, i) {
                                  final idx = _searchHits[i];
                                  final e = _store[idx]!;
                                  return InkWell(
                                    onTap: () => _onSearchHit(idx),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 13),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              e.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 15,
                                                color: p.text,
                                                letterSpacing: 0.8,
                                              ),
                                            ),
                                          ),
                                          if (e.sutras.isNotEmpty)
                                            Text(
                                              '${e.sutras.length} 部经文',
                                              style: TextStyle(
                                                  fontSize: 11.5,
                                                  color: p.textHint),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 底部上拉面板（与经藏页「全部经典」同款）：
  /// 折叠态是贴在屏幕下沿的一条 header（名号 + N部经），
  /// 上拖/单击展开后铺开该名号的关联经文与经文卡片。
  Widget _buildShelf(PaletteData p, ShanyishiEntry entry) {
    final mq = MediaQuery.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: mq.padding.bottom,
      child: AnimatedBuilder(
        animation: _shelfController,
        builder: (context, _) {
          final open = _shelfController.value;
          final contentH = _shelfContentMaxHeight() * open;
          // 收起时整块滑出屏幕下沿（连手势条一起让开），完全不残留。
          final slide = (1 - open) *
              (_shelfHeaderH + _shelfOpenTopExtra + mq.padding.bottom);
          return Transform.translate(
            offset: Offset(0, slide),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  clipBehavior: Clip.antiAlias,
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(_shelfTopRadius)),
                  child: Container(
                    key: const ValueKey('shanzhishi-shelf-panel'),
                    color: p.card,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildShelfHeader(p, entry),
                        if (contentH > 0)
                          SizedBox(
                            height: contentH,
                            child: _buildShelfContent(p, entry),
                          ),
                      ],
                    ),
                  ),
                ),
                // 上边界阴影：只画在面板之外，不压暗面板底色。
                Positioned(
                  left: 0,
                  right: 0,
                  top: -_shelfShadowReach,
                  height: _shelfShadowReach + _shelfTopRadius + 6,
                  child: _TopEdgeShadow(
                    radius: _shelfTopRadius,
                    reach: _shelfShadowReach,
                    blur: 2.5,
                    color: Colors.black.withValues(alpha: 0.1),
                  ),
                ),
                // 上边界细线：沿左右圆角连续描边。
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _ShelfTopBorderPainter(
                        radius: _shelfTopRadius,
                        color: p.borderSoft,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 面板 header：横杠 + 竖杠 + 名号。单击收起、上下拖擦洗开合。
  ///
  /// 竖杠与下方内容左边界（[_shelfSidePad]）对齐成同一条线；
  /// 名号字号比下面的正文大两号。
  Widget _buildShelfHeader(PaletteData p, ShanyishiEntry entry) {
    final openExtra = _shelfOpenTopExtra * _shelfController.value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _closeShelf,
      onVerticalDragUpdate: _onShelfDragUpdate,
      onVerticalDragEnd: _onShelfDragEnd,
      child: SizedBox(
        height: _shelfHeaderH + openExtra,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              _shelfSidePad, 8 + openExtra, _shelfSidePad, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: p.textHint,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  // 竖杠：与下方内容左对齐。
                  Container(
                    key: const ValueKey('shanzhishi_name_bar'),
                    width: 3,
                    height: 18,
                    decoration: BoxDecoration(
                      color: p.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.left,
                      style: TextStyle(
                        color: p.primary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 面板内容：关联经文（竖向一行一部，右侧箭头，点进阅读页）
  /// + 人天利益（一段一块，每段顶部带「人天利益」标志）。
  /// 右下角固定「编辑」按钮；「恢复」只在编辑保存过且还有快照时出现。
  Widget _buildShelfContent(PaletteData p, ShanyishiEntry entry) {
    return Stack(
      children: [
        Positioned.fill(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                _shelfSidePad, 10, _shelfSidePad, 88),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: _labelChip(p, '关联经文'),
              ),
              const SizedBox(height: 6),
              if (entry.sutras.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    '尚未记录关联经文',
                    style: TextStyle(fontSize: 12.5, color: p.textHint),
                  ),
                )
              else
                for (final s in entry.sutras) _sutraLinkRow(p, s),
              const SizedBox(height: 6),
              Container(height: 1, color: p.divider),
              const SizedBox(height: 12),
              // 人天利益：段与段之间不加分割线。
              for (final t in entry.paragraphs) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: _labelChip(p, '人天利益'),
                ),
                const SizedBox(height: 6),
                Text(
                  t,
                  style: TextStyle(
                    fontSize: 14,
                    color: p.text,
                    height: 1.8,
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
        Positioned(
          right: _shelfSidePad,
          bottom: 16,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 恢复：仅在本 session 内「编辑 → 保存」过、且还有快照时出现。
              if (_store.canRestore(entry) &&
                  _editedInSession.contains(entry.createdAt)) ...[
                _PanelActionButton(
                  key: const ValueKey('shanzhishi_restore'),
                  palette: p,
                  icon: Icons.restore,
                  label: '恢复',
                  primary: false,
                  onTap: _restoreEntry,
                ),
                const SizedBox(width: 8),
              ],
              _PanelActionButton(
                palette: p,
                icon: Icons.edit_outlined,
                label: '编辑',
                onTap: () => _editEntry(entry),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 一部关联经文：一行一名，右侧箭头，点进阅读页。
  Widget _sutraLinkRow(PaletteData p, String sutra) {
    return InkWell(
      key: ValueKey('shanzhishi_sutra_row_$sutra'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => _openSutraReading(sutra),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                sutra,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: p.text,
                  height: 1.5,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: p.textHint),
          ],
        ),
      ),
    );
  }

  /// 彩色标签胶囊：「名号」「关联经文」等小标签。
  Widget _labelChip(PaletteData p, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: p.tintBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: p.accentDeep,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// 面板右下角的胶囊按钮（编辑 / 恢复）：主按钮实底，次按钮描边。
class _PanelActionButton extends StatelessWidget {
  final PaletteData palette;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// true = 主按钮（实底），false = 次按钮（描边卡片底）。
  final bool primary;

  const _PanelActionButton({
    super.key,
    required this.palette,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final Color bg = primary ? p.primary : p.card;
    final Color fg = primary ? p.card : p.accentDeep;
    return Material(
      color: bg,
      elevation: primary ? 3 : 0,
      shadowColor: Colors.black.withValues(alpha: 0.22),
      shape: StadiumBorder(
        side: primary ? BorderSide.none : BorderSide(color: p.borderSoft),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fg,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 面板顶边阴影：只画在面板之外，不压暗面板底色（与经藏页上拉面板同款）。
class _TopEdgeShadow extends StatelessWidget {
  const _TopEdgeShadow({
    required this.radius,
    required this.reach,
    required this.blur,
    required this.color,
  });

  final double radius;
  final double reach;
  final double blur;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _TopEdgeShadowPainter(
          radius: radius,
          reach: reach,
          blur: blur,
          color: color,
        ),
      ),
    );
  }
}

class _TopEdgeShadowPainter extends CustomPainter {
  const _TopEdgeShadowPainter({
    required this.radius,
    required this.reach,
    required this.blur,
    required this.color,
  });

  final double radius;
  final double reach;
  final double blur;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 面板顶边位于 y = reach；左右圆角落在 [reach, reach + radius]，层高需覆盖到那里。
    final top = reach;
    final r = radius;
    final w = size.width;
    if (w <= r * 2 || size.height <= top + r) return;

    // 沿面板顶边描一条与轮廓完全重合的路径：直线 + 左右圆角。
    final edge = Path()
      ..moveTo(0, top + r)
      ..arcTo(
        Rect.fromCircle(center: Offset(r, top + r), radius: r),
        pi,
        pi / 2,
        false,
      )
      ..lineTo(w - r, top)
      ..arcTo(
        Rect.fromCircle(center: Offset(w - r, top + r), radius: r),
        3 * pi / 2,
        pi / 2,
        false,
      );

    // 面板本体：裁掉内侧，阴影只留在轮廓之外。
    final panel = Path()
      ..addRRect(RRect.fromRectAndCorners(
        Rect.fromLTWH(0, top, w, size.height - top),
        topLeft: Radius.circular(r),
        topRight: Radius.circular(r),
      ));
    final all = Path()
      ..addRect(Rect.fromLTWH(
        -w,
        -size.height,
        w * 3,
        size.height * 3,
      ));
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, w, top + r));
    canvas.clipPath(Path.combine(PathOperation.difference, all, panel));
    canvas.drawPath(
      edge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = reach / 4
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TopEdgeShadowPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.reach != reach ||
      oldDelegate.blur != blur ||
      oldDelegate.color != color;
}

/// 面板顶边细线：从左边往上、沿左圆角、横过顶边、再沿右圆角往下收尾，
/// 一整条连续描边（BoxDecoration.border 圆角段会被 ClipRRect 裁掉）。
class _ShelfTopBorderPainter extends CustomPainter {
  const _ShelfTopBorderPainter({
    required this.radius,
    required this.color,
  });

  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = radius;
    final w = size.width;
    if (w <= r * 2 || size.height <= r) return;
    final path = Path()
      ..moveTo(0, r)
      ..arcTo(
          Rect.fromCircle(center: Offset(r, r), radius: r), pi, pi / 2, false)
      ..lineTo(w - r, 0)
      ..arcTo(
        Rect.fromCircle(center: Offset(w - r, r), radius: r),
        3 * pi / 2,
        pi / 2,
        false,
      );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_ShelfTopBorderPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.color != color;
}

/// 悬浮球子按钮展开/收起的阻尼弹簧曲线：与阅读页右下角悬浮球同一实现，
/// 起步缓慢、向外展开后单次轻微过冲，再缓慢归位（类 iPhone 悬浮球）。
class _FabSpringCurve extends Curve {
  const _FabSpringCurve();

  @override
  double transformInternal(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    const double w = 4.0; // 振荡角频率（越小越慢）
    const double d = 3.2; // 阻尼系数（越小回弹越明显）
    double f = 1 - exp(-d * t) * (cos(w * t) + (d / w) * sin(w * t));
    // 末段平滑归一到 1，避免收尾出现跳变。
    if (t > 0.8) {
      final double k = (t - 0.8) / 0.2;
      f = f + (1 - f) * k;
    }
    return f;
  }
}
