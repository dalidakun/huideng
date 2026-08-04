import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'sync_service.dart';
import 'user_avatar.dart';
import 'login_page.dart';
import 'reading_page.dart';
import 'checkin_settings_page.dart';
import 'checkin_goals_page.dart';
import 'sutra_list_page.dart';
import 'calendar_page.dart';
import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'reply_chain.dart';
import 'my_page.dart';
import 'text_input_sheet.dart';
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
  /// 左上角头像点击回调：打开「我的」页面。
  final VoidCallback? onOpenMyPage;
  const StudyHubPage({super.key, this.onOpenMyPage});

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
  /// 是否允许他人在主页查看我的「精读」（在读经书）。
  bool _allowReadingShare = false;
  List<Map<String, dynamic>> _customTypes = [];
  /// 实际配置的功课类型列表（功课打卡卡片与自动分享共用）。
  List<Map<String, dynamic>> _checkInTypesList = [];
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
  List<AnnouncementItem> _announcements = [];
  bool _announceLoading = false;
  bool _announceError = false;
  static const int _feedPageSize = 20;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  static const _commentIcon = AssetImage('assets/images/ic_comment.png');
  static const _viewIcon = AssetImage('assets/images/ic_view.png');

  @override
  void initState() {
    super.initState();
    NoteSutraCatalog.load(); // 预加载经书目录，让卡片 @经书 提取可用
    _pulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500));
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.05).animate(
        CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
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
      _allowReadingShare = prefs.getBool('privacy_show_reading') ?? false;
      _todayCheckIns = _loadTodayCheckIns(prefs);
      _checkinStreak = _calcStreak(prefs);
      _studyDays = prefs.getInt('study_day_count') ?? 0;
      final customRaw = prefs.getString('custom_checkin_types') ?? '[]';
      _customTypes =
          (jsonDecode(customRaw) as List<dynamic>).cast<Map<String, dynamic>>();
      _checkInTypesList = _buildConfiguredCheckInTypes(prefs);
      _plazaTabs = plazaTabs;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureTopSection());
  }

  Future<bool> _isCurrentFavorite(String? title) async {
    if (title == null) return false;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}sutras_list.json');
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
      final file =
          File('${docs.path}${Platform.pathSeparator}sutras_list.json');
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
      list[idx]['favoriteTime'] =
          wasFav ? null : DateTime.now().toIso8601String();
      await file.writeAsString(jsonEncode(list));
      if (!mounted) return;
      setState(() => _currentFavorite = !wasFav);
    } catch (_) {
      _showTopToast('收藏失败，请重试', isError: true);
    }
  }

  /// 精读经文卡右上角的「允许」开关：控制他人在主页查看我的精读。
  Future<void> _toggleReadingShare(bool v) async {
    setState(() => _allowReadingShare = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('privacy_show_reading', v);
    await SyncService.instance.push();
    if (mounted) {
      _showTopToast(
          v ? '已开启，其他同修可查看你的精读' : '已关闭，其他同修不可查看你的精读');
    }
  }

  /// 长按精读经文卡的经书名：弹出「收藏 / 标记完成」窗口（与经藏长按菜单同款样式）。
  Future<void> _showSutraActionsSheet() async {
    final title = _currentTitle;
    if (title == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetMenuItem(
                context,
                icon: _currentFavorite ? Icons.favorite : Icons.favorite_border,
                title: _currentFavorite ? '取消收藏' : '收藏',
                onTap: () {
                  Navigator.pop(context);
                  _toggleFavoriteCurrent();
                },
              ),
              _sheetMenuItem(
                context,
                icon: Icons.mark_chat_read,
                title: '标记完成阅读',
                onTap: () {
                  Navigator.pop(context);
                  _markCurrentRead();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// 经藏长按菜单同款菜单项：白底、图标 24 + 文字 16。
  Widget _sheetMenuItem(
    BuildContext ctx, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF212121), size: 24),
            const SizedBox(width: 16),
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFF212121),
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 标记当前精读经文为已读完成。
  Future<void> _markCurrentRead() async {
    final title = _currentTitle;
    if (title == null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (!await file.exists()) {
        _showTopToast('未找到经书列表，无法标记', isError: true);
        return;
      }
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      final list = decoded.map((e) => (e as Map<String, dynamic>)).toList();
      final idx = list.indexWhere((e) => e['title'] == title);
      if (idx < 0) {
        _showTopToast('未找到该经书，无法标记', isError: true);
        return;
      }
      list[idx]['isRead'] = true;
      list[idx]['readTime'] = DateTime.now().toIso8601String();
      await file.writeAsString(jsonEncode(list));
      if (!mounted) return;
      _showTopToast('已标记完成');
    } catch (_) {
      _showTopToast('标记失败，请重试', isError: true);
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                decoration: BoxDecoration(
                  color: _text.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.14),
                        blurRadius: 14,
                        offset: const Offset(0, 4)),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(isError ? Icons.info_outline : Icons.star,
                        size: 16, color: _gold),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(msg,
                          style: const TextStyle(
                              fontSize: 13, color: Colors.white)),
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
    return allRecords
        .where((r) => r['date'] == today)
        .map((r) =>
            {'type': r['type'].toString(), 'label': r['label'].toString()})
        .toList();
  }

  int _calcStreak(SharedPreferences prefs) {
    final raw = prefs.getString('checkin_records') ?? '[]';
    final records = (jsonDecode(raw) as List<dynamic>)
        .map((r) => r['date'].toString())
        .toSet();
    int streak = 0;
    final today = DateTime.now();
    final startIndex = records.contains(_today()) ? 0 : 1;
    for (int i = startIndex; i < 365; i++) {
      final day = today.subtract(Duration(days: i));
      final ds =
          '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      if (records.contains(ds)) {
        streak++;
      } else {
        break;
      }
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
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ReadingPage(
                title: _currentTitle!, filePath: _currentFilePath)));
  }

  void _onFeedScroll() {
    if (_feedScroll.position.pixels >=
        _feedScroll.position.maxScrollExtent - 200) {
      _loadMoreFeed();
    }
    // 只有当广场栏目栏被滚动到贴住顶部（AppBar 下边缘）时才显示“新增笔记”按钮。
    _measureTopSectionOnce();
    final showFab =
        _topSectionHeight > 0 && _feedScroll.offset >= _topSectionHeight;
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

  /// 拉取一页广场笔记并过滤掉被屏蔽用户的帖子；若整页均被屏蔽且还有更多，自动续取下一页（最多 4 页）。
  /// 返回（可见笔记, 下一页页码, 是否还有更多）。
  Future<(List<PlazaNote>, int, bool)> _fetchFilteredFeed(
      int page, String sort) async {
    final blocked = CloudNotesService.instance.blockedUserIds;
    if (blocked.isEmpty) {
      final (list, more) = await CloudNotesService.instance
          .getPlazaNotes(page: page, pageSize: _feedPageSize, sort: sort);
      return (list, page + 1, more);
    }
    final collected = <PlazaNote>[];
    var cur = page;
    var hasMore = true;
    for (var i = 0; i < 4; i++) {
      final (list, more) = await CloudNotesService.instance
          .getPlazaNotes(page: cur, pageSize: _feedPageSize, sort: sort);
      for (final n in list) {
        if (!blocked.contains(n.ownerUserId)) collected.add(n);
      }
      hasMore = more;
      cur++;
      if (collected.isNotEmpty || !hasMore) break;
    }
    return (collected, cur, hasMore);
  }

  /// 加载当前 tab 的笔记流。最新：按发布时间倒序（最新分享的在前）。
  /// 最热：按自定义热门规则（阅读/点赞/评论/转发）倒序。关注：仅展示已关注同修的笔记。
  /// 公告：暂为占位 UI。
  Future<void> _loadFeed() async {
    await CloudNotesService.instance.refreshLikedNoteIds();
    await CloudNotesService.instance.refreshFollowStates();
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
        final (list, nextPage, hasMore) = await _fetchFilteredFeed(1, sort);
        if (mounted) {
          setState(() {
            _feedNotes.addAll(list);
            _feedVersion++;
            _feedPage = nextPage;
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
      } else if (tab == 'announce') {
        await _loadAnnouncements();
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

  /// 拉取公告列表（主页公告栏展示，最新在前）。
  Future<void> _loadAnnouncements() async {
    if (mounted) {
      setState(() {
        _announceLoading = true;
        _announceError = false;
      });
    }
    try {
      final list = await CloudNotesService.instance.getAnnouncements();
      if (!mounted) return;
      setState(() {
        _announcements = list;
        _announceLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _announceLoading = false;
        _announceError = true;
      });
    }
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
        final (list, nextPage, hasMore) = await _fetchFilteredFeed(1, sort);
        if (!mounted) return;
        c.notes = list;
        c.page = nextPage;
        c.hasMore = hasMore;
        c.initial = false;
        c.error = false;
      } else {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('followed_user_ids') ?? '';
        final ids = raw.isEmpty
            ? <String>{}
            : raw.split(',').where((s) => s.isNotEmpty).toSet();
        final blocked = CloudNotesService.instance.blockedUserIds;
        final all = <PlazaNote>[];
        final seen = <String>{};
        var page = 1;
        var hasMore = true;
        while (hasMore && page <= 50) {
          final (list, more) = await CloudNotesService.instance
              .getPlazaNotes(page: page, pageSize: _feedPageSize);
          for (final n in list) {
            if (ids.contains(n.ownerUserId) &&
                !blocked.contains(n.ownerUserId) &&
                seen.add(n.id)) {
              all.add(n);
            }
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
      final blocked = CloudNotesService.instance.blockedUserIds;
      var page = 1;
      var hasMore = true;
      const maxPages = 10;
      const minCollect = _feedPageSize;
      while (hasMore && page <= maxPages && all.length < minCollect) {
        final (list, more) = await CloudNotesService.instance
            .getPlazaNotes(page: page, pageSize: _feedPageSize);
        for (final n in list) {
          if (_followedIds.contains(n.ownerUserId) &&
              !blocked.contains(n.ownerUserId) &&
              seen.add(n.id)) {
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
      final (list, nextPage, hasMore) =
          await _fetchFilteredFeed(_feedPage, sort);
      if (!mounted) return;
      setState(() {
        _feedNotes.addAll(list);
        _feedVersion++;
        _feedPage = nextPage;
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
                                title: Text(_plazaTabMeta[items[i]] ?? items[i],
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

  void _openPlazaNote(PlazaNote note) {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)));
  }

  Future<void> _openSutraByPath(String title, String? filePath) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ReadingPage(title: title, filePath: filePath)));
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
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Row(
                  children: [
                    Text('$latestDate 阅读',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _text)),
                    const Spacer(),
                    Text('${sutras.length} 部',
                        style: TextStyle(fontSize: 13, color: _textHint)),
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(title,
                                      style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500,
                                          color: _text)),
                                  const SizedBox(height: 4),
                                  Text(
                                      '已读 ${(progress * 100).toStringAsFixed(1)}%',
                                      style: TextStyle(
                                          fontSize: 12, color: _textHint)),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right,
                                color: _textHint, size: 20),
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
      await _recordLockedSutra(prefs, _currentTitle!, _currentFilePath ?? '');
      _loadData();
    }
  }

  /// 记录锁定过的经文（精读依据）：去重置顶、上限 50 本。
  Future<void> _recordLockedSutra(
      SharedPreferences prefs, String title, String filePath) async {
    final list = prefs.getStringList('locked_sutras') ?? [];
    list.removeWhere((e) => e.startsWith('$title|||'));
    list.insert(0, '$title|||$filePath');
    if (list.length > 50) list.removeRange(50, list.length);
    await prefs.setStringList('locked_sutras', list);
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
          padding: const EdgeInsets.only(left: 2),
          child: Row(
            children: [
              GestureDetector(
                onTap: widget.onOpenMyPage,
                child: UserAvatar(
                  userId: AuthService.instance.currentUser.value?.id,
                  radius: 16,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                '修学',
                style: TextStyle(
                  color: Color(0xFF5d4037),
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                '·',
                style: TextStyle(
                  color: Color(0xFF9E9588),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '燃一盏灯，看见自己，照亮别人',
                  style: TextStyle(
                    color: Color(0xFF9E9588),
                    fontSize: 10.5,
                  ),
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton(
              icon: const Icon(Icons.calendar_month_outlined,
                  color: Color(0xFF71867A), size: 20),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const CalendarPage())),
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
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 10,
                offset: const Offset(0, 2)),
          ],
        ),
        child: const Padding(
          padding: EdgeInsets.all(40),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child:
                  CircularProgressIndicator(strokeWidth: 2.5, color: _primary),
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
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2)),
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
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                        color: _primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.menu_book_rounded,
                        size: 16, color: const Color(0xFF71867A)),
                  ),
                  const SizedBox(width: 10),
                  const Text('精读经文',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _text)),
                  const Spacer(),
                  if (_currentTitle != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                          color: _overlay,
                          borderRadius: BorderRadius.circular(11)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.today,
                              size: 12, color: _primaryLight),
                          const SizedBox(width: 4),
                          Text('已学$_studyDays天',
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: _primaryLight,
                                  fontWeight: FontWeight.w500)),
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
              onLongPress: _currentTitle != null ? _showSutraActionsSheet : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_displayTitle(_currentTitle!),
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: _textSec,
                              height: 1.4)),
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
                  Text('${(_progress * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(
                          fontSize: 12,
                          color: _textHint,
                          fontWeight: FontWeight.w500)),
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
                        Icon(
                            _lockedTitle != null ? Icons.lock : Icons.lock_open,
                            size: 13),
                        const SizedBox(width: 4),
                        Text(_lockedTitle != null ? '已锁定' : '锁定经书',
                            style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 18),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 34,
                        height: 22,
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: Switch(
                            value: _allowReadingShare,
                            onChanged: _toggleReadingShare,
                            activeTrackColor: const Color(0xFF71867A),
                            activeThumbColor: Colors.white,
                            inactiveTrackColor: const Color(0xFFE8E2DA),
                            inactiveThumbColor: const Color(0xFFBDB6AC),
                            trackOutlineColor: WidgetStateProperty.resolveWith(
                                (_) => Colors.transparent),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(_allowReadingShare ? '已允许' : '允许',
                          style: const TextStyle(
                              fontSize: 12, color: _textSec)),
                    ],
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _showRecentSutras,
                    style: TextButton.styleFrom(
                        foregroundColor: _textSec,
                        padding: const EdgeInsets.symmetric(horizontal: 16)),
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
                    builder: (context, child) =>
                        Transform.scale(scale: _pulseAnim.value, child: child),
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: _overlay,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(Icons.auto_stories_rounded,
                          size: 30,
                          color: _primaryLight.withValues(alpha: 0.8)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text('今日尚未开启经文之旅',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: _text)),
                  const SizedBox(height: 4),
                  Text('选择一部经文，开始今日修学',
                      style: TextStyle(fontSize: 13, color: _textSec)),
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const SutraListPage())),
                        icon: const Icon(Icons.explore, size: 17),
                        label: const Text('浏览经藏',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w500)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
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
    final types = _checkInTypes();
    final shownKeys = {for (final t in types) t['key']};
    final doneCount =
        _todayCheckIns.where((r) => shownKeys.contains(r['type'])).length;

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2)),
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
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                      color: _primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8)),
                  child: Icon(Icons.check_circle_outline,
                      size: 17, color: const Color(0xFF71867A)),
                ),
                const SizedBox(width: 10),
                Text('功课打卡',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _text)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                      color: _overlay, borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.today, size: 12, color: _primaryLight),
                      const SizedBox(width: 4),
                      Text('打卡$_checkinStreak天',
                          style: TextStyle(
                              fontSize: 11,
                              color: _primaryLight,
                              fontWeight: FontWeight.w500)),
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
                final checked =
                    _todayCheckIns.any((r) => r['type'] == t['key']);
                return _CheckInButton(
                  icon: t['icon'] as IconData?,
                  emoji: t['emoji'] as String?,
                  label: t['label'] as String,
                  checked: checked,
                  onTap: () =>
                      _toggleCheckIn(t['key'] as String, t['label'] as String),
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
                Text('$doneCount/${types.length}',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _primary)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const CheckInSettingsPage())),
                  style: TextButton.styleFrom(
                      foregroundColor: _textSec,
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
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
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const CheckInGoalsPage())),
                  style: TextButton.styleFrom(
                      foregroundColor: _textSec,
                      padding: const EdgeInsets.symmetric(horizontal: 16)),
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
      return _buildAnnounceSlivers(viewportH);
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

    final feedGroups = _feedGroups;
    final feedLen = feedGroups.length;
    final showFooter = _feedLoading || !_feedHasMore || _feedError;
    // 保守估计每条笔记高度，保证补足后的内容高度一定够吸顶。
    final feedEstimate = feedLen * 110.0 + (showFooter ? 70.0 : 0.0);
    final spacerH = math.max(0.0, minFeed - feedEstimate);
    return [
      SliverPadding(
        // 横向内边距移入每条帖子内部，保证分割线通栏贴边（与「我的 → 帖子」一致）。
        padding: const EdgeInsets.only(top: 4, bottom: 32),
        sliver: SliverList(
          key: ValueKey('feed_$_feedVersion'),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final Widget body;
              if (index < feedLen) {
                final g = feedGroups[index];
                body = _buildFeedGroupCard(g.$1, g.$2);
              } else {
                body = _buildFeedFooter();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 帖子顶部通栏分割线（首条不画，避免顶部多一条线）。
                  if (index > 0)
                    const Divider(
                        height: 1, thickness: 0.6, color: Color(0xFFD8CCBC)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: body,
                  ),
                ],
              );
            },
            childCount: feedLen + (showFooter ? 1 : 0),
            addRepaintBoundaries: true,
          ),
        ),
      ),
      if (spacerH > 0) SliverToBoxAdapter(child: SizedBox(height: spacerH)),
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
          isFollowing ? (notLoggedIn ? '登录后关注同修' : '还没有关注同修') : '菩提空间还没有笔记',
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w600, color: _text),
        ),
        const SizedBox(height: 6),
        Text(
          isFollowing ? '关注同修后，这里会显示他们的新笔记' : '分享你的修学心得，让大家一起受益',
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

  /// 公告 tab：展示管理员发布的公告（最新在前），支持下拉刷新。
  List<Widget> _buildAnnounceSlivers(double viewportH) {
    if (_announceLoading && _announcements.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.2, color: _gold),
            ),
          ),
        ),
      ];
    }
    if (_announceError && _announcements.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(minHeight: math.max(0.0, viewportH - _headerHeight())),
              child: _buildFeedError(),
            ),
          ),
        ),
      ];
    }
    if (_announcements.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(minHeight: math.max(0.0, viewportH - _headerHeight())),
              child: _buildAnnounceEmpty(),
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: 4, bottom: 32),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildAnnouncementCard(_announcements[index]),
            childCount: _announcements.length,
          ),
        ),
      ),
    ];
  }

  Widget _buildAnnouncementCard(AnnouncementItem item) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => NoteDetailPage(noteId: item.id)),
          ),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('公告',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF9A6B3F))),
                    ),
                    const Spacer(),
                    Text(_formatTime(item.createdAt),
                        style:
                            const TextStyle(fontSize: 11, color: _textHint)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  item.title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text),
                ),
                const SizedBox(height: 6),
                Text(
                  item.content,
                  style: const TextStyle(fontSize: 14, color: _textSec, height: 1.6),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.forum_outlined,
                        size: 14, color: _textHint),
                    const SizedBox(width: 4),
                    Text('点击查看评论与互动',
                        style: const TextStyle(fontSize: 12, color: _textHint)),
                    const Spacer(),
                    const Icon(Icons.chevron_right, size: 16, color: _textHint),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAnnounceEmpty() {
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

  String _formatTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
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

  /// 分组：非回复为根，回复（含回复的回复）递归挂到对应父帖下面，根只显示一次。
  /// 与「我的 → 回复」页一致，原贴一次展示、下面用头像连线串起所有评论。
  List<(PlazaNote, List<PlazaNote>)> get _feedGroups {
    final byId = {for (final n in _feedNotes) n.id: n};
    final children = <String, List<PlazaNote>>{};
    final roots = <PlazaNote>[];
    for (final n in _feedNotes) {
      // 只有真正的回复帖（repostKind=='reply'）才归入原贴的回复链；
      // 转发/引用转发（repostOf 非空但非 reply）作为独立帖子展示。
      if (n.repostKind == 'reply' && byId.containsKey(n.repostOf)) {
        children.putIfAbsent(n.repostOf, () => []).add(n);
      } else {
        roots.add(n);
      }
    }
    List<PlazaNote> collect(PlazaNote node) {
      final subs = children[node.id] ?? const <PlazaNote>[];
      return [
        for (final c in subs) c,
        for (final c in subs) ...collect(c),
      ];
    }

    return [
      for (final r in roots) (r, collect(r)),
    ];
  }

  /// 分组卡片：根帖用「帖子」页同款样式（头像+昵称+指标+三点菜单），
  /// 其下所有回复用「回复」页同款头像连线串起。
  Widget _buildFeedGroupCard(PlazaNote root, List<PlazaNote> replies) {
    final me = AuthService.instance.currentUser.value;
    final isMine = me != null && root.ownerUserId == me.id;
    final rootWidget = PostFeedRow(
      note: root,
      onReplyPosted: _refreshCurrentSmooth,
      onTap: () => _openPlazaNote(root),
      onEdit: isMine ? () => _editFeedNote(root) : null,
      onDelete: isMine ? () => _deleteFeedNote(root) : null,
      onMore: (n) => _showFeedReplyMenu(n),
      // 广场以浏览为主：他人帖子不显示关注按钮，关注/屏蔽收进三点菜单。
      showFollowButton: false,
    );
    if (replies.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: rootWidget,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 21,
              top: 62,
              bottom: 0,
              child: Container(width: 1, color: const Color(0xFFC9C9C9)),
            ),
            rootWidget,
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 6),
          child: ReplyChain(
            replies: replies,
            parentAccounts: {
              root.id: root.authorAccount,
              for (final r in replies) r.id: r.authorAccount,
            },
            onComment: (n) => replyToNote(context, n, _refreshCurrentSmooth),
            onLike: (n) => likeTargetNote(context, n, _refreshCurrentSmooth),
            onRepost: (n) => forwardNote(context, n, _refreshCurrentSmooth),
            onMore: (n) => _showFeedReplyMenu(n),
          ),
        ),
      ],
    );
  }

  /// 回复节点更多菜单：自己的回复显示编辑/删除，他人回复显示关注/屏蔽。
  Future<void> _showFeedReplyMenu(PlazaNote note) async {
    final me = AuthService.instance.currentUser.value;
    if (me == null || note.ownerUserId != me.id) {
      if (me != null && note.ownerUserId.isNotEmpty) {
        await showMoreMenu(context, note.ownerUserId, note.authorName);
      }
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text(note.authorName,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            const Divider(height: 1, color: _border),
            postMenuItem(ctx, 'edit', Icons.edit_outlined, '编辑'),
            postMenuItem(ctx, 'delete', Icons.delete_outline, '删除'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'edit') {
      _editFeedNote(note);
    } else if (choice == 'delete') {
      _deleteFeedNote(note);
    }
  }

  /// 编辑自己发布的帖子内容。
  Future<void> _editFeedNote(PlazaNote note) async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SheetTextInput(
        title: '编辑帖子',
        hint: '写下新的内容…',
        initialText: note.content,
        maxLength: 2000,
        minLines: 3,
        maxLines: 6,
        confirmText: '保存',
      ),
    );
    if (saved == null || saved.trim().isEmpty || !mounted) return;
    try {
      await CloudNotesService.instance
          .updateSharedNote(cloudId: note.id, content: saved.trim());
      if (!mounted) return;
      _showTopToast('已更新');
      _refreshCurrentSmooth();
    } catch (e) {
      if (mounted) _showTopToast(e.toString());
    }
  }

  /// 删除自己发布的帖子。
  Future<void> _deleteFeedNote(PlazaNote note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除帖子',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: const Text('删除后帖子将从菩提空间移除，且无法恢复。确定删除吗？',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: _textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除',
                style: TextStyle(
                    color: Color(0xFFC0392B), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await CloudNotesService.instance.deleteCloudNote(note.id);
      if (!mounted) return;
      setState(() => _feedNotes.removeWhere((n) => n.id == note.id));
      _showTopToast('已删除');
    } catch (e) {
      if (mounted) _showTopToast(e.toString());
    }
  }

  Future<void> _toggleCheckIn(String typeKey, String label) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> allRecords = jsonDecode(raw);
    final today = _today();

    final idx = allRecords
        .indexWhere((r) => r['date'] == today && r['type'] == typeKey);
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
    await _loadData();
    await _maybeAutoShareCheckin(prefs);
  }

  /// 打卡类型列表：固定五项 + 自定义。若已配置具体功课，则只展示已配置的类型。
  List<Map<String, dynamic>> _checkInTypes() {
    return _checkInTypesList.isEmpty ? _allCheckInTypes() : _checkInTypesList;
  }

  List<Map<String, dynamic>> _allCheckInTypes() {
    return [
      {'key': 'meditation', 'label': '静坐', 'icon': Icons.self_improvement_outlined},
      {'key': 'reading', 'label': '诵经', 'icon': Icons.chrome_reader_mode_outlined},
      {'key': 'mantra', 'label': '持咒', 'icon': Icons.notifications_none_outlined},
      {'key': 'buddha', 'label': '称名', 'icon': Icons.spa_outlined},
      {'key': 'copying', 'label': '抄经', 'icon': Icons.edit_outlined},
      ..._customTypes.map((t) =>
          {'key': t['key'], 'label': t['label'], 'icon': Icons.playlist_add}),
    ];
  }

  /// 依据功课设置筛选实际配置的类型；全部未配置时回退为固定五项，避免空卡。
  List<Map<String, dynamic>> _buildConfiguredCheckInTypes(SharedPreferences prefs) {
    final all = _allCheckInTypes();
    final configured = all.where((t) {
      switch (t['key']) {
        case 'meditation':
          return _hasNonEmptyItems(prefs, 'setting_meditation_minutes');
        case 'reading':
          return _hasNonEmptyNamed(prefs, 'setting_reading_titles');
        case 'mantra':
          return _hasNonEmptyNamed(prefs, 'setting_mantra_items');
        case 'buddha':
          return _hasNonEmptyNamed(prefs, 'setting_buddha_items');
        case 'copying':
          return _hasNonEmptyItems(prefs, 'setting_copying_titles');
        default:
          return true; // 自定义类型始终展示。
      }
    }).toList();
    return configured.isEmpty ? all : configured;
  }

  bool _hasNonEmptyItems(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return false;
    try {
      final d = jsonDecode(raw);
      if (d is List) return d.any((e) => e.toString().trim().isNotEmpty);
    } catch (_) {}
    return false;
  }

  bool _hasNonEmptyNamed(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return false;
    try {
      final d = jsonDecode(raw);
      if (d is List) {
        return d.any((e) {
          final n = e is Map ? (e['name'] ?? '') : e;
          return n.toString().trim().isNotEmpty;
        });
      }
    } catch (_) {}
    return false;
  }

  /// 完成当日全部功课且开启「分享每日功课」时，弹窗展示当天功课并确认后发布到菩提空间（每日仅一次）。
  Future<void> _maybeAutoShareCheckin(SharedPreferences prefs) async {
    try {
      if (!(prefs.getBool('privacy_share_daily_checkin') ?? false)) return;
      if (!AuthService.instance.isLoggedIn) return;
      final today = _today();
      if (prefs.getString('shared_checkin_date') == today) return;
      final types = _checkInTypes();
      if (types.isEmpty) return;
      final todayKeys = {for (final r in _todayCheckIns) r['type'] ?? ''};
      if (!types.every((t) => todayKeys.contains(t['key']))) return;

      final lines = _buildCheckInShareLines(prefs, types);
      if (lines.isEmpty) return;
      final content = '今天完成功课：\n${lines.join('\n')}';
      if (!mounted) return;

      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('恭喜你完成今天的功课！',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: _text)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('今天完成的功课如下，是否分享到菩提空间？',
                  style: TextStyle(fontSize: 13, color: _textSec)),
              const SizedBox(height: 12),
              Container(
                width: double.maxFinite,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _overlay,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final l in lines)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(l,
                            style: const TextStyle(
                                fontSize: 14, color: _text, height: 1.4)),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: _textSec)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _gold),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('分享到菩提空间'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      await CloudNotesService.instance
          .publishNote(title: '今日功课完成', content: content);
      await prefs.setString('shared_checkin_date', today);
      if (mounted) _showTopToast('已分享到菩提空间');
    } catch (_) {
      // 分享失败静默处理，不打断打卡。
    }
  }

  /// 依据当天已完成的功课，生成分享内容行（样式与功课设置一致）。
  List<String> _buildCheckInShareLines(
      SharedPreferences prefs, List<Map<String, dynamic>> types) {
    final done = <String>{for (final r in _todayCheckIns) r['type'] ?? ''};
    final lines = <String>[];
    for (final t in types) {
      final key = t['key'] as String;
      if (!done.contains(key)) continue;
      switch (key) {
        case 'meditation':
          for (final e in _decodeStrList(prefs.getString('setting_meditation_minutes'))) {
            if (e.trim().isNotEmpty) lines.add('静坐 ${e.trim()}分钟');
          }
        case 'reading':
          for (final e in _decodeNamedList(prefs.getString('setting_reading_titles'))) {
            if (e.$1.isNotEmpty) {
              lines.add('诵经 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}遍' : ''}');
            }
          }
        case 'mantra':
          for (final e in _decodeNamedList(prefs.getString('setting_mantra_items'))) {
            if (e.$1.isNotEmpty) {
              lines.add('持咒 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}遍' : ''}');
            }
          }
        case 'buddha':
          for (final e in _decodeNamedList(prefs.getString('setting_buddha_items'))) {
            if (e.$1.isNotEmpty) {
              lines.add('称名 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}声' : ''}');
            }
          }
        case 'copying':
          for (final e in _decodeStrList(prefs.getString('setting_copying_titles'))) {
            if (e.trim().isNotEmpty) lines.add('抄经 ${e.trim()}');
          }
        default:
          for (final c in _customTypes) {
            if (c['key'] == key) {
              final label = (c['label'] ?? '').toString();
              final unit = (c['unit'] ?? '遍').toString();
              final count = (c['count'] ?? '').toString();
              if (label.isNotEmpty) {
                lines.add('$label ${count.trim().isEmpty ? '0' : count.trim()}$unit');
              }
            }
          }
      }
    }
    return lines;
  }

  List<String> _decodeStrList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final d = jsonDecode(raw);
      if (d is List) return d.map((e) => e.toString()).toList();
    } catch (_) {}
    return [];
  }

  List<(String, String)> _decodeNamedList(String? raw) {
    final out = <(String, String)>[];
    if (raw == null || raw.isEmpty) return out;
    try {
      final d = jsonDecode(raw);
      if (d is List) {
        for (final e in d) {
          if (e is Map) {
            out.add(((e['name'] ?? '').toString(), (e['count'] ?? '').toString()));
          } else {
            out.add((e.toString(), ''));
          }
        }
      }
    } catch (_) {}
    return out;
  }

  double _checkInAmount(String typeKey, SharedPreferences prefs) {
    switch (typeKey) {
      case 'meditation':
        final list =
            jsonDecode(prefs.getString('setting_meditation_minutes') ?? '[]')
                as List<dynamic>;
        return list.fold<double>(
            0, (s, e) => s + (double.tryParse(e.toString()) ?? 0));
      case 'reading':
        return _sumNamedCount(prefs.getString('setting_reading_titles'));
      case 'mantra':
        return _sumNamedCount(prefs.getString('setting_mantra_items'));
      case 'buddha':
        return _sumNamedCount(prefs.getString('setting_buddha_items'));
      case 'copying':
        final list =
            jsonDecode(prefs.getString('setting_copying_titles') ?? '[]')
                as List<dynamic>;
        return list.length.toDouble();
      default:
        final customs =
            (jsonDecode(prefs.getString('custom_checkin_types') ?? '[]')
                    as List<dynamic>)
                .cast<Map<String, dynamic>>();
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
    return list.fold<double>(
        0, (s, e) => s + (double.tryParse((e['count'] ?? '').toString()) ?? 0));
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
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
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
                icon:
                    const Icon(Icons.menu, color: Color(0xFF8B6B5A), size: 20),
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

  const _CheckInButton(
      {this.icon,
      this.emoji,
      required this.label,
      required this.checked,
      required this.onTap});

  @override
  State<_CheckInButton> createState() => _CheckInButtonState();
}

class _CheckInButtonState extends State<_CheckInButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 150));
    _scale = Tween<double>(begin: 1.0, end: 0.92)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
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
        builder: (context, child) =>
            Transform.scale(scale: _scale.value, child: child),
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
                Icon(widget.icon,
                    size: 22,
                    color: checked ? _primary : const Color(0xFF71867A))
              else
                Text(widget.emoji ?? '', style: TextStyle(fontSize: 20)),
              const SizedBox(height: 4),
              Text(widget.label,
                  style: TextStyle(
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
