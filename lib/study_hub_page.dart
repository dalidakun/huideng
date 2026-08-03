import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'login_page.dart';
import 'reading_page.dart';
import 'checkin_settings_page.dart';
import 'checkin_goals_page.dart';
import 'sutra_list_page.dart';
import 'calendar_page.dart';
import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'note_edit_page.dart';
import 'note_sutra_links.dart';

const Color _primary = Color(0xFF5C4033);
const Color _primaryLight = Color(0xFF8B6B5A);
const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _border = Color(0xFFEBE1D6);
const Color _overlay = Color(0xFFFFF5EC);

const Map<String, String> _plazaTabMeta = {
  'latest': '最新',
  'hot': '推荐',
  'follow': '关注',
  'announce': '公告',
};

/// 每个广场栏目的笔记流缓存：切换栏目时不重新拉取，直接展示已缓存内容，
/// 离开栏目时后台预取，回到栏目时数据已经就绪。
class _PlazaFeedCache {
  List<PlazaNote> notes = [];
  int page = 1;
  bool hasMore = true;
  bool initial = true;
  bool error = false;
}

class StudyHubPage extends StatefulWidget {
  const StudyHubPage({super.key});

  @override
  State<StudyHubPage> createState() => StudyHubPageState();
}

class StudyHubPageState extends State<StudyHubPage>
    with TickerProviderStateMixin, RouteAware {
  static SharedPreferences? _warmPrefs;

  static Future<void> warmPrefs() async {
    _warmPrefs = await SharedPreferences.getInstance();
  }

  void reload() {
    _loadData();
    _refreshCurrentSmooth();
  }
  String? _currentTitle;
  String? _currentFilePath;
  double _progress = 0.0;
  List<Map<String, String>> _todayCheckIns = [];
  int _checkinStreak = 0;
  int _studyDays = 0;
  String? _lockedTitle;
  String? _lockedFilePath;
  bool _currentFavorite = false;
  List<Map<String, dynamic>> _customTypes = [];
  bool _loaded = false;
  int _tabIndex = 0;
  List<String> _plazaTabs = ['latest', 'hot', 'follow', 'announce'];
  final Map<String, _PlazaFeedCache> _tabCaches = {};
  final List<PlazaNote> _feedNotes = [];
  final Set<String> _followedIds = {};
  final Map<int, String> _timeCache = HashMap<int, String>();
  final Map<String, String> _plainTextCache = {};
  final Map<String, List<(String, String)>> _sutraQuoteCache = {};
  static DateTime _timeCacheNow = DateTime.now();
  final ScrollController _feedScroll = ScrollController();
  final GlobalKey _topSectionKey = GlobalKey();
  double _topSectionHeight = 0;
  bool _showFab = false;
  int _feedPage = 1;
  int _feedVersion = 0;
  bool _feedHasMore = true;
  bool _feedInitial = true;
  bool _feedLoading = false;
  bool _feedError = false;
  static const int _feedPageSize = 20;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  static const _commentIcon = AssetImage('assets/images/ic_comment.png');
  static const _viewIcon = AssetImage('assets/images/ic_view.png');

  @override
  void initState() {
    super.initState();
    NoteSutraCatalog.load(); // 预加载经书目录，让卡片 @经书 提取可用
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.05).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _pulseController.repeat(reverse: true);
    _feedScroll.addListener(_onFeedScroll);
    _loadData();
    _loadFeed();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureTopSection();
      precacheImage(_commentIcon, context);
      precacheImage(_viewIcon, context);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  /// 从阅读页等路由返回时立即刷新“当前读经”进度。
  @override
  void didPopNext() {
    _loadData();
    _refreshCurrentSmooth();
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _pulseController.dispose();
    _feedScroll.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final prefs = _warmPrefs ?? await SharedPreferences.getInstance();
    _warmPrefs = prefs;

    final lastDate = prefs.getString('study_last_date') ?? '';
    final today = _today();
    if (today != lastDate) {
      final count = prefs.getInt('study_day_count') ?? 0;
      unawaited(prefs.setInt('study_day_count', count + 1));
      unawaited(prefs.setString('study_last_date', today));
    }

    String? title;
    String? path;
    final lockTitle = prefs.getString('locked_sutra_title');
    final lockPath = prefs.getString('locked_sutra_file_path');
    String? lockT;
    String? lockP;
    if (lockTitle != null) {
      title = lockTitle;
      path = lockPath;
      lockT = lockTitle;
      lockP = lockPath;
    } else {
      title = prefs.getString('current_sutra_title');
      path = prefs.getString('current_sutra_file_path');
    }
    final fav = await _isCurrentFavorite(title);

    var plazaTabs = <String>['latest', 'hot', 'follow', 'announce'];
    final tabOrderRaw = prefs.getString('plaza_tab_order');
    if (tabOrderRaw != null && tabOrderRaw.isNotEmpty) {
      try {
        final saved = (jsonDecode(tabOrderRaw) as List<dynamic>).cast<String>();
        final valid = <String>[];
        for (final k in saved) {
          if (k == 'discover') {
            // 旧“发现”栏目拆分为“最新 / 最热”。
            if (!valid.contains('latest')) valid.add('latest');
            if (!valid.contains('hot')) valid.add('hot');
          } else if (_plazaTabMeta.containsKey(k) && !valid.contains(k)) {
            valid.add(k);
          }
        }
        for (final k in _plazaTabMeta.keys) {
          if (!valid.contains(k)) valid.add(k);
        }
        plazaTabs = valid;
      } catch (_) {}
    }

    setState(() {
      _loaded = true;
      _currentTitle = title;
      _currentFilePath = path;
      _lockedTitle = lockT;
      _lockedFilePath = lockP;
      if (_currentFilePath != null) {
        _progress = prefs.getDouble('progress_$_currentFilePath') ?? 0.0;
      }
      _currentFavorite = fav;
      _todayCheckIns = _loadTodayCheckIns(prefs);
      _checkinStreak = _calcStreak(prefs);
      _studyDays = prefs.getInt('study_day_count') ?? 0;
      final customRaw = prefs.getString('custom_checkin_types') ?? '[]';
      _customTypes = (jsonDecode(customRaw) as List<dynamic>).cast<Map<String, dynamic>>();
      _plazaTabs = plazaTabs;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureTopSection());
  }

  Future<bool> _isCurrentFavorite(String? title) async {
    if (title == null) return false;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (!await file.exists()) return false;
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      for (final e in decoded) {
        if (e is Map && e['title'] == title) {
          return e['isFavorite'] == true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _toggleFavoriteCurrent() async {
    final title = _currentTitle;
    if (title == null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (!await file.exists()) {
        _showTopToast('未找到经书列表，无法收藏', isError: true);
        return;
      }
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      final list = decoded.map((e) => (e as Map<String, dynamic>)).toList();
      final idx = list.indexWhere((e) => e['title'] == title);
      if (idx < 0) {
        _showTopToast('未找到该经书，无法收藏', isError: true);
        return;
      }
      final wasFav = list[idx]['isFavorite'] == true;
      list[idx]['isFavorite'] = !wasFav;
      list[idx]['favoriteTime'] = wasFav ? null : DateTime.now().toIso8601String();
      await file.writeAsString(jsonEncode(list));
      if (!mounted) return;
      setState(() => _currentFavorite = !wasFav);
    } catch (_) {
      _showTopToast('收藏失败，请重试', isError: true);
    }
  }

  void _showTopToast(String msg, {bool isError = false}) {
    if (!mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final topPad = MediaQuery.of(context).padding.top;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: topPad + kToolbarHeight + 10,
        left: 20,
        right: 20,
        child: IgnorePointer(
          child: Material(
            color: Colors.transparent,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                decoration: BoxDecoration(
                  color: _text.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.14), blurRadius: 14, offset: const Offset(0, 4)),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(isError ? Icons.info_outline : Icons.star, size: 16, color: _gold),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(msg, style: const TextStyle(fontSize: 13, color: Colors.white)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 2), () {
      if (entry.mounted) entry.remove();
    });
  }

  List<Map<String, String>> _loadTodayCheckIns(SharedPreferences prefs) {
    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> allRecords = jsonDecode(raw);
    final today = _today();
    return allRecords.where((r) => r['date'] == today).map((r) => {'type': r['type'].toString(), 'label': r['label'].toString()}).toList();
  }

  int _calcStreak(SharedPreferences prefs) {
    final raw = prefs.getString('checkin_records') ?? '[]';
    final records = (jsonDecode(raw) as List<dynamic>).map((r) => r['date'].toString()).toSet();
    int streak = 0;
    final today = DateTime.now();
    final startIndex = records.contains(_today()) ? 0 : 1;
    for (int i = startIndex; i < 365; i++) {
      final day = today.subtract(Duration(days: i));
      final ds = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      if (records.contains(ds)) { streak++; } else { break; }
    }
    return streak;
  }

  String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  String _displayTitle(String title) =>
      title.replaceAll(RegExp(r'T\d+n[0-9a-z]+_\d+$'), '');

  void _openSutra() {
    if (_currentTitle == null) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => ReadingPage(title: _currentTitle!, filePath: _currentFilePath)));
  }

  void _onFeedScroll() {
    if (_feedScroll.position.pixels >= _feedScroll.position.maxScrollExtent - 200) {
      _loadMoreFeed();
    }
    // 只有当广场栏目栏被滚动到贴住顶部（AppBar 下边缘）时才显示“新增笔记”按钮。
    _measureTopSectionOnce();
    final showFab = _topSectionHeight > 0 && _feedScroll.offset >= _topSectionHeight;
    if (showFab != _showFab) {
      setState(() => _showFab = showFab);
    }
  }

  void _measureTopSectionOnce() {
    if (_topSectionHeight > 0) return;
    final ctx = _topSectionKey.currentContext;
    final box = ctx?.findRenderObject();
    if (box is RenderBox && box.size.height > 0) {
      _topSectionHeight = box.size.height;
    }
  }

  void _measureTopSection() {
    final ctx = _topSectionKey.currentContext;
    final box = ctx?.findRenderObject();
    if (box is RenderBox && box.size.height > 0) {
      _topSectionHeight = box.size.height;
    }
  }

  /// 加载当前 tab 的笔记流。最新：按发布时间倒序（最新分享的在前）。
  /// 最热：按自定义热门规则（阅读/点赞/评论/转发）倒序。关注：仅展示已关注同修的笔记。
  /// 公告：暂为占位 UI。
  Future<void> _loadFeed() async {
    await CloudNotesService.instance.refreshLikedNoteIds();
    await NoteSutraCatalog.load(); // 确保经书目录已缓存，提取 @经书 时可用
    _timeCache.clear();
    _plainTextCache.clear();
    _sutraQuoteCache.clear();
    if (!mounted) return;
    final tab = _plazaTabs[_tabIndex];
    setState(() {
      _feedInitial = true;
      _feedError = false;
      _feedNotes.clear();
      _feedVersion++;
      _feedPage = 1;
      _feedHasMore = true;
      _feedLoading = false;
    });
    try {
      if (tab == 'latest' || tab == 'hot') {
        final sort = tab == 'hot' ? 'hot' : 'latest';
        final (list, hasMore) = await CloudNotesService.instance
            .getPlazaNotes(page: 1, pageSize: _feedPageSize, sort: sort);
        if (mounted) {
          setState(() {
            _feedNotes.addAll(list);
            _feedVersion++;
            _feedPage = 2;
            _feedHasMore = hasMore;
            _feedInitial = false;
          });
        }
      } else if (tab == 'follow') {
        await _loadFollowedIds();
        if (mounted) setState(() => _feedInitial = false);
        if (mounted && _followedIds.isNotEmpty) {
          await _loadFollowingNotes();
        }
      } else {
        if (mounted) setState(() => _feedInitial = false);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _feedInitial = false;
          _feedError = true;
        });
      }
    }
    _saveFeedToCache(tab);
  }

  _PlazaFeedCache _cacheFor(String tab) =>
      _tabCaches.putIfAbsent(tab, _PlazaFeedCache.new);

  /// 把当前正在展示的栏目内容快照进缓存，供切换栏目后恢复。
  void _saveFeedToCache(String tab) {
    final c = _cacheFor(tab);
    c.notes = List.of(_feedNotes);
    c.page = _feedPage;
    c.hasMore = _feedHasMore;
    c.initial = _feedInitial;
    c.error = _feedError;
  }

  /// 把某栏目的缓存内容恢复到当前展示状态（不触发网络请求）。
  void _restoreFeedFromCache(String tab) {
    final c = _cacheFor(tab);
    _feedNotes
      ..clear()
      ..addAll(c.notes);
    _feedPage = c.page;
    _feedHasMore = c.hasMore;
    _feedInitial = c.initial;
    _feedError = c.error;
    _feedLoading = false;
  }

  /// 平滑刷新当前栏目：已有缓存就后台刷新（不闪加载态），首次才全量加载。
  void _refreshCurrentSmooth() {
    final tab = _plazaTabs[_tabIndex];
    if (_cacheFor(tab).initial) {
      _loadFeed();
    } else {
      _refreshFeedInBackground(tab);
    }
  }

  /// 后台预取指定栏目的最新数据，直接写入缓存；若用户正好在该栏目则同步到界面。
  Future<void> _refreshFeedInBackground(String tab) async {
    if (tab == 'announce') return;
    final c = _cacheFor(tab);
    try {
      if (tab == 'latest' || tab == 'hot') {
        final sort = tab == 'hot' ? 'hot' : 'latest';
        final (list, hasMore) = await CloudNotesService.instance
            .getPlazaNotes(page: 1, pageSize: _feedPageSize, sort: sort);
        if (!mounted) return;
        c.notes = list;
        c.page = 2;
        c.hasMore = hasMore;
        c.initial = false;
        c.error = false;
      } else {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('followed_user_ids') ?? '';
        final ids = raw.isEmpty
            ? <String>{}
            : raw.split(',').where((s) => s.isNotEmpty).toSet();
        final all = <PlazaNote>[];
        final seen = <String>{};
        var page = 1;
        var hasMore = true;
        while (hasMore && page <= 50) {
          final (list, more) = await CloudNotesService.instance
              .getPlazaNotes(page: page, pageSize: _feedPageSize);
          for (final n in list) {
            if (ids.contains(n.ownerUserId) && seen.add(n.id)) all.add(n);
          }
          hasMore = more;
          page++;
        }
        if (!mounted) return;
        c.notes = all;
        c.hasMore = false;
        c.initial = false;
        c.error = false;
      }
      if (!mounted) return;
      if (_plazaTabs[_tabIndex] == tab) {
        _restoreFeedFromCache(tab);
        setState(() {});
      }
    } catch (_) {
      if (!mounted) return;
      c.error = true;
      c.initial = false;
      if (_plazaTabs[_tabIndex] == tab) {
        _restoreFeedFromCache(tab);
        setState(() {});
      }
    }
  }

  Future<void> _loadFollowedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('followed_user_ids') ?? '';
    final ids = raw.isEmpty
        ? <String>{}
        : raw.split(',').where((s) => s.isNotEmpty).toSet();
    if (!mounted) return;
    setState(() => _followedIds
      ..clear()
      ..addAll(ids));
  }

  /// 关注 tab：拉取公开笔记并筛选出关注同修的作品。
  /// 最多翻 10 页（200 条），凑够一屏（20 条）即停止。
  Future<void> _loadFollowingNotes() async {
    setState(() => _feedLoading = true);
    try {
      final all = <PlazaNote>[];
      final seen = <String>{};
      var page = 1;
      var hasMore = true;
      const maxPages = 10;
      const minCollect = _feedPageSize;
      while (hasMore && page <= maxPages && all.length < minCollect) {
        final (list, more) = await CloudNotesService.instance
            .getPlazaNotes(page: page, pageSize: _feedPageSize);
        for (final n in list) {
          if (_followedIds.contains(n.ownerUserId) && seen.add(n.id)) {
            all.add(n);
          }
        }
        hasMore = more;
        page++;
      }
      if (!mounted) return;
      setState(() {
        _feedNotes
          ..clear()
          ..addAll(all);
        _feedHasMore = false;
        _feedLoading = false;
        _feedInitial = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _feedLoading = false;
        _feedInitial = false;
        _feedError = true;
      });
    }
  }

  Future<void> _loadMoreFeed() async {
    final tab = _plazaTabs[_tabIndex];
    if ((tab != 'latest' && tab != 'hot') ||
        _feedLoading ||
        !_feedHasMore ||
        _feedInitial) {
      return;
    }
    setState(() => _feedLoading = true);
    try {
      final sort = tab == 'hot' ? 'hot' : 'latest';
      final (list, hasMore) = await CloudNotesService.instance
          .getPlazaNotes(page: _feedPage, pageSize: _feedPageSize, sort: sort);
      if (!mounted) return;
      setState(() {
        _feedNotes.addAll(list);
        _feedVersion++;
        _feedPage++;
        _feedHasMore = hasMore;
        _feedLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _feedLoading = false);
    }
  }

  void _onTabChanged(int i) {
    if (_tabIndex == i) return;
    final prevTab = _plazaTabs[_tabIndex];
    _saveFeedToCache(prevTab);
    setState(() {
      _tabIndex = i;
      _restoreFeedFromCache(_plazaTabs[i]);
    });
    if (_cacheFor(_plazaTabs[i]).initial) {
      // 该栏目从未加载过，首次进入才全量加载。
      _loadFeed();
    }
    // 后台预取刚离开的栏目，等再次回来时已是最新。
    _refreshFeedInBackground(prevTab);
  }

  /// 弹出栏目排序面板，长按拖动调整顺序并持久化。
  Future<void> _showTabSortDialog() async {
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        var items = List<String>.from(_plazaTabs);
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('栏目排序',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _text)),
                    const SizedBox(height: 4),
                    const Text('长按拖动调整栏目顺序',
                        style: TextStyle(fontSize: 12, color: _textSec)),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: items.length * 56.0,
                      child: ReorderableListView(
                        shrinkWrap: true,
                        buildDefaultDragHandles: false,
                        proxyDecorator: (child, index, animation) {
                          return AnimatedBuilder(
                            animation: animation,
                            builder: (context, child) {
                              final t =
                                  Curves.easeInOut.transform(animation.value);
                              return Material(
                                color: _card,
                                elevation: 4 + 8 * t,
                                shadowColor:
                                    Colors.black.withValues(alpha: 0.22),
                                borderRadius: BorderRadius.circular(12),
                                child: child,
                              );
                            },
                            child: child,
                          );
                        },
                        onReorder: (o, n) {
                          setModalState(() {
                            if (n > o) n -= 1;
                            final item = items.removeAt(o);
                            items.insert(n, item);
                          });
                        },
                        children: [
                          for (var i = 0; i < items.length; i++)
                            ReorderableDelayedDragStartListener(
                              index: i,
                              key: ValueKey(items[i]),
                              child: ListTile(
                                contentPadding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                leading: ReorderableDragStartListener(
                                  index: i,
                                  child: const Icon(Icons.drag_handle,
                                      color: _textHint),
                                ),
                                title: Text(
                                    _plazaTabMeta[items[i]] ?? items[i],
                                    style: const TextStyle(
                                        fontSize: 15, color: _text)),
                                trailing: const Icon(Icons.unfold_more,
                                    color: _textHint),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, items),
                        style: FilledButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                        child: const Text('完成', style: TextStyle(fontSize: 15)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (result == null || result.isEmpty) return;
    final currentType = _plazaTabs[_tabIndex];
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _plazaTabs = result;
      _tabIndex = _plazaTabs.indexOf(currentType);
      if (_tabIndex < 0) _tabIndex = 0;
      _restoreFeedFromCache(_plazaTabs[_tabIndex]);
    });
    await prefs.setString('plaza_tab_order', jsonEncode(_plazaTabs));
    if (_cacheFor(_plazaTabs[_tabIndex]).initial) {
      _loadFeed();
    }
  }

  Future<void> _toggleFollow(PlazaNote note) async {
    if (!AuthService.instance.isLoggedIn) {
      _showTopToast('请先登录后再关注同修');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('followed_user_ids') ?? '';
    final ids = raw.isEmpty
        ? <String>{}
        : raw.split(',').where((s) => s.isNotEmpty).toSet();
    final following = !ids.contains(note.ownerUserId);
    if (following) {
      ids.add(note.ownerUserId);
    } else {
      ids.remove(note.ownerUserId);
    }
    await prefs.setString('followed_user_ids', ids.join(','));
    if (!mounted) return;
    setState(() => _followedIds
      ..clear()
      ..addAll(ids));
    if (_plazaTabs[_tabIndex] == 'follow') {
      setState(() {
        _feedNotes.removeWhere((n) => n.id == note.id);
        _feedVersion++;
      });
    }
    _showTopToast(following ? '已关注' : '已取消关注');
  }

  void _openPlazaNote(PlazaNote note) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)));
  }

  Future<void> _openSutraByPath(String title, String? filePath) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ReadingPage(title: title, filePath: filePath)));
    _loadData();
  }

  Future<void> _showRecentSutras() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('daily_sutra_history') ?? '{}';
    final Map<String, dynamic> history = jsonDecode(raw);
    if (history.isEmpty) return;
    final dates = history.keys.toList()..sort((a, b) => b.compareTo(a));
    final latestDate = dates.first;
    final List<dynamic> sutras = history[latestDate] as List<dynamic>;

    if (!mounted || sutras.isEmpty) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Row(
                  children: [
                    Text('$latestDate 阅读', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
                    const Spacer(),
                    Text('${sutras.length} 部', style: TextStyle(fontSize: 13, color: _textHint)),
                  ],
                ),
              ),
              const Divider(height: 1, color: _border),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: sutras.map((s) {
                    final title = s['title'] as String? ?? '';
                    final fp = s['filePath'] as String?;
                    final progress = (s['progress'] as num?)?.toDouble() ?? 0.0;
                    return InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        if (title.isNotEmpty) _openSutraByPath(title, fp);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _text)),
                                  const SizedBox(height: 4),
                                  Text('已读 ${(progress * 100).toStringAsFixed(1)}%', style: TextStyle(fontSize: 12, color: _textHint)),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right, color: _textHint, size: 20),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _toggleLock() async {
    if (_currentTitle == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (_lockedTitle != null) {
      await prefs.remove('locked_sutra_title');
      await prefs.remove('locked_sutra_file_path');
      setState(() {
        _lockedTitle = null;
        _lockedFilePath = null;
      });
    } else {
      await prefs.setString('locked_sutra_title', _currentTitle!);
      await prefs.setString('locked_sutra_file_path', _currentFilePath ?? '');
      _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Color(0xFF212121)),
        title: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: const Text(
            '诸行无常，一切皆苦；诸法无我，寂灭为乐。',
            style: TextStyle(
              color: Color(0xFF616161),
              fontSize: 12,
              fontWeight: FontWeight.normal,
            ),
            softWrap: false,
            overflow: TextOverflow.visible,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton(
              icon: const Icon(Icons.calendar_month_outlined, color: Color(0xFF71867A), size: 20),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CalendarPage())),
            ),
          ),
        ],
      ),
      floatingActionButton: _showFab
          ? Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SizedBox(
                width: 48,
                height: 48,
                child: FloatingActionButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const NoteEditPage()),
                  ).then((_) => _refreshCurrentSmooth()),
                  heroTag: 'plaza_fab',
                  backgroundColor: const Color(0xFF71867A),
                  elevation: 8,
                  highlightElevation: 12,
                  shape: const CircleBorder(),
                  child: const Icon(Icons.add, color: Colors.white, size: 24),
                ),
              ),
            )
          : null,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final viewportH = constraints.maxHeight;
          return RefreshIndicator(
            onRefresh: _loadFeed,
            color: _gold,
            child: CustomScrollView(
              controller: _feedScroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    key: _topSectionKey,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                    child: Column(
                      children: [
                        _buildCurrentSutraCard(),
                        const SizedBox(height: 14),
                        _buildCheckInCard(),
                      ],
                    ),
                  ),
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _PlazaHeaderDelegate(
                    tabIndex: _tabIndex,
                    tabs: _plazaTabs,
                    onTabChanged: _onTabChanged,
                    onReorderPressed: () => _showTabSortDialog(),
                    textScale: MediaQuery.textScalerOf(context).scale(1.0),
                  ),
                ),
                ..._buildFeedSlivers(viewportH),
              ],
            ),
          );
        },
      ),
    );
  }

  double _headerHeight() {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    return (48 * scale).clamp(48.0, 88.0);
  }

  Widget _buildCurrentSutraCard() {
    if (!_loaded) {
      return Container(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2)),
          ],
        ),
        child: const Padding(
          padding: EdgeInsets.all(40),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: _primary),
            ),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _currentTitle != null ? _openSutra : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Row(
                children: [
                  Container(
                    width: 28, height: 28,
                    decoration: BoxDecoration(color: _primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.menu_book_rounded, size: 16, color: const Color(0xFF71867A)),
                  ),
                  const SizedBox(width: 10),
                  const Text('当前学习', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
                  const Spacer(),
                  if (_currentTitle != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(color: _overlay, borderRadius: BorderRadius.circular(11)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.today, size: 12, color: _primaryLight),
                          const SizedBox(width: 4),
                          Text('已学$_studyDays天', style: const TextStyle(fontSize: 11, color: _primaryLight, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_currentTitle != null) ...[
            const SizedBox(height: 6),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openSutra,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_displayTitle(_currentTitle!), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _textSec, height: 1.4)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: _progress,
                        minHeight: 5,
                        backgroundColor: _border,
                        valueColor: const AlwaysStoppedAnimation<Color>(_gold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('${(_progress * 100).toStringAsFixed(1)}%', style: const TextStyle(fontSize: 12, color: _textHint, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _toggleLock,
                    style: TextButton.styleFrom(
                      foregroundColor: _lockedTitle != null ? _gold : _textSec,
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_lockedTitle != null ? Icons.lock : Icons.lock_open, size: 13),
                        const SizedBox(width: 4),
                        Text(_lockedTitle != null ? '已锁定' : '锁定经书', style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 18),
                  TextButton(
                    onPressed: _toggleFavoriteCurrent,
                    style: TextButton.styleFrom(
                      foregroundColor: _currentFavorite ? _gold : _textSec,
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(_currentFavorite ? 'assets/images/star_filled.png' : 'assets/images/star_outline.png', width: 13, height: 13),
                        const SizedBox(width: 4),
                        Text(_currentFavorite ? '已收藏' : '收藏', style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _showRecentSutras,
                    style: TextButton.styleFrom(foregroundColor: _textSec, padding: const EdgeInsets.symmetric(horizontal: 16)),
                    child: const Text('最近阅读 ›', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
          ] else ...[
            Center(
              child: Column(
                children: [
                  const SizedBox(height: 2),
                  AnimatedBuilder(
                    animation: _pulseAnim,
                    builder: (context, child) => Transform.scale(scale: _pulseAnim.value, child: child),
                    child: Container(
                      width: 56, height: 56,
                      decoration: BoxDecoration(
                        color: _overlay,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(Icons.auto_stories_rounded, size: 30, color: _primaryLight.withValues(alpha: 0.8)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text('今日尚未开启经文之旅', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _text)),
                  const SizedBox(height: 4),
                  Text('选择一部经文，开始今日修学', style: TextStyle(fontSize: 13, color: _textSec)),
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SutraListPage())),
                        icon: const Icon(Icons.explore, size: 17),
                        label: const Text('浏览经藏', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildCheckInCard() {
    final types = [
      {'key': 'meditation', 'label': '静坐', 'icon': Icons.self_improvement_outlined},
      {'key': 'reading', 'label': '诵经', 'icon': Icons.chrome_reader_mode_outlined},
      {'key': 'mantra', 'label': '持咒', 'icon': Icons.notifications_none_outlined},
      {'key': 'buddha', 'label': '称名', 'icon': Icons.spa_outlined},
      {'key': 'copying', 'label': '抄经', 'icon': Icons.edit_outlined},
      ..._customTypes.map((t) => {'key': t['key'], 'label': t['label'], 'icon': Icons.playlist_add}),
    ];
    final doneCount = _todayCheckIns.length;

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Row(
              children: [
                Container(
                  width: 30, height: 30,
                  decoration: BoxDecoration(color: _primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: Icon(Icons.check_circle_outline, size: 17, color: const Color(0xFF71867A)),
                ),
                const SizedBox(width: 10),
                Text('功课打卡', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
                const Spacer(),
                Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(color: _overlay, borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.today, size: 12, color: _primaryLight),
                        const SizedBox(width: 4),
                        Text('打卡$_checkinStreak天', style: TextStyle(fontSize: 11, color: _primaryLight, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 66,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: types.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final t = types[i];
                final checked = _todayCheckIns.any((r) => r['type'] == t['key']);
                return _CheckInButton(
                  icon: t['icon'] as IconData?,
                  emoji: t['emoji'] as String?,
                  label: t['label'] as String,
                  checked: checked,
                  onTap: () => _toggleCheckIn(t['key'] as String, t['label'] as String),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: doneCount / types.length,
                      minHeight: 4,
                      backgroundColor: _border,
                      valueColor: const AlwaysStoppedAnimation<Color>(_primary),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text('$doneCount/${types.length}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _primary)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CheckInSettingsPage())),
                  style: TextButton.styleFrom(foregroundColor: _textSec, padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune, size: 13),
                      const SizedBox(width: 4),
                      Text('设置每日功课', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CheckInGoalsPage())),
                  style: TextButton.styleFrom(foregroundColor: _textSec, padding: const EdgeInsets.symmetric(horizontal: 16)),
                  child: Text('打卡目标 ›', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建当前栏目的笔记流 slivers。为保证“发现/关注/公告”栏目栏被吸顶后，
  /// 点击任意子项都不掉落，内容较少时用 spacer 补足滚动量，
  /// 使内容高度至少达到视口高度（视口 - 栏目栏高度），从而始终能吸顶。
  List<Widget> _buildFeedSlivers(double viewportH) {
    final tab = _plazaTabs[_tabIndex];
    if (tab == 'announce') {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: math.max(0.0, viewportH - _headerHeight()),
              ),
              child: _buildAnnounceBody(),
            ),
          ),
        ),
      ];
    }
    final hasNotes = _feedNotes.isNotEmpty;
    final minFeed = math.max(0.0, viewportH - _headerHeight());

    if (!hasNotes) {
      if (_feedInitial || _feedLoading) {
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: const SizedBox(
                width: 24,
                height: 24,
                child:
                    CircularProgressIndicator(strokeWidth: 2.2, color: _gold),
              ),
            ),
          ),
        ];
      }
      if (_feedError) {
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: minFeed),
                child: _buildFeedError(),
              ),
            ),
          ),
        ];
      }
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minFeed),
              child: _buildFeedEmpty(),
            ),
          ),
        ),
      ];
    }

    final feedLen = _feedNotes.length;
    final showFooter = _feedLoading || !_feedHasMore || _feedError;
    // 保守估计每条笔记高度，保证补足后的内容高度一定够吸顶。
    final feedEstimate = feedLen * 110.0 + (showFooter ? 70.0 : 0.0);
    final spacerH = math.max(0.0, minFeed - feedEstimate);
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
        sliver: SliverList(
          key: ValueKey('feed_$_feedVersion'),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              if (index < feedLen) {
                return _buildFeedTile(_feedNotes[index]);
              }
              return _buildFeedFooter();
            },
            childCount: feedLen + (showFooter ? 1 : 0),
            addRepaintBoundaries: true,
          ),
        ),
      ),
      if (spacerH > 0)
        SliverToBoxAdapter(child: SizedBox(height: spacerH)),
    ];
  }

  Widget _buildFeedFooter() {
    if (_feedLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
          ),
        ),
      );
    }
    if (_feedError) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: TextButton.icon(
            onPressed: _loadFeed,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('加载失败，点击重试', style: TextStyle(fontSize: 13)),
            style: TextButton.styleFrom(foregroundColor: _textSec),
          ),
        ),
      );
    }
    if (!_feedHasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text('— 到底了 —',
              style: const TextStyle(fontSize: 12, color: _textHint)),
        ),
      );
    }
    return const SizedBox(height: 12);
  }

  Widget _buildFeedEmpty() {
    final isFollowing = _plazaTabs[_tabIndex] == 'follow';
    final notLoggedIn = !AuthService.instance.isLoggedIn;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.auto_awesome_outlined, size: 52, color: _textHint),
        const SizedBox(height: 14),
        Text(
          isFollowing
              ? (notLoggedIn ? '登录后关注同修' : '还没有关注同修')
              : '菩提空间还没有笔记',
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w600, color: _text),
        ),
        const SizedBox(height: 6),
        Text(
          isFollowing
              ? '关注同修后，这里会显示他们的新笔记'
              : '分享你的修学心得，让大家一起受益',
          style: const TextStyle(fontSize: 13, color: _textSec),
        ),
        const SizedBox(height: 18),
        if (isFollowing && notLoggedIn)
          FilledButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LoginPage()),
            ),
            icon: const Icon(Icons.login, size: 17),
            label: const Text('登录',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            style: FilledButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
          ),
      ],
    );
  }

  /// 公告 tab：管理员发布公告的展示位，功能暂未接入，先出占位 UI。
  Widget _buildAnnounceBody() {
    return Column(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: _gold.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.campaign_outlined,
              size: 30, color: Color(0xFF9A6B3F)),
        ),
        const SizedBox(height: 16),
        const Text('暂无公告',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
        const SizedBox(height: 8),
        const Text('管理员发布的公告将在这里显示',
            style: TextStyle(fontSize: 13, color: _textSec)),
      ],
    );
  }

  Widget _buildFeedError() {
    return Padding(
      padding: const EdgeInsets.only(top: 60, bottom: 40),
      child: Column(
        children: [
          Icon(Icons.wifi_off_outlined, size: 52, color: _textHint),
          const SizedBox(height: 14),
          const Text('加载失败',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _loadFeed,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试', style: TextStyle(fontSize: 14)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeedTile(PlazaNote note) {
    final content = _plainTextCache.putIfAbsent(note.id, () => NoteSutraLinks.plainText(note.content));
    final preview = content.length > 60
        ? '${content.substring(0, 60)}...'
        : content;
    final sutraQuotes = _sutraQuoteCache.putIfAbsent(note.id, () => NoteSutraLinks.extract(note.content));
    final isMine =
        AuthService.instance.currentUser.value?.id == note.ownerUserId;
    final isLoggedIn = AuthService.instance.isLoggedIn;
    final followed = _followedIds.contains(note.ownerUserId);
    final liked = CloudNotesService.instance.likedNoteIds.contains(note.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2)),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openPlazaNote(note),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 13, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (note.repostOf.isNotEmpty) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.repeat, size: 12, color: _gold),
                        const SizedBox(width: 2),
                        Text(note.quoteContent.isNotEmpty ? '引用' : '转发',
                            style: const TextStyle(
                                fontSize: 11, color: _gold)),
                      ],
                    ),
                  ],
                  if (isLoggedIn && !isMine) ...[
                    const Spacer(),
                    GestureDetector(
                      onTap: () => _toggleFollow(note),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: followed
                              ? Colors.transparent
                              : _gold.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: followed
                                  ? _border
                                  : _gold.withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          followed ? '已关注' : '关注',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: followed
                                ? _textHint
                                : const Color(0xFF9A6B3F),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (note.content.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  preview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, color: _textSec, height: 1.5),
                ),
              ],
              if (sutraQuotes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _bg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final q in sutraQuotes)
                        InkWell(
                          onTap: () => _openSutraByPath(q.$1, q.$2),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                const Icon(Icons.menu_book_rounded,
                                    size: 14, color: _gold),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    q.$1,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        color: Color(0xFF9A6B3F),
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                                const Icon(Icons.chevron_right,
                                    size: 14, color: _gold),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (note.quoteContent.isNotEmpty) ...[
                const SizedBox(height: 6),
                Builder(builder: (_) {
                  final quoteSutras =
                      NoteSutraLinks.extract(note.quoteOfContent);
                  final quotePlain = _plainTextCache.putIfAbsent(
                      'quote_${note.id}',
                      () => NoteSutraLinks.plainText(note.quoteOfContent));
                  final quotePreview = quotePlain.length > 80
                      ? '${quotePlain.substring(0, 80)}...'
                      : quotePlain;
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: _bg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                            '@${note.repostSourceAuthor} 的笔记',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: _textSec)),
                        if (quotePreview.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            quotePreview,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, color: _textSec, height: 1.5),
                          ),
                        ],
                        for (final q in quoteSutras) ...[
                          const SizedBox(height: 5),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.menu_book_rounded,
                                  size: 13, color: _gold),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  '@${q.$1}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF9A6B3F),
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  );
                }),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Flexible(
                    child: Row(
                      children: [
                        const Icon(Icons.person_outline,
                            size: 13, color: _textHint),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(note.authorName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: _textSec)),
                        ),
                        if (note.authorAccount.isNotEmpty) ...[
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text('@${note.authorAccount}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13, color: Color(0xFF8C8C8C))),
                          ),
                          const SizedBox(width: 3),
                          Text('·',
                              style: const TextStyle(
                                  fontSize: 13, color: Color(0xFF8C8C8C))),
                          const SizedBox(width: 2),
                        ],
                        const SizedBox(width: 2),
                        const Icon(Icons.schedule,
                            size: 13, color: Color(0xFF8C8C8C)),
                        const SizedBox(width: 2),
                        Text(_formatNoteTime(note.createdAt),
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xFF8C8C8C))),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image(image: _commentIcon,
                          width: 13, height: 13),
                      const SizedBox(width: 3),
                      Text(_formatCount(note.commentCount),
                          style: const TextStyle(
                              fontSize: 12, color: _textSec)),
                      const SizedBox(width: 8),
                      const Icon(Icons.repeat_rounded,
                          size: 13, color: _textSec),
                      const SizedBox(width: 3),
                      Text(_formatCount(note.repostCount),
                          style: const TextStyle(
                              fontSize: 12, color: _textSec)),
                      const SizedBox(width: 8),
                      Icon(
                        liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 13,
                        color: liked
                            ? _gold
                            : _textSec,
                      ),
                      const SizedBox(width: 3),
                      Text(_formatCount(note.likeCount),
                          style: TextStyle(
                              fontSize: 12,
                              color: liked
                                  ? _gold
                                  : _textSec)),
                      const SizedBox(width: 8),
                      Image(image: _viewIcon,
                          width: 13, height: 13),
                      const SizedBox(width: 3),
                      Text(_formatCount(note.viewCount),
                          style: const TextStyle(
                              fontSize: 12, color: _textSec)),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 将计数缩写为更紧凑的形式，避免大数字撑开布局被后面图标遮盖。
  String _formatCount(int count) {
    if (count >= 100000000) {
      return '${(count / 100000000).toStringAsFixed(1)}亿';
    }
    if (count >= 10000) {
      return '${(count / 10000).toStringAsFixed(1)}万';
    }
    return '$count';
  }

  String _formatNoteTime(int ms) {
    if (ms <= 0) return '';
    return _timeCache.putIfAbsent(ms, () {
      final t = DateTime.fromMillisecondsSinceEpoch(ms);
      _timeCacheNow = DateTime.now();
      final today = DateTime(_timeCacheNow.year, _timeCacheNow.month, _timeCacheNow.day);
      final day = DateTime(t.year, t.month, t.day);
      final diff = today.difference(day).inDays;
      if (diff == 0) {
        return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      }
      if (diff == 1) return '昨天';
      if (t.year == _timeCacheNow.year) return '${t.month}月${t.day}日';
      return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    });
  }

  Future<void> _toggleCheckIn(String typeKey, String label) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> allRecords = jsonDecode(raw);
    final today = _today();

    final idx = allRecords.indexWhere((r) => r['date'] == today && r['type'] == typeKey);
    if (idx >= 0) {
      allRecords.removeAt(idx);
    } else {
      allRecords.add({
        'date': today,
        'type': typeKey,
        'label': label,
        'amount': _checkInAmount(typeKey, prefs),
      });
    }
    await prefs.setString('checkin_records', jsonEncode(allRecords));
    _loadData();
  }

  double _checkInAmount(String typeKey, SharedPreferences prefs) {
    switch (typeKey) {
      case 'meditation':
        final list = jsonDecode(prefs.getString('setting_meditation_minutes') ?? '[]') as List<dynamic>;
        return list.fold<double>(0, (s, e) => s + (double.tryParse(e.toString()) ?? 0));
      case 'reading':
        return _sumNamedCount(prefs.getString('setting_reading_titles'));
      case 'mantra':
        return _sumNamedCount(prefs.getString('setting_mantra_items'));
      case 'buddha':
        return _sumNamedCount(prefs.getString('setting_buddha_items'));
      case 'copying':
        final list = jsonDecode(prefs.getString('setting_copying_titles') ?? '[]') as List<dynamic>;
        return list.length.toDouble();
      default:
        final customs = (jsonDecode(prefs.getString('custom_checkin_types') ?? '[]') as List<dynamic>).cast<Map<String, dynamic>>();
        for (final c in customs) {
          if (c['key'] == typeKey) {
            return double.tryParse((c['count'] ?? '').toString()) ?? 0;
          }
        }
        return 0;
    }
  }

  double _sumNamedCount(String? raw) {
    if (raw == null || raw.isEmpty) return 0;
    final list = jsonDecode(raw) as List<dynamic>;
    return list.fold<double>(0, (s, e) => s + (double.tryParse((e['count'] ?? '').toString()) ?? 0));
  }

}

class _PlazaHeaderDelegate extends SliverPersistentHeaderDelegate {
  final int tabIndex;
  final List<String> tabs;
  final ValueChanged<int> onTabChanged;
  final VoidCallback onReorderPressed;
  final double textScale;

  const _PlazaHeaderDelegate({
    required this.tabIndex,
    required this.tabs,
    required this.onTabChanged,
    required this.onReorderPressed,
    this.textScale = 1.0,
  });

  double get _height => (48 * textScale).clamp(48.0, 88.0);

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: _bg,
      ),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                _buildTab(context, _plazaTabMeta[tabs[i]] ?? tabs[i], i),
              const Spacer(),
              IconButton(
                onPressed: onReorderPressed,
                tooltip: '排序',
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 40, height: 40),
                icon: const Icon(Icons.menu, color: Color(0xFF8B6B5A), size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTab(BuildContext context, String label, int index) {
    final selected = tabIndex == index;
    return GestureDetector(
      onTap: () => onTabChanged(index),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? _text : _textSec,
              ),
            ),
            const SizedBox(height: 3),
            Container(
              width: 36,
              height: 3,
              decoration: BoxDecoration(
                color: selected ? _gold : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _PlazaHeaderDelegate oldDelegate) =>
      oldDelegate.tabIndex != tabIndex ||
      oldDelegate.textScale != textScale ||
      oldDelegate.tabs.join(',') != tabs.join(',');
}

class _CheckInButton extends StatefulWidget {
  final IconData? icon;
  final String? emoji;
  final String label;
  final bool checked;
  final VoidCallback onTap;

  const _CheckInButton({this.icon, this.emoji, required this.label, required this.checked, required this.onTap});

  @override
  State<_CheckInButton> createState() => _CheckInButtonState();
}

class _CheckInButtonState extends State<_CheckInButton> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));
    _scale = Tween<double>(begin: 1.0, end: 0.92).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapDown(_) => _ctrl.forward();
  void _onTapUp(_) {
    _ctrl.reverse();
    widget.onTap();
  }
  void _onTapCancel() => _ctrl.reverse();

  @override
  Widget build(BuildContext context) {
    final checked = widget.checked;
    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, child) => Transform.scale(scale: _scale.value, child: child),
        child: Container(
          width: 60,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: checked ? _gold : _overlay,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null)
                Icon(widget.icon, size: 22, color: checked ? _primary : const Color(0xFF71867A))
              else
                Text(widget.emoji ?? '', style: TextStyle(fontSize: 20)),
              const SizedBox(height: 4),
              Text(widget.label, style: TextStyle(
                fontSize: 12,
                color: checked ? _primary : _textSec,
                fontWeight: checked ? FontWeight.w600 : FontWeight.w400,
              )),
            ],
          ),
        ),
      ),
    );
  }
}

