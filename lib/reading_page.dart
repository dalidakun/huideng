import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sutra_asset_path.dart';
import 'sutra_downloader.dart';
import 'sutra_edit_page.dart' show editedSutraFilePath;
import 'sutra_favorites.dart';
import 'sutra_read_later.dart';
import 'app_state.dart';
import 'reader_preferences.dart';
import 'note_edit_page.dart';
import 'reading_time_service.dart';
import 'sutra_list_page.dart'
    show
        routeObserver,
        sutraDisplayTitleWithPath,
        sutraBaseTitle,
        loadLocalMultiVolumeBases;
import 'reading_guide_page.dart';
import 'reading_notes_page.dart';
import 'reading_note_edit_page.dart';
import 'paragraph_thoughts_page.dart';
import 'cloud_notes_service.dart';
import 'auth_service.dart';

import 'app_palette.dart';
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
  State<ReadingPage> createState() => _ReadingPageState();
}

class _ReadingPageState extends State<ReadingPage>
    with WidgetsBindingObserver, RouteAware {
  String _content = '';
  List<String> _paragraphs = [];
  double _fontSize = 16.0;
  double _lineHeight = 1.8;
  int _pageMode = ReaderPreferences.pageModeScroll;
  int _bgColorIndex = 0;
  bool _isDarkMode = false;
  late ScrollController _scrollController;
  PageController? _pageController;
  final TextEditingController _searchController = TextEditingController();
  bool _showSearchBar = false;
  bool _showMoreMenu = false;
  bool _showStylePanel = false;
  Offset? _pointerDownPos;
  DateTime? _pointerDownTime;
  bool _longPressActive = false;
  bool _menuOpenAtDown = false;
  bool _hasTextSelection = false;
  bool _actionRowTapped = false; // 点击段落操作栏（AI译/笔记/方框）时置true，阻止外层Listener触发面板
  final GlobalKey _moreMenuKey = GlobalKey();

  // ── AI 翻译面板状态 ─────────────────────────
  String? _aiParagraph; // 当前选中要翻译的段落原文
  int _aiParagraphIndex = -1; // 该段在 _paragraphs 中的下标
  bool _aiPanelLoading = false; // 翻译请求进行中
  String? _aiTranslation; // 已生成的白话译文
  String? _aiError; // 错误信息
  bool _aiDiagLoading = false; // 诊断请求进行中
  String? _aiDiagText; // 诊断结果文本
  List<int> _searchMatches = [];
  int _currentMatchIndex = 0;
  double _scrollProgress = 0.0;

  // ── 读经段落笔记 / 完成态（云端同步） ─────────
  Map<int, String> _paraNotes = {}; // index -> 备注文本（空串表示无）
  Map<int, List<Map<String, int>>> _paraUnderlines = {}; // index -> 该段已画线的文字区间 [{start,end}]
  // 单击已画线文字时触发弹窗的手势识别器容器（随 build 重建）。
  final List<TapGestureRecognizer> _underlineTapRecognizers = [];
  Offset? _underlineTapPos;
  // 长按选中时的菜单是否已弹出（防止拖动句柄时重复插入 Overlay）。
  OverlayEntry? _selectionMenuEntry;
  // 所有仍处于显示中的浮层菜单条目（长按选中 + 单击画线），
  // 打开其他页面（如想法输入页）前统一移除，避免残留弹窗。
  final List<OverlayEntry> _activeMenuEntries = [];
  // 每一次长按选中的菜单请求序号。用于丢弃切换页面 / 关闭弹窗后仍排队的
  // addPostFrameCallback，避免其在想法输入页上重新插入残留的「复制/画线」弹窗。
  int _menuRequestId = 0;
  // 本页之上有其他路由（想法编辑页等）时为 true：期间禁止重建浮层菜单，
  // 否则选区收起会再次触发 contextMenuBuilder，把弹窗插到新页面上方。
  bool _coveredByRoute = false;
  // 长按选中的 EditableTextState，用于点 画线/想法/复制 时读取实时选区。
  EditableTextState? _selectionTextState;
  // 每次选区变化时更新的最新范围（长按初始为单字，拖动句柄后为完整范围）。
  (int, int)? _selectionRange;
  Map<int, bool> _paraDone = {}; // index -> 是否已读完/学完
  Map<int, bool> _paraShared = {}; // index -> 该段笔记是否已分享到菩提空间
  Map<int, String> _paraCloudIds = {}; // index -> 分享后的云端帖子 ID
  bool _paraNotesLoading = false;
  int _activeNoteParagraphIndex = -1; // 正在编辑备注的段落（用于输入框）
  final TextEditingController _noteInputController = TextEditingController();
  late final String? _resolvedFilePath;
  bool _isLoadingContent = true;
  bool _needsDownload = false;
  bool _isDownloading = false;
  double _downloadProgress = 0;
  bool _isFavorite = false;
  bool _isRead = false;
  bool _isReadLater = false;
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

  /// 顶部标题展示名（含「卷X」卷标）：异步加载多卷集合后计算；
  /// 加载完成前先显示去掉 CBETA 编号的基础经名。
  String? _displayTitle;

  /// 当前展示标题：卷标就绪前兜底为基础经名，避免标题栏闪现 CBETA 编号。
  String get _titleShown => _displayTitle ?? sutraBaseTitle(widget.title);

  Future<void> _loadDisplayTitle() async {
    final mvBases = await loadLocalMultiVolumeBases();
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
    ReadingTimeService.instance.start();
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
    _loadDisplayTitle();
  }

  /// 把任意形式的经书路径规范化为打包资产路径（assets/sutras_ascii/...）：
  ///  - 打包资产路径（含旧版中文路径）按经书 ID 重新定位；
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
      final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final raw = prefs.getString('daily_sutra_history') ?? '{}';
      final Map<String, dynamic> history = jsonDecode(raw);
      final List<dynamic> dayList = (history[today] as List<dynamic>?) ?? [];
      dayList.removeWhere((e) => e['filePath'] == savePath);
      final progress = prefs.getDouble('progress_$savePath') ?? 0.0;
      dayList.insert(0, {'title': widget.title, 'filePath': savePath, 'progress': progress});
      history[today] = dayList;
      await prefs.setString('daily_sutra_history', jsonEncode(history));
    });
  }

  Future<void> _loadSavedScrollState() async {
    final prefs = await SharedPreferences.getInstance();
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath == null) return;
    // 兼容旧版本用本机绝对路径命名的 scroll_ 键（换机/重装后
    // 云端同步回来的可能是这类键）：取首个候选键的滚动位置。
    final variants =
        await SutraDownloader.pathKeyVariants(keyPath, title: widget.title);
    double? savedPos;
    for (final v in variants) {
      savedPos ??= prefs.getDouble('scroll_$v');
    }
    // 进度以规范路径键的最新值（阅读页实时写入，离开时即保存）为准，
    // 规范键缺失时兼容旧键名并回退每日阅读历史，避免换机/重装后进度清零。
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
  void didPush() => ReadingTimeService.instance.start();

  @override
  void didPopNext() {
    ReadingTimeService.instance.start();
    // 回到本页：恢复允许弹窗（下次长按选中）。
    _coveredByRoute = false;
  }

  @override
  void didPushNext() {
    ReadingTimeService.instance.stop();
    // 有新页面盖在本页上（如想法编辑页）：清掉浮层菜单并禁止其重建。
    // 否则失焦导致选区收起时 contextMenuBuilder 会再次回调，
    // 把「复制/画线」弹窗重新插到新页面上方，形成残留。
    _clearSelectionMenu();
    _coveredByRoute = true;
  }

  @override
  void didPop() => ReadingTimeService.instance.stop();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ReadingTimeService.instance.start();
    } else {
      ReadingTimeService.instance.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_subscribed) routeObserver.unsubscribe(this);
    ReadingTimeService.instance.stop();
    _scrollController.dispose();
    _pageController?.dispose();
    _searchController.dispose();
    _noteInputController.dispose();
    for (final r in _underlineTapRecognizers) {
      r.dispose();
    }
    _underlineTapRecognizers.clear();
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
        WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRestoreScroll());
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
      // Sync displayed progress to real position.
      setState(() {
        _scrollProgress = maxScroll <= 0 ? 0.0 : (_scrollController.offset / maxScroll).clamp(0.0, 1.0);
      });
    }
  }

  void _scrollListener() {
    if (_scrollController.hasClients) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll > 0) {
        final newProgress = _scrollController.offset / maxScroll;
        setState(() {
          _scrollProgress = newProgress;
        });
        _saveScrollPosition();
      }
      if (_scrollController.offset >= maxScroll) {
        _markAsRead();
      }
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      // 兼容历史数据里存成 int 的取值（如 fontSize），统一转 double。
      _fontSize = (prefs.get('fontSize') as num?)?.toDouble() ?? 16.0;
      _isDarkMode = prefs.getBool('isDarkMode') ?? false;
      _lineHeight = (prefs.get('reader_line_height') as num?)?.toDouble() ?? 1.8;
      _pageMode = prefs.getInt('reader_page_mode') ?? ReaderPreferences.pageModeScroll;
      _bgColorIndex = prefs.getInt('reader_bg_color') ?? 0;
    });
    // 同步全局夜间模式信号，消息中心等页面跟随切换浅色/深色配色。
    appDarkMode.value = _isDarkMode;
  }

  Future<void> _saveScrollPosition() async {
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath != null && _scrollController.hasClients) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('scroll_$keyPath', _scrollController.offset);
      await prefs.setDouble('progress_$keyPath', _scrollProgress);
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
    if (filePath != null) {
      // 1. 优先加载已编辑的副本（如果存在）
      final editedPath = await editedSutraFilePath(filePath);
      final editedFile = File(editedPath);
      final hasEdited = await editedFile.exists();
      if (hasEdited) {
        try {
          final content = await editedFile.readAsString();
          if (mounted) {
            setState(() {
              _content = content;
              _paragraphs = _parseParagraphs(content);
              _isLoadingContent = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRestoreScroll());
          }
          return;
        } catch (_) {
          // 读取失败则回退到原始文件
        }
      }

      // 2. 其次加载已下载到本地的副本
      File? localCopy;
      if (filePath.startsWith('assets/sutras_ascii/')) {
        localCopy = await SutraDownloader.localFileForAssetPath(filePath);
      }
      // 兜底：任何形式的路径（如换机/重新登录后从云端同步回来的旧设备
      // 绝对路径）只要能从标题/路径中识别出经书 ID，就去本地下载目录找副本，
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
            WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRestoreScroll());
          }
          return;
        } catch (_) {
          // 读取失败则回退到打包资源
        }
      }

      // 3. 再回退到打包资源
      if (filePath.startsWith('assets/')) {
        try {
          String content = await rootBundle.loadString(filePath);
          if (mounted) {
            setState(() {
              _content = content;
              _paragraphs = _parseParagraphs(content);
              _isLoadingContent = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRestoreScroll());
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _content = '该经文正文尚未下载，请点击上方"下载"按钮获取后再阅读。';
              _paragraphs = [];
              _isLoadingContent = false;
              _needsDownload = true;
            });
          }
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
              WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRestoreScroll());
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

  List<String> _parseParagraphs(String content) {
    return content.split('\n').where((line) => line.trim().isNotEmpty).toList();
  }

  /// 拉取本经所有段落的笔记与完成态（云端）到本地状态。
  Future<void> _loadParagraphNotes() async {
    if (_paraNotesLoading) return;
    setState(() => _paraNotesLoading = true);
    try {
      final items = await CloudNotesService.instance.getParagraphNotes(_sutraKey);
      if (!mounted) return;
      setState(() {
        _paraNotes = {
          for (final it in items)
            if (it['index'] is int) it['index'] as int: (it['note'] ?? '').toString(),
        };
        // 画线：仅当云端明确返回 underlines 字段时才覆盖本地，避免旧后端/未部署
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
                  (u['start'] ?? 0) >= 0 && (u['end'] ?? 0) >= (u['start'] ?? 0))
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
        _paraShared = {
          for (final it in items)
            if (it['index'] is int) it['index'] as int: it['shared'] == true,
        };
        _paraCloudIds = {
          for (final it in items)
            if (it['index'] is int)
              it['index'] as int: (it['cloudId'] ?? '').toString(),
        };
        _paraNotesLoading = false;
      });
    } catch (e) {
      // 笔记拉取失败不阻塞阅读：保持本地为空，静默降级。
      if (!mounted) return;
      setState(() => _paraNotesLoading = false);
      debugPrint('[reading] 拉取段落笔记失败: $e');
    }
  }

  /// 保存某段备注文本到云端并更新本地状态。
  Future<void> _saveParagraphNote(int index, String note,
      {bool shared = false, String cloudId = '', List<Map<String, int>>? underlines}) async {
    if (index < 0 || index >= _paragraphs.length) return;
    // 段落笔记存云端、按用户隔离：未登录直接提示，避免白白弹错误窗。
    if (!AuthService.instance.isLoggedIn) {
      _promptLoginForNotes();
      return;
    }
    final noteTrim = note.trim();
    setState(() {
      if (noteTrim.isEmpty) {
        _paraNotes.remove(index);
        _paraShared.remove(index);
        _paraCloudIds.remove(index);
      } else {
        _paraNotes[index] = noteTrim;
        _paraShared[index] = shared;
        _paraCloudIds[index] = cloudId;
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
        note: noteTrim,
        shared: shared,
        cloudId: cloudId,
        underlines: underlines ?? _paraUnderlines[index] ?? const [],
      );
      if (!mounted) return;
      _loadParagraphNotes();
    } catch (e) {
      debugPrint('[reading] 保存段落笔记失败: $e');
      if (!mounted) return;
      final msg = e is CloudApiException ? e.message : '网络异常，请稍后重试';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存笔记失败：$msg')),
      );
    }
  }

  /// 未登录时点击笔记/勾选/读经笔记的统一提示。
  void _promptLoginForNotes() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('登录后才能保存读经想法与画线（跨设备同步），请先在「我的」页面登录')),
    );
  }

  /// 切换某段「已读完/学完」标记并云端同步。
  Future<void> _toggleParagraphDone(int index) async {
    if (index < 0 || index >= _paragraphs.length) return;
    if (!AuthService.instance.isLoggedIn) {
      _promptLoginForNotes();
      return;
    }
    final newDone = !(_paraDone[index] ?? false);
    setState(() => _paraDone[index] = newDone);
    try {
      await CloudNotesService.instance.toggleParagraphDone(
        sutraKey: _sutraKey,
        index: index,
        text: _paragraphs[index],
        done: newDone,
      );
    } catch (e) {
      debugPrint('[reading] 切换段落完成态失败: $e');
      if (!mounted) return;
      // 失败回滚，避免本地显示与云端不一致。
      setState(() => _paraDone[index] = !newDone);
      final msg = e is CloudApiException ? e.message : '网络异常，请稍后重试';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新失败：$msg')),
      );
    }
  }

  Future<void> _downloadContent() async {
    if (_isDownloading) return;
    final id = SutraDownloader.extractId(widget.title, _resolvedFilePath ?? widget.filePath);
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
          // 服务器/代理的 Content-Length 可能不准（压缩、分块传输等），
          // received 会大于 total，导致百分比超过 100%，这里夹在 [0,1]。
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
        SnackBar(content: Text('下载失败：$e')),
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
                    '下载中… ${(_downloadProgress * 100).toStringAsFixed(0)}%',
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
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 打开笔记编辑页：预填「$经书名」在顶部，可写笔记并发布到菩提空间。
  /// 经名带当前卷标（与顶部标题栏一致，如「$地藏菩萨本愿经卷一」）；
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
          const SnackBar(content: Text('没有可导出的内容'), duration: Duration(seconds: 2)),
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
            SnackBar(content: Text('已保存：$savedPath'), duration: const Duration(seconds: 3)),
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
      if (savePath != null && savePath.isNotEmpty && !savePath.startsWith('content:')) {
        final file = File(savePath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已保存：$savePath'), duration: const Duration(seconds: 3)),
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
          SnackBar(content: Text('已保存到应用目录：${file.path}'), duration: const Duration(seconds: 4)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e'), duration: const Duration(seconds: 4)),
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

  @override
  Widget build(BuildContext context) {
    // 每帧重建前释放上一帧的画线点击识别器，避免其指向旧的 TextSpan。
    for (final r in _underlineTapRecognizers) {
      r.dispose();
    }
    _underlineTapRecognizers.clear();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // AI 面板展开时，系统返回先收起它（回到阅读页）；否则正常退出阅读页。
        if (assistantVisible.value) {
          assistantVisible.value = false;
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
            backgroundColor: Color(ReaderPreferences.bgColors[_bgColorIndex]),
            appBar: AppBar(
              backgroundColor: ReaderPreferences.appBarColor(_bgColorIndex),
              elevation: 0,
              leadingWidth: 48,
              titleSpacing: 0,
              iconTheme: IconThemeData(color: _isDarkBg ? Colors.white.withOpacity(0.7) : const Color(0xFF212121)),
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
                          color: _isDarkMode ? Colors.white.withOpacity(0.7) : const Color(0xFF212121),
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
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
                },
                child: Stack(
                children: [
                  Column(
                    children: [
                      if (_showSearchBar)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                                          : const BorderSide(color: Color(0xFFD9D9D9), width: 1),
                                    ),
                                    filled: true,
                                    fillColor: Colors.white,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      child: Text(
                                        '${_currentMatchIndex + 1}/${_searchMatches.length}',
                                        style: TextStyle(
                          color: _isDarkBg ? Colors.white.withOpacity(0.7) : const Color(0xFF212121),
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                                      onPressed: _goToPreviousMatch,
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                                      onPressed: _goToNextMatch,
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      _buildDownloadBanner(),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Listener(
                            onPointerDown: (event) {
                              // 注意：此处绝不重置 _actionRowTapped ——
                              // 指针事件按「从内到外」派发，操作栏的内层 Listener
                              // 先把标记置 true，若这里再清掉，onPointerUp 就拦不住了。
                              _pointerDownPos = event.position;
                              _pointerDownTime = DateTime.now();
                              _longPressActive = false;
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
                              // 段落操作栏（AI译/笔记/方框）拦截：阻止触发面板。
                              if (_actionRowTapped) {
                                _actionRowTapped = false;
                                // 同步清理按下状态，避免残留影响 300ms 长按计时器。
                                _pointerDownPos = null;
                                _pointerDownTime = null;
                                _longPressActive = false;
                                return;
                              }
                              // 记下按下时是否是「收菜单」的点击（由外层 Listener 设置）。
                              final menuOpenAtDown = _menuOpenAtDown;
                              _menuOpenAtDown = false;
                              final downPos = _pointerDownPos;
                              _pointerDownPos = null;
                              _pointerDownTime = null;
                              // 长按或滑动均不触发面板。
                              if (_longPressActive) {
                                _longPressActive = false;
                                return;
                              }
                              if (downPos != null &&
                                  (event.position - downPos).distance > 10) return;
                              // 按下时菜单是展开的 → 这次点击是收菜单，不弹面板。
                              if (menuOpenAtDown) return;
                              // 正文正有文字被选中 → 点击是取消选中/交互，不弹面板。
                              if (_hasTextSelection) return;
                              // AI 翻译面板打开时，点击仅用于收起面板，不触发表单切换。
                              if (_aiParagraph != null) return;
                              setState(() {
                                if (_showMoreMenu) {
                                  _showMoreMenu = false;
                                } else if (_showSearchBar) {
                                  _showSearchBar = false;
                                  _searchController.clear();
                                  _searchMatches.clear();
                                  _currentMatchIndex = 0;
                                }
                                // 单击正文不再弹出任何面板（阅读设置已移入右上角菜单）。
                              });
                            },
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                if (_isLoadingContent) {
                                  return const Center(child: CircularProgressIndicator());
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
                                  controller: _scrollController,
                                  child: _searchController.text.isEmpty
                                      ? Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                           children: List.generate(_paragraphs.length, (i) {
                                              return Padding(
                                                padding: const EdgeInsets.only(bottom: 24.0),
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    SelectableText.rich(
                                                      TextSpan(
                                                        style: _paraBaseStyle(i),
                                                        children: _buildParagraphSpans(i),
                                                      ),
                                                      onSelectionChanged: (sel, cause) {
                                                        _hasTextSelection = !sel.isCollapsed;
                                                        _onSelectionChanged(sel);
                                                      },
                                                      contextMenuBuilder: (context, editableTextState) =>
                                                          _buildSelectionToolbar(context, editableTextState, i),
                                                    ),
                                                    Align(
                                                      alignment: Alignment.centerLeft,
                                                      child: _buildParagraphActions(i),
                                                    ),
                                                  ],
                                                ),
                                              );
                                          }),
                                        )
                                      : Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                           children: List.generate(_paragraphs.length, (i) {
                                              return Padding(
                                                padding: const EdgeInsets.only(bottom: 24.0),
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    SelectableText.rich(
                                                     TextSpan(
                                                       style: _paraBaseStyle(i),
                                                       children: _buildParagraphSpans(i),
                                                     ),
                                                     onSelectionChanged: (sel, cause) {
                                                       _hasTextSelection = !sel.isCollapsed;
                                                       _onSelectionChanged(sel);
                                                     },
                                                     contextMenuBuilder: (context, editableTextState) =>
                                                         _buildSelectionToolbar(context, editableTextState, i),
                                                    ),
                                                     Align(
                                                      alignment: Alignment.centerLeft,
                                                      child: _buildParagraphActions(i),
                                                    ),
                                                 ],
                                               ),
                                             );
                                          }),
                                        ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                    AppPalette.instance.isPlain && !_isDarkBg ? 2 : 3),
                                child: LinearProgressIndicator(
                                  value: _scrollProgress,
                                  minHeight: 5,
                                  backgroundColor: _isDarkBg
                                      ? Colors.white.withOpacity(0.15)
                                      : AppPalette.instance.isPlain
                                          ? AppPalette.p.border
                                          : const Color(0xFFE8D9C4),
                                  valueColor:
                                      AlwaysStoppedAnimation<Color>(!_isDarkBg &&
                                              AppPalette.instance.isPlain
                                          ? const Color(0xFF4A4A4A)
                                          : AppPalette.p.accent),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${(_scrollProgress * 100).toStringAsFixed(1)}%',
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
                    ],
                  ),

                if (_showMoreMenu)
                  Positioned(
                    top: 4,
                    right: 16,
                    child: Material(
                      key: _moreMenuKey,
                      elevation: 6,
                      borderRadius: BorderRadius.circular(12),
                      color: _isDarkBg ? const Color(0xFF2c2c2c) : Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildMoreMenuItem(
                              icon: const Icon(Icons.text_fields, size: 18),
                              label: '阅读设置',
                              onTap: _openReadingSettings,
                            ),
                            _buildMoreMenuItem(
                              icon: const Icon(Icons.menu_book_outlined, size: 18),
                              label: '读经想法',
                              onTap: _openReadingNotes,
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
                Positioned(
                  right: 16,
                  bottom: 111,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: _buildFloatingIcon(
                      tooltip: 'AI 助手',
                      heroTag: 'sutra_ai_assistant',
                      onTap: _openAssistant,
                      child: const Text(
                        'AI',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: 57,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: _buildFloatingIcon(
                      tooltip: '写笔记',
                      heroTag: 'sutra_note',
                      onTap: _openNoteEditor,
                      child: ColorFiltered(
                        colorFilter: ColorFilter.mode(
                          AppPalette.p.primary,
                          BlendMode.srcIn,
                        ),
                        child: Image.asset(
                          'assets/images/write.png',
                          width: 18,
                          height: 18,
                        ),
                      ),
                    ),
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
                     child: _buildReadingSettingsPanel(),
                   ),
                 ],
                 if (_aiParagraph != null) ...[
                  // 阅读区遮罩：点击面板上方空隙（未盖住的经文区）即可关闭。
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _closeAiPanel,
                    ),
                  ),
                  Positioned(
                    top: 56, // 与标题栏底部间隔约一个标题栏高度，露出经文空隙
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _buildAiPanel(),
                  ),
                ],
                ],
              ),
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
      // 菜单已打开 → 关闭菜单。
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

  /// 切换翻页样式（纵向滚动 / 左右翻页）：
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
      list[idx]['readTime'] =
          newRead ? DateTime.now().toIso8601String() : null;
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

  /// 右下角浮动图标：与助手页底部圆圈按钮同款（浅色圆底 + 阴影）。
  Widget _buildFloatingIcon({
    required Widget child,
    required String tooltip,
    required String heroTag,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: FloatingActionButton(
        heroTag: heroTag,
        onPressed: onTap,
        backgroundColor: _isDarkBg ? Colors.white : const Color(0xFFf7f7f7),
        elevation: 8,
        highlightElevation: 12,
        shape: const CircleBorder(),
        child: IconTheme(
          data: IconThemeData(
            color: AppPalette.p.primary,
          ),
          child: child,
        ),
      ),
    );
  }

  void _openAssistant() {
    // 唤出全局常驻的 AI 面板（WebView 不销毁，会话跨页面延续）；再次点击收起。
    assistantVisible.value = !assistantVisible.value;
  }

  /// 点击某段的「AI译」：打开翻译面板并自动翻译该段。
  void _openAiTranslate(int index) {
    if (index < 0 || index >= _paragraphs.length) return;
    final paragraph = _paragraphs[index];
    // 收起阅读设置面板，避免与翻译面板重叠。
    _showStylePanel = false;
    // 同步面板内「读经笔记」输入框为该段现有备注。
    _noteInputController.text = _paraNotes[index] ?? '';
    setState(() {
      _aiParagraphIndex = index;
      _aiParagraph = paragraph;
      _aiTranslation = null;
      _aiError = null;
      _aiDiagText = null;
      _aiPanelLoading = true;
      _activeNoteParagraphIndex = index;
    });
    _requestAiTranslate();
  }

  /// 请求白话翻译（面板打开后/重试时调用）。
  Future<void> _requestAiTranslate() async {
    final paragraph = _aiParagraph;
    if (paragraph == null) return;
    setState(() {
      _aiPanelLoading = true;
      _aiError = null;
    });
    try {
      final text = await CloudNotesService.instance.aiTranslate(paragraph: paragraph);
      if (!mounted) return;
      setState(() {
        _aiTranslation = _stripAnnotation(text);
        _aiPanelLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiPanelLoading = false;
        _aiError = e is CloudApiException ? e.message : '翻译失败，请稍后重试';
      });
    }
  }

  /// 剔除译文末尾的「注：…」等补充说明，只保留译文正文。
  /// （模型在某些旧缓存/旧版本可能仍会输出这类标注。）
  String _stripAnnotation(String text) {
    if (text.isEmpty) return text;
    // 匹配：行首或句末换行后出现的 注/说明/备注/注释 标注（可带【】、（）等装饰）。
    final RegExp noteRe = RegExp(
      r'(?:\r?\n|。|；)[　\s]*(?:【|\[|（|\(|〔|『)?(?:注\s*[:：]?\s*\d*|注\s*释[:：]|说明[:：]|備注[:：]|备注[:：]|注释[:：])',
    );
    final match = noteRe.firstMatch(text);
    if (match != null) {
      return text.substring(0, match.start).trim();
    }
    return text.trim();
  }

  /// 关闭 AI 翻译面板。
  void _closeAiPanel() {
    FocusScope.of(context).unfocus();
    _noteInputController.clear();
    setState(() {
      _aiParagraph = null;
      _aiParagraphIndex = -1;
      _aiTranslation = null;
      _aiError = null;
      _aiPanelLoading = false;
      _activeNoteParagraphIndex = -1;
    });
  }

  /// 一键网络自诊断：检测云函数到大模型的连通性，把根因显示在面板里。
  Future<void> _runAiDiag() async {
    if (_aiDiagLoading) return;
    setState(() {
      _aiDiagLoading = true;
      _aiDiagText = null;
    });
    try {
      final res = await CloudNotesService.instance.aiNetProbe();
      if (!mounted) return;
      final b = StringBuffer();
      b.writeln('密钥已配置：${res['keyConfigured'] == true ? '是' : '否'}');
      b.writeln('域名解析(DNS)：${res['dns'] ?? '未测'} ${res['ip'] ?? ''}');
      b.writeln('TCP连接：${res['tcp'] ?? '未测'}${res['tcp'] == 'fail' ? ' ${res['tcpError'] ?? ''}' : ''}');
      b.writeln('TLS握手：${res['tls'] ?? '未测'}${res['tls'] == 'fail' ? ' ${res['tlsError'] ?? ''}' : ''}');
      b.writeln('结论：${res['conclusion'] ?? '未知'}');
      setState(() {
        _aiDiagText = b.toString();
        _aiDiagLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiDiagText = '诊断失败：${e is CloudApiException ? e.message : e}';
        _aiDiagLoading = false;
      });
    }
  }

  /// 段落右侧的操作栏（同一水平位）：待办圆圈 | AI译 | 笔记。
  Widget _buildParagraphActions(int index) {
    final isActive = _aiParagraphIndex == index && _aiParagraph != null;
    final fg = _isDarkBg ? Colors.white.withOpacity(0.6) : const Color(0xFF9A9A9A);
    final activeFg = AppPalette.p.accent;
    final hasNote = (_paraNotes[index] ?? '').isNotEmpty;
    final done = _paraDone[index] == true;
    return Padding(
      // 操作栏紧贴本段文字（与该段一体）；
      // 与下一段的间隔交给段落容器的外部 bottom 留白。
      padding: const EdgeInsets.only(
        top: 0,
        bottom: 0,
      ),
      child: Listener(
        // 点击操作栏时置 true，阻止外层 Listener 触发面板（指针从内到外派发）。
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
                            color: _isDarkBg ? const Color(0xFF1A1A1A) : Colors.white)
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // AI译
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openAiTranslate(index),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                   Icon(
                    Icons.auto_awesome,
                    size: 13,
                    color: isActive ? activeFg : fg,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'AI译',
                    style: TextStyle(
                      fontSize: 13,
                      color: isActive ? activeFg : fg,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            // 笔记
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _onParagraphNoteTap(index),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                   Icon(
                    hasNote ? Icons.sticky_note_2 : Icons.sticky_note_2_outlined,
                    size: 14,
                    color: hasNote ? activeFg : fg,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '想法',
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

  /// 点击「想法」：打开该段经文所有用户想法的汇总底部弹层。
  /// （若 AI 翻译面板正显示该段且用户在看笔记输入框，则仍聚焦到笔记输入框。）
  void _onParagraphNoteTap(int index) {
    if (index < 0 || index >= _paragraphs.length) return;
    // 若 AI 翻译面板正显示该段，切到笔记输入框。
    if (_aiParagraphIndex == index && _aiParagraph != null) {
      setState(() {
        _activeNoteParagraphIndex = index;
        _noteInputController.text = _paraNotes[index] ?? '';
      });
      return;
    }
    ParagraphThoughtsPage.open(
      context,
      sutraTitle: _titleShown,
      paragraph: _paragraphs[index],
    );
  }

  /// 进入「读经想法」编辑页。默认显示整段原文；
  /// [displayText] 非空时顶部显示被选中的具体文字（由长按/单击画线的想法入口传入）。
  Future<void> _showNoteDialog(int index, {String? displayText}) async {
    if (index < 0 || index >= _paragraphs.length) return;
    // 跳转前先禁用浮层菜单：push 之后本页失焦、选区收起，
    // contextMenuBuilder 可能再次回调，把「复制/画线」弹窗插到想法页上方。
    _clearSelectionMenu();
    _coveredByRoute = true;
    FocusScope.of(context).unfocus();
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => ReadingNoteEditPage(
          paragraph: displayText ?? _paragraphs[index],
          initialText: _paraNotes[index] ?? '',
          hasExistingNote: (_paraNotes[index] ?? '').isNotEmpty,
          sutraTitle: _titleShown,
          initialShared: _paraShared[index] == true,
          initialCloudId: _paraCloudIds[index],
        ),
      ),
    );
    _coveredByRoute = false;
    if (result == null || !mounted) return;
    final note = result['note'] as String? ?? '';
    if (note == '__delete__') {
      await _deleteParagraphNote(index);
      return;
    }
    final shared = result['shared'] == true;
    final cloudId = (result['cloudId'] as String?) ?? '';
    await _saveParagraphNote(index, note,
        shared: shared, cloudId: cloudId, underlines: _paraUnderlines[index] ?? const []);
  }

  /// 删除某段备注（保留完成态）。
  Future<void> _deleteParagraphNote(int index) async {
    final cloudId = _paraCloudIds[index];
    setState(() {
      if (_activeNoteParagraphIndex == index) {
        _activeNoteParagraphIndex = -1;
        _noteInputController.clear();
      }
      _paraNotes.remove(index);
      _paraUnderlines.remove(index);
      _paraDone.remove(index);
      _paraShared.remove(index);
      _paraCloudIds.remove(index);
    });
    try {
      await CloudNotesService.instance.deleteParagraphNote(
        sutraKey: _sutraKey,
        index: index,
      );
      // 曾分享到菩提空间的帖子同步取消分享（隐藏）。
      if (cloudId != null && cloudId.isNotEmpty) {
        await CloudNotesService.instance.unpublishNote(cloudId);
      }
      if (!mounted) return;
      _loadParagraphNotes();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：${e is CloudApiException ? e.message : e}')),
      );
    }
  }

  /// 打开「阅读设置」底部弹层（三个点点菜单入口）：
  /// 面板挂在页面 Stack 里，滑块 setState 能实时刷新面板上的数字。
  void _openReadingSettings() {
    setState(() {
      _showMoreMenu = false;
      _showStylePanel = true;
    });
  }

  /// 打开「读经笔记」页：列出本经所有段落笔记，点击某段可跳回该段。
  Future<void> _openReadingNotes() async {
    setState(() {
      _showMoreMenu = false;
    });
    // 先同步一次最新云端状态，避免跳转前笔记页数据过期。
    await _loadParagraphNotes();
    if (!mounted) return;
    final jumpIndex = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => ReadingNotesPage(
          sutraKey: _sutraKey,
          title: _titleShown,
          paragraphs: _paragraphs,
          notes: Map.of(_paraNotes),
          done: Map.of(_paraDone),
          onDelete: (index) => _deleteParagraphNote(index),
          onSave: (index, note) => _saveParagraphNote(
            index,
            note,
            shared: _paraShared[index] == true,
            cloudId: _paraCloudIds[index] ?? '',
          ),
          onToggleDone: (index) => _toggleParagraphDone(index),
        ),
      ),
    );
    if (!mounted || jumpIndex == null) return;
    _jumpToParagraph(jumpIndex);
  }

  /// 滚动到指定段落（用于从读经笔记跳回该段）。
  void _jumpToParagraph(int index) {
    if (_pageMode == ReaderPreferences.pageModeFlip) {
      // 翻页模式：直接切到包含该段的那一页。
      final page = _flipPages.indexWhere((paras) => paras.contains(index));
      if (page >= 0 && _pageController != null) {
        _pageController!.animateToPage(
          page,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
      return;
    }
    // 滚动模式：用估算偏移定位到该段。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final estimate = _estimateParagraphOffset(index);
      final max = _scrollController.position.maxScrollExtent;
      final target = estimate.clamp(0.0, max);
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    });
  }

  /// 估算第 index 段在滚动容器中的像素偏移（按字号×行距×字符数粗算）。
  double _estimateParagraphOffset(int index) {
    double y = 0;
    const topPadding = 16.0;
    for (int i = 0; i < index && i < _paragraphs.length; i++) {
      final lines = (_paragraphs[i].length / _effectiveCharsPerLine()).ceil();
      y += lines * _fontSize * _lineHeight;
      y += 24; // 段间距（操作栏与下一段文字之间的留白）
      y += 24; // 操作栏高度（含上方贴段留白）
    }
    return topPadding + y;
  }

  double _effectiveCharsPerLine() {
    // 粗略估算每行可容纳的字符数（华文每字宽度≈字号）。
    final width = (MediaQuery.of(context).size.width - 32);
    return (width / _fontSize).clamp(6.0, 60.0).toDouble();
  }

  /// 全屏白话翻译面板（不含原文与讨论，译文大字号，仅右上角×号可关闭）。
  /// 底部白话翻译面板：从下方滑出、顶边左右圆角、不触碰标题栏，
  /// 译文字号/行距跟随正文设置；仅右上角×号可关闭。
  Widget _buildAiPanel() {
    final isDark = _isDarkBg;
    final panelBg = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF212121);
    final subColor = isDark ? Colors.white.withOpacity(0.6) : const Color(0xFF999999);

    Widget body;
    if (_aiPanelLoading) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(strokeWidth: 3),
              const SizedBox(height: 12),
              Text('正在把这段翻译成白话文…',
                  style: TextStyle(fontSize: 14, color: subColor)),
            ],
          ),
        ),
      );
    } else if (_aiError != null) {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 28),
            const SizedBox(height: 8),
            Text(
              _aiError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 15),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _requestAiTranslate,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _runAiDiag,
              icon: _aiDiagLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check, size: 18),
              label: Text(_aiDiagLoading ? '诊断中…' : '一键诊断'),
              style: TextButton.styleFrom(foregroundColor: AppPalette.p.accent),
            ),
            if (_aiDiagText != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: textColor.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _aiDiagText!,
                  style: TextStyle(fontSize: 12, height: 1.5, color: subColor),
                ),
              ),
            ],
          ],
        ),
      );
    } else if (_aiTranslation != null) {
      // 白话译文 + 底部读经笔记输入框（为该段添加备注）。
      final note = (_paraNotes[_aiParagraphIndex] ?? '');
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            _aiTranslation!,
            style: TextStyle(
              color: textColor,
              fontSize: _fontSize,
              height: _lineHeight,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.sticky_note_2_outlined,
                  size: 16, color: subColor),
              const SizedBox(width: 6),
              Text('读经想法',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textColor)),
              const Spacer(),
              if (note.isNotEmpty)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _deleteParagraphNote(_aiParagraphIndex),
                  child: Text('删除',
                      style: TextStyle(
                          fontSize: 12, color: Colors.redAccent)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _noteInputController,
            maxLines: 4,
            minLines: 2,
            decoration: InputDecoration(
              hintText: '为这段经文写下你的想法…',
              hintStyle: TextStyle(fontSize: 13, color: subColor),
              filled: true,
              fillColor: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F3EF),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
            style: TextStyle(fontSize: 14, color: textColor),
            onChanged: (_) {
              if (_activeNoteParagraphIndex != _aiParagraphIndex) {
                _activeNoteParagraphIndex = _aiParagraphIndex;
              }
            },
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: () => _saveParagraphNote(
                  _aiParagraphIndex, _noteInputController.text,
                  shared: _paraShared[_aiParagraphIndex] == true,
                  cloudId: _paraCloudIds[_aiParagraphIndex] ?? ''),
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('保存想法'),
              style: FilledButton.styleFrom(
                backgroundColor: AppPalette.p.accent,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: textColor.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '已保存：$note',
                style: TextStyle(fontSize: 12, height: 1.5, color: subColor),
              ),
            ),
          ],
        ],
      );
    } else {
      body = const SizedBox.shrink();
    }

    // 屏幕尺寸在 builder 外取好：builder 里调 MediaQuery.of 会随键盘
    // 弹出/收起反复注册 InheritedWidget 依赖，保存笔记时触发
    // 「_dependents.isEmpty」断言错误。
    final screenSize = MediaQuery.of(context).size;
    return TweenAnimationBuilder<Offset>(
      tween: Tween(begin: const Offset(0, 1), end: Offset.zero),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          color: panelBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.18),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          bottom: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部栏：标题 + 右上角小号关闭（仅此处可关闭）
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 8, 2),
                child: Row(
                  children: [
                    Text(
                      '白话翻译',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: _closeAiPanel,
                      visualDensity: VisualDensity.compact,
                      iconSize: 20,
                      tooltip: '关闭',
                      color: subColor,
                      padding: const EdgeInsets.all(4),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  child: body,
                ),
              ),
            ],
          ),
        ),
      ),
      builder: (context, offset, child) => Transform.translate(
        offset: Offset(
          offset.dx * screenSize.width,
          offset.dy * screenSize.height,
        ),
        child: child,
      ),
    );
  }

  /// 更多菜单里的带文字条目。
  Widget _buildMoreMenuItem({
    required Widget icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final fg = _isDarkBg ? Colors.white : AppPalette.p.primary;
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
    final isDark = _isDarkBg;
    final panelBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF212121);
    final subTextColor = isDark ? Colors.white.withOpacity(0.6) : const Color(0xFF999999);
    final accentColor = AppPalette.p.accent;

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
              // 顶部拖拽条
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 8),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white.withOpacity(0.2) : const Color(0xFFD0D0D0),
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
                    Icon(Icons.text_fields, size: 18, color: subTextColor),
                    const SizedBox(width: 8),
                    Text('字号', style: TextStyle(fontSize: 14, color: textColor)),
                    const SizedBox(width: 8),
                    Text('${_fontSize.toStringAsFixed(0)}',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: accentColor)),
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
                    Icon(Icons.format_line_spacing, size: 18, color: subTextColor),
                    const SizedBox(width: 8),
                    Text('行距', style: TextStyle(fontSize: 14, color: textColor)),
                    const SizedBox(width: 8),
                    Text('${_lineHeight.toStringAsFixed(1)}',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: accentColor)),
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
              // 夜间/白天模式：太阳 + 月亮两个图标
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                child: Row(
                  children: [
                    Icon(_isDarkBg ? Icons.dark_mode : Icons.light_mode,
                        size: 18, color: subTextColor),
                    const SizedBox(width: 8),
                    Text(_isDarkBg ? '夜间模式' : '白天模式',
                        style: TextStyle(fontSize: 14, color: textColor)),
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
                    Icon(Icons.palette_outlined, size: 18, color: subTextColor),
                    const SizedBox(width: 8),
                    Text('背景', style: TextStyle(fontSize: 14, color: textColor)),
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
                              color: Color(ReaderPreferences.bgColors[i]),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: selected ? accentColor : Colors.transparent,
                                width: 2,
                              ),
                              boxShadow: selected
                                  ? [
                                      BoxShadow(
                                        color: accentColor.withOpacity(0.3),
                                        blurRadius: 4,
                                      )
                                    ]
                                  : null,
                            ),
                            child: selected
                                ? Icon(Icons.check, size: 14,
                                    color: i == 4 ? Colors.white : const Color(0xFF212121))
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
                    Icon(Icons.menu_book_outlined, size: 18, color: subTextColor),
                    const SizedBox(width: 8),
                    Text('翻页', style: TextStyle(fontSize: 14, color: textColor)),
                    const Spacer(),
                    _buildToggleChip(
                      label: '纵向滚动',
                      selected: _pageMode == ReaderPreferences.pageModeScroll,
                      onTap: () {
                        _switchPageMode(ReaderPreferences.pageModeScroll);
                      },
                    ),
                    const SizedBox(width: 8),
                    _buildToggleChip(
                      label: '左右翻页',
                      selected: _pageMode == ReaderPreferences.pageModeFlip,
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
    final isDark = _isDarkMode;
    final accentColor = AppPalette.p.accent;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? accentColor.withOpacity(isDark ? 0.3 : 0.15)
              : (isDark ? Colors.white.withOpacity(0.08) : const Color(0xFFF0F0F0)),
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
            color: selected ? accentColor : (isDark ? Colors.white.withOpacity(0.6) : const Color(0xFF999999)),
          ),
        ),
      ),
    );
  }

  void _performSearch(String query) {
    if (query.isEmpty) {
      setState(() {
        _searchMatches.clear();
        _currentMatchIndex = 0;
      });
      return;
    }

    final matches = <int>[];
    final content = _content.toLowerCase();
    final lowerQuery = query.toLowerCase();

    int index = content.indexOf(lowerQuery);
    while (index != -1) {
      matches.add(index);
      index = content.indexOf(lowerQuery, index + 1);
    }

    setState(() {
      _searchMatches = matches;
      _currentMatchIndex = matches.isNotEmpty ? 0 : -1;
    });

    if (matches.isNotEmpty) {
      _scrollToMatch(0);
    }
  }

  void _scrollToMatch(int index) {
    if (index >= 0 && index < _searchMatches.length && _scrollController.hasClients) {
      final position = _searchMatches[index];
      _scrollController.animateTo(
        position.toDouble(),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToPreviousMatch() {
    if (_searchMatches.isNotEmpty) {
      final newIndex = _currentMatchIndex > 0 ? _currentMatchIndex - 1 : _searchMatches.length - 1;
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

  /// 段落的基准文字样式（含是否已读完的置灰）。
  TextStyle _paraBaseStyle(int i) => TextStyle(
        color: _paraDone[i] == true
            ? (_isDarkBg
                ? Colors.white.withOpacity(0.35)
                : const Color(0xFFBDBDBD))
            : (_isDarkBg ? Colors.white : const Color(0xFF212121)),
        fontSize: _fontSize,
        height: _lineHeight,
        letterSpacing: 0.5,
      );

  /// 将第 i 段文字切成多个 TextSpan：叠加「画线」下划线 与 搜索结果高亮。
  /// 已画线的文字区域带 Tap 识别器，单击即弹出 复制 / 擦除(buy) / 想法 菜单。
  List<TextSpan> _buildParagraphSpans(int i) {
    final text = _paragraphs[i];
    final len = text.length;
    if (len == 0) return [TextSpan(text: '')];

    // 画线区间：合并重叠/相邻成有序不相交段 [(s,e)...]。
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

  /// 非画线区间的普通 span（仅按搜索高亮细分）。
  List<TextSpan> _plainSpans(String text, int s, int e, List<bool> isSrch) {
    final spans = <TextSpan>[];
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
          backgroundColor: se0
              ? (_isDarkBg ? Colors.yellow.withOpacity(0.3) : Colors.yellow)
              : null,
        ),
      ));
      start = end;
    }
    if (spans.isEmpty) spans.add(TextSpan(text: text.substring(s, e)));
    return spans;
  }

  /// 已画线区间的 span：整段加下划线，内部按搜索高亮细分；每个 sub span
  /// 都带上同一个 Tap 识别器，单击触发该画线的弹窗。
  List<TextSpan> _underlineSpans(
      String text, int para, int s, int e, List<bool> isSrch) {
    final spans = <TextSpan>[];
    final recognizer = TapGestureRecognizer()
      ..onTapDown = (d) {
        _underlineTapPos = d.globalPosition;
      }
      ..onTap = () => _onUnderlineTap(para, s, e);
    _underlineTapRecognizers.add(recognizer);
    var start = s;
    while (start < e) {
      final se0 = isSrch[start];
      var end = start + 1;
      while (end < e && isSrch[end] == se0) {
        end++;
      }
      spans.add(TextSpan(
        text: text.substring(start, end),
        recognizer: recognizer,
        style: TextStyle(
          decoration: TextDecoration.underline,
          decorationColor:
              _isDarkBg ? Colors.white : const Color(0xFF212121),
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
        recognizer: recognizer,
        style: TextStyle(
          decoration: TextDecoration.underline,
          decorationColor:
              _isDarkBg ? Colors.white : const Color(0xFF212121),
          decorationThickness: 1.4,
        ),
      ));
    }
    return spans;
  }

  /// 统一的菜单卡片：横向的 复制 / 画线(擦除) / 本段全选 / 想法（每项图标上文字下）。
  /// 单击画线（Overlay）与长按选中（contextMenuBuilder）共用，保证两者 UI 一致。
  /// [close] 在需要关闭弹窗时调用（复制 / 想法）；画线与全选不关闭，可继续操作。
  /// [onResolveRange] 为空时用 [start,end]（单击画线）；否则用它实时取当前选区（长按选中）。
  Widget _buildMenuCard({
    required int para,
    required int start,
    required int end,
    required VoidCallback close,
    (int, int)? Function()? onResolveRange,
    VoidCallback? onSelectFull,
  }) {
    if (para < 0 || para >= _paragraphs.length) return const SizedBox.shrink();
    final p = _paragraphs[para];
    final s = start.clamp(0, p.length);
    final e = end.clamp(0, p.length);
    final underlined = (_paraUnderlines[para] ?? const <Map<String, int>>[]).any(
        (u) => s < (u['end'] ?? 0) && e > (u['start'] ?? 0));

    return _IdeaMenuCard(
      para: para,
      paragraph: p,
      initialStart: s,
      initialEnd: e,
      initialUnderlined: underlined,
      initialHasIdea: (_paraNotes[para] ?? '').isNotEmpty,
      isDarkBg: _isDarkBg,
      close: close,
      onSelectFull: onSelectFull,
      onResolveRange: onResolveRange,
      onDrawUnderline: (ss, ee) => _toggleUnderline(para, ss, ee),
      onOpenNote: (ss, ee) => _openIdeaFromRange(para, ss, ee),
    );
  }

  /// 移除单个浮层菜单条目并从跟踪列表中剔除；[onDismiss] 由调用方触发。
  void _removeMenuEntry(OverlayEntry entry) {
    _activeMenuEntries.remove(entry);
    if (entry.mounted) entry.remove();
  }

  /// 打开「想法」编辑页前，确保所有长按选中 / 单击画线的浮层弹窗已被移除，
  /// 避免弹窗残留显示在新的想法输入界面上。
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

  /// 根据当前选中的 [start,end) 区间打开「想法」编辑页，顶部显示被选中的文字。
  void _openIdeaFromRange(int para, int start, int end) {
    _clearSelectionMenu();
    if (para < 0 || para >= _paragraphs.length) return;
    final p = _paragraphs[para];
    final s = start.clamp(0, p.length);
    final e = end.clamp(0, p.length);
    final display =
        (s < e && e <= p.length) ? p.substring(s, e) : p;
    _showNoteDialog(para, displayText: display);
  }

  /// 浮层菜单：在 [anchor] 处弹出统一的卡片（复制 / 画线(擦除) / 本段全选 / 想法）。
  /// 会测量卡片实际尺寸并夹在屏幕安全区内，优先显示在选中处上方、居中；
  /// 空间不足则自动转下方。
  /// [showBarrier]：为 true 时点击菜单外关闭（单击画线场景）；为 false 时不遮罩、
  /// 允许继续拖动选中句柄，通过选区折叠自动关闭（长按选中场景）。
  /// [onResolveRange]：返回当前应作用的目标区间；为空时用 [start,end]（单击画线场景）。
  OverlayEntry? _showFloatingMenu({
    required int para,
    required int start,
    required int end,
    required Offset anchor,
    VoidCallback? onDismiss,
    bool showBarrier = true,
    (int, int)? Function()? onResolveRange,
    VoidCallback? onSelectFull,
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

  /// 单击已画线文字：在点击处弹出与长按选中相同的菜单。
  void _onUnderlineTap(int para, int start, int end) {
    final target = _underlineTapPos ??
        MediaQuery.of(context).size.center(Offset.zero);
    _showFloatingMenu(para: para, start: start, end: end, anchor: target);
  }

  /// 画线 / 取消画线：给第 i 段 [start,end) 区间添加或移除下划线，并云端同步。
  /// 选中区间已完全被现有画线覆盖 → 擦除；否则 → 新增整段 [start,end)（渲染端会自动合并重叠）。
  Future<void> _toggleUnderline(int i, int start, int end) async {
    if (start >= end) return;
    if (!AuthService.instance.isLoggedIn) {
      _promptLoginForNotes();
      return;
    }
    final current = List<Map<String, int>>.from(_paraUnderlines[i] ?? const []);
    // 选中范围是否已被某条画线完整覆盖（此时视为“擦除”）。
    final covering = current
        .where((u) =>
            (u['start'] ?? 0) <= start && (u['end'] ?? 0) >= end)
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
      next = [...current, {'start': start, 'end': end}];
    }
    next.sort((a, b) => (a['start'] ?? 0).compareTo(b['start'] ?? 0));
    await _saveParagraphNote(
      i,
      _paraNotes[i] ?? '',
      shared: _paraShared[i] == true,
      cloudId: _paraCloudIds[i] ?? '',
      underlines: next,
    );
  }

  /// 选区变化：更新最新范围，供浮层 画线/想法/复制 使用；
  /// 当长按选中浮层打开、而用户把选区折叠（点击空白 / 清空）时，
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
  /// 并更新 [_selectionRange] 供后续画线/想法作用于整段。
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

  /// 长按选中文字后的菜单：与「单击画线」共用同一个卡片 UI
  /// （复制 / 画线(擦除) / 本段全选 / 想法，每项图标上文字下）。
  /// 不直接把卡片返回给框架（那样会铺满整屏变白屏），而是返回空组件，
  /// 由 [Overlay] 在选中处上方独立弹出同一张卡片，经文保持可见。
  /// 不使用全屏遮罩，句柄仍可拖动调整选区；点 画线/想法 时读取实时选区，
  /// 确保画线覆盖的就是当前可见的高亮范围（而非长按时的初始单字）。
  Widget _buildSelectionToolbar(
      BuildContext context, EditableTextState editableTextState, int i) {
    // 本页被其他路由覆盖（如想法编辑页）时不再弹任何菜单，
    // 也不记录选区状态：直接返回空组件即可。
    if (_coveredByRoute) return const SizedBox.shrink();
    // 每次长按都视为一次新的菜单请求；用递增序号作废切换页面后仍排队的旧回调。
    final myId = ++_menuRequestId;
    final p = _paragraphs[i];
    final sel = editableTextState.textEditingValue.selection;
    final start = sel.isValid ? sel.start.clamp(0, p.length) : 0;
    final end = sel.isValid ? sel.end.clamp(0, p.length) : 0;
    final anchor = editableTextState.contextMenuAnchors.primaryAnchor;
    _selectionTextState = editableTextState;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectionMenuEntry != null || myId != _menuRequestId) {
        return;
      }
      _selectionMenuEntry = _showFloatingMenu(
        para: i,
        start: start,
        end: end,
        anchor: anchor,
        showBarrier: false,
        // 读取当前最新选区（随句柄拖动即时更新），保证画线/想法作用于用户当前高亮的整段。
        onResolveRange: () {
          final r = _selectionRange;
          if (r != null) {
            final cs = r.$1.clamp(0, p.length);
            final ce = r.$2.clamp(0, p.length);
            if (ce > cs) return (cs, ce);
          }
          final s0 = _selectionTextState?.textEditingValue.selection;
          if (s0 == null || !s0.isValid || s0.isCollapsed) return null;
          final cs2 = s0.start.clamp(0, p.length);
          final ce2 = s0.end.clamp(0, p.length);
          if (ce2 <= cs2) return null;
          return (cs2, ce2);
        },
        // 「本段全选」：把视觉高亮扩大到整段（真实选中整段文字），并置后续画线/想法作用整段。
        onSelectFull: () => _selectFullParagraph(i),
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
    // 每段除文字外的高度：操作栏行(~20) + 贴段留白(4) + 段间距(24)。
    const extras = 48.0;
    final pages = <List<int>>[];
    var current = <int>[];
    var used = 0.0;
    for (var i = 0; i < _paragraphs.length; i++) {
      final tp = TextPainter(
        text: TextSpan(text: _paragraphs[i], style: _flipTextStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      final h = tp.height + extras;
      if (current.isNotEmpty && used + h > height) {
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

    if (!_flipPageRestored &&
        _savedProgress != null &&
        _flipPages.length > 1) {
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
      _scrollProgress = _flipPages.length > 1 ? (index + 1) / _flipPages.length : 1.0;
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

  /// 翻页模式的某一页：按段落逐段渲染（每段文本 + 各自操作栏）。
  Widget _buildFlipPage(List<int> paras, int pageIndex) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final i in paras) _buildFlipParagraph(i),
        ],
      ),
    );
  }

  /// 翻页模式下的单个段落（文本 + 右侧操作栏）。
  Widget _buildFlipParagraph(int index) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText.rich(
            TextSpan(
              style: _paraBaseStyle(index),
              children: _buildParagraphSpans(index),
            ),
            onSelectionChanged: (sel, cause) {
              _hasTextSelection = !sel.isCollapsed;
              _onSelectionChanged(sel);
            },
            contextMenuBuilder: (context, editableTextState) =>
                _buildSelectionToolbar(context, editableTextState, index),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: _buildParagraphActions(index),
          ),
        ],
      ),
    );
  }
}

/// 长按选中 / 单击画线的统一菜单卡片：横向 复制 / 画线(擦除) / 全选 / 想法。
/// 画线与全选时不关闭弹窗，可继续点击想法（针对当前选中的文字）。
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
  });

  @override
  State<_IdeaMenuCard> createState() => _IdeaMenuCardState();
}

class _IdeaMenuCardState extends State<_IdeaMenuCard> {
  late int _start;
  late int _end;
  late bool _underlined;
  // 点击「本段全选」后置真：之后画线/想法作用于整段，不再依赖实时选区。
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
          _item(
              _underlined ? Icons.undo : Icons.format_underlined,
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
          _item(Icons.edit_note, widget.initialHasIdea ? '修改想法' : '想法', () {
            final (s, e) = _activeRange;
            widget.close();
            widget.onOpenNote(s, e);
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
