import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sutra_asset_path.dart';
import 'sutra_downloader.dart';
import 'sutra_edit_page.dart' show editedSutraFilePath, SutraEditPage;
import 'sutra_edit_drafts.dart';
import 'sutra_favorites.dart';
import 'sutra_read_later.dart';
import 'app_state.dart';
import 'reader_preferences.dart';
import 'note_edit_page.dart';
import 'paragraph_alignment.dart';
import 'reading_time_service.dart';
import 'sutra_list_page.dart'
    show
        routeObserver,
        sutraDisplayTitleWithPath,
        sutraBaseTitle,
        loadLocalMultiVolumeBases;
import 'note_sutra_links.dart' show NoteSutraCatalog;
import 'sutra_title_overrides.dart';
import 'reading_guide_page.dart';
import 'reading_notes_page.dart';
import 'reading_note_edit_page.dart';
import 'reading_sutra_notes_page.dart';
import 'paragraph_thoughts_page.dart';
import 'post_rich_content.dart' show SutraDiscussionPage;
import 'ai_translate_page.dart';
import 'sutra_highlights_page.dart';
import 'sutra_live_sync.dart' show LiveHighlightSegment;
import 'cloud_notes_service.dart';
import 'auth_service.dart';
import 'record_index.dart';

import 'app_palette.dart';

/// 阅读页正文「已构建并完成首帧布局」的通知。
///
/// 右下角「继续阅读」圆形展开路由监听它：正文（长经文的整段Column）构建耗时会
/// 阻塞 UI 线程，若此时圆形正在展开，动画按真实时间推进就会「卡一下再跳到底」。
/// 收到本通知后再开始展开，页面已经渲染好，圆形便能顺滑铺满（与经藏页右上见
/// DeepSeek 按钮一致）。其他入口没有监听者，派发无副作用。
class ReadingContentReadyNotification extends Notification {
  const ReadingContentReadyNotification();
}

/// 右下角悬浮球展开/收起的阻尼弹簧曲线：起步缓慢、向外展开后单次轻微过冲，
/// 再缓慢归位（类 iPhone 悬浮球），比 easeOutBack 更绵长、更丝滑。
class _FabSpringCurve extends Curve {
  const _FabSpringCurve();

  @override
  double transformInternal(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    const double w = 4.0; // 振荡角频率（越小越慢）
    const double d = 3.2; // 阻尼系数（越小回弹越明显）
    double f =
        1 - math.exp(-d * t) * (math.cos(w * t) + (d / w) * math.sin(w * t));
    // 末段平滑归一到 1，避免收尾出现跳变。
    if (t > 0.8) {
      final double k = (t - 0.8) / 0.2;
      f = f + (1 - f) * k;
    }
    return f;
  }
}

class ReadingPage extends StatefulWidget {
  final String title;
  final String? filePath;
  final bool fromAssistant;

  const ReadingPage({
    super.key,
    required this.title,
    this.filePath,
    this.fromAssistant = false,
  });

  @override
  State<ReadingPage> createState() => ReadingPageState();
}

class ReadingPageState extends State<ReadingPage>
    with WidgetsBindingObserver, RouteAware {
  String _content = '';
  List<String> _paragraphs = [];
  List<String> _rawLines = [];
  double _fontSize = 16.0;
  double _lineHeight = 1.8;
  int _pageMode = ReaderPreferences.pageModeScroll;
  int _bgColorIndex = 0;
  bool _isDarkMode = false;
  late ScrollController _scrollController;
  final GlobalKey _scrollViewKey = GlobalKey();
  PageController? _pageController;
  final TextEditingController _searchController = TextEditingController();
  bool _showSearchBar = false;
  bool _showMoreMenu = false;
  bool _showStylePanel = false;
  bool _showQuickPanel = false; // 点击正文中部弹出的画线/感想/阅读设置 面板
  bool _showFabMenu = false; // 右下角悬浮球展开：显示 AI/笔记/讨论 三个按钮
  Offset? _fabBallCenter; // 悬浮球圆心（null=默认右下角）；长按可拖动到任意位置
  Offset? _fabDragStartBall; // 长按拖动开始时的圆心
  bool _selectionActiveAtDown = false; // 按下时正文是否有文字选中或长按浮层菜单打开
  Offset? _pointerDownPos;
  bool _longPressActive = false;
  bool _menuOpenAtDown = false;
  // 按下时「阅读设置」面板正打开、且这次按在面板外（用于收起面板）：
  // 抬起后只收起面板，不再触发正文单击面板，避免切换翻页方式后
  // 收起设置面板的同一次点击顺带弹出「画线感想/笔记」速览面板。
  bool _stylePanelDismissAtDown = false;
  bool _hasTextSelection = false;
  bool _actionRowTapped = false; // 点击段落操作栏（AI读笔记/方框）时置true，阻止外层Listener触发面板
  final GlobalKey _moreMenuKey = GlobalKey();
  final GlobalKey _stylePanelKey = GlobalKey();

  // 搜索命中列表：每项为 (段落下标, 段内起始字符下标)。
  // 必须在「实际渲染的段落」上匹配（与高亮同一数据源），命中数才恒等于
  // 正文里被高亮的处数；备注段落（@@块）不参与搜索，不_buildParagraphSpans 一致。
  List<(int, int)> _searchMatches = [];
  int _currentMatchIndex = 0;
  /// 阅读进度（0~1）。
  ///
  /// 通过 setter 同步写进 [_scrollProgressListenable]：滚动进度只用来显示
  /// 底部进度条/百分比，原先每帧 setState 会让整个正文（一次性整页 Column）
  /// 重新走一遍 build + 全文重排版，滚动和「编辑页返回」都会明显掉帧。
  set _scrollProgress(double v) {
    _scrollProgressValue = v;
    if (_scrollProgressListenable.value != v) {
      _scrollProgressListenable.value = v;
    }
  }

  double get _scrollProgress => _scrollProgressValue;
  double _scrollProgressValue = 0.0;

  /// 底部进度条/百分比单独监听这个 notifier，滚动时只重建这一小块。
  final ValueNotifier<double> _scrollProgressListenable = ValueNotifier(0.0);

  /// 滚动位置落盘的节流定时器：原先滚动每帧都打两次 SharedPreferences
  /// 平台调用，滚动和「编辑页返回」恢复进度时都会掉帧。
  Timer? _scrollSaveTimer;

  /// 已标记「读过」的经书路径：原先滚到底后每帧都写一次同一 bool。
  String? _markedReadKey;

  // ── 读经段落笔记 / 完成态（云端同步，─────────
  Map<int, List<ParaNote>> _paraNotes = {}; // index -> 该段全部备注（同一人可多条，
  Map<int, List<Map<String, int>>> _paraUnderlines =
      {}; // index -> 该段已画线的文字区间 [{start,end}]
  // 每个渲染簇（以首段下标为键）的GlobalKey：单击画线段落时按几何命中判完
  // 「是否点在画线文字上」，不依赖手势竞技场时序，行为恒定。
  final Map<int, GlobalKey> _paraTapKeys = {};
  // 画线/感想归集页是否正在打开（防止重复点击导致路由栈叠加）。
  bool _openingHighlights = false;
  bool _openingNotes = false;
  // 长按选中时的菜单是否已弹出（防止拖动句柄时重复插全Overlay）。
  OverlayEntry? _selectionMenuEntry;
  // 所有仍处于显示中的浮层菜单条目（长按选中 + 单击画线），
  // 打开其他页面（如感想输入页）前统一移除，避免残留弹窗。
  final List<OverlayEntry> _activeMenuEntries = [];
  // 每一次长按选中的菜单请求序号。用于丢弃切换页面/ 关闭弹窗后仍排队的
  // addPostFrameCallback，避免其在感想输入页上重新插入残留的「复到画线」弹窗。
  int _menuRequestId = 0;
  // 本页之上有其他路由（感想编辑页等）时不true：期间禁止重建浮层菜单，
  // 否则选区收起会再次触取contextMenuBuilder，把弹窗插到新页面上方。
  bool _coveredByRoute = false;
  // 长按选中的EditableTextState，用于点 画线/感想/复制 时读取实时选区。
  EditableTextState? _selectionTextState;
  // 每次选区变化时更新的最新范围（长按初始为单字，拖动句柄后为完整范围）。
  (int, int)? _selectionRange;
  Map<int, bool> _paraDone = {}; // index -> 是否已读完学完
  bool _paraNotesLoading = false;
  // 是否至少成功拉取过一次段落笔记：拉取失败时不能按「空表」去迁移/重建数据。
  bool _paraNotesLoaded = false;
  Set<int> _paraHasAnyThought = {}; // 有任意用户感想的段落下标集合（操作栏「所有备注」变绿）
  // 更新排版后未能按原文重新定位到新段的原始 index 集合（保留数据并标记提示）。
  Set<int> _unalignedIndices = {};
  // 从`。。。` 前缀标记、阅读时隐藏操作栏（AI读感想/待办）的段落 index 集合。
  Set<int> _hiddenActionParagraphs = {};
  // 从`。。。//` 标记、该段与下一段之间不留间隔（不分段）的段落index 集合。
  Set<int> _tightParagraphs = {};
  // 从`bbb` 成`BBB` 结尾的段落index 集合：该段文字加粗显示。
  Set<int> _boldParagraphs = {};
  Set<int> _noteParagraphs = {};
  bool _isSutraAdmin = false; // 当前登录用户是否为管理员（决定菜单显示编辑经文更新排版，
  int _activeNoteParagraphIndex = -1; // 正在编辑备注的段落（用于输入框）
  final TextEditingController _noteInputController = TextEditingController();
  late final String? _resolvedFilePath;
  bool _isLoadingContent = true;
  // 正文首帧渲染完成后是否已派发 [ReadingContentReadyNotification]（只派发一次）。
  bool _contentReadyNotified = false;
  bool _needsDownload = false;
  bool _isDownloading = false;
  double _downloadProgress = 0;
  bool _isFavorite = false;
  bool _isRead = false;
  bool _isReadLater = false;
  // 管理员本机标记：该经排版是否已完成（点击「完成排版」后置位，标题栏显示徽标）。
  bool _isLayoutDone = false;
  double? _savedPosition;

  /// 当前背景是否为深色（索引4 = 393536）。
  bool get _isDarkBg => _bgColorIndex == 4;
  double? _savedProgress;
  int _restoreAttempts = 0;

  // 翻页模式：分页结果与缓存，避免每帧重算。
  // 每页存的是该页包含的段落索引列表（按段落分页，段内才带操作栏）。
  List<List<int>> _flipPages = [];
  String _flipCacheKey = '';
  int _currentFlipPage = 0;
  bool _flipPageRestored = false;

  /// 顶部标题双击回到顶部：记录上次点击时间。
  DateTime? _lastTitleTap;

  /// 顶部标题展示名（含「卷X」卷标）：异步加载多卷集合后计算，
  /// 加载完成前先显示去掉 CBETA 编号的基础经名。
  String? _displayTitle;

  /// 当前展示标题：管理员订正的经名优先，其次卷标就绪后的展示名，
  /// 再次去掉 CBETA 编号的基础经名（避免标题栏闪现编号）。
  String get _titleShown {
    final override = SutraTitleOverrides.forTitle(widget.title) ??
        SutraTitleOverrides.forTitle(
            SutraDownloader.extractId(null, _resolvedFilePath ?? widget.filePath));
    return override ?? _displayTitle ?? sutraBaseTitle(widget.title);
  }

  Future<void> _loadDisplayTitle() async {
    // 多卷判定优先用随包目录（与时间线 / 经藏列表 / 讨论页同一份数据），
    // 它完整覆盖全部经书；本地 sutras_list.json 可能缺失或是用户子集，
    // 只作为随包目录不可用时的兜底，避免读经页把「卷X」卷标漏掉、
    // 与时间线上的经名对不上。
    Set<String> mvBases;
    try {
      await NoteSutraCatalog.load();
      mvBases = NoteSutraCatalog.cachedMultiVolumeBases;
    } catch (_) {
      mvBases = const {};
    }
    if (mvBases.isEmpty) {
      mvBases = await loadLocalMultiVolumeBases();
    }
    if (!mounted) return;
    setState(() {
      _displayTitle = sutraDisplayTitleWithPath(widget.title,
          filePath: _resolvedFilePath ?? widget.filePath,
          multiVolumeBases: mvBases);
    });
    // 内容可能在标题加载后仍在进行，笔记状态按需要异步拉取即可。
    _loadParagraphNotes();
  }

  /// 本经的段落笔记云端存储主键（用经名，稳定且跨设备一致）。
  String get _sutraKey => widget.title;

  /// 是否已订阅路由生命周期（用于读经计时）。
  bool _subscribed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ReadingTimeService.instance.startFor(this);
    _resolvedFilePath =
        widget.filePath == null ? null : _canonicalFilePath(widget.filePath!);
    _scrollController = ScrollController();
    _scrollController.addListener(_scrollListener);
    _pageController = PageController();
    _saveCurrentSutra();
    _loadSettings();
    _loadSavedScrollState();
    _loadContent();
    _loadFavoriteState();
    _loadReadState();
    _loadReadLaterState();
    _loadLayoutDoneState();
    _loadDisplayTitle();
    // 内容加载完成后自动检查云端是否有更新排版（所有用户均需执行，不依赖登录状态）。
    _autoCheckAndApplyLayout();
    // 异步获取管理员身份：管理员在菜单显示「编辑经文」。
    CloudNotesService.instance.isAdmin().then((v) {
      if (mounted) setState(() => _isSutraAdmin = v);
    }).catchError((_) {});
  }

  /// 把任意形式的经书路径规范化为打包资产路径（assets/sutras_ascii/...）：
  ///  - 打包资产路径（含旧版中文路径）按经书 ID 重新定位，
  ///  - 本机真实存在的文件（用户自选导入等）保持原样直接读取；
  ///  - 其余（如换机/重新登录后从云端同步回来的旧设备绝对路径）按经书 ID
  ///    归一到本地下载目录对应的资产路径，保证本地副本检查能命中。
  String _canonicalFilePath(String p) {
    if (p.startsWith('assets/')) {
      return SutraAssetPath.resolve(title: widget.title, filePath: p);
    }
    if (File(p).existsSync()) return p;
    final resolved = SutraAssetPath.resolve(title: widget.title, filePath: p);
    return resolved.startsWith('assets/') ? resolved : p;
  }

  void _saveCurrentSutra() {
    final savePath = _resolvedFilePath ?? widget.filePath;
    if (savePath == null) return;
    SharedPreferences.getInstance().then((prefs) async {
      await prefs.setString('current_sutra_title', widget.title);
      await prefs.setString('current_sutra_file_path', savePath);
      final recent = prefs.getStringList('recent_sutras') ?? [];
      recent.removeWhere((e) => e.startsWith('${widget.title}|||'));
      recent.insert(0, '${widget.title}|||$savePath');
      if (recent.length > 20) recent.removeRange(20, recent.length);
      await prefs.setStringList('recent_sutras', recent);

      final now = DateTime.now();
      final today =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final raw = prefs.getString('daily_sutra_history') ?? '{}';
      final Map<String, dynamic> history = jsonDecode(raw);
      final List<dynamic> dayList = (history[today] as List<dynamic>?) ?? [];
      dayList.removeWhere((e) => e['filePath'] == savePath);
      final progress = prefs.getDouble('progress_$savePath') ?? 0.0;
      dayList.insert(0,
          {'title': widget.title, 'filePath': savePath, 'progress': progress});
      history[today] = dayList;
      await prefs.setString('daily_sutra_history', jsonEncode(history));
    });
  }

  Future<void> _loadSavedScrollState() async {
    final prefs = await SharedPreferences.getInstance();
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath == null) return;
    // 兼容旧版本用本机绝对路径命名的scroll_ 键（换机/重装后
    // 云端同步回来的可能是这类键）：取首个候选键的滚动位置。
    final variants =
        await SutraDownloader.pathKeyVariants(keyPath, title: widget.title);
    double? savedPos;
    for (final v in variants) {
      savedPos ??= prefs.getDouble('scroll_$v');
    }
    // 进度以规范路径键的最新值（阅读页实时写入，离开时即保存）为准，
    // 规范键缺失时兼容旧键名并回退每日阅读历史，避免换本重装后进度清零。
    final savedProg = await SutraDownloader.latestProgressForPath(
        prefs, keyPath,
        title: widget.title);
    _savedPosition = savedPos;
    _savedProgress = savedProg > 0 ? savedProg : null;

    if (mounted && _savedProgress != null) {
      setState(() {
        _scrollProgress = _savedProgress!;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null && !_subscribed) {
      _subscribed = true;
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didPush() {
    ReadingTimeService.instance.startFor(this);
  }

  @override
  void didPopNext() {
    ReadingTimeService.instance.startFor(this);
    // 回到本页：恢复允许弹窗（下次长按选中）。
    _coveredByRoute = false;
  }

  @override
  void didPushNext() {
    ReadingTimeService.instance.stopFor(this);
    // 有新页面盖在本页上（如感想编辑页）：清掉浮层菜单并禁止其重建。
    // 否则失焦导致选区收起时contextMenuBuilder 会再次回调，
    // 把「复到画线」弹窗重新插到新页面上方，形成残留。
    _clearSelectionMenu();
    _coveredByRoute = true;
  }

  @override
  void didPop() {
    ReadingTimeService.instance.stopFor(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ReadingTimeService.instance.startFor(this);
    } else {
      ReadingTimeService.instance.stopFor(this);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_subscribed) routeObserver.unsubscribe(this);
    ReadingTimeService.instance.stopFor(this);
    // 未及落盘的滚动进度补写一次（必须在 dispose 控制器之前读 offset）。
    if (_scrollSaveTimer != null) {
      _scrollSaveTimer!.cancel();
      _scrollSaveTimer = null;
      unawaited(_saveScrollPosition());
    }
    _scrollProgressListenable.dispose();
    _scrollController.dispose();
    _pageController?.dispose();
    _searchController.dispose();
    _noteInputController.dispose();
    _paraTapKeys.clear();
    _clearSelectionMenu();
    _selectionTextState = null;
    // 离开阅读页时收起 AI 面板（WebView 本身常驻，不销毁）。
    assistantVisible.value = false;
    super.dispose();
  }

  void _scheduleRestoreScroll() {
    if (!mounted) return;
    if (!_scrollController.hasClients) return;

    // Wait until content is laid out. Large texts can take a few frames.
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) {
      if (_restoreAttempts < 20) {
        _restoreAttempts++;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _scheduleRestoreScroll());
      }
      return;
    }

    final savedProgress = _savedProgress;
    final savedPosition = _savedPosition;
    double? target;
    if (savedProgress != null && savedProgress > 0) {
      target = (savedProgress * maxScroll).clamp(0, maxScroll);
    } else if (savedPosition != null && savedPosition > 0) {
      target = savedPosition.clamp(0, maxScroll);
    }

    if (target != null) {
      _scrollController.jumpTo(target);
      // 只更新进度（走 setter 同步到进度 notifier），不再 setState：
      // 这里 setState 会让整篇正文在返回动画刚结束时再重排一遍。
      _scrollProgress = maxScroll <= 0
          ? 0.0
          : (_scrollController.offset / maxScroll).clamp(0.0, 1.0);
    }
  }

  void _scrollListener() {
    if (_scrollController.hasClients) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll > 0) {
        // 只更新字段 + 进度 notifier：不 setState，滚动时正文不再整页重建。
        _scrollProgress = (_scrollController.offset / maxScroll).clamp(0.0, 1.0);
        _scheduleSaveScrollPosition();
      }
      if (_scrollController.offset >= maxScroll) {
        _maybeMarkAsRead();
      }
    }
  }

  /// 每 400ms 至多落盘一次滚动位置（节流而非防抖，持续滚动也会周期保存）。
  void _scheduleSaveScrollPosition() {
    if (_scrollSaveTimer != null) return;
    _scrollSaveTimer = Timer(const Duration(milliseconds: 400), () {
      _scrollSaveTimer = null;
      if (!mounted) return;
      _saveScrollPosition();
    });
  }

  /// 滚到底只需写一次「已读」：原先每帧都发一次 SharedPreferences 调用。
  void _maybeMarkAsRead() {
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath == null || _markedReadKey == keyPath) return;
    _markedReadKey = keyPath;
    _markAsRead();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      // 兼容历史数据里存成int 的取值（如fontSize），统一载double。
      _fontSize = (prefs.get('fontSize') as num?)?.toDouble() ?? 16.0;
      _isDarkMode = prefs.getBool('isDarkMode') ?? false;
      _lineHeight =
          (prefs.get('reader_line_height') as num?)?.toDouble() ?? 1.8;
      _pageMode =
          prefs.getInt('reader_page_mode') ?? ReaderPreferences.pageModeScroll;
      _bgColorIndex = prefs.getInt('reader_bg_color') ?? 0;
    });
    // 同步全局夜间模式信号，消息中心等页面跟随切换浅色/深色配色。
    appDarkMode.value = _isDarkMode;
  }

  Future<void> _saveScrollPosition() async {
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath != null && _scrollController.hasClients) {
      // 先取快照再 await：原实现在 await 之后才读 offset，State 销毁后
      // 控制器已无 position 会抛错。
      final offset = _scrollController.offset;
      final progress = _scrollProgress;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('scroll_$keyPath', offset);
      await prefs.setDouble('progress_$keyPath', progress);
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('fontSize', _fontSize);
    await prefs.setBool('isDarkMode', _isDarkMode);
    await prefs.setDouble('reader_line_height', _lineHeight);
    await prefs.setInt('reader_page_mode', _pageMode);
    await prefs.setInt('reader_bg_color', _bgColorIndex);
  }

  Future<void> _loadContent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_read_title', widget.title);
    if (_resolvedFilePath != null) {
      await prefs.setString('last_read_filePath', _resolvedFilePath!);
    } else if (widget.filePath != null) {
      await prefs.setString('last_read_filePath', widget.filePath!);
    }
    final filePath = _resolvedFilePath ?? widget.filePath;
    debugPrint('[加载内容] filePath=$filePath');
    if (filePath != null) {
      // 1. 优先加载已编辑的副本（如果存在）
      final editedPath = await editedSutraFilePath(filePath);
      final editedFile = File(editedPath);
      final hasEdited = await editedFile.exists();
      debugPrint('[加载内容] editedPath=$editedPath hasEdited=$hasEdited');
      if (hasEdited) {
        try {
          final content = await editedFile.readAsString();
          // 本地编辑副本即镜像一份到可上云的草稿：卸载重装换debug 包后
          // 该目录被清空时，还能从云端同步回来的草稿恢复编辑版。
          unawaited(SutraEditDraft.save(
            title: widget.title,
            filePath: filePath,
            content: content,
          ));
          if (mounted) {
            setState(() {
              _content = content;
              _paragraphs = _parseParagraphs(content);
              _isLoadingContent = false;
            });
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _scheduleRestoreScroll());
          }
          return;
        } catch (_) {
          // 读取失败则回退到原始文件
        }
      }

      // 1.4 秒开：本地已有下载副本 / 打包资源时先立即展示正文（纯本地，无
      //     网络），不再等云端「编辑版」检查（一次网络往返 1~2 秒）造成的
      //     空白等待；随后后台拉取云端排版，若有更新再原地替换。
      if (!hasEdited) {
        if (await _showLocalCopyOrPackaged(filePath)) {
          unawaited(_refreshEditedFromCloud(filePath, editedPath));
          return;
        }
      }

      // 1.5 本地编辑副本不存在（卸载重装 / debug↔release 签名不同导致先卸载
      //     再装，应用私有目录被清空）：用云同步回来的草稿恢复，避免用户
      //     看到「排版过的经文又变回原版」。草稿比云端已发布版新才采用。
      if (!hasEdited) {
        final draftContent = await _restoreEditedDraft(filePath, editedPath);
        if (draftContent != null) {
          if (mounted) {
            setState(() {
              _content = draftContent;
              _paragraphs = _parseParagraphs(draftContent);
              _isLoadingContent = false;
            });
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _scheduleRestoreScroll());
          }
          return;
        }
      }

      // 2. 无本地编辑副本时，检查云端是否有管理员「已排版」版本：
      //    只要云端的sutraEdits 存在（即点击过「完成排版」），就任GitHub
      //    拉取编辑版并保存为本地编辑副本。这样「任意一部经书都有且仅有两种
      //    状态：未编辑显示原始版 / 已排版显示编辑版」，且以云端为准，
      //    本地任何旧副本都不会挡住云端最新排版。
      if (!hasEdited) {
        final id = SutraDownloader.extractId(widget.title, filePath);
        if (id != null && id.isNotEmpty) {
          final cloudContent = await _loadCloudEditedContent(id, editedPath);
          if (cloudContent != null) {
            if (mounted) {
              setState(() {
                _content = cloudContent;
                _paragraphs = _parseParagraphs(cloudContent);
                _isLoadingContent = false;
              });
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => _scheduleRestoreScroll());
            }
            return;
          }
        }
      }

      // 3. 其次加载已下载到本地的副本（原始版兜底）
      File? localCopy;
      if (filePath.startsWith('assets/sutras_ascii/')) {
        localCopy = await SutraDownloader.localFileForAssetPath(filePath);
        debugPrint('[加载内容] localCopy=$localCopy');
      }
      // 兜底：任何形式的路径（如换机/重新登录后从云端同步回来的旧设备
      // 绝对路径）只要能从标题路径中识别出经书 ID，就去本地下载目录找副本，
      // 避免已下载的经书被误判为「未下载」而反复提示重新下载。
      if (localCopy == null) {
        final id = SutraDownloader.extractId(widget.title, filePath);
        if (id != null &&
            id.isNotEmpty &&
            await SutraDownloader.isDownloaded(id)) {
          localCopy = await SutraDownloader.localFile(id);
        }
      }
      if (localCopy != null) {
        try {
          final content = await localCopy.readAsString();
          if (mounted) {
            setState(() {
              _content = content;
              _paragraphs = _parseParagraphs(content);
              _isLoadingContent = false;
            });
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _scheduleRestoreScroll());
          }
          return;
        } catch (_) {
          // 读取失败则回退到打包资源
        }
      }

      // 3. 再回退到打包资源。管理员「编辑经文」版放在 assets/sutras_edited/
      // （与原始版assets/sutras_ascii/ 同结构）。两者都打进安装包时优先显示
      // 编辑版：重装/首次安装默认即最新排版，与云端发布一致，管理员账号也
      // 无需再另走「更新排版」；编辑版未打包时回退原始版。
      if (filePath.startsWith('assets/')) {
        String content;
        try {
          content = await _loadPackagedContent(filePath);
        } catch (e) {
          debugPrint('[加载内容] 打包资源加载失败，走自动下载编辑版 $e');
          // 打包与本地均无正文（经文正文本就不打安装包，按需下载）：
          // 自动拉取管理员「编辑经文」发布的编辑版展示；云端无编辑版时
          // download 会自动回退原始版。这样重装首次安装默认即编辑排版，
          // 管理员与普通用户都无需再逐部经书手动「更新排版」。
          final id = SutraDownloader.extractId(widget.title, filePath);
          if (id != null && id.isNotEmpty) {
            final ok = await _autoFetchEditedContent(id);
            if (ok || !mounted) return;
          }
          if (mounted) {
            setState(() {
              _content = '该经文正文尚未下载，请点击上方"下载"按钮获取后再阅读。';
              _paragraphs = [];
              _isLoadingContent = false;
              _needsDownload = true;
            });
          }
          return;
        }
        if (mounted) {
          setState(() {
            _content = content;
            _paragraphs = _parseParagraphs(content);
            _isLoadingContent = false;
          });
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _scheduleRestoreScroll());
        }
      } else {
        try {
          File file = File(filePath);
          if (await file.exists()) {
            String content = await file.readAsString();
            if (mounted) {
              setState(() {
                _content = content;
                _paragraphs = _parseParagraphs(content);
                _isLoadingContent = false;
              });
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => _scheduleRestoreScroll());
            }
          } else if (mounted) {
            setState(() {
              _content = '该经文正文尚未下载。';
              _paragraphs = [];
              _isLoadingContent = false;
              _needsDownload = true;
            });
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _content = '无法加载文件内容';
              _paragraphs = [];
              _isLoadingContent = false;
            });
          }
        }
      }
    } else {
      if (mounted) {
        setState(() {
          _content = '这是《$_titleShown》的预览内容。\n\n暂无实际文件，请添加本地文件。';
          _paragraphs = ['暂无实际文件，请添加本地文件。'];
          _isLoadingContent = false;
        });
      }
    }
  }

  /// 打包资源正文：优先读管理员「编辑经文」版（assets/sutras_edited/…），
  /// 与原始版 assets/sutras_ascii/…同结构；编辑版在包中不存在或读取失败时
  /// 回退到原始版。这样重装首次安装默认展示最新排版，无需逐部经书手动拉取。
  Future<String> _loadPackagedContent(String assetPath) async {
    if (assetPath.startsWith('assets/sutras_ascii/')) {
      final rel = assetPath.substring('assets/sutras_ascii/'.length);
      final edited = 'assets/sutras_edited/$rel';
      try {
        return await rootBundle.loadString(edited);
      } catch (_) {
        // 编辑版未打包进此安装包，回退原始版。
      }
    }
    return rootBundle.loadString(assetPath);
  }

  /// 「秒开」：直接把本地已下载副本 / 打包资源展示出来（纯本地，无网络），
  /// 命中即 setState 显示并返回 true；本地与打包都没有则返回 false（不改 UI，
  /// 交由调用方继续走草稿/云端/下载提示流程）。
  Future<bool> _showLocalCopyOrPackaged(String filePath) async {
    File? localCopy;
    if (filePath.startsWith('assets/sutras_ascii/')) {
      localCopy = await SutraDownloader.localFileForAssetPath(filePath);
      debugPrint('[加载内容] localCopy=$localCopy');
    }
    // 兜底：任何形式的路径只要识别出经书 ID，就去本地下载目录找副本。
    if (localCopy == null) {
      final id = SutraDownloader.extractId(widget.title, filePath);
      if (id != null &&
          id.isNotEmpty &&
          await SutraDownloader.isDownloaded(id)) {
        localCopy = await SutraDownloader.localFile(id);
      }
    }
    if (localCopy != null) {
      try {
        _applyLoadedContent(await localCopy.readAsString());
        return true;
      } catch (_) {
        // 读取失败则回退打包资源
      }
    }
    if (filePath.startsWith('assets/')) {
      try {
        _applyLoadedContent(await _loadPackagedContent(filePath));
        return true;
      } catch (_) {
        // 打包资源也没有：交由调用方走云端/下载提示
      }
    } else {
      try {
        final f = File(filePath);
        if (await f.exists()) {
          _applyLoadedContent(await f.readAsString());
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// 后台检查是否有更新的「编辑版」（先本地云草稿，再云端正式版），命中且与
  /// 当前正文不同则原地替换。全程异步，不阻塞首屏。
  Future<void> _refreshEditedFromCloud(
      String filePath, String editedPath) async {
    try {
      final draftContent = await _restoreEditedDraft(filePath, editedPath);
      if (draftContent != null) {
        if (mounted && _content != draftContent) {
          _applyLoadedContent(draftContent);
        }
        return;
      }
      final id = SutraDownloader.extractId(widget.title, filePath);
      if (id == null || id.isEmpty) return;
      final cloudContent = await _loadCloudEditedContent(id, editedPath);
      if (cloudContent != null && mounted && _content != cloudContent) {
        _applyLoadedContent(cloudContent);
      }
    } catch (_) {}
  }

  /// 统一的正文落地：设置内容、解析段落、结束 loading 并恢复阅读位置。
  void _applyLoadedContent(String content) {
    if (!mounted) return;
    setState(() {
      _content = content;
      _paragraphs = _parseParagraphs(content);
      _isLoadingContent = false;
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scheduleRestoreScroll());
  }

  /// 本地编辑副本缺失时，用云同步回来的草稿（SyncService 已拉回prefs，
  /// 恢复编辑版，并写回本地编辑副本。返回null 表示无草稿或草稿已过期。
  ///
  /// 只有草稿不比云端已发布版旧时才采用（`sutraEditMeta.updatedAt` 更晚说明
  /// 管理员后来又「完成排版」过，正式版优先），拿不到云端元信息（断网等，
  /// 视为云端无更新，直接恢复草稿。
  Future<String?> _restoreEditedDraft(String filePath, String editedPath) async {
    try {
      final draft = await SutraEditDraft.read(title: widget.title, filePath: filePath);
      if (draft == null) return null;
      final id = SutraDownloader.extractId(widget.title, filePath);
      if (id != null && id.isNotEmpty) {
        final meta = await CloudNotesService.instance.sutraEditMeta(id);
        final remoteAt = (meta?['updatedAt'] as num?)?.toInt() ?? 0;
        if (remoteAt > draft.savedAt) return null;
      }
      await File(editedPath).writeAsString(draft.content, flush: true);
      debugPrint('[加载内容] 从云草稿恢复编辑版长度=${draft.content.length}');
      return draft.content;
    } catch (_) {
      return null;
    }
  }

  /// 从云端（GitHub sutras_edited/）拉取管理员「已排版」的编辑版，并保存为
  /// 本地编辑副本。只在云端确有编辑版时返回内容；云端无编辑版返回 null。
  /// 与「保存到本地编辑副本」串在一起：重装后首次打开也立即享受云端排版。
  Future<String?> _loadCloudEditedContent(String id, String editPath) async {
    try {
      final meta = await CloudNotesService.instance.sutraEditMeta(id);
      final remoteAt = (meta?['updatedAt'] as num?)?.toInt() ?? 0;
      debugPrint('[云端编辑版检查] id=$id found=${meta?['found']} remoteAt=$remoteAt');
      if (remoteAt <= 0) return null; // 云端无编辑版，用原始版。

      // 从GitHub 直连拉取编辑版，避免 CDN 未缓存时回退到原始版。
      final vol = id.substring(0, 3);
      final urls = [
        'https://raw.githubusercontent.com/dalidakun/huideng/main/assets/sutras_edited/$vol/$id.txt',
        'https://ghfast.top/https://raw.githubusercontent.com/dalidakun/huideng/main/assets/sutras_edited/$vol/$id.txt',
        'https://gh-proxy.com/https://raw.githubusercontent.com/dalidakun/huideng/main/assets/sutras_edited/$vol/$id.txt',
      ];
      String? content;
      for (final u in urls) {
        try {
          final resp = await _httpGet(u);
          if (resp != null && resp.isNotEmpty) {
            content = resp;
            break;
          }
        } catch (_) {}
      }
      if (content == null || content.isEmpty) return null;
      // 保存为本地编辑副本，下次打开直接读本地（不再依赖网络）。
      try {
        await File(editPath).writeAsString(content);
      } catch (_) {}
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('sutra_edit_ver_$id', remoteAt);
      return content;
    } catch (_) {
      return null;
    }
  }

  /// 本地/打包都没有正文时，自动下载管理员「编辑经文」发布的版本来展示。
  /// 成功到setState 加载并返回true；失败返回false（由调用方显示下载提示）。
  Future<bool> _autoFetchEditedContent(String id) async {
    debugPrint('[自动下载编辑版] id=$id');
    try {
      final filePath = _resolvedFilePath ?? widget.filePath;
      if (filePath == null) return false;
      final editPath = await editedSutraFilePath(filePath);
      final content = await _loadCloudEditedContent(id, editPath);
      debugPrint(
          '[自动下载编辑版] 云端编辑版 ${content != null}, 长度=${content?.length ?? 0}');
      if (content != null) {
        if (!mounted) return false;
        setState(() {
          _content = content;
          _paragraphs = _parseParagraphs(content);
          _isLoadingContent = false;
          _needsDownload = false;
        });
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _scheduleRestoreScroll());
        return true;
      }
      // 云端无编辑版：回退到原始版下载（与下载按钮一致）。
      final file = await SutraDownloader.download(id);
      final origContent = await file.readAsString();
      if (!mounted) return false;
      setState(() {
        _content = origContent;
        _paragraphs = _parseParagraphs(origContent);
        _isLoadingContent = false;
        _needsDownload = false;
      });
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scheduleRestoreScroll());
      return true;
    } catch (_) {
      return false;
    }
  }

  List<String> _parseParagraphs(String content) {
    final out = <String>[];
    _rawLines = [];
    _hiddenActionParagraphs.clear();
    _tightParagraphs.clear();
    _boldParagraphs.clear();
    _noteParagraphs.clear();
    final lines = content.split('\n');
    const hideMark = '。。。';
    // 不分段记号：支持半角 /// 与全见／／／。
    const tightUnits = ['///', '／／／'];
    // ── 备注段落：@@ 开失…@@ 结尾 的块状解果──
    // 支持三种写法，
    //   1) 单行：@@内容@@
    //   2) 多行：@@ 开失+ 若干内容行+ @@ 结尾
    //   3) 空模板：@@@@（编辑器「备注」按钮插入的光标模板，
    // 块内所有行合并为一段，不做任何符号/分段/翻译处理。
    final noteBuf = <String>[];
    var inNote = false;
    void flushNote() {
      if (noteBuf.isEmpty) return;
      _noteParagraphs.add(out.length);
      _hiddenActionParagraphs.add(out.length);
      out.add(noteBuf.join('\n'));
      _rawLines.add(noteBuf.join('\n'));
      noteBuf.clear();
    }

    for (final line in lines) {
      var text = line.trim();

      // 块内空行：保留为原样换行（不打断备注块）。
      if (text.isEmpty) {
        if (inNote && noteBuf.isNotEmpty) {
          noteBuf.add('');
        } else if (!inNote) {
          flushNote();
        }
        continue;
      }

      // 备注块内的行。
      if (inNote) {
        if (text.endsWith('@@')) {
          final rest = text.substring(0, text.length - 2);
          if (rest.isNotEmpty) noteBuf.add(rest);
          flushNote();
          inNote = false;
        } else if (text.startsWith('@@')) {
          noteBuf.add(text.substring(2));
        } else {
          noteBuf.add(text);
        }
        continue;
      }

      // 单行：@@内容@@（内容可为空单@@@@）。
      if (text.startsWith('@@') && text.endsWith('@@') && text.length >= 4) {
        noteBuf.add(text.substring(2, text.length - 2));
        flushNote();
        continue;
      }

      // 块开始：@@ 开头（未在本行结束）。
      if (text.startsWith('@@')) {
        final rest = text.substring(2);
        if (rest.isNotEmpty) noteBuf.add(rest);
        inNote = true;
        continue;
      }

      // 遇到面@@ 行，先刷出之前累积的备注
      flushNote();

      var hide = false;
      var tight = false;
      var bold = false;

      // ── 1. 尾部 hideMark + tight 检测（后bbb 遮挡的情况） ──
      // 先尝试完整匹配。。。// 成///。。。（最常见组合）。
      for (final u in tightUnits) {
        if (text.endsWith(hideMark + u)) {
          text = text.substring(0, text.length - hideMark.length - u.length);
          hide = true;
          tight = true;
          break;
        }
        if (text.endsWith(u + hideMark)) {
          text = text.substring(0, text.length - u.length - hideMark.length);
          hide = true;
          tight = true;
          break;
        }
      }
      // 仅匹配。。。：可能回bbb 等标记遮住了 ///，先前。。。再检查。
      if (!tight && text.endsWith(hideMark)) {
        text = text.substring(0, text.length - hideMark.length);
        hide = true;
        for (final u in tightUnits) {
          if (text.endsWith(u)) {
            text = text.substring(0, text.length - u.length);
            tight = true;
            break;
          }
        }
      }
      // 若仍时hideMark，但文本后。。。（如text。。。bbb），先剥 bbb 再检测。
      if (!hide && text.contains(hideMark)) {
        var boldCandidate = false;
        if (text.length >= 3) {
          final tail3 = text.substring(text.length - 3);
          if (tail3 == 'bbb' || tail3 == 'BBB') {
            text = text.substring(0, text.length - 3).trimRight();
            boldCandidate = true;
            bold = true;
          }
        }
        if (boldCandidate) {
          // 再次检测hideMark
          for (final u in tightUnits) {
            if (text.endsWith(hideMark + u)) {
              text =
                  text.substring(0, text.length - hideMark.length - u.length);
              hide = true;
              tight = true;
              break;
            }
            if (text.endsWith(u + hideMark)) {
              text =
                  text.substring(0, text.length - u.length - hideMark.length);
              hide = true;
              tight = true;
              break;
            }
          }
          if (!tight && text.endsWith(hideMark)) {
            text = text.substring(0, text.length - hideMark.length);
            hide = true;
            for (final u in tightUnits) {
              if (text.endsWith(u)) {
                text = text.substring(0, text.length - u.length);
                tight = true;
                break;
              }
            }
          }
          if (hide) text = text.trim();
        }
      }

      // ── 2. 头部 hideMark + tight 检测（对称逻辑，──
      for (final u in tightUnits) {
        if (text.startsWith(hideMark + u)) {
          text = text.substring(hideMark.length + u.length);
          hide = true;
          tight = true;
          break;
        }
        if (text.startsWith(u + hideMark)) {
          text = text.substring(u.length + hideMark.length);
          hide = true;
          tight = true;
          break;
        }
      }
      if (!tight && text.startsWith(hideMark)) {
        text = text.substring(hideMark.length);
        hide = true;
        for (final u in tightUnits) {
          if (text.startsWith(u)) {
            text = text.substring(u.length);
            tight = true;
            break;
          }
        }
      }
      // 头部后。。。但被bbb 遮挡的情内
      if (!hide && text.contains(hideMark)) {
        var boldCandidate = false;
        if (text.length >= 3) {
          final head3 = text.substring(0, 3);
          if (head3 == 'bbb' || head3 == 'BBB') {
            text = text.substring(3).trimLeft();
            boldCandidate = true;
            bold = true;
          }
        }
        if (boldCandidate) {
          for (final u in tightUnits) {
            if (text.startsWith(hideMark + u)) {
              text = text.substring(hideMark.length + u.length);
              hide = true;
              tight = true;
              break;
            }
            if (text.startsWith(u + hideMark)) {
              text = text.substring(u.length + hideMark.length);
              hide = true;
              tight = true;
              break;
            }
          }
          if (!tight && text.startsWith(hideMark)) {
            text = text.substring(hideMark.length);
            hide = true;
            for (final u in tightUnits) {
              if (text.startsWith(u)) {
                text = text.substring(u.length);
                tight = true;
                break;
              }
            }
          }
          if (hide) text = text.trim();
        }
      }

      text = text.trim();
      if (text.isEmpty) continue;

      // ── 3. bbb / BBB 加粗标记（尾部或头部均可，──
      if (!bold && text.length >= 3) {
        final tail3 = text.substring(text.length - 3);
        if (tail3 == 'bbb' || tail3 == 'BBB') {
          text = text.substring(0, text.length - 3).trimRight();
          bold = true;
        } else {
          final head3 = text.substring(0, 3);
          if (head3 == 'bbb' || head3 == 'BBB') {
            text = text.substring(3).trimLeft();
            bold = true;
          }
        }
      }
      if (text.isEmpty) continue;

      _rawLines.add(line.trim());
      if (hide) {
        _hiddenActionParagraphs.add(out.length);
        if (tight) _tightParagraphs.add(out.length);
      }
      if (bold) _boldParagraphs.add(out.length);
      out.add(text);
    }
    // 循环结束后，刷出末尾累积的备注段落（含未闭合的块，
    inNote = false;
    flushNote();
    return out;
  }

  /// 拉取本经所有段落的笔记与完成态（云端）到本地状态。
  Future<void> _loadParagraphNotes() async {
    if (_paraNotesLoading) return;
    setState(() => _paraNotesLoading = true);
    try {
      final items =
          await CloudNotesService.instance.getParagraphNotes(_sutraKey);
      if (!mounted) return;
      setState(() {
        final loadedNotes = <int, List<ParaNote>>{};
        for (final it in items) {
          final idx = it['index'];
          if (idx is! int) continue;
          final list =
              (it['notes'] as List?)?.whereType<ParaNote>().toList() ??
                  const <ParaNote>[];
          if (list.isNotEmpty) loadedNotes[idx] = list;
        }
        _paraNotes = loadedNotes;
        // 画线：仅当云端明确返回underlines 字段时才覆盖本地，避免旧后端/未部置
        // 返回空字段时把刚画好的线冲掉。合并时以各段现有本地值为基础。
        final merged = Map<int, List<Map<String, int>>>.of(_paraUnderlines);
        for (final it in items) {
          final idx = it['index'];
          if (idx is! int) continue;
          if (it['underlines'] is! List) continue; // 旧后端无该字段，保留本地
          final raw = (it['underlines'] as List)
              .whereType<Map>()
              .map((u) => {
                    'start': (u['start'] is int)
                        ? u['start'] as int
                        : int.tryParse('${u['start']}') ?? 0,
                    'end': (u['end'] is int)
                        ? u['end'] as int
                        : int.tryParse('${u['end']}') ?? 0,
                  })
              .where((u) =>
                  (u['start'] ?? 0) >= 0 &&
                  (u['end'] ?? 0) >= (u['start'] ?? 0))
              .toList();
          if (raw.isEmpty) {
            merged.remove(idx);
          } else {
            merged[idx] = raw;
          }
        }
        _paraUnderlines = merged;
        _paraDone = {
          for (final it in items)
            if (it['index'] is int) it['index'] as int: it['done'] == true,
        };
        _paraNotesLoading = false;
        _paraNotesLoaded = true;
      });
      // 为「记录」时间线补齐回填记录的段落原文/ 画线文字（只填空字段）。
      unawaited(RecordIndex.instance.enrichParagraphs(
        sutraKey: _sutraKey,
        paragraphs: _paragraphs,
        rows: items,
      ));
      // 并行加载「哪些段有任意用户感想」（不阻塞主流程）。
      _loadParagraphThoughtsIndicator();
    } catch (e) {
      // 笔记拉取失败不阻塞阅读：保持本地为空，静默降级。
      if (!mounted) return;
      setState(() => _paraNotesLoading = false);
      debugPrint('[reading] 拉取段落笔记失败: $e');
    }
  }

  /// 等待进行中的笔记拉取，必要时补拉一次；返回是否已拿到本地笔记数据。
  /// 段号迁移（排版变化）前必须调用：笔记还没拉到就按旧下标对齐，会漏掉
  /// 云端备注，甚至把已有的本地状态当成「没有笔记」处理掉。
  Future<bool> _ensureParagraphNotesLoaded() async {
    while (_paraNotesLoading && mounted) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted) return false;
    if (_paraNotesLoaded) return true;
    await _loadParagraphNotes();
    if (!mounted) return false;
    return _paraNotesLoaded;
  }

  /// 拉取本经所有有感想（任意用户）的段落下标集合，用于操作栏「所有感想」变绿。
  Future<void> _loadParagraphThoughtsIndicator() async {
    if (!mounted) return;
    try {
      final indices =
          await CloudNotesService.instance.getParagraphsWithThoughts(_sutraKey);
      if (!mounted) return;
      setState(() => _paraHasAnyThought = indices);
    } catch (_) {}
  }

  /// 保存某段备注文本到云端并更新本地状态。
  /// 保存某段全部备注（[notes] 为该段当前所有备注；空列表表示清除该段备注）。
  Future<void> _saveParagraphNote(int index, List<ParaNote> notes,
      {List<Map<String, int>>? underlines}) async {
    if (index < 0 || index >= _paragraphs.length) return;
    // 段落笔记存云端、按用户隔离：未登录直接提示，避免白白弹错误窗。
    if (!AuthService.instance.isLoggedIn) {
      _promptLoginForNotes();
      return;
    }
    final clean = [for (final n in notes) if (!n.isBlank) n];
    setState(() {
      if (clean.isEmpty) {
        _paraNotes.remove(index);
      } else {
        _paraNotes[index] = clean;
      }
      if (underlines != null) {
        if (underlines.isEmpty) {
          _paraUnderlines.remove(index);
        } else {
          _paraUnderlines[index] = underlines;
        }
      }
      _activeNoteParagraphIndex = -1;
    });
    try {
      await CloudNotesService.instance.saveParagraphNote(
        sutraKey: _sutraKey,
        index: index,
        text: _paragraphs[index],
        notes: clean,
        underlines: underlines ?? _paraUnderlines[index] ?? const [],
      );
      // 「记录」时间线：以该段第一条备注作为时间线条目文本。
      // 放在 mounted 判断之前：即便本页已销毁，这条备注也必须进时间线，
      // 否则会出现「云端有、时间线没有」的丢失（重新打开该经才会补上）。
      final primaryText = clean.isNotEmpty ? clean.first.text.trim() : '';
      final synced = <({int start, int end})>[
        for (final u in underlines ?? _paraUnderlines[index] ?? const [])
          (
            start: u['start'] ?? 0,
            end: u['end'] ?? 0,
          ),
      ];
      unawaited(RecordIndex.instance.syncParagraph(
        sutraKey: _sutraKey,
        para: index,
        paraText: _paragraphs[index],
        thought: primaryText,
        underlines: synced,
      ));
      if (!mounted) return;
      _loadParagraphNotes();
    } catch (e) {
      debugPrint('[reading] 保存段落笔记失败: $e');
      if (!mounted) return;
      final msg = e is CloudApiException ? e.message : '网络异常，请稍后重试';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存笔记失败，msg')),
      );
    }
  }

  /// 未登录时点击笔记/勾选读经笔记的统一提示。
  void _promptLoginForNotes() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('登录后才能保存读经感想与画线（跨设备同步），请先在「我的」页面登录')),
    );
  }

  /// 切换某段「已读完/学完」标记并云端同步。
  Future<void> _toggleParagraphDone(int index) async {
    if (index < 0 || index >= _paragraphs.length) return;
    if (!AuthService.instance.isLoggedIn) {
      _promptLoginForNotes();
      return;
    }
    // 若该段属云`。。。//` 连成的一体段簇，则整个簇一起切换完成态。
    final cluster = _connectedTightCluster(index);
    final allDone = cluster.every((k) => _paraDone[k] == true);
    final newDone = !allDone;
    setState(() {
      for (final k in cluster) {
        _paraDone[k] = newDone;
      }
    });
    try {
      for (final k in cluster) {
        await CloudNotesService.instance.toggleParagraphDone(
          sutraKey: _sutraKey,
          index: k,
          text: _paragraphs[k],
          done: newDone,
        );
      }
    } catch (e) {
      debugPrint('[reading] 切换段落完成态失败 $e');
      if (!mounted) return;
      // 失败回滚，避免本地显示与云端不一致。
      setState(() {
        for (final k in cluster) {
          _paraDone[k] = !newDone;
        }
      });
      final msg = e is CloudApiException ? e.message : '网络异常，请稍后重试';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新失败，msg')),
      );
    }
  }

  Future<void> _downloadContent() async {
    if (_isDownloading) return;
    final id = SutraDownloader.extractId(
        widget.title, _resolvedFilePath ?? widget.filePath);
    if (id == null) return;
    // 本地已有完整文件时直接重新加载内容，不重新下载。
    // 防止上游误判 _needsDownload=true（如路径恢复竞态）导致已下载经文被重下。
    if (await SutraDownloader.isDownloaded(id)) {
      if (!mounted) return;
      setState(() {
        _needsDownload = false;
      });
      await _loadContent();
      return;
    }
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
    });
    try {
      await SutraDownloader.download(id, onProgress: (received, total) {
        if (!mounted) return;
        setState(() {
          // 服务器代理的Content-Length 可能不准（压缩、分块传输等），
          // received 会大云total，导致百分比超过 100%，这里夹在[0,1]。
          _downloadProgress =
              total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
        });
      });
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _needsDownload = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载完成')),
      );
      await _loadContent();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败，e')),
      );
    }
  }

  Widget _buildDownloadBanner() {
    if (!_needsDownload) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _isDarkBg ? const Color(0xFF2c2c2c) : AppPalette.p.tintBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: _isDownloading
                ? Text(
                    '下载中…${(_downloadProgress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      color: _isDarkBg ? Colors.white : AppPalette.p.primary,
                      fontSize: 13,
                    ),
                  )
                : Text(
                    '该经文正文未打包，需要联网下载。',
                    style: TextStyle(
                      color: _isDarkBg ? Colors.white : AppPalette.p.primary,
                      fontSize: 13,
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          if (_isDownloading)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: _downloadProgress > 0 ? _downloadProgress : null,
                color: AppPalette.p.accent,
              ),
            )
          else
            SizedBox(
              height: 30,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppPalette.p.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  textStyle: const TextStyle(fontSize: 13),
                ),
                onPressed: _downloadContent,
                child: const Text('下载'),
              ),
            ),
        ],
      ),
    );
  }

  void _scrollToStart() {
    // 用户手动回到顶部后，清除打开时恢复用的进度基准，避免后台延迟触发的
    // 排版更新恢复（_scheduleRestoreScroll）又用陈旧的 _savedProgress 把进度拽回去。
    _savedPosition = null;
    _savedProgress = null;
    _flipPageRestored = true;
    if (_pageMode == ReaderPreferences.pageModeFlip &&
        (_pageController?.hasClients ?? false)) {
      // 左右翻页模式：直接切回第一页（无分页时不触取onPageChanged，需同步状态）。
      final wasAtStart = _currentFlipPage == 0;
      setState(() {
        _currentFlipPage = 0;
        _scrollProgress =
            _flipPages.length > 1 ? 1.0 / _flipPages.length : 1.0;
      });
      if (!wasAtStart) _pageController?.jumpToPage(0);
      _saveFlipProgress();
      return;
    }
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 打开笔记编辑页：预填。经书名」在顶部，可写笔记并发布到菩提空间。
  /// 经名带当前卷标（与顶部标题栏一致，如。地藏菩萨本愿经卷一」），
  /// 广场渲染时卷标会整体并入链接显示，热度榜仍按基础经名聚合。
  void _openNoteEditor() async {
    final display = _titleShown;
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditPage(presetContent: '\$$display '),
      ),
    );
  }

  Future<void> _exportTxt() async {
    final trimmed = _content.trim();
    if (trimmed.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('没有可导出的内容'), duration: Duration(seconds: 2)),
        );
      }
      return;
    }

    final safeTitle = widget.title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '');
    final filename = '$safeTitle.txt';

    // UTF-8 BOM 防乱码
    final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(trimmed)];

    // 优先：用原生保存对话框选择位置，由插件直接写入
    try {
      final savedPath = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          data: Uint8List.fromList(bytes),
          fileName: filename,
          mimeTypesFilter: const ['text/plain'],
        ),
      );
      if (savedPath != null && savedPath.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('已保存：$savedPath'),
                duration: const Duration(seconds: 3)),
          );
        }
        return;
      }
    } catch (_) {
      // ignore and fallback
    }

    // 兜底1：file_picker 保存对话框
    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '导出TXT',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['txt'],
      );
      if (savePath != null &&
          savePath.isNotEmpty &&
          !savePath.startsWith('content:')) {
        final file = File(savePath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('已保存：$savePath'),
                duration: const Duration(seconds: 3)),
          );
        }
        return;
      }
    } catch (_) {
      // ignore
    }

    // 兜底2：保存到应用文档目录
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$filename');
      await file.writeAsBytes(bytes, flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('已保存到应用目录，{file.path}'),
              duration: const Duration(seconds: 4)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('保存失败，e'), duration: const Duration(seconds: 4)),
        );
      }
    }
  }

  Future<void> _markAsRead() async {
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('read_$keyPath', true);
  }

  /// 正文加载完成、且已完成一帧布局后，向上派发一次就绪通知
  /// （供右下角圆形展开路由在动画开始前等待，避免展开过程卡顿）。
  void _notifyContentReadyIfNeeded() {
    if (_contentReadyNotified || _isLoadingContent) return;
    _contentReadyNotified = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      const ReadingContentReadyNotification().dispatch(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    _notifyContentReadyIfNeeded();
    // 单击画线改为在正文Listener 上按几何命中判定（见 _resolveUnderlineHit），
    // 不再依赖 TextSpan 识别器，无需在这里维护识别器生命周期。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // 悬浮菜单展开时，系统返回先收起它。
        if (_showFabMenu) {
          _closeFabMenu();
          return;
        }
        // AI 面板展开时，系统返回先收起它（回到阅读页）；否则正常退出阅读页。
        if (assistantVisible.value) {
          assistantVisible.value = false;
        } else {
          Navigator.of(context).pop();
        }
      },
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
        backgroundColor: Color(ReaderPreferences.bgColors[_bgColorIndex]),
        appBar: AppBar(
          backgroundColor: ReaderPreferences.appBarColor(_bgColorIndex),
          elevation: 0,
          leadingWidth: 48,
          titleSpacing: 0,
          iconTheme: IconThemeData(
              color: _isDarkBg
                  ? Colors.white.withOpacity(0.7)
                  : const Color(0xFF212121)),
          title: GestureDetector(
            onTap: () {
              final now = DateTime.now();
              final last = _lastTitleTap;
              _lastTitleTap = now;
              if (last != null &&
                  now.difference(last) < const Duration(milliseconds: 350)) {
                _scrollToStart();
              }
            },
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: _titleShown));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已复制到剪贴板'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    _titleShown,
                    style: TextStyle(
                      color: _isDarkMode
                          ? Colors.white.withOpacity(0.7)
                          : const Color(0xFF212121),
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_isSutraAdmin && _isLayoutDone)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: _isDarkBg
                            ? const Color(0x33FFD54F)
                            : const Color(0x1A43A047),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: _isDarkBg
                              ? const Color(0x66FFD54F)
                              : const Color(0x6643A047),
                          width: 0.5,
                        ),
                      ),
                      child: Text(
                        '已完成排版',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: _isDarkBg
                              ? const Color(0xFFFFD54F)
                              : const Color(0xFF43A047),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                icon: const Icon(Icons.search, size: 18),
                onPressed: _toggleSearch,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                splashRadius: 16,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  icon: const Icon(Icons.more_horiz, size: 20),
                  onPressed: _toggleMoreMenu,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  splashRadius: 16,
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Listener(
            onPointerDown: (event) {
              if (_showMoreMenu && !_isPointerInsideMenu(event.position)) {
                // 标记这次点击是用来收起菜单的，内容区收到抬起后不弹面板。
                _menuOpenAtDown = true;
                setState(() {
                  _showMoreMenu = false;
                });
              }
              if (_showStylePanel &&
                  !_isPointerInsideStylePanel(event.position)) {
                // 标记这次点击是用来收起阅读设置面板的：只收起面板，
                // 抬起后内容区不再弹「画线感想/笔记」速览面板。
                _stylePanelDismissAtDown = true;
                setState(() {
                  _showStylePanel = false;
                });
              }
            },
            child: Stack(
              children: [
                Column(
                  children: [
                    if (_showSearchBar)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        color: Colors.transparent,
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                decoration: InputDecoration(
                                  hintText: '搜索内容',
                                  hintStyle: const TextStyle(
                                    color: Color(0xFF999999),
                                    fontSize: 14,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: _isDarkBg
                                        ? BorderSide.none
                                        : const BorderSide(
                                            color: Color(0xFFD9D9D9), width: 1),
                                  ),
                                  filled: true,
                                  fillColor: Colors.white,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  isDense: true,
                                ),
                                style: const TextStyle(
                                  color: Color(0xFF212121),
                                  fontSize: 14,
                                ),
                                onChanged: _performSearch,
                              ),
                            ),
                            if (_searchMatches.isNotEmpty)
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12),
                                    child: Text(
                                      '${_currentMatchIndex + 1}/${_searchMatches.length}',
                                      style: TextStyle(
                                        color: _isDarkBg
                                            ? Colors.white.withOpacity(0.7)
                                            : const Color(0xFF212121),
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.keyboard_arrow_up,
                                        size: 20),
                                    onPressed: _goToPreviousMatch,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.keyboard_arrow_down,
                                        size: 20),
                                    onPressed: _goToNextMatch,
                                  ),
                                ],
                              ),
                            if (_searchMatches.isEmpty &&
                                _searchController.text.isNotEmpty)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                child: Text(
                                  '无匹配',
                                  style: TextStyle(
                                    color: _isDarkBg
                                        ? Colors.white.withOpacity(0.7)
                                        : const Color(0xFF212121),
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    _buildDownloadBanner(),
                    Expanded(
                      child: Listener(
                        onPointerDown: (event) {
                          // 注意：此处绝不重置_actionRowTapped —…
                          // 指针事件按「从内到外」派发，操作栏的内层 Listener
                          // 先把标记置true，若这里再清掉，onPointerUp 就拦不住了。
                          _pointerDownPos = event.position;
                          _longPressActive = false;
                          // 记录按下时文字是否已选中 / 长按浮层是否已打开，
                          // 若是，则这次点击用于「收起选中/菜单」，不得弹出底部面板。
                          // 擦除等浮层菜单只连_activeMenuEntries（不记_selectionMenuEntry），
                          // 因此画_activeMenuEntries 一并覆盖：首点只关菜单，二次点击才弹面板。
                          _selectionActiveAtDown =
                              _selectionMenuEntry != null ||
                                  _activeMenuEntries.isNotEmpty ||
                                  _hasTextSelection;
                          // 300ms 后若手指仍未抬起，视为长按（文字选择）。
                          Future.delayed(const Duration(milliseconds: 300), () {
                            if (_pointerDownPos != null && mounted) {
                              _longPressActive = true;
                            }
                          });
                        },
                        // 指针被系统打断（来电/手势竞争）时清掉标记，避免残留。
                        onPointerCancel: (_) {
                          _actionRowTapped = false;
                        },
                        onPointerUp: (event) {
                          // 段落操作栏（AI读笔记/方框）拦截：阻止触发面板。
                          if (_actionRowTapped) {
                            _actionRowTapped = false;
                            // 同步清理按下状态，避免残留影响 300ms 长按计时器。
                            _pointerDownPos = null;
                            _longPressActive = false;
                            _selectionActiveAtDown = false;
                            return;
                          }
                          // 记下按下时是否是「收菜单」的点击（由外层 Listener 设置）。
                          final menuOpenAtDown = _menuOpenAtDown;
                          _menuOpenAtDown = false;
                          // 记下按下时是否是「收阅读设置面板」的点击（由外层 Listener 设置）。
                          final styleDismissAtDown = _stylePanelDismissAtDown;
                          _stylePanelDismissAtDown = false;
                          final downPos = _pointerDownPos;
                          _pointerDownPos = null;
                          // 长按或滑动均不触发面板。
                          if (_longPressActive) {
                            _longPressActive = false;
                            _selectionActiveAtDown = false;
                            return;
                          }
                          if (downPos != null &&
                              (event.position - downPos).distance > 10) return;
                          // 按下时菜单是展开的→这次点击是收菜单，不弹面板。
                          if (menuOpenAtDown) return;
                          // 按下时阅读设置面板展开、点在面板外 →这次点击是收面板，
                          // 不弹「画线感想/笔记」速览面板（模式切换后收起设置不误弹）。
                          if (styleDismissAtDown) return;
                          // 按下时正文正有文字被选中 / 长按浮层菜单打开 →
                          // 这次点击是「取消选中 / 收起浮层」，不弹出底部面板。
                          if (_selectionActiveAtDown || _hasTextSelection) {
                            _selectionActiveAtDown = false;
                            return;
                          }
                          // 延迟到事件分发结束后再决定面板：单击画线的判定完全按
                          // 几何命中（_resolveUnderlineHit），不依赖手势竞技场时序，
                          // 避免「有时弹擦除卡片、有时弹底部面板」的时好时坏。
                          Timer.run(() {
                            if (!mounted) return;
                            setState(() {
                              if (_showMoreMenu) {
                                _showMoreMenu = false;
                              } else if (_showStylePanel) {
                                _showStylePanel = false;
                              } else if (_showSearchBar) {
                                _showSearchBar = false;
                                _searchController.clear();
                                _searchMatches.clear();
                                _currentMatchIndex = 0;
                              }
                            });
                            // 点击画线段落：按几何命中决定行为。
                            //  - 命中画线文字 →只弹「擦除」小菜单，不弹底部面板；
                            //  - 命中带画线的段落（但不在画线文字上）→不弹任何面板，
                            //  - 纯正文段落→弹底部画线/感想/阅读设置 面板。
                            final hit = _resolveUnderlineHit(event.position);
                            if (hit != null) {
                              if (hit.start >= 0) {
                                _showUnderlineMenu(hit.cluster, hit.para,
                                    hit.start, hit.end, event.position);
                              }
                              return;
                            }
                            _openQuickPanel();
                          });
                        },
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            if (_isLoadingContent) {
                              return const Center(
                                  child: CircularProgressIndicator());
                            }
                            if (_pageMode == ReaderPreferences.pageModeFlip &&
                                _searchController.text.isEmpty) {
                              final pages = _getFlipPages(
                                  constraints.maxWidth, constraints.maxHeight);
                              return PageView.builder(
                                controller: _pageController,
                                itemCount: pages.length,
                                onPageChanged: _onFlipPageChanged,
                                itemBuilder: (context, index) =>
                                    _buildFlipPage(pages[index], index),
                              );
                            }
                            return SingleChildScrollView(
                              key: _scrollViewKey,
                              controller: _scrollController,
                              child: _searchController.text.isEmpty
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        for (final group in _allClusterGroups())
                                          _buildClusterParagraph(group,
                                              showUnaligned: true),
                                      ],
                                    )
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        for (final group in _allClusterGroups())
                                          _buildClusterParagraph(group,
                                              showUnaligned: false),
                                      ],
                                    ),
                            );
                          },
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                      // 进度条单独监听 notifier：滚动只重建这一行，
                      // 不触发整篇正文的 build + 全文重排版。
                      child: ValueListenableBuilder<double>(
                        valueListenable: _scrollProgressListenable,
                        builder: (context, progress, _) => Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                    AppPalette.instance.isPlain && !_isDarkBg
                                        ? 2
                                        : 3),
                                child: LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 5,
                                  backgroundColor: _isDarkBg
                                      ? Colors.white.withOpacity(0.15)
                                      : AppPalette.instance.isPlain
                                          ? AppPalette.p.border
                                          : const Color(0xFFE8D9C4),
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      !_isDarkBg && AppPalette.instance.isPlain
                                          ? const Color(0xFF4A4A4A)
                                          : AppPalette.p.accent),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${(progress * 100).toStringAsFixed(1)}%',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _isDarkBg
                                    ? Colors.white.withOpacity(0.7)
                                    : AppPalette.p.textSec,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (_showMoreMenu)
                  Positioned(
                    key: const ValueKey('more_menu'),
                    top: 4,
                    right: 16,
                    child: Material(
                      key: _moreMenuKey,
                      elevation: 6,
                      borderRadius: BorderRadius.circular(12),
                      color: _isDarkBg ? const Color(0xFF2c2c2c) : Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_isSutraAdmin)
                              _buildMoreMenuItem(
                                icon: const Icon(Icons.warning_amber_rounded,
                                    size: 18, color: Color(0xFFE53935)),
                                label: '编辑经文',
                                onTap: _openEditor,
                              ),
                            if (_isSutraAdmin)
                              _buildMoreMenuItem(
                                icon: Icon(
                                  _isLayoutDone
                                      ? Icons.check_circle
                                      : Icons.check_circle_outline,
                                  size: 18,
                                  color: _isLayoutDone
                                      ? (_isDarkBg
                                          ? const Color(0xFFFFD54F)
                                          : const Color(0xFF43A047))
                                      : null,
                                ),
                                label: '完成排版',
                                onTap: _toggleLayoutDone,
                              ),
                            if (_isSutraAdmin && _isLayoutDone)
                              _buildMoreMenuItem(
                                icon: const Icon(Icons.undo_rounded,
                                    size: 18, color: Color(0xFFE53935)),
                                label: '撤销完成排版',
                                onTap: _toggleLayoutUndone,
                              ),
                            _buildMoreMenuItem(
                              icon:
                                  const Icon(Icons.settings_outlined, size: 18),
                              label: '阅读设置',
                              onTap: _openReadingSettings,
                            ),
                            _buildMoreMenuItem(
                              icon: Icon(
                                _isFavorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                size: 18,
                              ),
                              label: _isFavorite ? '取消收藏' : '收藏',
                              onTap: _toggleFavorite,
                            ),
                            _buildMoreMenuItem(
                              icon: Icon(
                                _isReadLater
                                    ? Icons.bookmark
                                    : Icons.bookmark_border,
                                size: 18,
                              ),
                              label: _isReadLater ? '取消稍后阅读' : '稍后阅读',
                              onTap: _toggleReadLater,
                            ),
                            _buildMoreMenuItem(
                              icon: Icon(
                                _isRead
                                    ? Icons.mark_chat_read
                                    : Icons.mark_chat_unread,
                                size: 18,
                              ),
                              label: _isRead ? '取消完成' : '标记完成',
                              onTap: _toggleRead,
                            ),
                            _buildMoreMenuItem(
                              icon: const Icon(Icons.help_outline, size: 18),
                              label: '使用说明',
                              onTap: _openUsageGuide,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_showFabMenu)
                  // 展开悬浮菜单时，点菜单外任意位置收起（吞掉点击，避免触发正文）。
                  Positioned.fill(
                    key: const ValueKey('fab_overlay'),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _closeFabMenu,
                    ),
                  ),
                // 悬浮球层：铺满阅读区，内部按当前圆心摆放悬浮球与其弧线菜单。
                Positioned.fill(
                  key: const ValueKey('fab_layer'),
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        _buildFabMenu(constraints),
                  ),
                ),
                if (_showStylePanel) ...[
                  // 阅读设置面板打开时，点阅读区任意位置收起。
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () => setState(() => _showStylePanel = false),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      key: _stylePanelKey,
                      child: _buildReadingSettingsPanel(),
                    ),
                  ),
                ],
                if (_showQuickPanel) ...[
                  // 速览面板打开时，点面板外任意位置收起。
                  // opaque：吞掉点击，避免下层正文的单击处理再弹面板。
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _showQuickPanel = false),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _buildQuickPanel(),
                  ),
                ],
              ],
              ),
            ),
        ),
    );
  }

  /// 判断点击位置是否落在「⋯」展开菜单内。
  bool _isPointerInsideMenu(Offset position) {
    final ctx = _moreMenuKey.currentContext;
    if (ctx == null) return false;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return false;
    final local = box.globalToLocal(position);
    return local.dx >= 0 &&
        local.dy >= 0 &&
        local.dx <= box.size.width &&
        local.dy <= box.size.height;
  }

  /// 判断点击位置是否落在「阅读设置」面板内。
  bool _isPointerInsideStylePanel(Offset position) {
    final ctx = _stylePanelKey.currentContext;
    if (ctx == null) return false;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return false;
    final local = box.globalToLocal(position);
    return local.dx >= 0 &&
        local.dy >= 0 &&
        local.dx <= box.size.width &&
        local.dy <= box.size.height;
  }

  void _toggleSearch() {
    setState(() {
      _showSearchBar = !_showSearchBar;
      if (!_showSearchBar) {
        _searchController.clear();
        _searchMatches.clear();
        _currentMatchIndex = 0;
      }
    });
  }

  void _toggleTheme() {
    setState(() {
      _isDarkMode = !_isDarkMode;
    });
    appDarkMode.value = _isDarkMode;
    _saveSettings();
  }

  void _toggleMoreMenu() {
    if (_showMoreMenu) {
      // 菜单已打开 →关闭菜单。
      setState(() {
        _showMoreMenu = false;
      });
    } else {
      // 正常打开菜单
      setState(() {
        _showMoreMenu = true;
      });
    }
  }

  /// 切换翻页样式（纵向滚动/ 左右翻页）：
  /// 切换前把当前进度作为另一模式的定位基准，保证切换后进度不回退到开头。
  void _switchPageMode(int mode) {
    if (mode == _pageMode) return;
    _savedProgress = _scrollProgress;
    setState(() {
      _pageMode = mode;
    });
    ReaderPreferences.setPageMode(mode);
    // 切回纵向滚动时按当前进度重新定位。
    if (mode == ReaderPreferences.pageModeScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scheduleRestoreScroll();
      });
      return;
    }
    // 进入翻页模式：按当前进度定位到对应页（分页数据在首帧渲染后已就绪）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_flipPages.length > 1 && (_pageController?.hasClients ?? false)) {
        final target = (_savedProgress! * _flipPages.length)
            .floor()
            .clamp(0, _flipPages.length - 1);
        _pageController?.jumpToPage(target);
        _flipPageRestored = true;
        setState(() {
          _currentFlipPage = target;
          _scrollProgress = (target + 1) / _flipPages.length;
        });
      }
    });
  }

  /// 打开「使用说明」页面。
  void _openUsageGuide() {
    setState(() {
      _showMoreMenu = false;
    });
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ReadingGuidePage()),
    );
  }

  /// 加载当前经书收藏状态（菜单图标/文字随状态切换）。
  Future<void> _loadFavoriteState() async {
    final fav = await SutraFavorites.isFavorite(
        widget.title, _resolvedFilePath ?? widget.filePath);
    if (mounted) {
      setState(() {
        _isFavorite = fav;
      });
    }
  }

  /// 收藏 / 取消收藏当前经书，并同步到「我的收藏」。
  Future<void> _toggleFavorite() async {
    final nowFav = await SutraFavorites.toggle(
        widget.title, _resolvedFilePath ?? widget.filePath);
    if (!mounted) return;
    setState(() {
      _showMoreMenu = false;
      _isFavorite = nowFav;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nowFav ? '已收藏，可在「我的收藏」中查看' : '已取消收藏'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 获取当前视口顶部可见段落的原始文本（用于编辑页定位同步）。
  String? _topVisibleParagraphText() {
    if (!_scrollController.hasClients || _rawLines.isEmpty) return null;
    try {
      final scrollBox =
          _scrollViewKey.currentContext?.findRenderObject() as RenderBox?;
      if (scrollBox == null) return null;
      final viewportTop = scrollBox.localToGlobal(Offset.zero).dy;
      final groups = _allClusterGroups();
      for (final group in groups) {
        final key = _paraTapKeys[group.first];
        final box = key?.currentContext?.findRenderObject() as RenderBox?;
        if (box == null) continue;
        final pos = box.localToGlobal(Offset.zero);
        if (pos.dy >= viewportTop - 2) {
          if (group.first < _rawLines.length) {
            final text = _rawLines[group.first];
            return text.trim().isNotEmpty ? text.trim() : null;
          }
        }
      }
      // 兜底：返回第一个段落
      if (groups.isNotEmpty && groups.first.first < _rawLines.length) {
        final text = _rawLines[groups.first.first];
        return text.trim().isNotEmpty ? text.trim() : null;
      }
    } catch (_) {}
    return null;
  }

  /// 按段落文本在阅读页中定位并滚动到对应位置。
  Future<void> _scrollToText(String? targetText) async {
    if (targetText == null || targetText.trim().isEmpty) return;
    // 取前 15 个非空字符做子串匹配，兼容编辑页/阅读页微小差异。
    final key = targetText.trim().replaceAll(RegExp(r'\s+'), '');
    if (key.length < 5) return;
    final searchKey = key.substring(0, 15.clamp(0, key.length));
    final matches = <int>[];
    for (var i = 0; i < _paragraphs.length; i++) {
      final normalized = _paragraphs[i].trim().replaceAll(RegExp(r'\s+'), '');
      if (normalized.startsWith(searchKey)) matches.add(i);
    }
    if (matches.isEmpty || matches.length > 1) return; // 找不到或不唯一，回退到百分比
    final paraIdx = matches[0];
    // 找到该段落所在cluster 的GlobalKey，获取其像素位置。
    final groups = _allClusterGroups();
    int? groupIdx;
    for (var g = 0; g < groups.length; g++) {
      if (groups[g].contains(paraIdx)) {
        groupIdx = g;
        break;
      }
    }
    if (groupIdx == null) return;
    final paraKey = _paraTapKeys[groups[groupIdx].first];
    final box = paraKey?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final targetOffset = box.localToGlobal(Offset.zero).dy;
    final scrollBox =
        _scrollViewKey.currentContext?.findRenderObject() as RenderBox?;
    if (scrollBox == null) return;
    final viewportTop = scrollBox.localToGlobal(Offset.zero).dy;
    final newOffset = _scrollController.offset + targetOffset - viewportTop;
    await _scrollController.animateTo(
      newOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// 管理员「编辑经文」：打开编辑页，保存后同步最新排版到云端 / GitHub。
  Future<void> _openEditor() async {
    final filePath = _resolvedFilePath ?? widget.filePath;
    if (filePath == null) return;
    setState(() => _showMoreMenu = false);
    final topText = _topVisibleParagraphText();
    // 排版编辑会增删/合并段落，段号随之平移：先留一份旧段落快照，
    // 保存返回后按原文把备注/画线/完成态重新对齐到新段号，否则备注会错位。
    final oldParagraphs = List<String>.from(_paragraphs);
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => SutraEditPage(
          title: widget.title,
          initialTitle: _titleShown,
          content: _content,
          keyPath: filePath,
          scrollProgress: _scrollProgress,
          topParagraphText: topText,
        ),
      ),
    );
    if (result == null || !mounted) return;
    // 标题订正：同步到本地覆盖表 + 云端，立即刷新标题显示（正文未变也处理）。
    if (result['titleChanged'] == true) {
      await _saveEditedTitle((result['title'] as String?)?.trim() ?? '');
      if (!mounted) return;
    }
    if (result['changed'] != true) return;
    // 笔记要趁段落还是旧版时拉到本地：拉回来的下标对应旧段号，
    // 等新内容加载完再拉就会拿新段去回填时间线原文，填出错位的文字。
    await _ensureParagraphNotesLoaded();
    if (!mounted) return;
    // 编辑页保存后，阅读页保持当前进度不变（不覆盖为编辑页光标位置）。
    // 同步最新进度，避免 _loadContent 恢复时用 initState 读取的过本
    // _savedProgress，导致从编辑页返回后进度回退到开头附近。
    _savedPosition = null;
    _savedProgress = _scrollProgress;
    _flipCacheKey = '';
    _flipPages = [];
    _flipPageRestored = false;
    await _loadContent();
    if (!mounted) return;
    if (_isSameParagraphs(oldParagraphs, _paragraphs)) return; // 段号未变
    await _applyUpdatedLayout(oldParagraphs, _content);
  }

  /// 管理员订正经名：写本地覆盖表（立即生效）并同步云端，供所有用户套用。
  /// 空标题表示清除覆盖，恢复目录原始经名。
  Future<void> _saveEditedTitle(String newTitle) async {
    final keyPath = _resolvedFilePath ?? widget.filePath;
    final id = SutraDownloader.extractId(widget.title, keyPath);
    if (id == null || id.isEmpty) return;
    await SutraTitleOverrides.setLocal(id, newTitle);
    if (mounted) setState(() {});
    try {
      await CloudNotesService.instance.saveSutraTitle(id, newTitle);
      _toast('标题已更新');
    } catch (_) {
      _toast('标题已保存到本地，云端同步稍后重试');
    }
  }

  /// 两份段落列表是否完全一致（内容与段数都没变，则段号无需迁移）。
  bool _isSameParagraphs(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 普通用户自动检查并应用最新排版（静默执行，不弹提示）。
  /// 在initState 中确定非管理员身份后调用。
  Future<void> _autoCheckAndApplyLayout() async {
    // 等待内容加载完成后再检查。
    while (_isLoadingContent && mounted) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted) return;
    final filePath = _resolvedFilePath ?? widget.filePath;
    final id = SutraDownloader.extractId(widget.title, filePath);
    if (id == null || id.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final verKey = 'sutra_edit_ver_$id';
    final meta = await CloudNotesService.instance.sutraEditMeta(id);
    final remoteAt = (meta?['updatedAt'] as num?)?.toInt() ?? 0;
    final localAt = prefs.getInt(verKey) ?? 0;
    debugPrint('[排版检查] id=$id meta=$meta remoteAt=$remoteAt localAt=$localAt');
    if (remoteAt <= 0 || remoteAt <= localAt) {
      debugPrint('[排版检查] 无需更新 remoteAt=$remoteAt localAt=$localAt');
      return;
    }
    debugPrint('[排版检查] 检测到云端有新版，开始下载编辑版');
    // 有新版：任GitHub 直接拉取编辑版内容，避免 CDN 未缓存导致回退到原始版。
    final oldParagraphs = List<String>.from(_paragraphs);
    try {
      final vol = id.substring(0, 3);
      final editedUrl =
          'https://raw.githubusercontent.com/dalidakun/huideng/main/assets/sutras_edited/$vol/$id.txt';
      String? content;
      try {
        final resp = await _httpGet(editedUrl);
        if (resp != null && resp.isNotEmpty) content = resp;
      } catch (_) {}
      // 备用：通过 GitHub 代理镜像拉取
      if (content == null || content.isEmpty) {
        final proxies = [
          'https://ghfast.top/https://raw.githubusercontent.com/dalidakun/huideng/main/assets/sutras_edited/$vol/$id.txt',
          'https://gh-proxy.com/https://raw.githubusercontent.com/dalidakun/huideng/main/assets/sutras_edited/$vol/$id.txt',
        ];
        for (final p in proxies) {
          try {
            final resp = await _httpGet(p);
            if (resp != null && resp.isNotEmpty) {
              content = resp;
              break;
            }
          } catch (_) {}
        }
      }
      if (content == null || content.isEmpty) return; // 无法获取编辑版，不覆盖当前内容。
      if (!mounted) return;
      await prefs.setInt(verKey, remoteAt);
      // 保存到本地编辑副本，后续打开直接读取。
      final editedPath = await editedSutraFilePath(filePath!);
      if (editedPath != null) await File(editedPath).writeAsString(content);
      await _applyUpdatedLayout(oldParagraphs, content);
    } catch (_) {
      // 静默失败，不打扰用户。
    }
  }

  /// 简是HTTP GET，返回响底body；失败返回null。
  static Future<String?> _httpGet(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      return await resp.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    } finally {
      client.close(force: false);
    }
  }

  /// 非管理员「更新排版」：任GitHub / 云端拉取管理员编辑的最新排版并覆盖本地。
  /// 若本地已有更好（更新）的版本则提示「此版已是最新版本」。
  Future<void> _checkSutraUpdate() async {
    setState(() => _showMoreMenu = false);
    final filePath = _resolvedFilePath ?? widget.filePath;
    final id = SutraDownloader.extractId(widget.title, filePath);
    if (id == null || id.isEmpty) {
      _toast('此经书不支持更新排版');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final verKey = 'sutra_edit_ver_$id';
    final meta = await CloudNotesService.instance.sutraEditMeta(id);
    final remoteAt = (meta?['updatedAt'] as num?)?.toInt() ?? 0;
    final localAt = prefs.getInt(verKey) ?? 0;
    if (remoteAt <= 0 || remoteAt <= localAt) {
      _toast('此版已是最新版本');
      return;
    }

    // 保存旧段落快照用于感想画线对齐，再下载新版内容。
    final oldParagraphs = List<String>.from(_paragraphs);
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
    });
    try {
      // 直接任GitHub 拉取编辑版内容，避免 CDN 回退到原始版。
      final vol = id.substring(0, 3);
      final urls = [
        'https://raw.githubusercontent.com/dalidakun/huideng/main/assets/sutras_edited/$vol/$id.txt',
        'https://ghfast.top/https://raw.githubusercontent.com/dalidakun/huideng/main/assets/sutras_edited/$vol/$id.txt',
        'https://gh-proxy.com/https://raw.githubusercontent.com/dalidakun/huideng/main/assets/sutras_edited/$vol/$id.txt',
      ];
      String? content;
      for (final u in urls) {
        try {
          final resp = await _httpGet(u);
          if (resp != null && resp.isNotEmpty) {
            content = resp;
            break;
          }
        } catch (_) {}
      }
      if (content == null || content.isEmpty) {
        throw Exception('无法获取编辑版');
      }
      if (!mounted) return;
      await prefs.setInt(verKey, remoteAt);
      // 保存到本地编辑副本。
      final editedPath = await editedSutraFilePath(filePath!);
      if (editedPath != null) await File(editedPath).writeAsString(content);
      await _applyUpdatedLayout(oldParagraphs, content);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isDownloading = false);
      _toast('更新排版失败，请检查网络后重试');
    }
  }

  /// 应用更新后的排版：替换内容 + 把旧段的备注/画线/完成态按原文重新对齐到新段。
  /// [oldParagraphs] 为更新前的段落列表。
  Future<void> _applyUpdatedLayout(
      List<String> oldParagraphs, String newContent) async {
    // 先把笔记拉到本地（等进行中的拉取）：笔记还没就绪就按旧下标迁移，
    // 会漏掉云端备注；此时 [_paragraphs] 仍是旧版，拉取回来的下标才对得上。
    final notesReady = await _ensureParagraphNotesLoaded();
    if (!mounted) return;
    // 换成新排版：正文与「隐藏操作栏 / 不分段 / 加粗」等按下标重算。
    setState(() {
      _content = newContent;
      _paragraphs = _parseParagraphs(newContent);
      _isLoadingContent = false;
      _isDownloading = false;
      _unalignedIndices = {};
    });
    // 笔记拉取失败（多为断网）：不按「空表」迁移，避免误删已有数据。
    if (!notesReady) return;

    // 对齐：遍历旧段落中「有备注 / 有画线/ 已完成」的段落，按原文在新段里找包含它的段。
    final affectedOld = <int>{
      ..._paraNotes.keys,
      ..._paraUnderlines.keys,
      ..._paraDone.keys,
    };
    // 没有可迁移的笔记：云端与时间线都不动（避免按空表清掉已有条目）。
    if (affectedOld.isEmpty) return;
    final aligned = alignParagraphAnnotations(
      oldParagraphs: oldParagraphs,
      paragraphs: _paragraphs,
      notes: _paraNotes,
      underlines: _paraUnderlines,
      done: _paraDone,
    );

    setState(() {
      _paraNotes = aligned.notes;
      _paraUnderlines = aligned.underlines;
      _paraDone = aligned.done;
      _unalignedIndices = aligned.unmigratedOld;
    });

    // 写回云端：删除旧 index 记录，用文index 重写，保证跨设备一致。
    await _writeBackAlignedParagraphNotes(aligned.notes, aligned.underlines,
        aligned.done, affectedOld, aligned.unmigratedOld);

    if (!mounted) return;
    // 以用户当前实际进度为恢复基准（而非打开页面时读到的过期值），
    // 否则排版更新完成后会把已拖回顶部（或已滚动到别处）的进度拽回旧位置。
    _savedPosition = null;
    _savedProgress = _scrollProgress;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scheduleRestoreScroll());
  }

  /// 更新排版后把对齐结果写回云端（删除旧 index、写入新 index）。
  Future<void> _writeBackAlignedParagraphNotes(
    Map<int, List<ParaNote>> notes,
    Map<int, List<Map<String, int>>> underlines,
    Map<int, bool> done,
    Set<int> oldIndices,
    Set<int> unmigratedOld,
  ) async {
    // 删除所有旧 index 的云端记录（含未能对齐、保留在原index 的）。
    for (final oldIdx in oldIndices) {
      try {
        await CloudNotesService.instance
            .deleteParagraphNote(sutraKey: _sutraKey, index: oldIdx);
      } catch (_) {}
    }
    // 用新 index 重写。备注/画线/完成态任一有数据的段都要重写：
    // 只遍历备注表的话，「只有画线」的段在上面删除后就丢了。
    final newIndices = <int>{...notes.keys, ...underlines.keys, ...done.keys};
    for (final newIdx in newIndices.toList()..sort()) {
      if (newIdx < 0 || newIdx >= _paragraphs.length) continue;
      final noteList = notes[newIdx] ?? const <ParaNote>[];
      final under = underlines[newIdx] ?? const <Map<String, int>>[];
      final isDone = done[newIdx] == true;
      if (noteList.isEmpty && under.isEmpty && !isDone) continue;
      final text = _paragraphs[newIdx];
      try {
        await CloudNotesService.instance.saveParagraphNote(
          sutraKey: _sutraKey,
          index: newIdx,
          text: text,
          notes: noteList,
          underlines: under,
        );
      } catch (_) {}
      // 云端行删除重建后默认 done=false，完成态要单独补写。
      if (isDone) {
        try {
          await CloudNotesService.instance.toggleParagraphDone(
              sutraKey: _sutraKey, index: newIdx, text: text, done: true);
        } catch (_) {}
      }
    }
    // 未对齐的段在新段里保留原 index 位置并重新保存（保留数据提示用）。
    if (unmigratedOld.isNotEmpty) {
      await _loadParagraphNotes();
    }
    // 「记录」时间线：段号已整体重排，按新段号重建本经的画线/感想条目。
    // 时间线每段一条，取其第一条备注正文。
    final primaryNotes = <int, String>{
      for (final e in notes.entries)
        e.key: e.value.isNotEmpty ? e.value.first.text.trim() : '',
    };
    unawaited(RecordIndex.instance.resyncSutra(
      sutraKey: _sutraKey,
      paragraphs: _paragraphs,
      notes: primaryNotes,
      underlines: underlines,
    ));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 加载当前经书稍后阅读状态。
  Future<void> _loadReadLaterState() async {
    final rl = await SutraReadLater.isReadLater(
        widget.title, _resolvedFilePath ?? widget.filePath);
    if (mounted) {
      setState(() {
        _isReadLater = rl;
      });
    }
  }

  /// 标记 / 取消稍后阅读当前经书。
  Future<void> _toggleReadLater() async {
    final nowRL = await SutraReadLater.toggle(
        widget.title, _resolvedFilePath ?? widget.filePath);
    if (!mounted) return;
    setState(() {
      _showMoreMenu = false;
      _isReadLater = nowRL;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nowRL ? '已标记稍后阅读' : '已取消稍后阅读'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 加载当前经书排版完成标记（管理员本机记录，仅管理员显示）。
  Future<void> _loadLayoutDoneState() async {
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath == null) return;
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool('sutra_layout_done_$keyPath') ?? false;
    if (done) {
      if (mounted) setState(() => _isLayoutDone = true);
      return;
    }
    // 本地无标记时，检查云端是否有管理员排版（重装后SharedPreferences 清空）。
    final id = SutraDownloader.extractId(widget.title, keyPath);
    if (id != null && id.isNotEmpty) {
      try {
        final meta = await CloudNotesService.instance.sutraEditMeta(id);
        final remoteFound = meta != null && meta['found'] == true;
        if (remoteFound) {
          if (mounted) setState(() => _isLayoutDone = true);
          // 同步恢复本地标记，避免下次仍需查云端。
          await prefs.setBool('sutra_layout_done_$keyPath', true);
        }
      } catch (_) {}
    }
  }

  /// 管理员点击「完成排版」：标记该经排版已完成，同步到云端供所有用户自动获取最新版。
  Future<void> _toggleLayoutDone() async {
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath == null) return;
    setState(() {
      _showMoreMenu = false;
      _isLayoutDone = true;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sutra_layout_done_$keyPath', true);
    // 将最终排版同步到云端 / GitHub，普通用户自动获取最新版。
    final id = SutraDownloader.extractId(widget.title, keyPath);
    if (id != null && id.isNotEmpty) {
      try {
        await CloudNotesService.instance.saveSutraEdit(id, _content);
      } catch (_) {}
    }
    _toast('已完成排版');
  }

  /// 管理员撤销「完成排版」：只删除云端编辑版（GitHub 文件 + 云端记录）。
  /// 保留本地编辑副本和当前显示内容，方便在撤销的基础上继续编辑后重新上传。
  /// 用于误点「完成排版」导致云端保存的不是最终版的情形。
  Future<void> _toggleLayoutUndone() async {
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销完成排版'),
        content:
            const Text('将删除云端已保存的排版版本，该经恢复为未排版状态。\n本地编辑副本会保留，可继续编辑后重新上传。确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定撤销'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _showMoreMenu = false);
    _toast('正在撤销…');
    final prefs = await SharedPreferences.getInstance();
    final id = SutraDownloader.extractId(widget.title, keyPath);
    if (id != null && id.isNotEmpty) {
      try {
        await CloudNotesService.instance.deleteSutraEdit(id);
      } catch (_) {
        _toast('撤销失败，请检查网络后重试');
        return;
      }
      try {
        await prefs.remove('sutra_edit_ver_$id');
      } catch (_) {}
    }
    // 只清除「已完成」标记，保留本地编辑副本（供继续编辑）。
    await prefs.remove('sutra_layout_done_$keyPath');
    if (!mounted) return;
    setState(() => _isLayoutDone = false);
    _toast('已撤销完成排版');
  }

  /// 加载当前经书阅读完成状态。
  Future<void> _loadReadState() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (!await f.exists()) return;
      final list = (jsonDecode(await f.readAsString()) as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final title = widget.title;
      final idx = list.indexWhere((e) => e['title'] == title);
      if (idx >= 0 && list[idx]['isRead'] == true) {
        if (mounted) setState(() => _isRead = true);
      }
    } catch (_) {}
  }

  /// 标记完成 / 取消标记完成当前经书。
  Future<void> _toggleRead() async {
    final title = widget.title;
    final docs = await getApplicationDocumentsDirectory();
    final f = File('${docs.path}${Platform.pathSeparator}sutras_list.json');
    var list = <Map<String, dynamic>>[];
    if (await f.exists()) {
      try {
        list = (jsonDecode(await f.readAsString()) as List<dynamic>)
            .cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    final idx = list.indexWhere((e) => e['title'] == title);
    final wasRead = idx >= 0 && list[idx]['isRead'] == true;
    final newRead = !wasRead;
    if (idx >= 0) {
      list[idx]['isRead'] = newRead;
      list[idx]['readTime'] = newRead ? DateTime.now().toIso8601String() : null;
    } else {
      list.add({
        'title': title,
        'size': '',
        'charCount': 0,
        'isPinned': false,
        'isRead': true,
        'isFavorite': false,
        'filePath': _resolvedFilePath ?? widget.filePath,
        'folder': null,
        'favoriteTime': null,
        'readTime': DateTime.now().toIso8601String(),
      });
    }
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(list), flush: true);
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
    await SutraFavorites.syncStatePref(title);
    if (!mounted) return;
    setState(() {
      _showMoreMenu = false;
      _isRead = newRead;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(newRead ? '已标记完成阅读' : '已取消完成阅读标记'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 悬浮球「加深」后的灰色底：展开态主按钮与三个动作按钮共用，保证同色。
  Color get _fabDeepBg => _isDarkBg
      ? const Color(0xFF2C2C2C).withOpacity(0.92)
      : const Color(0xFF4A4A4A).withOpacity(0.85);

  /// 右下角浮动图标：圆形按钮，可指定底色与图标色。
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
        backgroundColor:
            backgroundColor ?? (_isDarkBg ? Colors.white : const Color(0xFFf7f7f7)),
        elevation: 8,
        highlightElevation: 12,
        shape: const CircleBorder(),
        child: IconTheme(
          data: IconThemeData(
            color: foregroundColor ?? AppPalette.p.primary,
          ),
          child: child,
        ),
      ),
    );
  }

  /// 悬浮球菜单层：铺满阅读区，按当前圆心摆放主按钮与三个弧线动作按钮。
  /// 动作按钮以主按钮为圆心、沿四分之一圆弧排布（正前 / 45° / 正上或正下）；
  /// 靠近屏幕左、上边缘时弧线自动反向，保证弧线始终落在屏内。
  Widget _buildFabMenu(BoxConstraints constraints) {
    const double radius = 72; // 弧线半径
    const double btn = 44; // 动作按钮直径（比默认主按钮大）
    const double toggle = 46; // 悬浮球直径
    final double box = radius + btn / 2 + toggle / 2 + 4; // 画布边长
    final Size area = Size(constraints.maxWidth, constraints.maxHeight);
    final Offset defaultCenter = Offset(
      area.width - 16 - toggle / 2,
      area.height - 57 - toggle / 2,
    );
    final Offset ballCenter =
        _clampFabBallCenter(_fabBallCenter ?? defaultCenter, area, toggle);
    // 右半屏向左展开、下半屏向上展开；靠近左/上边缘时自动反向。
    final double signX = ballCenter.dx > area.width / 2 ? -1 : 1;
    final double signY = ballCenter.dy > area.height / 2 ? -1 : 1;
    final Offset ballInBox = Offset(
      signX < 0 ? box - toggle / 2 : toggle / 2,
      signY < 0 ? box - toggle / 2 : toggle / 2,
    );
    final Offset boxTopLeft = ballCenter - ballInBox;
    double dirX(double deg) => signX * math.cos(deg * math.pi / 180);
    double dirY(double deg) => signY * math.sin(deg * math.pi / 180);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          key: const ValueKey('fab_menu'),
          left: boxTopLeft.dx,
          top: boxTopLeft.dy,
          child: SizedBox(
            width: box,
            height: box,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _buildFabAction(
                  show: _showFabMenu,
                  radius: radius,
                  size: btn,
                  dirX: dirX(0),
                  dirY: dirY(0),
                  centerX: ballInBox.dx,
                  centerY: ballInBox.dy,
                  tooltip: '经文讨论',
                  heroTag: 'sutra_discussion',
                  onTap: () => _runFabAction(_openDiscussion),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      Colors.white,
                      BlendMode.srcIn,
                    ),
                    child: Image.asset(
                      'assets/images/l1.png',
                      width: 20,
                      height: 20,
                    ),
                  ),
                ),
                _buildFabAction(
                  show: _showFabMenu,
                  radius: radius,
                  size: btn,
                  dirX: dirX(45),
                  dirY: dirY(45),
                  centerX: ballInBox.dx,
                  centerY: ballInBox.dy,
                  tooltip: 'AI 助手',
                  heroTag: 'sutra_ai_assistant',
                  onTap: () => _runFabAction(_openAssistant),
                  child: const Text(
                    'AI',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                _buildFabAction(
                  show: _showFabMenu,
                  radius: radius,
                  size: btn,
                  dirX: dirX(90),
                  dirY: dirY(90),
                  centerX: ballInBox.dx,
                  centerY: ballInBox.dy,
                  tooltip: '写笔记',
                  heroTag: 'sutra_note',
                  onTap: () => _runFabAction(_openNoteEditor),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      Colors.white,
                      BlendMode.srcIn,
                    ),
                    child: Image.asset(
                      'assets/images/write.png',
                      width: 20,
                      height: 20,
                    ),
                  ),
                ),
                Positioned(
                  left: ballInBox.dx - toggle / 2,
                  top: ballInBox.dy - toggle / 2,
                  child: _buildFabToggle(
                    size: toggle,
                    ballCenter: ballCenter,
                    area: area,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 把悬浮球圆心限制在阅读区内（可贴近四边，弧线会自动反向）。
  Offset _clampFabBallCenter(Offset c, Size area, double toggle) {
    const double margin = 6;
    final double minX = toggle / 2 + margin;
    final double minY = toggle / 2 + margin;
    final double maxX = area.width - toggle / 2 - margin;
    final double maxY = area.height - toggle / 2 - margin;
    return Offset(
      c.dx.clamp(minX, math.max(minX, maxX)).toDouble(),
      c.dy.clamp(minY, math.max(minY, maxY)).toDouble(),
    );
  }

  /// 弧线上的单个动作按钮：展开时沿弧线方向从主按钮向外滑出并淡入，收起反向缩回。
  Widget _buildFabAction({
    required bool show,
    required double radius,
    required double size,
    required double dirX,
    required double dirY,
    required double centerX,
    required double centerY,
    required String tooltip,
    required String heroTag,
    required VoidCallback onTap,
    required Widget child,
  }) {
    // 收起时相对主按钮圆心的像素位移。
    final Offset hidden = Offset(-dirX * radius, -dirY * radius);
    return Positioned(
      left: centerX + radius * dirX - size / 2,
      top: centerY + radius * dirY - size / 2,
      child: IgnorePointer(
        ignoring: !show,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: show ? 1 : 0),
          duration: const Duration(milliseconds: 480),
          curve: const _FabSpringCurve(),
          builder: (context, t, built) {
            // t=0 收在主按钮圆心；easeOutBack 会令 t 略大于 1（向外多探出一点再收回）。
            final Offset pos = hidden * (1 - t);
            // 淡入放慢到前 70%，与位移的回弹同步，观感更顺滑。
            final double opacity = (t / 0.7).clamp(0.0, 1.0);
            return Transform.translate(
              offset: pos,
              child: Opacity(opacity: opacity, child: built),
            );
          },
          child: SizedBox(
            width: size,
            height: size,
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

  /// 右下角悬浮主按钮：几乎透明的圆形，内含灰白圆圈（类 iPhone 悬浮球）。
  /// 点击展开/收起；长按可拖动到阅读区任意位置（弧线方向随位置自动反向）。
  Widget _buildFabToggle({
    required double size,
    required Offset ballCenter,
    required Size area,
  }) {
    const Color ringColor = Colors.white;
    // 半透明灰色圆底：透过它能看到下方正文，不遮挡文字。
    final Color collapsedBg = _isDarkBg
        ? Colors.white.withOpacity(0.16)
        : const Color(0xFF9E9E9E).withOpacity(0.30);
    final Color expandedBg = _fabDeepBg;
    return Tooltip(
      message: _showFabMenu ? '收起' : '更多功能',
      // 关闭长按气泡：长按留给「拖动悬浮球」，避免两者手势冲突。
      triggerMode: TooltipTriggerMode.manual,
      child: SizedBox(
        width: size,
        height: size,
        child: AnimatedScale(
          // 展开后主按钮略微缩小，三个动作按钮比它更大。
          scale: _showFabMenu ? 0.85 : 1.0,
          duration: const Duration(milliseconds: 480),
          curve: Curves.easeOut,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleFabMenu,
            onLongPressStart:
                _showFabMenu ? null : (_) => _fabDragStartBall = ballCenter,
            onLongPressMoveUpdate: _showFabMenu
                ? null
                : (d) {
                    final start = _fabDragStartBall;
                    if (start == null) return;
                    setState(() {
                      _fabBallCenter = _clampFabBallCenter(
                        start + d.offsetFromOrigin,
                        area,
                        size,
                      );
                    });
                  },
            onLongPressEnd: _showFabMenu
                ? null
                : (_) => _fabDragStartBall = null,
            onLongPressCancel:
                _showFabMenu ? null : () => _fabDragStartBall = null,
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
                      ? const Icon(
                          Icons.close,
                          key: ValueKey('fabClose'),
                          size: 18,
                          color: Colors.white,
                        )
                      : Container(
                          key: const ValueKey('fabRing'),
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: ringColor, width: 2),
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

  /// 切换悬浮菜单：展开时收起其他浮层。
  void _toggleFabMenu() {
    setState(() {
      _showFabMenu = !_showFabMenu;
      if (_showFabMenu) {
        _showMoreMenu = false;
        _showQuickPanel = false;
        _showStylePanel = false;
      }
    });
  }

  /// 收起悬浮菜单（点菜单外/返回键/执行动作时统一调用）。
  void _closeFabMenu() {
    if (!_showFabMenu) return;
    setState(() => _showFabMenu = false);
  }

  /// 执行悬浮菜单动作：先收起菜单与其他浮层，再执行回调。
  void _runFabAction(VoidCallback action) {
    setState(() {
      _showFabMenu = false;
      _showMoreMenu = false;
      _showQuickPanel = false;
      _showStylePanel = false;
    });
    action();
  }

  /// 打开本经的讨论页（与点击 \$经文 进入的是同一页面）。
  void _openDiscussion() {
    final path = _resolvedFilePath ?? widget.filePath ?? '';
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SutraDiscussionPage(
          title: _titleShown,
          filePath: path,
        ),
      ),
    );
  }

  void _openAssistant() {
    // 唤出全局常驻的AI 面板（WebView 不销毁，会话跨页面延续）；再次点击收起。
    assistantVisible.value = !assistantVisible.value;
  }

  /// 点击某段的「AI译」：打开白话翻译弹层并自动翻译该段。
  /// 若该段与相邻段通过 `。。。//` 标记连成一体（无间隔），则把整个连段段落簇
  /// 一起翻译，而不是只翻其中一小段。
  void _openAiTranslate(int index) {
    if (index < 0 || index >= _paragraphs.length) return;
    final cluster = _connectedTightCluster(index);
    final paragraph = cluster.map((k) => _paragraphs[k]).join('\n');
    // 收起阅读设置 / 速览面板，避免与新弹层重叠。
    setState(() {
      _showStylePanel = false;
      _showQuickPanel = false;
    });
    AiTranslatePage.open(
      context,
      paragraph: paragraph,
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      isDark: _isDarkBg,
    );
  }

  /// 返回不[index] 通过 `。。。//` 连成一体（无间隔）的连续段落下标簇。
  /// `_tightParagraphs.contains(j)` 表示段落 j 不j+1 之间无间隔；
  /// 从[index] 为中心向两侧扩张到整段紧密连段的两端。
  List<int> _connectedTightCluster(int index) {
    if (_paragraphs.length <= 1)
      return [index.clamp(0, _paragraphs.length - 1)];
    var lo = index;
    var hi = index;
    while (lo > 0 && _tightParagraphs.contains(lo - 1)) lo--; // (lo-1) 连到 lo
    while (hi < _paragraphs.length - 1 && _tightParagraphs.contains(hi))
      hi++; // hi 连到 hi+1
    return [for (var k = lo; k <= hi; k++) k];
  }

  /// 把一段连续段落下标列表按 `。。。//` 紧密连段切成多个「渲染簇」：
  /// 每簇内相邻段落两两相连（无间隔），须渲染成同一个可选文本才可跨段拖动选择。
  List<List<int>> _clusterGroups(List<int> indices) {
    final groups = <List<int>>[];
    var cur = <int>[];
    for (var i = 0; i < indices.length; i++) {
      final idx = indices[i];
      cur.add(idx);
      final nextIdx = i + 1 < indices.length ? indices[i + 1] : -1;
      // 仅当本段与下一段在数据上相邻（idx+1）且用标记连在一起时才继续并入同簇。
      if (nextIdx != idx + 1 || !_tightParagraphs.contains(idx)) {
        groups.add(cur);
        cur = <int>[];
      }
    }
    if (cur.isNotEmpty) groups.add(cur);
    return groups;
  }

  /// 渲染簇的合并文本：段落间画`\n` 连接（与编辑器的「不分段」视觉一致）。
  String _clusterText(List<int> cluster) =>
      cluster.map((k) => _paragraphs[k]).join('\n');

  /// 把簇内选区 [ss,ee)（合并文本坐标）按段落切成多段局部区间
  /// (段落下标, 段内start, 段内end)，用于画线/ 感想时逐段落处理。
  List<(int, int, int)> _clusterLocalSegments(
      List<int> cluster, int ss, int ee) {
    final out = <(int, int, int)>[];
    var off = 0;
    for (final k in cluster) {
      final len = _paragraphs[k].length;
      final lo = ss < off ? off : ss;
      final hi = ee > off + len ? off + len : ee;
      if (hi > lo) out.add((k, lo - off, hi - off));
      off += len + 1; // +1 = 段间 `\n`
    }
    return out;
  }

  /// 簇内选区画线/擦除：先把簇内各段的新画线区间一次性算好，经
  /// [_applyUnderlinesAndSave] 在*单个** setState 里同步更新本地状态
  /// （整簇画线擦除一次到位，避免逐段 setState 造成的“逐行画线/擦除”），
  /// 再逐段写入云端。
  /// 语义沿用 [_toggleUnderline]：选中区间已被现有画线完整覆盖 →擦除，
  /// 否则 →新增画线（渲染端自动合并重叠）。
  Future<void> _toggleUnderlineCluster(
      List<int> cluster, int ss, int ee) async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLoginForNotes();
      return;
    }
    final changes = <int, List<Map<String, int>>>{};
    for (final (k, ls, le) in _clusterLocalSegments(cluster, ss, ee)) {
      if (ls >= le || k < 0 || k >= _paragraphs.length) continue;
      final current =
          List<Map<String, int>>.from(_paraUnderlines[k] ?? const []);
      final covering = current
          .where((u) => (u['start'] ?? 0) <= ls && (u['end'] ?? 0) >= le)
          .toList();
      List<Map<String, int>> next;
      if (covering.isNotEmpty) {
        final removeSet = covering.toSet();
        next = [
          for (final u in current)
            if (!removeSet.contains(u)) u,
        ];
      } else {
        next = [
          ...current,
          {'start': ls, 'end': le}
        ];
      }
      next.sort((a, b) => (a['start'] ?? 0).compareTo(b['start'] ?? 0));
      changes[k] = next;
    }
    if (changes.isEmpty) return;
    await _applyUnderlinesAndSave(changes);
  }

  /// 簇内选区开感想：存到选区所在的第一段，但预览经文显示完整跨段选中文字，
  /// 避免合并整段（```。。。//```）全选时只显示第一段。
  void _openIdeaFromRangeCluster(List<int> cluster, int ss, int ee) {
    final segs = _clusterLocalSegments(cluster, ss, ee);
    if (segs.isEmpty) return;
    final (k, _, _) = segs.first;
    // 逐段拼接选中文字，段间换行；避开簇坐标`\n` 边界，不产生首尾多余换行。
    final display = segs
        .map((seg) => _paragraphs[seg.$1].substring(seg.$2, seg.$3))
        .join('\n');
    _showNoteDialog(k, displayText: display);
  }

  /// 「本段全选」作用于整簇：合并文本整段选中。
  void _selectFullCluster(List<int> cluster) {
    final state = _selectionTextState;
    if (state != null) {
      state.selectAll(SelectionChangedCause.tap);
      _selectionRange = (0, _clusterText(cluster).length);
    }
  }

  /// 渲染簇的完整 TextSpan：每段各自带基础样式（含完成态置灰），段间`\n`。
  List<TextSpan> _buildClusterSpans(List<int> cluster) {
    final spans = <TextSpan>[];
    for (var k = 0; k < cluster.length; k++) {
      final i = cluster[k];
      spans.add(
        TextSpan(style: _paraBaseStyle(i), children: _buildParagraphSpans(i)),
      );
      if (k != cluster.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    return spans;
  }

  /// 排版变化提示横幅（画线感想未能重新定位的段落）。
  Widget _unalignedBanner() => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF3CD),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text(
            '排版已变化，此处的感想画线未能重新定位',
            style: TextStyle(fontSize: 12, color: Color(0xFF8a6d1a)),
          ),
        ),
      );

  /// 一个渲染簇（≥1 连续紧密段落）的正文块：合并成一不SelectableText 作
  /// 「本段全选/ 拖动选择」都能跨段作用；单段时保留原段落行为与操作栏。
  /// 备注段落单独渲染为浅色背景色块，破出正文 16px 内边距，通到屏幕左右边缘。
  Widget _buildClusterParagraph(
    List<int> group, {
    required bool showUnaligned,
    bool actionsRight = false,
  }) {
    final last = group.last;
    final bottom = _tightParagraphs.contains(last) ? 0.0 : 24.0;
    // 备注段落：整段底色块，左右通到屏幕边缘。
    if (group.length == 1 && _noteParagraphs.contains(group.first)) {
      return Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          color: _isDarkBg ? const Color(0xFF2C2C2C) : const Color(0xFFEEEEEE),
          child: SelectableText.rich(
            TextSpan(children: _buildClusterSpans(group)),
            key: _paraTapKey(group.first),
            onSelectionChanged: (sel, cause) {
              _hasTextSelection = !sel.isCollapsed;
              _onSelectionChanged(sel);
            },
            contextMenuBuilder: (context, editableTextState) =>
                _buildSelectionToolbar(context, editableTextState, group),
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showUnaligned)
              for (final idx in group)
                if (_unalignedIndices.contains(idx)) _unalignedBanner(),
            SelectableText.rich(
              TextSpan(children: _buildClusterSpans(group)),
              key: _paraTapKey(group.first),
              onSelectionChanged: (sel, cause) {
                _hasTextSelection = !sel.isCollapsed;
                _onSelectionChanged(sel);
              },
              contextMenuBuilder: (context, editableTextState) =>
                  _buildSelectionToolbar(context, editableTextState, group),
            ),
            if (!_hiddenActionParagraphs.contains(last))
              Align(
                alignment:
                    actionsRight ? Alignment.centerRight : Alignment.centerLeft,
                child: _buildParagraphActions(last, group: group),
              ),
          ],
        ),
      ),
    );
  }

  /// 全部段落下标的渲染簇划分（滚动模式的全文列表）。
  List<List<int>> _allClusterGroups() =>
      _clusterGroups([for (var i = 0; i < _paragraphs.length; i++) i]);

  /// 段落右侧的操作栏（同一水平位）：待办圆在| AI读| 笔记。
  /// [group] 为操作栏所属的渲染簇（`///` 合并段可能含多段）；变绿与打开都按整簇判定，
  /// 因为簇内选区的备注按约定存到簇首段（见[_openIdeaFromRangeCluster]）。
  Widget _buildParagraphActions(int index, {List<int> group = const []}) {
    final fg =
        _isDarkBg ? Colors.white.withOpacity(0.6) : const Color(0xFF9A9A9A);
    final activeFg = AppPalette.p.accent;
    final members = group.isEmpty ? <int>[index] : group;
    // 任意用户添加了感想即变绿（_paraHasAnyThought 由云端全量查询填充），
    // 合并段还要看本地已保存的备注，避免保存后整簇未刷新导致的短暂不变绿。
    final hasNote = members.any((i) =>
        _paraHasAnyThought.contains(i) || (_paraNotes[i] ?? const []).isNotEmpty);
    final done = _paraDone[index] == true;
    return Padding(
      // 操作栏紧贴本段文字（与该段一体），
      // 与下一段的间隔交给段落容器的外部bottom 留白。
      padding: const EdgeInsets.only(
        top: 0,
        bottom: 0,
      ),
      child: Listener(
        // 点击操作栏时置true，阻止外层Listener 触发面板（指针从内到外派发）。
        onPointerDown: (_) => _actionRowTapped = true,
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 待办圆圈（提前到最前）：点击打勾并把该段文字变灰。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _toggleParagraphDone(index),
              child: SizedBox(
                width: 20,
                height: 20,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    width: done ? 12 : 14,
                    height: done ? 12 : 14,
                    decoration: BoxDecoration(
                      color: done ? activeFg : Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: done ? activeFg : fg,
                        width: 1.2,
                      ),
                    ),
                    child: done
                        ? Icon(Icons.check,
                            size: 9,
                            color: _isDarkBg
                                ? const Color(0xFF1A1A1A)
                                : Colors.white)
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // AI读
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openAiTranslate(index),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 13,
                    color: fg,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'AI读',
                    style: TextStyle(
                      fontSize: 13,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            // 笔记
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _onParagraphNoteTap(
                members.firstWhere(
                  (i) =>
                      _paraHasAnyThought.contains(i) ||
                      (_paraNotes[i] ?? const []).isNotEmpty,
                  orElse: () => members.first,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    hasNote
                        ? Icons.sticky_note_2
                        : Icons.sticky_note_2_outlined,
                    size: 14,
                    color: hasNote ? activeFg : fg,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '所有备注',
                    style: TextStyle(
                      fontSize: 13,
                      color: hasNote ? activeFg : fg,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点击「备注」：打开该段经文所有用户备注的汇总底部弹层。
  void _onParagraphNoteTap(int index) {
    if (index < 0 || index >= _paragraphs.length) return;
    ParagraphThoughtsPage.open(
      context,
      sutraTitle: _titleShown,
      paragraph: _paragraphs[index],
      sutraKey: _sutraKey,
      paragraphIndex: index,
      loadMyNotes: () => List<ParaNote>.of(_paraNotes[index] ?? const []),
      onEditNote: (note) => _editParagraphNote(index, note),
      onDeleteNote: (note) => _deleteParagraphNote(index, noteId: note.id),
    );
  }

  /// 编辑某段里的一条备注（追加/替换/删除单条）。
  Future<void> _editParagraphNote(int index, ParaNote note) async {
    if (index < 0 || index >= _paragraphs.length) return;
    _clearSelectionMenu();
    _coveredByRoute = true;
    FocusScope.of(context).unfocus();
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => ReadingNoteEditPage(
          paragraph:
              note.quoted.trim().isNotEmpty ? note.quoted : _paragraphs[index],
          initialText: note.text,
          hasExistingNote: true,
          sutraTitle: _titleShown,
          initialShared: note.shared,
          initialCloudId: note.cloudId,
        ),
      ),
    );
    _coveredByRoute = false;
    if (result == null || !mounted) return;
    final existing = List<ParaNote>.of(_paraNotes[index] ?? const []);
    final pos = existing.indexWhere((n) => n.id == note.id);
    if (pos < 0) return;
    if (result['note'] == '__delete__') {
      existing.removeAt(pos);
      await _saveParagraphNote(index, existing,
          underlines: _paraUnderlines[index] ?? const []);
      return;
    }
    final text = (result['note'] as String? ?? '').trim();
    if (text.isEmpty) {
      existing.removeAt(pos);
      await _saveParagraphNote(index, existing,
          underlines: _paraUnderlines[index] ?? const []);
      return;
    }
    final shared = result['shared'] == true;
    existing[pos] = existing[pos].copyWith(
      text: text,
      shared: shared,
      cloudId: shared ? ((result['cloudId'] as String?) ?? '') : '',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _saveParagraphNote(index, existing,
        underlines: _paraUnderlines[index] ?? const []);
  }

  /// 进入「读经备注」编辑页，为 [index] 段*追加**一条新备注。
  /// [displayText] 非空时顶部显示被选中的具体文字（由长按单击画线的备注入口传入）。
  Future<void> _showNoteDialog(int index, {String? displayText}) async {
    if (index < 0 || index >= _paragraphs.length) return;
    // 跳转前先禁用浮层菜单：push 之后本页失焦、选区收起，
    // contextMenuBuilder 可能再次回调，把「复到画线」弹窗插到备注页上方。
    _clearSelectionMenu();
    _coveredByRoute = true;
    FocusScope.of(context).unfocus();
    final existing = List<ParaNote>.of(_paraNotes[index] ?? const []);
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => ReadingNoteEditPage(
          paragraph: displayText ?? _paragraphs[index],
          initialText: '',
          hasExistingNote: existing.isNotEmpty,
          sutraTitle: _titleShown,
        ),
      ),
    );
    _coveredByRoute = false;
    if (result == null || !mounted) return;
    if (result['note'] == '__delete__') {
      await _deleteParagraphNote(index);
      return;
    }
    final text = (result['note'] as String? ?? '').trim();
    if (text.isEmpty) return;
    final shared = result['shared'] == true;
    final newNote = ParaNote(
      id: ParaNote.newId(),
      text: text,
      quoted: (displayText ?? '').trim(),
      shared: shared,
      cloudId: shared ? ((result['cloudId'] as String?) ?? '') : '',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _saveParagraphNote(index, [...existing, newNote],
        underlines: _paraUnderlines[index] ?? const []);
  }

  /// 删除某段备注。[noteId] 为空时删除整段（含画线完成态），
  /// 指定时仅删除该条备注，保留其余备注、画线。
  Future<void> _deleteParagraphNote(int index, {String? noteId}) async {
    final existing = List<ParaNote>.of(_paraNotes[index] ?? const []);
    if (noteId != null) {
      final target = existing.where((n) => n.id == noteId).toList();
      if (target.isEmpty) return;
      existing.removeWhere((n) => n.id == noteId);
      setState(() => _activeNoteParagraphIndex = -1);
      try {
        await CloudNotesService.instance.deleteParagraphNote(
          sutraKey: _sutraKey,
          index: index,
          noteId: noteId,
        );
        final cloudId = target.first.cloudId;
        if (cloudId.isNotEmpty) {
          await CloudNotesService.instance.unpublishNote(cloudId);
        }
        if (!mounted) return;
        await _saveParagraphNote(index, existing,
            underlines: _paraUnderlines[index] ?? const []);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('删除失败，{e is CloudApiException ? e.message : e}')),
        );
      }
      return;
    }
    final cloudIds = [
      for (final n in existing)
        if (n.cloudId.isNotEmpty) n.cloudId,
    ];
    setState(() {
      if (_activeNoteParagraphIndex == index) {
        _activeNoteParagraphIndex = -1;
        _noteInputController.clear();
      }
      _paraNotes.remove(index);
      _paraUnderlines.remove(index);
      _paraDone.remove(index);
    });
    try {
      await CloudNotesService.instance.deleteParagraphNote(
        sutraKey: _sutraKey,
        index: index,
      );
      // 曾分享到菩提空间的帖子同步取消分享（隐藏）。
      for (final id in cloudIds) {
        await CloudNotesService.instance.unpublishNote(id);
      }
      if (!mounted) return;
      _loadParagraphNotes();
      // 「记录」时间线：整段删除后清掉该段的感想与画线条目。
      unawaited(RecordIndex.instance.syncParagraph(
        sutraKey: _sutraKey,
        para: index,
        paraText: _paragraphs[index],
        thought: '',
        underlines: const [],
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('删除失败，{e is CloudApiException ? e.message : e}')),
      );
    }
  }

  /// 打开「阅读设置」底部弹层（三个点点菜单 / 速览面板入口）：
  /// 面板挂在页面 Stack 里，滑块 setState 能实时刷新面板上的数字。
  void _openReadingSettings() {
    setState(() {
      _showMoreMenu = false;
      _showQuickPanel = false;
      _showStylePanel = true;
    });
  }

  /// 打开「读经笔记」页：列出本经所有段落感想，点击某段可跳回该段。
  /// 计算在后台隔离区进行并严格有界，任何规模的感想数据都不可能卡死界面。
  Future<void> _openReadingNotes() async {
    if (_openingNotes) return;
    _openingNotes = true;
    try {
      // 不setState：避免触发整个读经页重建与路由转场竞争。
      _showMoreMenu = false;
      _showQuickPanel = false;
      if (!mounted) return;
      final paragraphs = List<String>.of(_paragraphs);
      // 每条备注的正文+ 其针对的选中文字（可空，空表示针对整段）。
      final notes = <int, List<String>>{};
      final quotes = <int, List<String>>{};
      for (final e in _paraNotes.entries) {
        final ns = <String>[];
        final qs = <String>[];
        for (final n in e.value) {
          final t = n.text.trim();
          if (t.isEmpty) continue;
          ns.add(t);
          qs.add(n.quoted.trim());
        }
        if (ns.isNotEmpty) {
          notes[e.key] = ns;
          quotes[e.key] = qs;
        }
      }
      final tight = <int>{..._tightParagraphs};
      final noteCount = notes.values.fold<int>(0, (a, v) => a + v.length);
      final result = await _runCompute(
        () => _buildNotesSnapshot(
          paragraphs: paragraphs,
          notes: notes,
          quotes: quotes,
          tight: tight,
        ),
        isolateIf: noteCount > 200 || paragraphs.length > 3000,
        loadingText: '备注整理中…',
      );
      if (!mounted) return;
      debugPrint('[thoughts] open: paras=${paragraphs.length} '
          'notes=$noteCount');
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('备注整理失败，请稍后重试')),
        );
        return;
      }
      final (displayParagraphs, noteTexts, idxs) = result;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReadingNotesPage(
            title: _titleShown,
            paragraphs: displayParagraphs,
            notes: noteTexts,
            canDelete: idxs.isNotEmpty,
            sutraKey: _sutraKey,
            itemParagraphIndexes: idxs,
            onDeleteNote: _deleteNoteFromReadingNotes,
          ),
        ),
      );
      if (!mounted) return;
      // 返回读经页后刷新一次，确保删除后阅读页感想同步消失。
      await _loadParagraphNotes();
    } finally {
      _openingNotes = false;
    }
  }

  /// 从备注汇总页删除某段备注（清空该段全部备注，保留画线；更新阅读页 + 云端）。
  Future<bool> _deleteNoteFromReadingNotes(int index) async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLoginForNotes();
      return false;
    }
    if (index < 0 || index >= _paragraphs.length) return false;
    if ((_paraNotes[index] ?? const []).isEmpty) return false;
    await _saveParagraphNote(
      index,
      const [],
      underlines: _paraUnderlines[index] ?? const [],
    );
    return true;
  }

  /// 打开「读经笔记」汇总页：列出本经所有从右下角笔记按钮编写的笔记。
  Future<void> _openSutraNotes() async {
    if (_openingNotes) return;
    _openingNotes = true;
    try {
      _showMoreMenu = false;
      _showQuickPanel = false;
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReadingSutraNotesPage(
            title: _titleShown,
            canDelete: true,
          ),
        ),
      );
    } finally {
      _openingNotes = false;
    }
  }

  /// 干净单击正文中部：弹击画线/感想/笔记 速览面板。
  void _openQuickPanel() {
    if (_showQuickPanel) return;
    setState(() {
      _showQuickPanel = true;
    });
  }

  /// 打开「画线归集」页：把这部经里所有被画线的文字汇总展示。
  /// 同一 `。。。//` 连段簇内的画线合并为一条（段间 `\n`），每条带各段区间，
  /// 以便删除时逐段落落地。
  /// 计算在后台隔离区进行并严格有界：任何规模的画线数据都不可能卡死界面。
  Future<void> _openHighlightsPage() async {
    if (_openingHighlights) return;
    _openingHighlights = true;
    try {
      // 不setState：避免触发整个读经页重建与路由转场竞争。
      _showQuickPanel = false;
      if (!mounted) return;
      final paragraphs = List<String>.of(_paragraphs);
      final underlines = <int, List<Map<String, int>>>{
        for (final e in _paraUnderlines.entries) e.key: List.of(e.value),
      };
      final tight = <int>{..._tightParagraphs};
      final totalRanges =
          underlines.values.fold<int>(0, (a, v) => a + v.length);
      final result = await _runCompute(
        () => _buildHighlightsSnapshot(
          paragraphs: paragraphs,
          underlines: underlines,
          tight: tight,
        ),
        // 门槛放宽：经文稍长画线稍多即走隔离区，UI 永远不参与计算。
        isolateIf: totalRanges > 500 ||
            paragraphs.length > 3000 ||
            tight.length > 1000,
        loadingText: '画线整理中…',
      );
      if (!mounted) return;
      debugPrint('[highlights] open: paras=${paragraphs.length} '
          'ranges=$totalRanges tight=${tight.length}');
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('画线整理失败，请稍后重试')),
        );
        return;
      }
      final (highlights, itemSegments) = result;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SutraHighlightsPage(
            title: _titleShown,
            highlights: highlights,
            canDelete: highlights.isNotEmpty,
            sutraKey: _sutraKey,
            itemSegments: itemSegments,
            onDeleteUnderline: _deleteUnderlineFromHighlights,
          ),
        ),
      );
      if (!mounted) return;
      // 返回读经页后刷新一次，确保删除后阅读页划线同步消失。
      await _loadParagraphNotes();
    } finally {
      _openingHighlights = false;
    }
  }

  /// 运行 [compute]：小数据直接在主线程计算（快且无感），
  /// [isolateIf] 为真时改在独立隔离区计算，期间用全屏 loading 路由提示，
  /// 结束后自动移除。任何规模的数据都只影响耗时，不阻塞 UI。
  Future<T?> _runCompute<T>(T Function() compute,
      {required bool isolateIf, String loadingText = '整理中…'}) async {
    if (!isolateIf) {
      try {
        final r = compute();
        debugPrint('[compute] 主线程完成');
        return r;
      } catch (e, st) {
        debugPrint('[compute] 失败: $e\n$st');
        return null;
      }
    }
    debugPrint('[compute] 进入隔离区…');
    final stopwatch = Stopwatch()..start();
    final nav = Navigator.of(context, rootNavigator: true);
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black38,
          body: Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(loadingText),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    try {
      final result = await Isolate.run(() => compute());
      debugPrint('[compute] 耗时 ${stopwatch.elapsedMilliseconds}ms');
      return result;
    } catch (e, st) {
      debugPrint('[compute] 失败: $e\n$st');
      return null;
    } finally {
      if (nav.canPop()) nav.pop();
    }
  }

  // ── 归集页数据快照计算（纯函数，可在隔离区安全运行） ────────────
  static const int kMaxHighlightItems = 2000;
  static const int kMaxRangesPerPara = 5000;
  static const int kMaxCharsPerItem = 100000;

  /// 汇总画线为「紧密连段分组」条目。严格有界：至多 [kMaxHighlightItems] 条。
  /// 每段至多 [kMaxRangesPerPara] 个区间、每条至失[kMaxCharsPerItem] 字符，
  /// 超出即截断——保证任何数据下都能在有限时间内结束。
  static (List<String>, List<List<LiveHighlightSegment>>)
      _buildHighlightsSnapshot({
    required List<String> paragraphs,
    required Map<int, List<Map<String, int>>> underlines,
    required Set<int> tight,
  }) {
    final highlights = <String>[];
    final itemSegments = <List<LiveHighlightSegment>>[];
    final n = paragraphs.length;
    var i = 0;
    while (i < n && highlights.length < kMaxHighlightItems) {
      // 同一紧密连段簇：[i..j]（段 k 连到 k+1 当且仅当 tight 后k）。
      var j = i;
      while (j + 1 < n && tight.contains(j)) j++;
      final textParts = <String>[];
      final segs = <LiveHighlightSegment>[];
      var textLen = 0;
      for (var k = i; k <= j; k++) {
        final raw = underlines[k];
        if (raw == null || raw.isEmpty) continue;
        final text = paragraphs[k];
        final len = text.length;
        final merged = <(int, int)>[];
        var count = 0;
        for (final u in raw) {
          if (count++ >= kMaxRangesPerPara) break;
          final s = (u['start'] ?? 0).clamp(0, len);
          final e = (u['end'] ?? 0).clamp(0, len);
          if (e > s) merged.add((s, e));
        }
        merged.sort((a, b) => a.$1.compareTo(b.$1));
        final consolidated = <(int, int)>[];
        for (final r in merged) {
          if (consolidated.isNotEmpty && r.$1 <= consolidated.last.$2) {
            final last = consolidated.removeLast();
            consolidated.add((last.$1, r.$2 > last.$2 ? r.$2 : last.$2));
          } else {
            consolidated.add(r);
          }
        }
        for (final r in consolidated) {
          if (textLen >= kMaxCharsPerItem) break;
          final s = r.$1.clamp(0, len);
          final e = r.$2.clamp(0, len);
          if (e > s) {
            textParts.add(text.substring(s, e));
            textLen += e - s;
            segs.add((para: k, start: s, end: e));
          }
        }
      }
      if (textParts.isNotEmpty) {
        var joined = textParts.join('\n');
        if (joined.length > kMaxCharsPerItem) {
          joined = joined.substring(0, kMaxCharsPerItem) + '……';
        }
        highlights.add(joined);
        itemSegments.add(segs);
      }
      i = j + 1;
    }
    return (highlights, itemSegments);
  }

  /// 汇总备注段为「经文（连段簇合并展示）+ 备注文本 + 段落下标」数据。
  /// 同一段有多条备注时，展开为多行。[quotes] 不[notes] 一一对应，为该条备注
  /// 针对的选中文字；非空时经文列显示选中文字，为空（针对整段）才显示整段。
  static (List<String>, List<String>, List<int>) _buildNotesSnapshot({
    required List<String> paragraphs,
    required Map<int, List<String>> notes,
    required Map<int, List<String>> quotes,
    required Set<int> tight,
  }) {
    final idxs = <int>[
      for (final e in notes.entries)
        if (e.key >= 0 &&
            e.key < paragraphs.length &&
            e.value.any((n) => n.trim().isNotEmpty))
          e.key,
    ]..sort();
    final display = <String>[];
    final noteTexts = <String>[];
    final noteIdxs = <int>[];
    for (final i in idxs) {
      final group = _connectedTightClusterSnapshot(i, paragraphs, tight);
      final paraText = group.length > 1
          ? group.map((k) => paragraphs[k]).join('\n')
          : paragraphs[i];
      final qs = quotes[i] ?? const <String>[];
      final ns = notes[i]!;
      // 同一段多条备注：按备注针对的经文在段中的位置排序，越靠段首越靠前。
      // 位置键取选中文字在段内的起始下标；针对整段（无选中文字）视为段首 0，
      // 段内找不到选中文字时排到最后。位置相同时保持原有先后顺序。
      final order = <int>[
        for (var j = 0; j < ns.length; j++)
          if (ns[j].trim().isNotEmpty) j,
      ]..sort((a, b) {
          final qa = a < qs.length ? qs[a].trim() : '';
          final qb = b < qs.length ? qs[b].trim() : '';
          final pa = qa.isEmpty ? 0 : paragraphs[i].indexOf(qa);
          final pb = qb.isEmpty ? 0 : paragraphs[i].indexOf(qb);
          final c = (pa < 0 ? 1 << 30 : pa).compareTo(pb < 0 ? 1 << 30 : pb);
          return c != 0 ? c : a.compareTo(b);
        });
      for (final j in order) {
        final t = ns[j].trim();
        if (t.isEmpty) continue;
        final quote = j < qs.length ? qs[j].trim() : '';
        display.add(quote.isNotEmpty ? quote : paraText);
        noteTexts.add(t);
        noteIdxs.add(i);
      }
    }
    return (display, noteTexts, noteIdxs);
  }

  static List<int> _connectedTightClusterSnapshot(
      int index, List<String> paragraphs, Set<int> tight) {
    if (paragraphs.length <= 1) return [index.clamp(0, paragraphs.length - 1)];
    var lo = index;
    var hi = index;
    while (lo > 0 && tight.contains(lo - 1)) lo--;
    while (hi < paragraphs.length - 1 && tight.contains(hi)) hi++;
    return [for (var k = lo; k <= hi; k++) k];
  }

  /// 从画线归集页删除 [segments] 内各段[start,end) 区间中的全部画线（更新阅读页 + 云端）。
  Future<bool> _deleteUnderlineFromHighlights(
      List<LiveHighlightSegment> segments) async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLoginForNotes();
      return false;
    }
    var changed = false;
    for (final seg in segments) {
      final index = seg.para;
      if (index < 0 || index >= _paragraphs.length) continue;
      final current =
          List<Map<String, int>>.from(_paraUnderlines[index] ?? const []);
      final next = current.where((u) {
        final us = (u['start'] ?? 0);
        final ue = (u['end'] ?? 0);
        // 移除此区间相交的所有画线（渲染端合并出的整块都消失）。
        return !(ue > seg.start && us < seg.end);
      }).toList();
      if (next.length == current.length) continue;
      changed = true;
      await _saveParagraphNote(
        index,
        List<ParaNote>.of(_paraNotes[index] ?? const []),
        underlines: next,
      );
    }
    return changed;
  }

  /// 根据当前阅读背景色索引，返回面板渐进式配色。
  Map<String, Color> _panelColors() {
    switch (_bgColorIndex) {
      case 1: // 暖黄 #EDDAB9
        return {
          'panelBg': const Color(0xFFFFF3E4),
          'textColor': const Color(0xFF3E2723),
          'subText': const Color(0xFFA08070),
          'dragBar': const Color(0xFFDDD0C0),
          'accent': AppPalette.p.accent,
          'checkIcon': const Color(0xFF3E2723),
        };
      case 2: // 米灰 #E6DED4
        return {
          'panelBg': const Color(0xFFF0E8DE),
          'textColor': const Color(0xFF3E302A),
          'subText': const Color(0xFFA09080),
          'dragBar': const Color(0xFFDDD0C8),
          'accent': AppPalette.p.accent,
          'checkIcon': const Color(0xFF3E302A),
        };
      case 3: // 豆绿 #CCDAC0
        return {
          'panelBg': const Color(0xFFE4ECE0),
          'textColor': const Color(0xFF2A3828),
          'subText': const Color(0xFF809080),
          'dragBar': const Color(0xFFC8D8C0),
          'accent': AppPalette.p.accent,
          'checkIcon': const Color(0xFF2A3828),
        };
      case 4: // 深色 #393536
        return {
          'panelBg': const Color(0xFF1E1E1E),
          'textColor': Colors.white,
          'subText': Colors.white.withOpacity(0.6),
          'dragBar': Colors.white.withOpacity(0.2),
          'accent': const Color(0xFFC0A880),
          'checkIcon': Colors.white,
        };
      default: // 默认白#F5F5F5
        return {
          'panelBg': Colors.white,
          'textColor': const Color(0xFF212121),
          'subText': const Color(0xFF999999),
          'dragBar': const Color(0xFFD0D0D0),
          'accent': AppPalette.p.accent,
          'checkIcon': const Color(0xFF212121),
        };
    }
  }

  Widget _buildQuickPanel() {
    final c = _panelColors();
    final panelBg = c['panelBg']!;

    return GestureDetector(
      // 吞掉面板内的点击，避免穿透到下面的收起遮罩。
      onTap: () {},
      child: Container(
        decoration: BoxDecoration(
          color: panelBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(0)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Row(
              children: [
                _buildQuickPanelItem(
                  icon: Icons.border_color,
                  label: '画线',
                  onTap: _openHighlightsPage,
                ),
                _buildQuickPanelItem(
                  icon: Icons.sticky_note_2_outlined,
                  label: '备注',
                  onTap: _openReadingNotes,
                ),
                _buildQuickPanelItem(
                  icon: null,
                  label: '笔记',
                  onTap: _openSutraNotes,
                  iconWidget: ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      _panelColors()['accent']!,
                      BlendMode.srcIn,
                    ),
                    child: Image.asset(
                      'assets/images/write.png',
                      width: 24,
                      height: 24,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 速览面板里的单个按钮：上面图标、下面文字。
  Widget _buildQuickPanelItem({
    required IconData? icon,
    required String label,
    required VoidCallback onTap,
    Widget? iconWidget,
  }) {
    final c = _panelColors();
    final textColor = c['textColor']!;
    final accentColor = c['accent']!;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (iconWidget != null)
                iconWidget
              else
                Icon(icon, size: 26, color: accentColor),
              const SizedBox(height: 8),
              Text(label, style: TextStyle(fontSize: 13, color: textColor)),
            ],
          ),
        ),
      ),
    );
  }

  /// 更多菜单里的带文字条目。
  Widget _buildMoreMenuItem({
    required Widget icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final fg = _panelColors()['textColor']!;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconTheme(data: IconThemeData(color: fg), child: icon),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: fg, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  /// 底部弹出的「阅读设置」面板：字号、行间距、夜间模式、背景、翻页方式。
  Widget _buildReadingSettingsPanel() {
    final c = _panelColors();
    final panelBg = c['panelBg']!;
    final textColor = c['textColor']!;
    final subTextColor = c['subText']!;
    final accentColor = c['accent']!;

    return GestureDetector(
      // 吞掉面板内的点击，避免穿透到下面的收起遮罩。
      onTap: () {},
      child: Container(
        decoration: BoxDecoration(
          color: panelBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部拖拽板
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 8),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c['dragBar']!,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // 设置内容（小屏可滚动防溢出）
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 字号滑块
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Icon(Icons.text_fields,
                                size: 18, color: subTextColor),
                            const SizedBox(width: 8),
                            Text('字号',
                                style:
                                    TextStyle(fontSize: 14, color: textColor)),
                            const SizedBox(width: 8),
                            Text('${_fontSize.toStringAsFixed(0)}',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: accentColor)),
                            Expanded(
                              child: Slider(
                                value: _fontSize,
                                min: 12,
                                max: 32,
                                divisions: 20,
                                activeColor: accentColor,
                                inactiveColor: accentColor.withOpacity(0.2),
                                onChanged: (v) {
                                  setState(() => _fontSize = v);
                                  ReaderPreferences.setFontSize(v);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 行间距滑块
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Icon(Icons.format_line_spacing,
                                size: 18, color: subTextColor),
                            const SizedBox(width: 8),
                            Text('行距',
                                style:
                                    TextStyle(fontSize: 14, color: textColor)),
                            const SizedBox(width: 8),
                            Text('${_lineHeight.toStringAsFixed(1)}',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: accentColor)),
                            Expanded(
                              child: Slider(
                                value: _lineHeight,
                                min: 1.2,
                                max: 2.5,
                                divisions: 13,
                                activeColor: accentColor,
                                inactiveColor: accentColor.withOpacity(0.2),
                                onChanged: (v) {
                                  setState(() => _lineHeight = v);
                                  ReaderPreferences.setLineHeight(v);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 夜间/白天模式：太阅+ 月亮两个图标
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 6),
                        child: Row(
                          children: [
                            Icon(_isDarkBg ? Icons.dark_mode : Icons.light_mode,
                                size: 18, color: subTextColor),
                            const SizedBox(width: 8),
                            Text(_isDarkBg ? '夜间模式' : '白天模式',
                                style:
                                    TextStyle(fontSize: 14, color: textColor)),
                            const Spacer(),
                            // 太阳（白天模式）
                            GestureDetector(
                              onTap: _isDarkBg
                                  ? () {
                                      setState(() => _bgColorIndex = 0);
                                      _isDarkMode = false;
                                      appDarkMode.value = false;
                                      _saveSettings();
                                    }
                                  : null,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: !_isDarkBg
                                      ? const Color(0xFFF5A623).withOpacity(0.2)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Icon(
                                  Icons.light_mode,
                                  size: 22,
                                  color: !_isDarkBg
                                      ? const Color(0xFFF5A623)
                                      : subTextColor,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // 月亮（夜间模式）
                            GestureDetector(
                              onTap: !_isDarkBg
                                  ? () {
                                      setState(() => _bgColorIndex = 4);
                                      _isDarkMode = true;
                                      appDarkMode.value = true;
                                      _saveSettings();
                                    }
                                  : null,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: _isDarkBg
                                      ? const Color(0xFF4A90D9).withOpacity(0.2)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Icon(
                                  Icons.dark_mode,
                                  size: 22,
                                  color: _isDarkBg
                                      ? const Color(0xFF7BAFF7)
                                      : subTextColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 背景五色选择
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                        child: Row(
                          children: [
                            Icon(Icons.palette_outlined,
                                size: 18, color: subTextColor),
                            const SizedBox(width: 8),
                            Text('背景',
                                style:
                                    TextStyle(fontSize: 14, color: textColor)),
                            const Spacer(),
                            ...List.generate(5, (i) {
                              final selected = _bgColorIndex == i;
                              return Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() => _bgColorIndex = i);
                                    _isDarkMode = (i == 4);
                                    appDarkMode.value = _isDarkMode;
                                    _saveSettings();
                                  },
                                  child: Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      color:
                                          Color(ReaderPreferences.bgColors[i]),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: selected
                                            ? accentColor
                                            : Colors.transparent,
                                        width: 2,
                                      ),
                                      boxShadow: selected
                                          ? [
                                              BoxShadow(
                                                color: accentColor
                                                    .withOpacity(0.3),
                                                blurRadius: 4,
                                              )
                                            ]
                                          : null,
                                    ),
                                    child: selected
                                        ? Icon(Icons.check,
                                            size: 14, color: c['checkIcon']!)
                                        : null,
                                  ),
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                      // 翻页方式选择
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
                        child: Row(
                          children: [
                            Icon(Icons.menu_book_outlined,
                                size: 18, color: subTextColor),
                            const SizedBox(width: 8),
                            Text('翻页',
                                style:
                                    TextStyle(fontSize: 14, color: textColor)),
                            const Spacer(),
                            _buildToggleChip(
                              label: '纵向滚动',
                              selected:
                                  _pageMode == ReaderPreferences.pageModeScroll,
                              onTap: () {
                                _switchPageMode(
                                    ReaderPreferences.pageModeScroll);
                              },
                            ),
                            const SizedBox(width: 8),
                            _buildToggleChip(
                              label: '左右翻页',
                              selected:
                                  _pageMode == ReaderPreferences.pageModeFlip,
                              onTap: () {
                                _switchPageMode(ReaderPreferences.pageModeFlip);
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ), // inner Column
                ), // SingleChildScrollView
              ), // Flexible
            ], // outer Column children
          ), // outer Column
        ), // SafeArea
      ), // Container
    ); // GestureDetector
  }

  /// 样式面板里的切换胶囊按钮。
  Widget _buildToggleChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final c = _panelColors();
    final accentColor = c['accent']!;
    final subTextColor = c['subText']!;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? accentColor.withOpacity(_isDarkBg ? 0.3 : 0.15)
              : (_isDarkBg
                  ? Colors.white.withOpacity(0.08)
                  : const Color(0xFFF0F0F0)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? accentColor : Colors.transparent,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? accentColor : subTextColor,
          ),
        ),
      ),
    );
  }

  void _performSearch(String query) {
    final matches = _findSearchMatches(query);
    setState(() {
      _searchMatches = matches;
      _currentMatchIndex = 0;
    });

    if (matches.isNotEmpty) {
      _scrollToMatch(0);
    }
  }

  /// 在渲染段落中查找 [query] 的全部命中：整串连续匹配才算一次，命中后跳连
  /// query.length 个字符（互不重叠），口径不_buildParagraphSpans 的高亮完全
  /// 一致，故计数与正文里被高亮的处数永远相同。
  List<(int, int)> _findSearchMatches(String query) {
    final lowerQuery = query.toLowerCase();
    if (lowerQuery.isEmpty) return const [];
    final hits = <(int, int)>[];
    for (var i = 0; i < _paragraphs.length; i++) {
      // 备注段落不画搜索高亮（见 _buildParagraphSpans 提前返回），故不计数。
      if (_noteParagraphs.contains(i)) continue;
      final lower = _paragraphs[i].toLowerCase();
      var idx = lower.indexOf(lowerQuery);
      while (idx != -1) {
        hits.add((i, idx));
        idx = lower.indexOf(lowerQuery, idx + lowerQuery.length);
      }
    }
    return hits;
  }

  void _scrollToMatch(int index) {
    if (index < 0 || index >= _searchMatches.length) return;
    final para = _searchMatches[index].$1;
    // 搜索态下正文才刚从翻页PageView 切成 SingleChildScrollView，段落
    // GlobalKey 要等本帧构建完才可读，故延到帧末再定位。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      int? head;
      for (final g in _allClusterGroups()) {
        if (g.contains(para)) {
          head = g.first;
          break;
        }
      }
      if (head == null) return;
      final box = _paraTapKeys[head]?.currentContext?.findRenderObject()
          as RenderBox?;
      final scrollBox =
          _scrollViewKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || scrollBox == null || !box.hasSize) return;
      final viewportTop = scrollBox.localToGlobal(Offset.zero).dy;
      final paraTop = box.localToGlobal(Offset.zero).dy;
      final offset = (_scrollController.offset + paraTop - viewportTop - 8)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    });
  }

  void _goToPreviousMatch() {
    if (_searchMatches.isNotEmpty) {
      final newIndex = _currentMatchIndex > 0
          ? _currentMatchIndex - 1
          : _searchMatches.length - 1;
      setState(() {
        _currentMatchIndex = newIndex;
      });
      _scrollToMatch(newIndex);
    }
  }

  void _goToNextMatch() {
    if (_searchMatches.isNotEmpty) {
      final newIndex = (_currentMatchIndex + 1) % _searchMatches.length;
      setState(() {
        _currentMatchIndex = newIndex;
      });
      _scrollToMatch(newIndex);
    }
  }

  /// 段落的基准文字样式（含是否已读完的置灰、是否加粗）。
  TextStyle _paraBaseStyle(int i) => TextStyle(
        color: _paraDone[i] == true
            ? (_isDarkBg
                ? Colors.white.withOpacity(0.35)
                : const Color(0xFFBDBDBD))
            : _noteParagraphs.contains(i)
                ? const Color(0xFF71867A)
                : _boldParagraphs.contains(i)
                    ? (_isDarkBg ? Colors.white : Colors.black)
                    : (_isDarkBg ? Colors.white : const Color(0xFF212121)),
        fontSize: _noteParagraphs.contains(i)
            ? _fontSize - 3
            : _boldParagraphs.contains(i)
                ? _fontSize + 2
                : _fontSize,
        fontWeight: _boldParagraphs.contains(i) ? FontWeight.bold : null,
        height: _lineHeight,
        letterSpacing: 0.5,
      );

  /// 将第 i 段文字切成多不TextSpan：叠加「画线」下划线 不搜索结果高亮。
  /// 已画线的文字区域常Tap 识别器，单击即弹击复制 / 擦除(buy) / 感想 菜单。
  List<TextSpan> _buildParagraphSpans(int i) {
    final text = _paragraphs[i];
    final len = text.length;
    if (len == 0) return [TextSpan(text: '')];

    // ── 备注段落：按 \n 拆行，用 TextSpan(\n) 实现真正换行 ──
    if (_noteParagraphs.contains(i)) {
      final noteLines = text.split('\n');
      final spans = <TextSpan>[];
      for (var j = 0; j < noteLines.length; j++) {
        if (j > 0) spans.add(const TextSpan(text: '\n'));
        spans.add(TextSpan(text: noteLines[j]));
      }
      return spans;
    }

    // 画线区间：合并重取相邻成有序不相交段[(s,e)...]。
    final raw = <(int, int)>[];
    for (final u in _paraUnderlines[i] ?? const <Map<String, int>>[]) {
      final s = (u['start'] ?? 0).clamp(0, len);
      final e = (u['end'] ?? 0).clamp(0, len);
      if (e > s) raw.add((s, e));
    }
    raw.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final r in raw) {
      if (merged.isNotEmpty && r.$1 <= merged.last.$2) {
        final last = merged.removeLast();
        merged.add((last.$1, r.$2 > last.$2 ? r.$2 : last.$2));
      } else {
        merged.add(r);
      }
    }

    // 搜索高亮（按字符）。
    final isSrch = List<bool>.filled(len, false);
    final query = _searchController.text.toLowerCase();
    if (query.isNotEmpty) {
      final lower = text.toLowerCase();
      var idx = lower.indexOf(query);
      while (idx != -1) {
        for (var k = idx; k < idx + query.length && k < len; k++) {
          isSrch[k] = true;
        }
        idx = lower.indexOf(query, idx + query.length);
      }
    }

    final spans = <TextSpan>[];
    var pos = 0;
    for (final r in merged) {
      if (r.$1 > pos) spans.addAll(_plainSpans(text, pos, r.$1, isSrch));
      spans.addAll(_underlineSpans(text, i, r.$1, r.$2, isSrch));
      pos = r.$2;
    }
    if (pos < len) spans.addAll(_plainSpans(text, pos, len, isSrch));
    if (spans.isEmpty) spans.add(TextSpan(text: ''));
    return spans;
  }

  /// 非画线区间的普选span（仅按搜索高亮细分）。
  List<TextSpan> _plainSpans(String text, int s, int e, List<bool> isSrch) {
    final spans = <TextSpan>[];
    var start = s;
    while (start < e) {
      final se0 = isSrch[start];
      var end = start + 1;
      while (end < e && isSrch[end] == se0) {
        end++;
      }
      if (se0) {
        spans.add(TextSpan(
          text: text.substring(start, end),
          style: TextStyle(
            backgroundColor: _isDarkBg
                ? Colors.yellow.withValues(alpha: 0.3)
                : Colors.yellow,
          ),
        ));
      } else {
        spans.add(TextSpan(text: text.substring(start, end)));
      }
      start = end;
    }
    if (spans.isEmpty) spans.add(TextSpan(text: text.substring(s, e)));
    return spans;
  }

  /// 已画线区间的 span：整段加下划线，内部按搜索高亮细分。
  /// 单击判定不在 TextSpan 上挂识别器，而是由正文Listener 按几何命中完成
  /// （见 _tapInUnderlinedCluster），行为恒定且与 SelectableText 的选择手势不冲突。
  List<TextSpan> _underlineSpans(
      String text, int para, int s, int e, List<bool> isSrch) {
    final spans = <TextSpan>[];
    final fw = _boldParagraphs.contains(para) ? FontWeight.bold : null;
    final fc = _noteParagraphs.contains(para)
        ? const Color(0xFF71867A)
        : _boldParagraphs.contains(para)
            ? (_isDarkBg ? Colors.white : Colors.black)
            : null;
    var start = s;
    while (start < e) {
      final se0 = isSrch[start];
      var end = start + 1;
      while (end < e && isSrch[end] == se0) {
        end++;
      }
      spans.add(TextSpan(
        text: text.substring(start, end),
        style: TextStyle(
          fontWeight: fw,
          color: fc,
          decoration: TextDecoration.underline,
          decorationStyle: TextDecorationStyle.dotted,
          decorationColor: _isDarkBg ? Colors.white : const Color(0xFF212121),
          decorationThickness: 1.4,
          backgroundColor: se0
              ? (_isDarkBg ? Colors.yellow.withOpacity(0.3) : Colors.yellow)
              : null,
        ),
      ));
      start = end;
    }
    if (spans.isEmpty) {
      spans.add(TextSpan(
        text: text.substring(s, e),
        style: TextStyle(
          fontWeight: fw,
          color: fc,
          decoration: TextDecoration.underline,
          decorationStyle: TextDecorationStyle.dotted,
          decorationColor: _isDarkBg ? Colors.white : const Color(0xFF212121),
          decorationThickness: 1.4,
        ),
      ));
    }
    return spans;
  }

  /// 统一的菜单卡片：横向的复制 / 画线(擦除) / 本段全选/ 感想（每项图标上文字下）。
  /// 单击画线（Overlay）与长按选中（contextMenuBuilder）共用，保证两而UI 一致。
  /// [close] 在需要关闭弹窗时调用（复到/ 感想）；画线与全选不关闭，可继续操作。
  /// [onResolveRange] 为空时用 [start,end]（单击画线）；否则用它实时取当前选区（长按选中）。
  /// [cluster] 非空时选区为「紧密连段簇」合并文本的坐标：画线感想会按段逐个作用。
  Widget _buildMenuCard({
    required int para,
    required int start,
    required int end,
    required VoidCallback close,
    (int, int)? Function()? onResolveRange,
    VoidCallback? onSelectFull,
    List<int>? cluster,
    void Function(int start, int end)? drawUnderline,
  }) {
    final multi = cluster != null && cluster.length > 1;
    if (multi) {
      final text = _clusterText(cluster);
      final s = start.clamp(0, text.length);
      final e = end.clamp(0, text.length);
      // 画线按钮初始态：选区覆盖的任一段有画线即视为「已画线（可擦除）」。
      final underlined = _clusterLocalSegments(cluster, s, e).any((seg) =>
          (_paraUnderlines[seg.$1] ?? const <Map<String, int>>[]).any(
              (u) => seg.$2 < (u['end'] ?? 0) && seg.$3 > (u['start'] ?? 0)));
      final hasIdea = _clusterLocalSegments(cluster, s, e)
          .any((seg) => (_paraNotes[seg.$1] ?? const []).isNotEmpty);

      return _IdeaMenuCard(
        para: para,
        paragraph: text,
        initialStart: s,
        initialEnd: e,
        initialUnderlined: underlined,
        initialHasIdea: hasIdea,
        isDarkBg: _isDarkBg,
        close: close,
        onSelectFull: onSelectFull,
        onResolveRange: onResolveRange,
        // 有显开drawUnderline（如单击画线的「擦除整簇」）时优先使用；
        // 长按选中路径未传，回退到逐段画线/擦除开关。
        onDrawUnderline: drawUnderline ??
            (ss, ee) => _toggleUnderlineCluster(cluster, ss, ee),
        onOpenNote: (ss, ee) => _openIdeaFromRangeCluster(cluster, ss, ee),
        onSearch: (t) {
          Clipboard.setData(ClipboardData(text: t));
          assistantVisible.value = true;
        },
      );
    }
    if (para < 0 || para >= _paragraphs.length) return const SizedBox.shrink();
    final p = _paragraphs[para];
    final s = start.clamp(0, p.length);
    final e = end.clamp(0, p.length);
    final underlined = (_paraUnderlines[para] ?? const <Map<String, int>>[])
        .any((u) => s < (u['end'] ?? 0) && e > (u['start'] ?? 0));

    return _IdeaMenuCard(
      para: para,
      paragraph: p,
      initialStart: s,
      initialEnd: e,
      initialUnderlined: underlined,
      initialHasIdea: (_paraNotes[para] ?? const []).isNotEmpty,
      isDarkBg: _isDarkBg,
      close: close,
      onSelectFull: onSelectFull,
      onResolveRange: onResolveRange,
      onDrawUnderline:
          drawUnderline ?? (ss, ee) => _toggleUnderline(para, ss, ee),
      onOpenNote: (ss, ee) => _openIdeaFromRange(para, ss, ee),
      onSearch: (t) {
        Clipboard.setData(ClipboardData(text: t));
        assistantVisible.value = true;
      },
    );
  }

  /// 移除单个浮层菜单条目并从跟踪列表中剔除；[onDismiss] 由调用方触发。
  void _removeMenuEntry(OverlayEntry entry) {
    _activeMenuEntries.remove(entry);
    if (entry.mounted) entry.remove();
  }

  /// 打开「感想」编辑页前，确保所有长按选中 / 单击画线的浮层弹窗已被移除，
  /// 避免弹窗残留显示在新的感想输入界面上。
  void _clearSelectionMenu() {
    // 递增请求序号，作废仍在排队的 addPostFrameCallback，防止其在跳转后
    // 重新插入菜单弹窗。
    _menuRequestId++;
    for (final entry in _activeMenuEntries) {
      if (entry.mounted) entry.remove();
    }
    _activeMenuEntries.clear();
    _selectionMenuEntry = null;
    _selectionTextState = null;
    _selectionRange = null;
  }

  /// 根据当前选中的[start,end) 区间打开「感想」编辑页，顶部显示被选中的文字。
  void _openIdeaFromRange(int para, int start, int end) {
    _clearSelectionMenu();
    if (para < 0 || para >= _paragraphs.length) return;
    final p = _paragraphs[para];
    final s = start.clamp(0, p.length);
    final e = end.clamp(0, p.length);
    final display = (s < e && e <= p.length) ? p.substring(s, e) : p;
    _showNoteDialog(para, displayText: display);
  }

  /// 浮层菜单：在 [anchor] 处弹出统一的卡片（复制 / 画线(擦除) / 本段全选/ 感想）。
  /// 会测量卡片实际尺寸并夹在屏幕安全区内，优先显示在选中处上方、居中；
  /// 空间不足则自动转下方。
  /// [showBarrier]：为 true 时点击菜单外关闭（单击画线场景）；为 false 时不遮罩。
  /// 允许继续拖动选中句柄，通过选区折叠自动关闭（长按选中场景）。
  /// [onResolveRange]：返回当前应作用的目标区间；为空时用 [start,end]（单击画线场景）。
  /// [cluster] 非空时[start,end]/[onResolveRange] 均为紧密连段簇合并文本的坐标。
  OverlayEntry? _showFloatingMenu({
    required int para,
    required int start,
    required int end,
    required Offset anchor,
    VoidCallback? onDismiss,
    bool showBarrier = true,
    (int, int)? Function()? onResolveRange,
    VoidCallback? onSelectFull,
    List<int>? cluster,
    void Function(int start, int end)? drawUnderline,
  }) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return null;
    final size = MediaQuery.of(context).size;
    final safe = MediaQuery.of(context).padding;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          if (showBarrier)
            // 点击菜单外任意处关闭并恢复正常界面。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  _removeMenuEntry(entry);
                  onDismiss?.call();
                },
              ),
            ),
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _MenuLayoutDelegate(
                anchor: anchor,
                overlaySize: size,
                safeArea: safe,
              ),
              child: _buildMenuCard(
                para: para,
                start: start,
                end: end,
                close: () {
                  _removeMenuEntry(entry);
                  onDismiss?.call();
                },
                onResolveRange: onResolveRange,
                onSelectFull: onSelectFull,
                cluster: cluster,
                drawUnderline: drawUnderline,
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(entry);
    _activeMenuEntries.add(entry);
    return entry;
  }

  /// 单击已画线文字的擦除菜单：由正文 Listener 的几何判定调用（见Timer.run）。
  /// 紧密连段簇（```。。。//``` 合并整段）时 [cluster].length > 1，
  ///  - 预览经文为整簇，复制/感想作用于整簇选区，
  ///  - 「擦除」作用于整簇（整段一次性清除），而非仅命中的单个段落。
  void _showUnderlineMenu(
      List<int> cluster, int para, int start, int end, Offset anchor) {
    if (!mounted) return;
    _clearSelectionMenu();
    final multi = cluster.length > 1;
    // 把段落内坐标换算成簇合并文本坐标，供整簇菜单使用。
    var paraOffset = 0;
    if (multi) {
      for (final idx in cluster) {
        if (idx == para) break;
        paraOffset += _paragraphs[idx].length + 1;
      }
    }
    final ss = paraOffset + start;
    final ee = paraOffset + end;
    _showFloatingMenu(
      para: para,
      start: ss,
      end: ee,
      anchor: anchor,
      cluster: multi ? cluster : null,
      drawUnderline: (s, e) => multi
          ? _removeUnderlineCluster(cluster)
          : _removeUnderlineRange(para, s, e),
    );
  }

  /// 渲染簇的 GlobalKey（以首段下标为键，跨帧复用）。
  GlobalKey _paraTapKey(int para) =>
      _paraTapKeys.putIfAbsent(para, GlobalKey.new);

  /// 判定全局坐标 [global] 是否落在某个包含画线的段落内（含画线文字上和段落空白处）。
  /// 按渲染簇的paintBounds 做粗粒度命中：只要有任意段落含画线，该簇内
  /// 的点击一律由正文 Listener 拦截（不弹底部面板）。
  /// 点在画线文字上时额外返回 (para, start, end)，供弹出「擦除」小菜单，
  /// 点在非画线区域时返回 (para, -1, -1)，仅抑制面板，不弹菜单。
  /// 采用几何命中：用与正文完全一致的 span 重新排版，把点击点映射到字符，
  /// 再定位到具体段落及画线区间，行为恒定、不依赖手势竞技场时序。
  ({List<int> cluster, int para, int start, int end})? _resolveUnderlineHit(
      Offset global) {
    for (final group in _allClusterGroups()) {
      final key = _paraTapKeys[group.first];
      if (key == null) continue;
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final local = box.globalToLocal(global);
      if (!box.paintBounds.contains(local)) continue;
      // 簇内无任何画线→该簇是普通正文，可正常弹底部面板。
      final hasAny = group.any(
          (i) => (_paraUnderlines[i] ?? const <Map<String, int>>[]).isNotEmpty);
      if (!hasAny) continue;
      // 用与正文同一经span 重新排版，把点击点映射为合并文本字符偏移，
      // 再定位到具体段落及画线区间（命中 →擦除菜单；未命中 →仅抑制面板）。
      var off = 0;
      final tp = TextPainter(
        text: TextSpan(children: _buildClusterSpans(group)),
        textDirection: TextDirection.ltr,
        maxLines: null,
      )..layout(maxWidth: box.size.width);
      if (!tp.didExceedMaxLines) {
        try {
          off = tp.getPositionForOffset(local).offset;
        } catch (_) {}
      }
      tp.dispose();
      var base = 0;
      for (final i in group) {
        final len = _paragraphs[i].length;
        if (off >= base && off < base + len) {
          final r = _underlineRangeCovering(i, off - base);
          if (r != null) {
            return (cluster: group, para: i, start: r.$1, end: r.$2);
          }
          return (cluster: group, para: i, start: -1, end: -1);
        }
        base += len + 1; // 簇内段落间以 `\n` 连接（见 _buildClusterSpans）。
      }
      return (cluster: group, para: group.last, start: -1, end: -1);
    }
    return null;
  }

  /// 段落 [i] 中覆盖第 [o] 个字符的合并画线区间；不在画线上返回 null。
  (int, int)? _underlineRangeCovering(int i, int o) {
    final len = _paragraphs[i].length;
    if (o < 0 || o >= len) return null;
    final raws = <(int, int)>[];
    for (final u in _paraUnderlines[i] ?? const <Map<String, int>>[]) {
      final s = (u['start'] ?? 0).clamp(0, len);
      final e = (u['end'] ?? 0).clamp(0, len);
      if (e > s) raws.add((s, e));
    }
    raws.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final r in raws) {
      if (merged.isNotEmpty && r.$1 <= merged.last.$2) {
        final last = merged.removeLast();
        merged.add((last.$1, r.$2 > last.$2 ? r.$2 : last.$2));
      } else {
        merged.add(r);
      }
    }
    for (final r in merged) {
      if (o >= r.$1 && o < r.$2) return r;
    }
    return null;
  }

  /// 整块（紧密连段簇）擦除：清除簇内所有段落的全部画线。
  /// 一次性在单个 setState 里清空整簇的画线（避免逐段擦除造成的
  /// “逐行擦除”），再逐段写入云端。
  Future<void> _removeUnderlineCluster(List<int> cluster) async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLoginForNotes();
      return;
    }
    final changes = <int, List<Map<String, int>>>{};
    for (final i in cluster) {
      if (i < 0 || i >= _paragraphs.length) continue;
      final current = (_paraUnderlines[i] ?? const <Map<String, int>>[]);
      if (current.isEmpty) continue;
      // 有画线的段落才需要清空写入；无画线的段落跳过。
      changes[i] = [];
    }
    if (changes.isEmpty) return;
    await _applyUnderlinesAndSave(changes);
  }

  /// 批量应用画线变更：在单个 [setState] 里同步更新各段画线，随后逐段写入
  /// 云端。这样紧密连段簇（```。。。//``` 合并的多段）画线/擦除是一次态
  /// 全部生效，而不是逐段刷新导致的逐行渐变效果。
  Future<void> _applyUnderlinesAndSave(
      Map<int, List<Map<String, int>>> changes) async {
    setState(() {
      changes.forEach((k, underlines) {
        if (underlines.isEmpty) {
          _paraUnderlines.remove(k);
        } else {
          _paraUnderlines[k] = underlines;
        }
      });
      _activeNoteParagraphIndex = -1;
    });
    try {
      for (final MapEntry<int, List<Map<String, int>>> entry
          in changes.entries) {
        final k = entry.key;
        await CloudNotesService.instance.saveParagraphNote(
          sutraKey: _sutraKey,
          index: k,
          text: _paragraphs[k],
          notes: List<ParaNote>.of(_paraNotes[k] ?? const []),
          underlines: entry.value,
        );
      }
      if (!mounted) return;
      _loadParagraphNotes();
      // 「记录」时间线：连段簇画线/擦除直写云端、不经[_saveParagraphNote]，
      // 这里按每段最终画线列表补一次索引同步（差集画syncParagraph 处理）。
      for (final k in changes.keys) {
        if (k < 0 || k >= _paragraphs.length) continue;
        unawaited(RecordIndex.instance.syncParagraph(
          sutraKey: _sutraKey,
          para: k,
          paraText: _paragraphs[k],
          thought: _paraNotes[k]?.isNotEmpty == true
              ? _paraNotes[k]!.first.text.trim()
              : '',
          underlines: [
            for (final u in changes[k] ?? const <Map<String, int>>[])
              (start: u['start'] ?? 0, end: u['end'] ?? 0),
          ],
        ));
      }
    } catch (e) {
      debugPrint('[reading] 批量保存段落画线失败: $e');
      if (!mounted) return;
      final msg = e is CloudApiException ? e.message : '网络异常，请稍后重试';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存画线失败，msg')),
      );
    }
  }

  /// 画线 / 取消画线：给笔i 段[start,end) 区间添加或移除下划线，并云端同步。
  /// 选中区间已完全被现有画线覆盖 →擦除；否到→新增整段 [start,end)（渲染端会自动合并重叠）。
  Future<void> _toggleUnderline(int i, int start, int end) async {
    if (start >= end) return;
    if (!AuthService.instance.isLoggedIn) {
      _promptLoginForNotes();
      return;
    }
    final current = List<Map<String, int>>.from(_paraUnderlines[i] ?? const []);
    // 选中范围是否已被某条画线完整覆盖（此时视为“擦除”）。
    final covering = current
        .where((u) => (u['start'] ?? 0) <= start && (u['end'] ?? 0) >= end)
        .toList();
    List<Map<String, int>> next;
    if (covering.isNotEmpty) {
      final removeSet = covering.toSet();
      next = [
        for (final u in current)
          if (!removeSet.contains(u)) u,
      ];
    } else {
      // 新增整段选中范围；与既有画线重叠的部分会在渲染时自动合并。
      next = [
        ...current,
        {'start': start, 'end': end}
      ];
    }
    next.sort((a, b) => (a['start'] ?? 0).compareTo(b['start'] ?? 0));
    await _saveParagraphNote(
      i,
      List<ParaNote>.of(_paraNotes[i] ?? const []),
      underlines: next,
    );
  }

  /// 移除笔i 段与 [start,end) 相交的全部画线（单击画线菜单的「擦除」）。
  /// 语义与画线归集页 / 分享帖的删除一致：点击的那条可见画线整条消失；
  /// 无画线被实际移除时直接返回，不落云端。
  Future<void> _removeUnderlineRange(int i, int start, int end) async {
    if (start >= end) return;
    if (!AuthService.instance.isLoggedIn) {
      _promptLoginForNotes();
      return;
    }
    final current = List<Map<String, int>>.from(_paraUnderlines[i] ?? const []);
    final next = current
        .where((u) => !(((u['end'] ?? 0) > start) && ((u['start'] ?? 0) < end)))
        .toList();
    if (next.length == current.length) return;
    await _saveParagraphNote(
      i,
      List<ParaNote>.of(_paraNotes[i] ?? const []),
      underlines: next,
    );
  }

  /// 选区变化：更新最新范围，供浮层画线/感想/复制 使用，
  /// 当长按选中浮层打开、而用户把选区折叠（点击空白/ 清空）时，
  /// 关闭浮层并恢复为正常阅读页（无遮罩场景下的“点外关闭”）。
  void _onSelectionChanged(TextSelection sel) {
    if (sel.isCollapsed) {
      _selectionRange = null;
      if (_selectionMenuEntry == null) return;
      final OverlayEntry entry = _selectionMenuEntry!;
      _selectionMenuEntry = null;
      _selectionTextState = null;
      _removeMenuEntry(entry);
      return;
    }
    _selectionRange = (sel.start, sel.end);
  }

  /// 「本段全选」：把当前选中文字所在整个段落的蓝色高亮扩展到整段，
  /// 并更新[_selectionRange] 供后续画线感想作用于整段。
  void _selectFullParagraph(int i) {
    if (i < 0 || i >= _paragraphs.length) return;
    final p = _paragraphs[i];
    final state = _selectionTextState;
    if (state != null) {
      state.selectAll(SelectionChangedCause.tap);
      // selectAll 会把选区整段选中，同步记录供 onResolveRange 读取。
      _selectionRange = (0, p.length);
    }
  }

  /// 长按选中文字后的菜单：与「单击画线」共用同一个卡版UI
  /// （复到/ 画线(擦除) / 本段全选/ 感想，每项图标上文字下）。
  /// 不直接把卡片返回给框架（那样会铺满整屏变白屏），而是返回空组件，
  /// 画[Overlay] 在选中处上方独立弹出同一张卡片，经文保持可见。
  /// 不使用全屏遮罩，句柄仍可拖动调整选区；点 画线/感想 时读取实时选区，
  /// 确保画线覆盖的就是当前可见的高亮范围（而非长按时的初始单字）。
  /// [cluster] 为多段紧密连段簇时，选区坐标基于簇的合并文本；单段则传入单元素簇。
  Widget _buildSelectionToolbar(BuildContext context,
      EditableTextState editableTextState, List<int> cluster) {
    // 本页被其他路由覆盖（如感想编辑页）时不再弹任何菜单，
    // 也不记录选区状态：直接返回空组件即可。
    if (_coveredByRoute) return const SizedBox.shrink();
    // 每次长按都视为一次新的菜单请求；用递增序号作废切换页面后仍排队的旧回调。
    final myId = ++_menuRequestId;
    final len = _clusterText(cluster).length;
    final sel = editableTextState.textEditingValue.selection;
    final start = sel.isValid ? sel.start.clamp(0, len) : 0;
    final end = sel.isValid ? sel.end.clamp(0, len) : 0;
    final anchor = editableTextState.contextMenuAnchors.primaryAnchor;
    _selectionTextState = editableTextState;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectionMenuEntry != null || myId != _menuRequestId) {
        return;
      }
      _selectionMenuEntry = _showFloatingMenu(
        para: cluster.first,
        start: start,
        end: end,
        anchor: anchor,
        showBarrier: false,
        cluster: cluster,
        // 读取当前最新选区（随句柄拖动即时更新），保证画线/感想作用于用户当前高亮的整段。
        onResolveRange: () {
          final r = _selectionRange;
          if (r != null) {
            final cs = r.$1.clamp(0, len);
            final ce = r.$2.clamp(0, len);
            if (ce > cs) return (cs, ce);
          }
          final s0 = _selectionTextState?.textEditingValue.selection;
          if (s0 == null || !s0.isValid || s0.isCollapsed) return null;
          final cs2 = s0.start.clamp(0, len);
          final ce2 = s0.end.clamp(0, len);
          if (ce2 <= cs2) return null;
          return (cs2, ce2);
        },
        // 「本段全选」：把视觉高亮扩大到整段（真实选中整段文字），并置后续画线/感想作用整段。
        onSelectFull: () => cluster.length > 1
            ? _selectFullCluster(cluster)
            : _selectFullParagraph(cluster.first),
        onDismiss: () {
          _selectionMenuEntry = null;
          _selectionTextState = null;
          _selectionRange = null;
          _selectionRange = null;
        },
      );
    });
    return const SizedBox.shrink();
  }

  TextStyle get _flipTextStyle => TextStyle(
        color: _isDarkBg ? Colors.white : const Color(0xFF212121),
        fontSize: _fontSize,
        height: _lineHeight,
        letterSpacing: 0.5,
      );

  /// 按段落分页：每页包含若干「完整」段落（段内各自带操作栏），
  /// 装不下的段落整体放入下一页，避免跨页把一段截断、也避免一段只有一条操作栏。
  List<List<int>> _paginateParagraphs(double width, double height) {
    if (_paragraphs.isEmpty) return const [];
    // 每段除文字外的高度：操作栏行(~20) + 贴段留白(4) + 段间路24)。
    const extras = 48.0;
    // 正文块在渲染时左右各本16px 内边距（见_buildClusterParagraph），
    // 实际可用排版宽度比视口窄 32px。测量必须按同一宽度，否则会把文字
    // 估矮、一页塞进过多段落，导致末段操作栏越过页面底边被裁掉看不见。
    final textWidth = (width - 32.0).clamp(1.0, double.infinity).toDouble();
    // 末段操作栏正好贴到页面底边时，TextPainter 与选择文本实际排版可能本
    // 一两像素出入，留出少量余量，保证操作栏完整落在页内、不被裁切。
    final pageHeight = height - 4.0;
    final pages = <List<int>>[];
    var current = <int>[];
    var used = 0.0;
    for (var i = 0; i < _paragraphs.length; i++) {
      final tp = TextPainter(
        text: TextSpan(text: _paragraphs[i], style: _flipTextStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: textWidth);
      final h = tp.height + extras;
      if (current.isNotEmpty && used + h > pageHeight) {
        pages.add(current);
        current = [];
        used = 0.0;
      }
      current.add(i);
      used += h;
    }
    if (current.isNotEmpty) pages.add(current);
    return pages;
  }

  /// 获取（并缓存）翻页模式的页面列表，首次时恢复上次阅读进度。
  List<List<int>> _getFlipPages(double width, double height) {
    final key =
        '$_fontSize|$_lineHeight|${width.toStringAsFixed(1)}|${height.toStringAsFixed(1)}|para';
    if (key == _flipCacheKey && _flipPages.isNotEmpty) return _flipPages;
    _flipCacheKey = key;
    _flipPages = _paginateParagraphs(width, height);

    if (!_flipPageRestored && _savedProgress != null && _flipPages.length > 1) {
      _flipPageRestored = true;
      final target = (_savedProgress! * _flipPages.length)
          .floor()
          .clamp(0, _flipPages.length - 1);
      _currentFlipPage = target;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (_pageController?.hasClients ?? false)) {
          _pageController?.jumpToPage(target);
        }
      });
      _scrollProgress = (target + 1) / _flipPages.length;
    } else if (_currentFlipPage >= _flipPages.length) {
      _currentFlipPage = _flipPages.length - 1;
    }
    return _flipPages;
  }

  void _onFlipPageChanged(int index) {
    setState(() {
      _currentFlipPage = index;
      _scrollProgress =
          _flipPages.length > 1 ? (index + 1) / _flipPages.length : 1.0;
    });
    _saveFlipProgress();
    if (index == _flipPages.length - 1) {
      _markAsRead();
    }
  }

  Future<void> _saveFlipProgress() async {
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('progress_$keyPath', _scrollProgress);
  }

  /// 翻页模式的某一页：按渲染簇分组渲染。簇内紧密段落合并成一个可选文本块，
  /// 跨段拖动选择 / 本段全选不再被段边界卡住；操作栏仍按每段各自显示。
  Widget _buildFlipPage(List<int> paras, int pageIndex) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final group in _clusterGroups(paras))
            _buildClusterParagraph(group,
                showUnaligned: false, actionsRight: false),
        ],
      ),
    );
  }
}

/// 长按选中 / 单击画线的统一菜单卡片：横后复制 / 画线(擦除) / 全选/ 感想。
/// 画线与全选时不关闭弹窗，可继续点击感想（针对当前选中的文字）。
class _IdeaMenuCard extends StatefulWidget {
  final int para;
  final String paragraph;
  final int initialStart;
  final int initialEnd;
  final bool initialUnderlined;
  final bool initialHasIdea;
  final bool isDarkBg;
  final VoidCallback close;
  final void Function(int start, int end) onDrawUnderline;
  final void Function(int start, int end) onOpenNote;
  final (int, int)? Function()? onResolveRange;

  /// 「本段全选」时回调外层：把屏幕上的选中高亮扩展到整段（长按选中场景）。
  final VoidCallback? onSelectFull;

  /// 「搜索」回调：传入选中的文字，由外层打开 AI 助手。
  final void Function(String text)? onSearch;

  const _IdeaMenuCard({
    required this.para,
    required this.paragraph,
    required this.initialStart,
    required this.initialEnd,
    required this.initialUnderlined,
    required this.initialHasIdea,
    required this.isDarkBg,
    required this.close,
    required this.onDrawUnderline,
    required this.onOpenNote,
    this.onResolveRange,
    this.onSelectFull,
    this.onSearch,
  });

  @override
  State<_IdeaMenuCard> createState() => _IdeaMenuCardState();
}

class _IdeaMenuCardState extends State<_IdeaMenuCard> {
  late int _start;
  late int _end;
  late bool _underlined;
  // 点击「本段全选」后置真：之后画线感想作用于整段，不再依赖实时选区。
  bool _overrideFull = false;

  @override
  void initState() {
    super.initState();
    _start = widget.initialStart;
    _end = widget.initialEnd;
    _underlined = widget.initialUnderlined;
  }

  /// 当前应作用的目标区间：优先「本段全选」；其次实时选区；最后初始区间。
  (int, int) get _activeRange {
    if (_overrideFull) return (0, widget.paragraph.length);
    final live = widget.onResolveRange?.call();
    if (live != null) return live;
    return (_start, _end);
  }

  String get _selectedText {
    final (s, e) = _activeRange;
    final cs = s.clamp(0, widget.paragraph.length);
    final ce = e.clamp(0, widget.paragraph.length);
    return (ce > cs) ? widget.paragraph.substring(cs, ce) : '';
  }

  Widget _item(IconData icon, String label, VoidCallback onTap) {
    final fg = widget.isDarkBg ? Colors.white : const Color(0xFF212121);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: fg),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(fontSize: 12, color: fg)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.isDarkBg ? const Color(0xFF2A2A2A) : Colors.white;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      color: bg,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _item(Icons.copy, '复制', () {
            final t = _selectedText;
            widget.close();
            if (t.isNotEmpty) {
              Clipboard.setData(ClipboardData(text: t));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制到剪贴板')),
              );
            }
          }),
          _item(_underlined ? Icons.undo : Icons.format_underlined,
              _underlined ? '擦除' : '画线', () {
            final (s, e) = _activeRange;
            setState(() => _underlined = !_underlined);
            widget.onDrawUnderline(s, e);
          }),
          _item(Icons.select_all, '本段全选', () {
            setState(() {
              _overrideFull = true;
              _start = 0;
              _end = widget.paragraph.length;
              _underlined = false;
            });
            // 同步把屏幕上的选中高亮扩展到整段（长按选中场景）。
            widget.onSelectFull?.call();
          }),
          _item(Icons.edit_note, '备注', () {
            final (s, e) = _activeRange;
            widget.close();
            widget.onOpenNote(s, e);
          }),
          _item(Icons.search, '搜索', () {
            final t = _selectedText;
            widget.close();
            if (t.isNotEmpty) widget.onSearch?.call(t);
          }),
        ],
      ),
    );
  }
}

/// 浮层卡片的自适应布局：以上边/下边锚点为基准，把卡片居中并夹在屏幕安全区内。
class _MenuLayoutDelegate extends SingleChildLayoutDelegate {
  final Offset anchor;
  final Size overlaySize;
  final EdgeInsets safeArea;

  _MenuLayoutDelegate({
    required this.anchor,
    required this.overlaySize,
    required this.safeArea,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 10.0;
    final minLeft = safeArea.left + margin;
    final maxRight = size.width - safeArea.right - margin;
    final minTop = safeArea.top + margin;
    final maxBottom = size.height - safeArea.bottom - margin;

    // 水平居中于选中处，并夹在左右安全区内（卡片比屏幕宽时从安全区开始铺）。
    var left = anchor.dx - childSize.width / 2;
    if (left < minLeft) left = minLeft;
    if (left + childSize.width > maxRight) left = maxRight - childSize.width;
    if (left < minLeft) left = minLeft;

    // 优先显示在选中处上方；上方放不下则转下方；都不够时夹在垂直范围内。
    var top = anchor.dy - childSize.height - margin;
    if (top < minTop) top = anchor.dy + margin;
    if (top + childSize.height > maxBottom) top = maxBottom - childSize.height;
    if (top < minTop) top = minTop;

    return Offset(left, top);
  }

  @override
  bool shouldRelayout(covariant _MenuLayoutDelegate oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.overlaySize != overlaySize ||
      oldDelegate.safeArea != safeArea;
}
