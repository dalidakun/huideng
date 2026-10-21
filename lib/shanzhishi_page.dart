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
    with TickerProviderStateMixin {
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

  // ── 搜索（悬浮在本页，不跳新页面） ──
  bool _searchOpen = false;
  final TextEditingController _searchCtrl = TextEditingController();

  // ── 底部上拉面板（与经藏页「全部经典」同款） ──
  static const double _shelfHeaderH = 50;

  /// 密咒详情 header：名称与顶部横杠之间多留空，比佛号 header 高一截。
  static const double _mxHeaderH = 56;
  static const double _shelfOpenTopExtra = 12;
  static const double _shelfTopRadius = 16;
  static const double _shelfShadowReach = 14;

  /// 面板左右内边距：header 的名号与内容区共用，保证左对齐在同一条竖线上。
  static const double _shelfSidePad = 20;

  /// 展开后整块面板占可用高度的比例（与添加善知识面板一样大，接近满屏）。
  static const double _shelfOpenFraction = 0.9;

  bool _shelfExpanded = false;
  late final AnimationController _shelfController;

  // ── 密咒详情面板：与佛号上拉面板同一套抽屉（同样上滑动画、圆角、阴影、
  // 底色 p.card），只是占屏更高（铺到状态栏下沿）。 ──
  static const double _mxShelfOpenFraction = 0.95;

  /// 当前打开的密咒名；null = 面板不显示。
  String? _mxDetailName;

  /// 当前打开的密咒内部键（同名条目靠它区分详情与编辑目标）。
  String? _mxDetailKey;

  /// 详情页是否显示注音（右下角图标开关，默认显示）。切换不影响已存数据。
  bool _mxShowRuby = true;
  bool _mxShowNotes = true;

  /// 密咒原文的选区监听：长按选中文字后取精确的 start/end 偏移，
  /// 供「注音 / 备注」直接对选中片段编辑。
  final SelectionListenerNotifier _mxSelectionNotifier =
      SelectionListenerNotifier();

  /// 咒文列表滚动控制器：展开备注时滚到备注块，长咒文也能立刻看到备注。
  final ScrollController _mxListController = ScrollController();

  /// 密咒面板是否处于展开态（收起动画播完才回到 false，动画中重开不卸载）。
  bool _mxShelfExpanded = false;

  late final AnimationController _mxShelfController;

  // ── 密咒详情第三层抽屉：从神咒面板内再上滑一层，比神咒面板矮一截，
  // 用来放「关联经文 + 人天利益」（阅读）或「对咒文的备注」（备注）。 ──

  /// 第三层抽屉占可用高度的比例（比神咒面板的 95% 矮一些）。
  static const double _mxDrawerOpenFraction = 0.62;

  /// 第三层抽屉 header 高度。
  static const double _mxDrawerHeaderH = 52;

  /// 第三层抽屉当前内容：null = 收起；'reading' = 关联经文 + 人天利益。
  String? _mxDrawerMode;

  bool _mxDrawerExpanded = false;

  late final AnimationController _mxDrawerController;

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
    _mxShelfController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _mxDrawerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _store.addListener(_onStoreChanged);
    _mxStore.addListener(_onMxStoreChanged);
    widget.activeTab?.addListener(_onTabChanged);
    unawaited(_store.load());
    unawaited(_mxStore.load());
    unawaited(NoteSutraCatalog.load());
  }

  /// 云端数据恢复后重读两套 store，并按名号恢复当前选中项，
  /// 避免页面继续展示同步前写入的本地种子。
  Future<void> reload() async {
    final selected = _selected;
    final selectedName =
        selected != null && selected >= 0 && selected < _store.length
            ? _store.entries[selected].name
            : null;
    final mxDetailName = _mxDetailName;
    await Future.wait([_store.reload(), _mxStore.reload()]);
    if (!mounted) return;
    int? nextSelected;
    if (selectedName != null) {
      final idx = _store.entries.indexWhere((e) => e.name == selectedName);
      if (idx >= 0) nextSelected = idx;
    }
    setState(() {
      _selected = nextSelected;
      if (mxDetailName != null && !_mxStore.mantras.contains(mxDetailName)) {
        _mxDetailName = null;
        _mxDetailKey = null;
      }
    });
    final target = nextSelected;
    if (target != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sphereCtrl.animateToIndex(target);
      });
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    _mxStore.removeListener(_onMxStoreChanged);
    widget.activeTab?.removeListener(_onTabChanged);
    _shelfController.dispose();
    _mxShelfController.dispose();
    _mxDrawerController.dispose();
    _mxSelectionNotifier.dispose();
    _mxListController.dispose();
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
      // 切回佛号屏时密咒详情还开着：收起它（面板留在密咒屏里也看不见，
      // 但它的展开态会一直压着两屏共用的悬浮球）。
      if (logical != 1 && _mxDetailName != null) _closeMxShelf();
    });
  }

  // ─────────────── 密咒页的动作 ───────────────

  /// 打开密咒搜索浮层（搜的是密咒名，不搜佛号）。
  void _openMxSearch() {
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
    _closeMxSearch();
    _mxPageKey.currentState?.revealMantra(mantra);
  }

  /// 新建密咒：上拉面板取名，保存进密咒库（重名面板内提示）。
  Future<void> _openMantraAdd() async {
    await ShanZhiShiMantraEditSheet.show(context);
  }

  /// 点某条密咒：在本页底部拉出详情抽屉，查看经文出处、神咒原文与人天利益。
  /// 抽屉与点佛号弹出的面板同款（上滑动画、圆角、阴影、同底色）。
  /// 详情里的经文出处与佛号页一样，点一下进入阅读。
  /// [key] 是密咒的内部键（同名条目也能各看各的）。
  void _openMantraDetail(String key) {
    final name = _mxStore.nameOfKey(key) ?? '';
    setState(() {
      _mxDetailKey = key;
      _mxDetailName = name;
      _mxShelfExpanded = true;
      // 每次打开默认显示注音；有备注时备注块也直接展开，点「备注」可收起。
      _mxShowRuby = true;
      _mxShowNotes = true;
      // 第三层抽屉默认收起。
      _mxDrawerMode = null;
      _mxDrawerExpanded = false;
      _mxDrawerController.value = 0;
      // 面板占了右下角：悬浮球先收起，免得压住面板。
      _showFabMenu = false;
    });
    _mxShelfController.forward();
  }

  /// 点密咒面板 header 收起：整块滑出屏幕下沿后卸载（动画中重开则不卸载）。
  void _closeMxShelf() {
    _mxShelfExpanded = false;
    _mxDrawerExpanded = false;
    _mxDrawerController.value = 0;
    _mxShelfController.reverse().whenComplete(() {
      if (!_mxShelfExpanded && mounted) {
        setState(() {
          _mxDetailName = null;
          _mxDetailKey = null;
          _mxDrawerMode = null;
        });
      }
    });
  }

  /// 打开第三层抽屉：[mode] 目前只有 'reading'（关联经文 + 人天利益）。
  /// 已在同一 mode 且展开时再点则收起。
  void _openMxDrawer(String mode) {
    final closing = _mxDrawerMode == mode && _mxDrawerExpanded;
    setState(() {
      if (closing) {
        _mxDrawerExpanded = false;
      } else {
        _mxDrawerMode = mode;
        _mxDrawerExpanded = true;
      }
    });
    if (closing) {
      _mxDrawerController.reverse().whenComplete(() {
        if (!_mxDrawerExpanded && mounted) {
          setState(() => _mxDrawerMode = null);
        }
      });
    } else {
      _mxDrawerController.forward();
    }
  }

  /// 收起第三层抽屉（保留 mode，动画完再清，避免内容中途变空）。
  void _closeMxDrawer() {
    _mxDrawerExpanded = false;
    _mxDrawerController.reverse().whenComplete(() {
      if (!_mxDrawerExpanded && mounted) {
        setState(() => _mxDrawerMode = null);
      }
    });
  }

  /// 展开/收起咒文备注。展开时等新布局完成再滚到列表底部，
  /// 长咒文里备注块在正文下方，不滚动的话只能看到下划线。
  void _toggleMxNotes() {
    final show = !_mxShowNotes;
    setState(() => _mxShowNotes = show);
    if (show) _scrollToMxNotes();
  }

  /// 等备注块完成布局后，把咒文列表滚到最底部，让备注信息进入视口。
  void _scrollToMxNotes() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_mxListController.hasClients) return;
      _mxListController.animateTo(
        _mxListController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// 密咒面板内容区（不含 header）的最大高度：整块面板占可用高度的 95%，
  /// 比佛号面板（90%）再大一圈，几乎铺到状态栏下沿。
  double _mxShelfContentMaxHeight() {
    final mq = MediaQuery.of(context);
    final available = mq.size.height - mq.padding.top - mq.padding.bottom;
    return max(
      0.0,
      available * _mxShelfOpenFraction - _mxHeaderH - _shelfOpenTopExtra,
    );
  }

  /// 第三层抽屉内容区高度：占可用高度的 [_mxDrawerOpenFraction]。
  double _mxDrawerMaxContentHeight() {
    final mq = MediaQuery.of(context);
    final available = mq.size.height - mq.padding.top - mq.padding.bottom;
    return max(0.0, available * _mxDrawerOpenFraction - _mxDrawerHeaderH);
  }

  /// 纵向拖 header 时按手指位移实时擦洗展开比例（向下拖收起，向上拖展开）。
  void _onMxShelfDragUpdate(DragUpdateDetails d) {
    final maxH = _mxShelfContentMaxHeight();
    final delta = d.primaryDelta ?? 0;
    if (maxH <= 0 || delta == 0) return;
    _mxShelfController.value -= delta / maxH;
  }

  /// 松手吸附：甩动够快按甩动方向，否则吸到离得最近的一端。
  void _onMxShelfDragEnd(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    final open =
        velocity.abs() > 350 ? velocity < 0 : _mxShelfController.value >= 0.5;
    if (open) {
      _mxShelfExpanded = true;
      _mxShelfController.forward();
    } else {
      _closeMxShelf();
    }
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
    _closeSearch();
    _rememberLastTapped(idx);
    _sphereCtrl.animateToIndex(idx);
  }

  Future<void> _openAdd() async {
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
    final saved = await ShanZhiShiEditSheet.show(
      context,
      index: index,
      entry: entry,
    );
    if (!mounted) return;
    if (saved == null) return;
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
    // 出处常写成「《经名》」，解析前去掉书名号，免得目录精确/包含匹配失败。
    final title = sutra.replaceAll(RegExp(r'[《》〈〉]'), '').trim();
    var link = ShanZhiShiStore.resolveSutra(title);
    if (link == null) {
      // 目录可能还没加载完：等它一次再解析。
      try {
        await NoteSutraCatalog.load();
      } catch (_) {
        // 目录读取失败就按「找不到」处理。
      }
      link = ShanZhiShiStore.resolveSutra(title);
    }
    if (!mounted) return;
    final resolved = link;
    if (resolved == null || resolved.filePath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('经藏里没有找到「$title」', style: const TextStyle(fontSize: 13)),
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
    // 密咒详情面板还开着：先收起它。
    if (_mxDetailName != null) {
      _closeMxShelf();
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
    final open =
        velocity.abs() > 350 ? velocity < 0 : _shelfController.value >= 0.5;
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
  String get _fabPrefix =>
      _pageIdx == 0 ? 'shanzhishi_fab' : 'shanzhishi_mx_fab';

  Widget _buildFabLayer(MediaQueryData mq) {
    const double box = _fabRadius + _fabItemSize / 2 + _fabToggleSize / 2 + 4;
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
                        onTap: () =>
                            _runFabAction(onMantra ? _openMantraAdd : _openAdd),
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
                        onTap: () => _runFabAction(
                            onMantra ? _openMxSearch : _openSearch),
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
        final bool showFab =
            _selected == null && !_shelfExpanded && _mxDetailName == null;
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
                    else if (names.isEmpty)
                      _buildEmptySphere(p),
                    if (entry != null) _buildShelf(p, entry),
                  ],
                ),
                // 密咒竖排展示面（含星云底光）；本页没有自己的悬浮球——
                // 悬浮球两页共用，固定在两屏之上。详情面板与佛号屏一样
                // 贴在本屏的 Stack 里（上滑抽屉，不遮状态栏以外的地方）。
                Stack(
                  children: [
                    ShanZhiShiMantraView(
                      key: _mxPageKey,
                      onMantraTapped: _openMantraDetail,
                    ),
                    if (_mxDetailName != null) _buildMxShelf(p),
                  ],
                ),
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
              style:
                  TextStyle(fontSize: 14, color: p.textSec, letterSpacing: 1),
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
                        fontSize: 18,
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
  /// 右下角固定「编辑」按钮。
  Widget _buildShelfContent(PaletteData p, ShanyishiEntry entry) {
    return Stack(
      children: [
        Positioned.fill(
          child: ListView(
            padding:
                const EdgeInsets.fromLTRB(_shelfSidePad, 10, _shelfSidePad, 88),
            children: [
              if (entry.sutras.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    '尚未记录经文',
                    style: TextStyle(fontSize: 12.5, color: p.textHint),
                  ),
                )
              else
                // 一部经一行（经名包成胶囊）；这一部经的人天利益就接在它下面，
                // 「人天利益」标志贴着段落开头，经文与段落一一对应。
                // 从第二部经起与上一部经的最后一段拉开距离：不然两部经的
                // 内容连成一片，看不出下面已经是另一部经了。
                for (var i = 0; i < entry.sutras.length; i++) ...[
                  if (i > 0) const SizedBox(height: 18),
                  _sutraLinkRow(p, entry.sutras[i]),
                  for (final t
                      in entry.quotes[entry.sutras[i]] ?? const <String>[])
                    _paragraphBlock(p, t),
                ],
              if (_looseParagraphs(entry).isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(height: 1, color: p.divider),
                const SizedBox(height: 12),
                // 没挂到任何经文下的人天利益（旧数据）：仍平铺在下面。
                for (final t in _looseParagraphs(entry)) _paragraphBlock(p, t),
              ],
            ],
          ),
        ),
        Positioned(
          right: _shelfSidePad,
          bottom: 16,
          child: _PanelEditButton(
            palette: p,
            onTap: () => _editEntry(entry),
          ),
        ),
      ],
    );
  }

  /// 密咒详情抽屉：与佛号上拉面板同款结构（上滑动画、顶部圆角、外侧阴影、
  /// 同一底色 p.card），只是占屏更高（95%）。
  Widget _buildMxShelf(PaletteData p) {
    final mq = MediaQuery.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: mq.padding.bottom,
      child: AnimatedBuilder(
        animation: _mxShelfController,
        builder: (context, _) {
          final open = _mxShelfController.value;
          final contentH = _mxShelfContentMaxHeight() * open;
          // 收起时整块滑出屏幕下沿（连手势条一起让开），完全不残留。
          final slide = (1 - open) *
              (_mxHeaderH + _shelfOpenTopExtra + mq.padding.bottom);
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
                    key: const ValueKey('shanzhishi_mx_shelf_panel'),
                    color: p.card,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildMxShelfHeader(p),
                        if (contentH > 0)
                          SizedBox(
                            height: contentH,
                            child: _buildMxShelfContent(p),
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

  /// 密咒详情 header：横杠 + 居中名称。单击收起、上下拖擦洗开合。
  Widget _buildMxShelfHeader(PaletteData p) {
    final openExtra = _shelfOpenTopExtra * _mxShelfController.value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _closeMxShelf,
      onVerticalDragUpdate: _onMxShelfDragUpdate,
      onVerticalDragEnd: _onMxShelfDragEnd,
      child: SizedBox(
        height: _mxHeaderH + openExtra,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              _shelfSidePad, 8 + openExtra, _shelfSidePad, 0),
          child: Column(
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
              // 与横杠留出空隙，名称不贴着杠。
              const SizedBox(height: 14),
              Text(
                _mxDetailName ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.primary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 密咒详情内容：整页只剩顶部插图 + 神咒原文（居左，注音标在字上）。
  /// 关联经文 / 人天利益收进第三层抽屉；咒文备注点右下角图标后在咒文下方
  /// 内联展开。右下角竖排四个图标按钮（注音 / 备注 / 阅读 / 编辑）。
  Widget _buildMxShelfContent(PaletteData p) {
    final key = _mxDetailKey;
    final text = _mxStore.textOfKey(key);
    final annotations = _mxStore.annotationsOfKey(key);
    final hasRuby = annotations.any((a) => a.hasRuby);
    final hasNotes = annotations.any((a) => a.hasNote);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Column(
            children: [
              // 神咒名字与咒文之间的居中插图（半透明，钉在顶部，不随正文滚动）。
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 26),
                child: Opacity(
                  opacity: 0.55,
                  child: Image.asset(
                    'assets/images/shen.png',
                    width: 210,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  key: const ValueKey('shanzhishi_mx_list'),
                  controller: _mxListController,
                  padding: EdgeInsets.fromLTRB(
                      _shelfSidePad, 0, _shelfSidePad + 52, 88),
                  children: [
                    // 首行注音画在行框上方的空隙里（Stack 用 Clip.none 溢出绘制），
                    // 但第一行行框紧贴文本顶，注音会被边缘裁掉，
                    // 文本上方先补一段留白把首行注音让出来。
                    // 留白只跟「有没有注音」有关，不跟开关走：开关注音时高度不变，
                    // 正文不会上下跳，只是注音出现或消失。
                    SizedBox(height: hasRuby ? 14 : 0),
                    if (text.isEmpty)
                      Text(
                        '尚未填写神咒原文',
                        textAlign: TextAlign.left,
                        style: TextStyle(fontSize: 15, color: p.textHint),
                      )
                    else
                      SelectionArea(
                        contextMenuBuilder: (context, state) =>
                            _buildMxSelectionToolbar(state, text),
                        child: SelectionListener(
                          selectionNotifier: _mxSelectionNotifier,
                          child: annotations.isEmpty
                              ? Text(
                                  text,
                                  textAlign: TextAlign.left,
                                  style: TextStyle(
                                    fontSize: 16,
                                    height: 2.3,
                                    color: p.text,
                                    letterSpacing: 0.5,
                                  ),
                                )
                              : Text.rich(
                                  _buildAnnotatedMantraSpan(
                                    p,
                                    text,
                                    annotations,
                                    showRuby: _mxShowRuby,
                                  ),
                                  textAlign: TextAlign.left,
                                ),
                        ),
                      ),
                    // 备注不再走第三层抽屉：点「备注」直接在咒文下方展开，
                    // 被备注的文字始终带下划线，方便回看时找到位置。
                    if (_mxShowNotes && hasNotes)
                      _buildMantraNotesBlock(p, text, annotations),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 第三层抽屉：从神咒面板内再上滑一层，比神咒面板矮，压住咒文。
        if (_mxDrawerMode != null) _buildMxDrawer(p),
        // 整页只剩咒文与按钮：右下角竖排四个图标（注音 / 备注 / 阅读 / 编辑）。
        // 放在抽屉之后：抽屉展开时按钮仍浮在最上层，可再点一次收起。
        Positioned(
          right: _shelfSidePad,
          bottom: 16,
          child: _MxActionColumn(
            palette: p,
            showRuby: _mxShowRuby,
            showNotes: _mxShowNotes,
            hasNotes: hasNotes,
            onRuby: () => setState(() => _mxShowRuby = !_mxShowRuby),
            onNotes: _toggleMxNotes,
            onReading: () => _openMxDrawer('reading'),
            onEdit: _editMantra,
          ),
        ),
      ],
    );
  }

  /// 密咒原文的选区工具栏：去掉系统默认的「分享」，补上「注音」「备注」，
  /// 复制 / 全选保持系统行为，顺序为 复制、注音、备注、全选。
  Widget _buildMxSelectionToolbar(SelectableRegionState state, String text) {
    final custom = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: '注音',
        onPressed: () {
          final range = _mxSelectedRange(text.length);
          state.hideToolbar();
          if (range != null) {
            unawaited(_editMxSelectionAnnotation(
              start: range.$1,
              end: range.$2,
              ruby: true,
            ));
          }
        },
      ),
      ContextMenuButtonItem(
        label: '备注',
        onPressed: () {
          final range = _mxSelectedRange(text.length);
          state.hideToolbar();
          if (range != null) {
            unawaited(_editMxSelectionAnnotation(
              start: range.$1,
              end: range.$2,
              ruby: false,
            ));
          }
        },
      ),
    ];
    final items = <ContextMenuButtonItem>[];
    var inserted = false;
    for (final item in state.contextMenuButtonItems) {
      if (item.type == ContextMenuButtonType.share) continue;
      if (item.type == ContextMenuButtonType.selectAll) {
        if (!inserted) {
          items.addAll(custom);
          inserted = true;
        }
        items.add(item);
      } else {
        items.add(item);
      }
    }
    if (!inserted) items.addAll(custom);
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }

  /// 当前选区在咒文里的偏移；无效或已收起时返回 null。
  (int, int)? _mxSelectedRange(int textLength) {
    if (!_mxSelectionNotifier.registered || textLength == 0) return null;
    final range = _mxSelectionNotifier.selection.range;
    if (range == null) return null;
    final start = range.startOffset.clamp(0, textLength);
    final end = range.endOffset.clamp(0, textLength);
    if (end <= start) return null;
    return (start, end);
  }

  /// 对选中的咒文片段直接编辑注音或备注，不必再进整页编辑。
  Future<void> _editMxSelectionAnnotation({
    required int start,
    required int end,
    required bool ruby,
  }) async {
    final key = _mxDetailKey;
    final text = _mxStore.textOfKey(key);
    final cs = start.clamp(0, text.length);
    final ce = end.clamp(0, text.length);
    if (ce <= cs) return;
    final annotations = _mxStore.annotationsOfKey(key);
    var existingIndex = -1;
    for (var i = 0; i < annotations.length; i++) {
      if (annotations[i].start == cs && annotations[i].end == ce) {
        existingIndex = i;
        break;
      }
    }
    final existing =
        existingIndex >= 0 ? annotations[existingIndex] : null;
    final result = await showDialog<MantraAnnotationResult>(
      context: context,
      builder: (_) => MantraAnnotationDialog(
        quoted: text.substring(cs, ce),
        initialRuby: existing?.ruby ?? '',
        initialNote: existing?.note ?? '',
        focusRuby: ruby,
        canDelete: existing != null,
      ),
    );
    if (result == null || !mounted) return;
    final current = _mxStore.annotationsOfKey(key);
    var currentIndex = -1;
    for (var i = 0; i < current.length; i++) {
      if (current[i].start == cs && current[i].end == ce) {
        currentIndex = i;
        break;
      }
    }
    final next = List<MantraAnnotation>.of(current);
    if (result.ruby.isEmpty && result.note.isEmpty) {
      if (currentIndex >= 0) next.removeAt(currentIndex);
    } else {
      final ann = MantraAnnotation(
        start: cs,
        end: ce,
        ruby: result.ruby,
        note: result.note,
      );
      if (currentIndex >= 0) {
        next[currentIndex] = ann;
      } else {
        next.add(ann);
      }
    }
    final showRuby = result.ruby.isNotEmpty && !_mxShowRuby;
    final showNotes = result.note.isNotEmpty && !_mxShowNotes;
    if (showRuby || showNotes) {
      setState(() {
        if (showRuby) _mxShowRuby = true;
        if (showNotes) _mxShowNotes = true;
      });
    }
    await _mxStore.saveAnnotationsKey(key, next);
    if (result.note.isNotEmpty) _scrollToMxNotes();
  }

  /// 第三层抽屉：比神咒面板矮一截，只放「关联经文 + 人天利益」。
  /// 咒文备注改为在咒文下方内联展开，不再占用这一层抽屉。
  Widget _buildMxDrawer(PaletteData p) {
    final key = _mxDetailKey;
    final headerH = _mxDrawerHeaderH;
    final contentH = _mxDrawerMaxContentHeight();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedBuilder(
        animation: _mxDrawerController,
        builder: (context, _) {
          final open = _mxDrawerController.value;
          final slide = (1 - open) * (headerH + contentH);
          return Transform.translate(
            offset: Offset(0, slide),
            child: ClipRRect(
              clipBehavior: Clip.antiAlias,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(_shelfTopRadius)),
              child: Container(
                key: const ValueKey('shanzhishi_mx_drawer_panel'),
                color: p.tintBg,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildMxDrawerHeader(p),
                    SizedBox(
                      height: contentH,
                      child: _buildMxReadingDrawer(p, key),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 第三层抽屉 header：横杠 + 标题（关联经文），点空白收起。
  Widget _buildMxDrawerHeader(PaletteData p) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _closeMxDrawer,
      child: SizedBox(
        height: _mxDrawerHeaderH,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(_shelfSidePad, 16, _shelfSidePad, 0),
          child: Column(
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
                  Image.asset(
                    'assets/images/yuedu.png',
                    width: 18,
                    height: 18,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '关联经文',
                    style: TextStyle(
                      color: p.primary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
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

  /// 关联经文抽屉：每部经单独一行（点进阅读），其下接这部经的人天利益，
  /// 与善知识详情面板同款。没有关联经文时给出提示。
  Widget _buildMxReadingDrawer(PaletteData p, String? key) {
    final sources = _mxStore.sourcesOfKey(key);
    final bySutra = _mxStore.benefitBySutraOfKey(key);
    final loose = _mxStore.benefitOfKey(key);
    // 每部经挂到它名下的人天利益；没有按经文分开存的旧数据就把整份利益
    // 挂在唯一的经文下（有经文时不再另外平铺）。
    final attached = <String>{for (final l in bySutra.values) ...l};
    final flatOrphan = [
      for (final t in loose)
        if (!attached.contains(t)) t
    ];
    final flatUnderSingle = sources.length == 1 ? flatOrphan : const <String>[];
    final looseTail = sources.length == 1 ? const <String>[] : flatOrphan;
    return ListView(
      key: const ValueKey('shanzhishi_mx_reading_drawer'),
      padding: const EdgeInsets.fromLTRB(_shelfSidePad, 8, _shelfSidePad, 24),
      children: [
        if (sources.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '尚未记录关联经文',
              style: TextStyle(fontSize: 12.5, color: p.textHint),
            ),
          )
        else
          for (var i = 0; i < sources.length; i++) ...[
            if (i > 0) const SizedBox(height: 18),
            _sutraLinkRow(p, sources[i]),
            for (final t in bySutra[sources[i]] ?? const <String>[])
              _paragraphBlock(p, t),
            if (sources.length == 1)
              for (final t in flatUnderSingle) _paragraphBlock(p, t),
          ],
        // 没挂到任何经文下的人天利益（旧数据）：平铺在下面。
        for (final t in looseTail) _paragraphBlock(p, t),
      ],
    );
  }

  /// 把带批注的神咒原文拼成富文本：注音叠在选中文字上方，
  /// 不占额外行高，正文不会被挤下去；被备注的文字画一条下划线。
  /// [showRuby] 为 false 时不画注音（正文照常显示）。
  TextSpan _buildAnnotatedMantraSpan(
    PaletteData p,
    String text,
    List<MantraAnnotation> annotations, {
    bool showRuby = true,
  }) {
    final body = TextStyle(
      fontSize: 16,
      height: 2.3,
      color: p.text,
      letterSpacing: 0.5,
    );
    final rubyStyle = TextStyle(
      fontSize: 11,
      height: 1.1,
      fontWeight: FontWeight.w600,
      color: p.accentDeep,
    );
    // 注音的高度：2.3 行高在字上下各留 ~9.3px 空隙，注音以字距上方为中心
    // 画在空隙里，整行比正文放松，注音不挤。
    const rubySpace = 12.0;
    // 备注只画下划线，不影响行高。先铺一张覆盖表，逐字标出是否落在
    // 某条备注里，后面按「注音/备注边界」切段即可，避免每个字都遍历批注。
    final noteCovered = List<bool>.filled(text.length, false);
    for (final ann in annotations) {
      if (!ann.hasNote) continue;
      final s = ann.start.clamp(0, text.length);
      final e = ann.end.clamp(0, text.length);
      for (var k = s; k < e; k++) {
        noteCovered[k] = true;
      }
    }
    final noteLine = TextStyle(
      decoration: TextDecoration.underline,
      decorationColor: p.accentDeep,
      decorationThickness: 1.4,
    );
    final rubies = <({int start, int end, MantraAnnotation ann})>[
      for (final ann in annotations)
        if (ann.hasRuby)
          (
            start: ann.start.clamp(0, text.length),
            end: ann.end.clamp(0, text.length),
            ann: ann,
          )
    ]..removeWhere((r) => r.end <= r.start);

    // 同一处被多条批注覆盖时，让范围更小的那条优先（例如整段注音里
    // 单独给某几个字再标一次），免得后加的注音被大范围批注吞掉。
    int? winnerAt(int i) {
      int? best;
      var bestLen = 1 << 30;
      for (var k = 0; k < rubies.length; k++) {
        final r = rubies[k];
        if (i < r.start || i >= r.end) continue;
        final len = r.end - r.start;
        if (len < bestLen) {
          bestLen = len;
          best = k;
        }
      }
      return best;
    }

    final spans = <InlineSpan>[];
    // 每条批注只在它「胜出」的第一段文字上标一次注音；被别的批注打断的
    // 后半段仍然照常显示正文，避免同一注音反复出现。
    final shown = <int>{};
    var i = 0;
    while (i < text.length) {
      final w = winnerAt(i);
      // 换行必须留在普通文本里：WidgetSpan 内部带换行会把多行挤进一个
      // 行内占位符，导致后面的注音和排版都不对。换行单独成段，也不画下划线。
      if (text[i] == '\n' || text[i] == '\r') {
        spans.add(TextSpan(text: text[i]));
        i++;
        continue;
      }
      // 纯正文段：在「注音边界」和「备注边界」任一变化处切开。
      if (w == null) {
        var j = i + 1;
        while (j < text.length &&
            text[j] != '\n' &&
            text[j] != '\r' &&
            winnerAt(j) == null &&
            noteCovered[j] == noteCovered[i]) {
          j++;
        }
        spans.add(TextSpan(
          text: text.substring(i, j),
          style: noteCovered[i] ? noteLine : null,
        ));
        i = j;
        continue;
      }
      var j = i + 1;
      while (j < text.length &&
          text[j] != '\n' &&
          text[j] != '\r' &&
          winnerAt(j) == w &&
          noteCovered[j] == noteCovered[i]) {
        j++;
      }
      if (!shown.add(w)) {
        spans.add(TextSpan(
          text: text.substring(i, j),
          style: noteCovered[i] ? noteLine : null,
        ));
        i = j;
        continue;
      }
      final chunk = Text(
        text.substring(i, j),
        // 注音块也要带下划线：备注可能正好落在有注音的字上。
        style: noteCovered[i] ? body.merge(noteLine) : body,
        // WidgetSpan 里的子组件会被 Flutter 按段落字号再缩放一次，
        // 这里自己不再吃系统字号，免得注音和占位高度被放大两倍、压进正文。
        textScaler: TextScaler.noScaling,
      );
      // Stack 只按正文排版：占位符高度=正文本身，基线=正文基线，
      // 行高、字的位置和没有注音时完全一样。
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            chunk,
            // 注音负偏移画到行距空隙里，不参与排版。
            // IgnoreBaseline 很关键：Stack 的基线取「所有子节点里最高的一条」，
            // 不挡住注音的话会被它带成负值，整行被垫高一行（多出空白行）。
            if (showRuby)
              Positioned(
                top: -rubySpace / 2,
                left: -60,
                right: -60,
                child: IgnoreBaseline(
                  child: Center(
                    // 注音只是正文上方的装饰，不能参与选区：否则选区文本会混入
                    // 注音、偏移也会错位，导致「注音 / 备注」落到错误的字上。
                    child: SelectionContainer.disabled(
                      child: Text(
                        rubies[w].ann.ruby,
                        maxLines: 1,
                        softWrap: false,
                        style: rubyStyle,
                        textScaler: TextScaler.noScaling,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ));
      i = j;
    }
    return TextSpan(style: body, children: spans);
  }

  /// 备注块直接跟在咒文下方：每条备注一枚独立色块，左侧小箭头朝上，
  /// 表示它对应上方带下划线的文字；块内再引用一次原文字，避免长咒文
  /// 里找不到指的是哪一句。
  Widget _buildMantraNotesBlock(
    PaletteData p,
    String text,
    List<MantraAnnotation> annotations,
  ) {
    final notes = [
      for (final a in annotations)
        if (a.hasNote) a
    ]..sort((a, b) => a.start != b.start ? a.start - b.start : a.end - b.end);
    if (notes.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('shanzhishi_mantra_notes'),
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < notes.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
              child: _buildMantraNoteCard(p, text, notes[i]),
            ),
        ],
      ),
    );
  }

  Widget _buildMantraNoteCard(
    PaletteData p,
    String text,
    MantraAnnotation ann,
  ) {
    final s = ann.start.clamp(0, text.length);
    final e = ann.end.clamp(0, text.length);
    final quoted = e > s ? text.substring(s, e) : '';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 9),
          child: Icon(
            Icons.arrow_upward_rounded,
            size: 15,
            color: p.accentDeep,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 11),
            decoration: BoxDecoration(
              color: p.tintBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: p.accentDeep.withValues(alpha: 0.18),
              ),
            ),
            child: Text.rich(
              TextSpan(
                children: [
                  if (quoted.isNotEmpty)
                    TextSpan(
                      text: '「$quoted」',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: p.accentDeep,
                        decoration: TextDecoration.underline,
                        decorationColor: p.accentDeep,
                        decorationThickness: 1.2,
                      ),
                    ),
                  if (quoted.isNotEmpty) const TextSpan(text: '  '),
                  TextSpan(text: ann.note),
                ],
              ),
              style: TextStyle(fontSize: 15, height: 1.65, color: p.text),
            ),
          ),
        ),
      ],
    );
  }

  /// 密咒面板右下角「编辑」：打开与「添加」同款的面板（回填各项，可改名/改内容）。
  /// 名称被删空保存 = 删除这条密咒，详情抽屉随之收起。
  Future<void> _editMantra() async {
    final name = _mxDetailName ?? '';
    final key = _mxDetailKey;
    final saved = await ShanZhiShiMantraEditSheet.show(
      context,
      editing: name,
      editingKey: key,
    );
    if (!mounted) return;
    if (saved == null) return;
    if (saved.isEmpty) {
      _closeMxShelf();
      return;
    }
    // 合并到已有条目时，当前那条已被删掉，改按合并后的名字重新定位。
    var newKey = key;
    if (newKey == null || _mxStore.nameOfKey(newKey) == null) {
      final idx = _mxStore.mantras.indexOf(saved);
      newKey = idx >= 0 ? _mxStore.keyAt(idx) : null;
    }
    setState(() {
      _mxDetailName = saved;
      _mxDetailKey = newKey;
    });
  }

  /// 一段人天利益：把「人天利益」四个字当作段落开头那几个字，只是多裹了一层
  /// 色块——正文紧接其后、换行后回到左边（不缩进），与上文经文色块左对齐。
  Widget _paragraphBlock(PaletteData p, String text) {
    return Padding(
      // 与上面经文色块拉开一点：两者贴太近，会看成同一条。
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: p.tintBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '人天利益',
                  style: TextStyle(
                    // 比正文小一号：它是段落的标记，不该抢正文的注意力。
                    fontSize: 13,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: p.accentDeep,
                  ),
                ),
              ),
            ),
            const TextSpan(text: '  '),
            TextSpan(text: text),
          ],
        ),
        style: TextStyle(fontSize: 15, color: p.text, height: 1.8),
      ),
    );
  }

  /// 没挂到任何经文下的人天利益段落（旧数据迁移前的兜底展示）。
  static List<String> _looseParagraphs(ShanyishiEntry entry) {
    final tied = <String>{for (final l in entry.quotes.values) ...l};
    return [
      for (final t in entry.paragraphs)
        if (!tied.contains(t)) t
    ];
  }

  /// 一部关联经文：整行一条色块（铺满宽度），右侧箭头就在色块里，点进阅读页。
  Widget _sutraLinkRow(PaletteData p, String sutra) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        key: ValueKey('shanzhishi_sutra_row_$sutra'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => _openSutraReading(sutra),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          decoration: BoxDecoration(
            color: p.tintBg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  sutra,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.black,
                    letterSpacing: 1,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: p.accentDeep),
            ],
          ),
        ),
      ),
    );
  }
}

/// 面板右下角的圆形编辑按钮：只有一支笔，淡色底、细描边，刻意压低存在感
/// （不用纯黑实底——太抢眼，会盖过面板内容）。
class _PanelEditButton extends StatelessWidget {
  final PaletteData palette;
  final VoidCallback onTap;

  const _PanelEditButton({
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Material(
      color: p.tintBg,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(Icons.edit_outlined, size: 18, color: p.textSec),
        ),
      ),
    );
  }
}

/// 密咒面板右下角竖排图标按钮列（自上而下：注音 / 备注 / 阅读 / 编辑）。
/// 注音是开关：开启时高亮；其余单击触发对应动作。整页只留咒文与这排按钮。
class _MxActionColumn extends StatelessWidget {
  final PaletteData palette;
  final bool showRuby;
  final bool showNotes;
  final bool hasNotes;
  final VoidCallback onRuby;
  final VoidCallback onNotes;
  final VoidCallback onReading;
  final VoidCallback onEdit;

  const _MxActionColumn({
    required this.palette,
    required this.showRuby,
    required this.showNotes,
    required this.hasNotes,
    required this.onRuby,
    required this.onNotes,
    required this.onReading,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MxIconButton(
          palette: p,
          key: const ValueKey('shanzhishi_mx_ruby_toggle'),
          asset: 'assets/images/pinyin.png',
          highlighted: showRuby,
          tooltip: showRuby ? '关闭注音' : '显示注音',
          onTap: onRuby,
        ),
        const SizedBox(height: 10),
        _MxIconButton(
          palette: p,
          key: const ValueKey('shanzhishi_mx_notes_button'),
          asset: 'assets/images/beizhu.png',
          highlighted: showNotes && hasNotes,
          tooltip: showNotes ? '收起备注' : '咒文备注',
          onTap: onNotes,
        ),
        const SizedBox(height: 10),
        _MxIconButton(
          palette: p,
          key: const ValueKey('shanzhishi_mx_reading_button'),
          asset: 'assets/images/yuedu.png',
          highlighted: false,
          tooltip: '关联经文',
          onTap: onReading,
        ),
        const SizedBox(height: 10),
        _MxIconButton(
          palette: p,
          key: const ValueKey('shanzhishi_mx_edit_button'),
          asset: 'assets/images/bianji.png',
          highlighted: false,
          tooltip: '编辑',
          onTap: onEdit,
        ),
      ],
    );
  }
}

/// 竖排图标按钮列里的单颗按钮：圆形底色 + 图片图标，可选高亮态。
class _MxIconButton extends StatelessWidget {
  final PaletteData palette;
  final String asset;
  final bool highlighted;
  final String tooltip;
  final VoidCallback onTap;

  const _MxIconButton({
    super.key,
    required this.palette,
    required this.asset,
    required this.highlighted,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: p.card,
        shape: CircleBorder(
          side: highlighted
              ? BorderSide(color: p.accentDeep, width: 1.2)
              : BorderSide(color: p.borderSoft),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: Opacity(
                opacity: highlighted ? 1 : 0.75,
                child: Image.asset(
                  asset,
                  width: 20,
                  height: 20,
                  fit: BoxFit.contain,
                ),
              ),
            ),
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
