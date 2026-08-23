import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'loading_widgets.dart';
import 'sync_service.dart';
import 'user_avatar.dart';
import 'user_avatar_cache.dart';
import 'login_page.dart';
import 'reading_page.dart';
import 'checkin_settings_page.dart';
import 'checkin_goals_page.dart';
import 'sutra_list_page.dart';
import 'sutra_favorites.dart';
import 'calendar_page.dart';
import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'reply_chain.dart';
import 'my_page.dart';
import 'user_space_page.dart';
import 'text_input_sheet.dart';
import 'note_edit_page.dart';
import 'note_sutra_links.dart';
import 'hot_discussion_list_page.dart';
import 'post_rich_content.dart';
import 'reading_time_service.dart';
import 'sutra_downloader.dart';

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
  'hot': '发现',
  'discuss': '讨论',
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

/// 笔记是否来自被屏蔽用户：作者本人被屏蔽，或转发源作者被屏蔽，一律不展示。
/// 这样「直接发的帖子 / 自己转发的帖子 / 别人转发其内容的帖子」都被隐藏；
/// 例外：自己发出的评论保留（原帖作者被屏蔽时，上方以「已屏蔽用户」占位展示）。
bool _isBlockedContent(PlazaNote n) {
  final me = AuthService.instance.currentUser.value;
  final blocked = CloudNotesService.instance.blockedUserIds;
  if (blocked.isEmpty) return false;
  if (n.ownerUserId == me?.id) return false;
  if (blocked.contains(n.ownerUserId)) return true;
  return n.repostSourceUserId.isNotEmpty &&
      blocked.contains(n.repostSourceUserId);
}

/// 转发/回复的来源作者是否被屏蔽（用于把被屏蔽原帖替换为占位，保留自己的评论）。
bool _repostSourceBlocked(PlazaNote n) =>
    n.repostSourceUserId.isNotEmpty &&
    CloudNotesService.instance.blockedUserIds.contains(n.repostSourceUserId);

class StudyHubPage extends StatefulWidget {
  /// 左上角头像点击回调：打开「我的」页面。
  final VoidCallback? onOpenMyPage;

  /// 精读卡长按菜单修改收藏/已读状态后回调（用于通知经藏页刷新列表与收藏）。
  final VoidCallback? onSutraStateChanged;

  const StudyHubPage({super.key, this.onOpenMyPage, this.onSutraStateChanged});

  @override
  State<StudyHubPage> createState() => StudyHubPageState();
}

class StudyHubPageState extends State<StudyHubPage>
    with TickerProviderStateMixin, RouteAware, WidgetsBindingObserver {
  static SharedPreferences? _warmPrefs;

  static Future<void> warmPrefs() async {
    _warmPrefs = await SharedPreferences.getInstance();
  }

  void reload() {
    _loadData();
    // 有新帖时只把新帖插入到顶部，避免「整页刷新」的体感。
    if (StudyHubPageState.newPostBadge.value > 0) {
      _refreshNewPostsOnly();
    } else {
      _refreshCurrentSmooth();
    }
  }

  /// 双击底部「修学」菜单图标：无新帖时回到页面最顶部。
  void scrollToTop() {
    if (_feedScroll.hasClients && _feedScroll.offset > 0) {
      _feedScroll.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  String? _currentTitle;
  String? _currentFilePath;
  double _progress = 0.0;
  List<Map<String, String>> _todayCheckIns = [];
  int _checkinTotalDays = 0;
  String? _lockedTitle;
  String? _lockedFilePath;
  bool _currentFavorite = false;
  /// 当前精读经文是否已标记完成阅读（青色标题）。
  bool _currentRead = false;
  /// 多卷经书的基础经名集合，用于显示「卷X」卷标。
  Set<String> _multiVolumeBases = const {};
  /// 是否允许他人在主页查看我的「精读」（在读经书）。
  bool _allowReadingShare = false;
  List<Map<String, dynamic>> _customTypes = [];
  /// 实际配置的功课类型列表（功课打卡卡片与自动分享共用）。
  List<Map<String, dynamic>> _checkInTypesList = [];
  bool _loaded = false;
  int _tabIndex = 0;
  List<String> _plazaTabs = ['hot', 'discuss', 'follow', 'announce'];
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
  /// 关注 tab 关注态刷新失败（登录失效）时的状态：
  /// 此时不能显示「还没有关注同修」的空态误导用户，需提示重新登录。
  bool _feedAuthDead = false;
  /// 点击「显示X条新帖子」后当前栏目切到「最新优先」视图：新帖从列表第一条开始展示。
  /// 推荐栏默认按热度排序，切到最新视图后新帖不会被旧热帖压住；切走栏目或下拉刷新后恢复默认。
  bool _feedNewestFirst = false;
  List<AnnouncementItem> _announcements = [];
  bool _announceLoading = false;
  bool _announceError = false;
  static const int _feedPageSize = 20;
  /// 讨论栏目顶部的热门话题 / 热门经文（云端聚合，客户端经文取 8 个、话题取 4 个做当日轮换）。
  List<HotDiscussionItem> _hotTopics = [];
  List<HotDiscussionItem> _hotSutras = [];
  /// 全量热门榜（top50）：供「更多」页展示完整的经文/话题热度排行。
  List<HotDiscussionItem> _hotTopicAll = [];
  List<HotDiscussionItem> _hotSutraAll = [];
  /// 「发现/关注」新帖提醒：后台静默统计新帖数量，只更新「X条新帖子」提醒条，
  /// 不自动刷新列表，点击提醒或下拉才手动刷出，避免浏览时被打断。
  Timer? _newPostTimer;
  bool _newPostChecking = false;
  bool _appActive = true;
  int _newPostCount = 0;
  /// 滚动到顶部提醒条被隐藏时，是否显示悬浮的「显示X帖子」按钮。
  bool _showNewPostPill = false;
  /// _loadFeed 重入闸门：防止点击「显示X帖子」时双击重入，
  /// 或后台轮询新帖与点击触发的加载同时跑导致请求/状态错乱。
  bool _feedRefreshing = false;
  /// 全局「有新帖未查看」标记：驱动底部「修学」菜单图标上的 70867A 小圆点。
  static final ValueNotifier<int> newPostBadge = ValueNotifier<int>(0);
  static const Duration _newPostCheckInterval = Duration(seconds: 30);

  void _setNewPostCount(int v) {
    _newPostCount = v;
    newPostBadge.value = v;
  }
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  static const _commentIcon = AssetImage('assets/images/ic_comment.png');
  static const _viewIcon = AssetImage('assets/images/ic_view.png');

  /// 「讨论」栏目的判定：正文含 #话题 或 $经名 的帖子即视为讨论。
  static final RegExp _discussTopicRe = RegExp(r'#([^\s#，。！？,;:!?（）()]+)');
  static final RegExp _discussSutraRe =
      RegExp(r'\$([^\s#$，。！？,;:!?（）()@]+)');

  static bool _isDiscussionNote(PlazaNote n) {
    final text = '${n.title}\n${n.content}';
    return _discussTopicRe.hasMatch(text) || _discussSutraRe.hasMatch(text);
  }

  /// 正文是否包含被管理员删除的话题（#话题 精确到词边界，避免「#打坐」误伤「#打坐中」）。
  static bool _isBannedNote(PlazaNote n) {
    final bans = CloudNotesService.instance.bannedTopicNames;
    if (bans.isEmpty) return false;
    final text = '${n.title}\n${n.content}';
    for (final b in bans) {
      if (b.isEmpty) continue;
      if (RegExp('#${RegExp.escape(b)}(?=[\\s#，。！？,;:!?（）()]|\$)')
          .hasMatch(text)) {
        return true;
      }
    }
    return false;
  }

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
    ReadingTimeService.instance.ensureLoaded();
    final loadDataFuture = _loadData();
    _loadFeed();
    // 等栏目顺序就绪后，并行预取其余栏目：发现加载的同时，
    // 讨论/关注/公告也在后台刷新，之后切换栏目数据已就绪，不再转圈。
    loadDataFuture.then((_) => _prefetchOtherTabs());
    // 后台静默统计新帖数量，只更新「X条新帖子」提醒，不自动刷新列表。
    WidgetsBinding.instance.addObserver(this);
    _newPostTimer =
        Timer.periodic(_newPostCheckInterval, (_) => _checkNewPosts());
    // 登录会话是异步恢复的：首次加载广场时可能还没登录，
    // 等登录态就绪后重新拉取屏蔽列表并刷新，让被屏蔽用户的帖子立即消失。
    AuthService.instance.currentUser.addListener(_onAuthChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureTopSection();
      precacheImage(_commentIcon, context);
      precacheImage(_viewIcon, context);
    });
  }

  /// 登录态变化时刷新广场：屏蔽列表/关注列表就绪后，被屏蔽内容立即隐藏。
  /// 登录/登出会改变关注口径，同时失效「关注」栏目缓存并重新预取，
  /// 避免切换过去时还展示匿名期的空数据或转圈。
  void _onAuthChanged() {
    final u = AuthService.instance.currentUser.value;
    final followCache = _cacheFor('follow');
    followCache.initial = true;
    followCache.notes.clear();
    if (u != null) {
      _loadFeed();
      _refreshFeedInBackground('follow');
    } else {
      _refreshCurrentSmooth();
    }
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
    _appActive = true;
    _loadData();
    _refreshCurrentSmooth();
  }

  /// 其他页面覆盖在主页上时暂停轮询，返回时再立即刷新。
  @override
  void didPushNext() {
    _appActive = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 只暂停/恢复新帖数量统计，不自动刷新列表。
    _appActive = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    AuthService.instance.currentUser.removeListener(_onAuthChanged);
    WidgetsBinding.instance.removeObserver(this);
    _newPostTimer?.cancel();
    _newPostTimer = null;
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
    final read = await _isCurrentRead(title);
    final mvBases = await _loadMultiVolumeBases();

    // 精读卡进度：以阅读页实时写入的最新进度为准（规范路径键存在时，
    // 即使为 0 也代表最近一次关闭时的进度，不被更早的更高进度覆盖）；
    // 规范键缺失时兼容旧版本用本机绝对路径命名的 progress_ 键（换机/重装后
    // 云端同步回来的可能是这类键，按规范路径查会显示 0），progress_ 键全部
    // 缺失时再从每日阅读历史（随账号同步）兜底恢复，避免进度清零。
    var lastReadProgress = 0.0;
    if (path != null) {
      lastReadProgress =
          await SutraDownloader.latestProgressForPath(prefs, path, title: title);
    } else {
      lastReadProgress = SutraDownloader.progressFromDailyHistory(prefs, title);
    }

    var plazaTabs = <String>['hot', 'discuss', 'follow', 'announce'];
    final tabOrderRaw = prefs.getString('plaza_tab_order');
    if (tabOrderRaw != null && tabOrderRaw.isNotEmpty) {
      try {
        final saved = (jsonDecode(tabOrderRaw) as List<dynamic>).cast<String>();
        final valid = <String>[];
        for (final k in saved) {
          if (k == 'discover') {
            // 旧“发现”栏目并入「发现」，历史保存里残留的 latest 一律不再展示。
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
    // v2 一次性迁移：把「关注」移到「发现」之后紧挨着（老用户已有排序时生效，
    // 迁移完成后持久化新顺序，之后尊重用户手动排序）。
    if (!(prefs.getBool('plaza_tab_order_v2') ?? false)) {
      final order = List<String>.from(plazaTabs);
      final hotIdx = order.indexOf('hot');
      final followIdx = order.indexOf('follow');
      if (hotIdx >= 0 && followIdx >= 0) {
        order.removeAt(followIdx);
        order.insert(order.indexOf('hot') + 1, 'follow');
        plazaTabs = order;
      }
      await prefs.setBool('plaza_tab_order_v2', true);
      await prefs.setString('plaza_tab_order', jsonEncode(plazaTabs));
    }
    // 新栏目「讨论」：老用户保存的排序里没有它，统一插到「推荐」之后（在 v2 迁移后执行，
    // 避免被关注栏目的挪位覆盖）。
    if (!plazaTabs.contains('discuss')) {
      final hotIdx = plazaTabs.indexOf('hot');
      if (hotIdx >= 0) {
        plazaTabs.insert(hotIdx + 1, 'discuss');
      } else {
        plazaTabs.add('discuss');
      }
    }

    setState(() {
      _loaded = true;
      _currentTitle = title;
      _currentFilePath = path;
      _multiVolumeBases = mvBases;
      _lockedTitle = lockT;
      _lockedFilePath = lockP;
      _progress = lastReadProgress;
      _currentFavorite = fav;
      _currentRead = read;
      _allowReadingShare = prefs.getBool('privacy_show_reading') ?? false;
      _todayCheckIns = _loadTodayCheckIns(prefs);
      _checkinTotalDays = _calcTotalDays(prefs);
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

  Future<bool> _isCurrentRead(String? title) async {
    if (title == null) return false;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (!await file.exists()) return false;
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      for (final e in decoded) {
        if (e is Map && e['title'] == title) {
          return e['isRead'] == true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 原子写 sutras_list.json（临时文件 + 改名替换），避免并发读取读到损坏内容。
  Future<void> _writeSutraListAtomic(List<Map<String, dynamic>> list) async {
    final docs = await getApplicationDocumentsDirectory();
    final file =
        File('${docs.path}${Platform.pathSeparator}sutras_list.json');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(list), flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
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
      await _writeSutraListAtomic(list);
      await SutraFavorites.syncStatePref(title);
      if (!mounted) return;
      setState(() => _currentFavorite = !wasFav);
      widget.onSutraStateChanged?.call();
    } catch (_) {
      if (!mounted) return;
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
      _showToast(v ? '已开启，其他同修可查看你的精读' : '已关闭，其他同修不可查看你的精读');
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
                onTap: () async {
                  String? msg;
                  final wasFav = _currentFavorite;
                  // 先完整持久化再关闭弹窗，避免关闭触发的 reload 读到旧文件把状态覆盖掉。
                  await _toggleFavoriteCurrent();
                  msg = wasFav ? '已取消收藏' : '已收藏';
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  _showToast(msg);
                },
              ),
              _sheetMenuItem(
                context,
                icon: _currentRead ? Icons.mark_chat_unread : Icons.mark_chat_read,
                title: _currentRead ? '取消完成阅读' : '标记完成阅读',
                onTap: () async {
                  String? msg;
                  final wasRead = _currentRead;
                  await _toggleReadCurrent();
                  msg = wasRead ? '已取消完成阅读标记' : '已标记完成阅读';
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  _showToast(msg);
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

  /// 标记/取消标记当前精读经文为已读完成（与经藏长按菜单一致，双向切换）。
  Future<void> _toggleReadCurrent() async {
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
      final wasRead = list[idx]['isRead'] == true;
      list[idx]['isRead'] = !wasRead;
      list[idx]['readTime'] =
          wasRead ? null : DateTime.now().toIso8601String();
      await _writeSutraListAtomic(list);
      await SutraFavorites.syncStatePref(title);
      if (!mounted) return;
      setState(() => _currentRead = !wasRead);
      widget.onSutraStateChanged?.call();
    } catch (_) {
      if (!mounted) return;
      _showTopToast('标记失败，请重试', isError: true);
    }
  }

  /// 与经藏长按菜单一致的底部浮动提示（收藏/标记等操作反馈）。
  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ),
    );
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

  int _calcTotalDays(SharedPreferences prefs) {
    final raw = prefs.getString('checkin_records') ?? '[]';
    final records = jsonDecode(raw) as List<dynamic>;
    return records.map((r) => r['date'].toString()).toSet().length;
  }

  String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  String _displayTitle(String title) =>
      sutraDisplayTitle(title, multiVolumeBases: _multiVolumeBases);

  Future<Set<String>> _loadMultiVolumeBases() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (!await file.exists()) return const {};
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      return collectMultiVolumeBases(
          decoded.map((e) => Sutra.fromJson(e as Map<String, dynamic>)));
    } catch (_) {
      // 读取失败时保持当前卷标集合，避免瞬时读坏导致卷标闪没。
      return _multiVolumeBases;
    }
  }

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
    _updateNewPostPill();
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
  /// [filter] 非空时只保留满足条件的笔记（讨论栏目：含 #话题 或 $经名），
  /// [maxPages] 限制最多翻页数，避免内容稀疏时请求过多。
  /// 返回（可见笔记, 下一页页码, 是否还有更多）。
  Future<(List<PlazaNote>, int, bool)> _fetchFilteredFeed(
    int page,
    String sort, {
    bool Function(PlazaNote)? filter,
    int maxPages = 4,
  }) async {
    final blocked = CloudNotesService.instance.blockedUserIds;
    if (blocked.isEmpty && filter == null) {
      final (list, more) = await CloudNotesService.instance
          .getPlazaNotes(page: page, pageSize: _feedPageSize, sort: sort);
      return (list, page + 1, more);
    }
    final collected = <PlazaNote>[];
    var cur = page;
    var hasMore = true;
    for (var i = 0; i < maxPages; i++) {
      final (list, more) = await CloudNotesService.instance
          .getPlazaNotes(page: cur, pageSize: _feedPageSize, sort: sort);
      for (final n in list) {
        if (filter != null && !filter(n)) continue;
        if (_isBannedNote(n)) continue;
        if (blocked.isEmpty || !_isBlockedContent(n)) collected.add(n);
      }
      hasMore = more;
      cur++;
      if (collected.length >= _feedPageSize || !hasMore) break;
    }
    return (collected, cur, hasMore);
  }

  /// 加载当前 tab 的笔记流。发现：热度 + 时间衰减排序。
  /// [newestFirst] 为 true 时（点击「显示X条新帖子」），推荐栏也切到最新优先，
  /// 让新帖直接排在列表顶部，而不是被旧热帖压住。
  /// 关注：仅展示已关注同修的笔记。
  /// 公告：展示公告列表。
  Future<void> _loadFeed({bool newestFirst = false}) async {
    // 重入保护：点击「显示X帖子」体验卡顿时常被连点两次，
    // 第二次进入会和当前 setState/网络请求交错，反而拖慢响应。
    if (_feedRefreshing) return;
    _feedRefreshing = true;
    final tab = _plazaTabs[_tabIndex];
    // 立刻进入 loading 视觉：原实现把 setState 放在 4 个预热 await 之后，
    // 用户点击后到看见转圈之间有 1~3 秒「无反应」空窗，是「要连点才有反应」体感根因。
    if (mounted) {
      setState(() {
        _feedInitial = true;
        _feedError = false;
        _feedAuthDead = false;
        _feedNotes.clear();
        _feedVersion++;
        _feedPage = 1;
        _feedHasMore = true;
        _feedLoading = false;
        _feedNewestFirst = newestFirst;
        _setNewPostCount(0);
      });
    }
    _updateNewPostPill();
    try {
      // 4 个预热操作改为并行执行：原串行 await 累计 1~3 秒延迟，
      // 这是「点击后列表毫无反应」的根本原因之一。并行后只需等最慢的那个。
      await Future.wait([
        CloudNotesService.instance.refreshLikedNoteIds(),
        CloudNotesService.instance.refreshFollowStates(),
        CloudNotesService.instance.refreshBannedTopics(),
        NoteSutraCatalog.load(),
      ]);
      _timeCache.clear();
      _plainTextCache.clear();
      _sutraQuoteCache.clear();
      if (!mounted) return;
      try {
        if (tab == 'latest' || tab == 'hot') {
          final sort = (tab == 'hot' && !newestFirst) ? 'hot' : 'latest';
          var (list, nextPage, hasMore) = await _fetchFilteredFeed(1, sort);
          // 与「关注」栏目同口径兜底：作者 @账号/认证/阅藏进度缺失时按 uid 补齐，
          // 避免发现页同一用户与关注页显示不一致（头像旁无 @账号、无百分比）。
          list = await CloudNotesService.instance.enrichFeedAuthors(list);
          if (mounted) {
            setState(() {
              _feedNotes.addAll(list);
              _feedVersion++;
              _feedPage = nextPage;
              _feedHasMore = hasMore;
              _feedInitial = false;
            });
          }
        } else if (tab == 'discuss') {
          // 讨论：最新的「带 #话题 或 $经名」帖子 + 顶部热门榜（并行加载）。
          unawaited(_loadHotDiscussions());
          var (list, nextPage, hasMore) = await _fetchFilteredFeed(1, 'latest',
              filter: _isDiscussionNote, maxPages: 8);
          list = await CloudNotesService.instance.enrichFeedAuthors(list);
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
          if (mounted) {
            if (_followedIds.isEmpty &&
                CloudNotesService.instance.followStateFailed) {
              // 关注态刷新失败（登录失效）：别把「还没关注同修」空态给用户，
              // 明确提示登录已失效、引导重新登录。
              setState(() => _feedAuthDead = true);
            } else if (_followedIds.isNotEmpty) {
              await _loadFollowingNotes();
            }
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
      // 帖子列表加载后，批量预取作者头像（不阻塞 UI）。
      // UserAvatarCache 内部有 100ms 合并窗口，这里逐个 request 即可，
      // 会合并成一次 getUserProfiles 批量请求。
      if (_feedNotes.isNotEmpty) {
        final uids = <String>{};
        for (final n in _feedNotes) {
          if (n.ownerUserId.isNotEmpty) uids.add(n.ownerUserId);
          if (n.repostSourceUserId.isNotEmpty) uids.add(n.repostSourceUserId);
        }
        for (final uid in uids) {
          UserAvatarCache.instance.request(uid);
        }
      }
    } finally {
      _feedRefreshing = false;
    }
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

  /// 拉取讨论栏目的热门话题 / 热门经文（云端聚合 top50，经文取 8 个、话题取 4 个做当日轮换）。
  /// 轮换规则：前 N 名按当天日期确定性跳过少数几个 + 其余名次补足，
  /// 当天内稳定、跨天变化，避免永远同一批。经文名需命中经书目录才展示。
  Future<void> _loadHotDiscussions() async {
    try {
      await NoteSutraCatalog.load(); // 确保经书目录就绪，过滤有效经名
      final (topics, sutras) =
          await CloudNotesService.instance.getHotDiscussions();
      final titleMap = NoteSutraCatalog.cachedTitleMap ?? const {};
      final now = DateTime.now();
      final daySeed = now.year * 10000 + now.month * 100 + now.day;
      final validSutras =
          sutras.where((s) => titleMap.containsKey(s.name)).toList();
      // 已被管理员删除的话题直接剔除，确保热门卡片/「更多」榜都不再展示。
      final bans = CloudNotesService.instance.bannedTopicNames;
      final validTopics = bans.isEmpty
          ? topics
          : topics.where((t) => !bans.contains(t.name)).toList();
      if (!mounted) return;
      setState(() {
        // 经文两行 4+4（top14 内轮换）、话题一行 4 个（top10 内轮换），全量榜留给「更多」页。
        _hotTopics = _pickHotItems(validTopics.take(10).toList(), 4, daySeed);
        _hotSutras = _pickHotItems(validSutras.take(14).toList(), 8, daySeed);
        _hotTopicAll = validTopics;
        _hotSutraAll = validSutras;
      });
    } catch (_) {
      // 热门榜失败静默降级：只展示最新讨论列表。
    }
  }

  /// 当日确定性轮换取 count 个：前 count 名按 seed 跳过 count~/3 个，
  /// 再由第 count 名以后补足剩余名额；总量不足时全部展示，避免「有 1 个却显示没有」。
  static List<T> _pickHotItems<T>(List<T> list, int count, int daySeed) {
    if (list.isEmpty) return const [];
    if (list.length <= count) return List.of(list);
    final first = list.sublist(0, count);
    final rest = list.sublist(count);
    final picked = <T>[];
    // 跳过位按 seed 确定、互不重合。
    final skip = count ~/ 3;
    final offset = daySeed % count;
    final stride = 1 + daySeed % (count - 1);
    final skips = <int>{
      for (var i = 0; i < skip; i++) (offset + i * stride) % count
    };
    for (var i = 0; i < first.length; i++) {
      if (skips.contains(i)) continue;
      picked.add(first[i]);
    }
    // 其余名次补足剩余名额（不足时有多少取多少）。
    for (var i = 0; i < skip && i < rest.length; i++) {
      picked.add(rest[(offset + i) % rest.length]);
    }
    return picked;
  }

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
      ..addAll(c.notes.where((n) => !_isBlockedContent(n) && !_isBannedNote(n)));
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

  /// 「显示X帖子」/ 双击「修学」菜单图标的轻量刷新：
  /// 仅拉取当前栏目最新一页，把列表中没有的新帖一次性插入到顶部，
  /// 不清空已加载的帖、不切换排序、不闪整页加载态。这是用户期望的
  /// 「最新信息立即显示在顶部」效果。
  /// 与 `_loadFeed(newestFirst: true)` 的区别：原实现清空整列表重新加载，
  /// 已滚动到的位置和已加载的多页内容都会丢失，体感是「整个页面刷新一遍」。
  Future<void> _refreshNewPostsOnly() async {
    if (_feedRefreshing) return;
    _feedRefreshing = true;
    try {
      final tab = _plazaTabs[_tabIndex];
      if (tab == 'announce') return;
      final List<PlazaNote> list;
      if (tab == 'latest' || tab == 'hot') {
        // 始终按最新排序拿第一页，确保新帖出现在结果最前。
        final (first, _, _) = await _fetchFilteredFeed(1, 'latest');
        list = await CloudNotesService.instance.enrichFeedAuthors(first);
      } else if (tab == 'discuss') {
        final (first, _, _) = await _fetchFilteredFeed(1, 'latest',
            filter: _isDiscussionNote, maxPages: 2);
        list = await CloudNotesService.instance.enrichFeedAuthors(first);
      } else if (tab == 'follow') {
        list = await _fetchFollowFeedPreview();
      } else {
        return;
      }
      if (!mounted) return;
      final known = _feedNotes.map((n) => n.id).toSet();
      final fresh = list.where((n) => !known.contains(n.id)).toList();
      if (fresh.isEmpty) {
        // 实际上没有新内容：直接清零（修复「总是显示 X 帖子」的老问题）。
        final needClear = _newPostCount != 0 || _showNewPostPill;
        if (needClear) {
          setState(() {
            _setNewPostCount(0);
            _showNewPostPill = false;
          });
        }
        return;
      }
      setState(() {
        _feedNotes.insertAll(0, fresh);
        _feedVersion++;
        _setNewPostCount(0);
        _showNewPostPill = false;
      });
      // 顺手写回缓存，避免下次后台轮询又把刚插入的帖当新帖统计。
      _saveFeedToCache(tab);
      _scrollInstantTop();
    } catch (_) {
      // 静默失败。
    } finally {
      _feedRefreshing = false;
    }
  }

  /// 滚动到帖子列表区域顶部（无动画、不卡帧），用于点击「显示X帖子」后让新帖立刻可见。
  /// 当 Tab 栏已贴住 AppBar 时，保持粘贴状态（只滚到 _topSectionHeight），
  /// 不回显精读经文/功课等顶部区块，避免「页面刷新一遍」的体感。
  void _scrollInstantTop() {
    if (!_feedScroll.hasClients) return;
    final target = _topSectionHeight > 0 ? _topSectionHeight : 0.0;
    if ((_topSectionHeight > 0 && _feedScroll.offset > target) ||
        (_topSectionHeight <= 0 && _feedScroll.offset > 0)) {
      _feedScroll.jumpTo(target);
    }
  }

  /// 后台静默统计当前栏目新帖数量：只更新「X条新帖子」提醒，不刷新列表。
  /// 发现：按热度规则倒序；讨论：最新的带 #话题 或 $经名 帖子；关注：仅统计已关注同修的新帖。
  Future<void> _checkNewPosts() async {
    if (!mounted || !_appActive || _newPostChecking) return;
    final tab = _plazaTabs[_tabIndex];
    if (tab == 'announce') return;
    if (_feedNotes.isEmpty || _feedInitial || _feedLoading) return;
    _newPostChecking = true;
    try {
      final List<PlazaNote> list;
      if (tab == 'latest' || tab == 'hot') {
        // 最新优先视图下按最新统计新帖，与列表顶部的排序一致。
        final sort = (tab == 'hot' && !_feedNewestFirst) ? 'hot' : 'latest';
        final (first, _, _) = await _fetchFilteredFeed(1, sort);
        list = first;
      } else if (tab == 'discuss') {
        // 讨论：只需看最近 1~2 页（最新排序）里新增的讨论帖。
        final (first, _, _) = await _fetchFilteredFeed(1, 'latest',
            filter: _isDiscussionNote, maxPages: 2);
        list = first;
      } else if (tab == 'follow') {
        list = await _fetchFollowFeedPreview();
      } else {
        return;
      }
      if (!mounted) return;
      final known = _feedNotes.map((n) => n.id).toSet();
      final count = list.where((n) => !known.contains(n.id)).length;
      if (count > 0 && count != _newPostCount) {
        setState(() => _setNewPostCount(count));
        _updateNewPostPill();
      } else if (count == 0 && _newPostCount != 0) {
        // 后台确认已无新帖：必须显式清零，否则旧计数会一直挂在 UI 上，
        // 形成「明明没新信息却总显示 X 条」（原实现只有 `count > 0` 分支）。
        setState(() {
          _setNewPostCount(0);
          _showNewPostPill = false;
        });
      }
    } catch (_) {
      // 静默失败，下一轮再试。
    } finally {
      _newPostChecking = false;
    }
  }

  /// 关注栏目前瞻拉取：服务端直接查关注用户帖子，用于统计新帖。
  /// 只拉第一页（最新一屏），与 _loadFollowingNotes 口径一致但不改动界面数据。
  Future<List<PlazaNote>> _fetchFollowFeedPreview() async {
    if (CloudNotesService.instance.followingUserIds.isEmpty) {
      return const [];
    }
    try {
      final (list, _) = await CloudNotesService.instance
          .getFollowingNotes(page: 1, pageSize: _feedPageSize);
      return list;
    } catch (_) {
      return const [];
    }
  }

  /// 计算悬浮「显示X帖子」按钮是否可见：有新帖且已滚动到顶部提醒条被隐藏。
  void _updateNewPostPill() {
    final show = _newPostCount > 0 &&
        _topSectionHeight > 0 &&
        _feedScroll.hasClients &&
        _feedScroll.offset >= _topSectionHeight + 60;
    if (show != _showNewPostPill) {
      setState(() => _showNewPostPill = show);
    }
  }

  /// 点击悬浮按钮：滚动到帖子列表区域顶部，并立即把新帖插入到列表顶部（不清空重载）。
  /// 当 Tab 栏已贴住 AppBar 时，只滚到 _topSectionHeight，保持粘贴状态，
  /// 不回显精读经文/功课等顶部区块，避免「页面刷新一遍」的体感。
  Future<void> _refreshFromPill() async {
    final target = _topSectionHeight > 0 ? _topSectionHeight : 0.0;
    final animFuture = (_feedScroll.hasClients && _feedScroll.offset > target)
        ? _feedScroll.animateTo(target,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut)
        : Future<void>.value();
    await _refreshNewPostsOnly();
    await animFuture;
  }

  /// 打开主页时并行预取其余栏目：发现加载的同时，讨论/关注/公告在后台刷新，
  /// 之后切换到任一栏目，数据都已就绪，不再出现加载转圈。
  void _prefetchOtherTabs() {
    if (!mounted) return;
    final current = _plazaTabs[_tabIndex];
    for (final tab in _plazaTabs) {
      if (tab == current || !_cacheFor(tab).initial) continue;
      _refreshFeedInBackground(tab);
    }
  }

  /// 后台预取指定栏目的最新数据，直接写入缓存；若用户正好在该栏目则同步到界面。
  Future<void> _refreshFeedInBackground(String tab) async {
    final c = _cacheFor(tab);
    if (tab == 'announce') {
      // 公告：后台预取列表；当前正好停在公告栏目时同步到界面。
      await _loadAnnouncements();
      if (!mounted) return;
      c.initial = false;
      c.error = _announceError;
      return;
    }
    try {
      if (tab == 'latest' || tab == 'hot') {
        // 用户正停留在最新优先视图时，后台刷新也保持最新排序，避免新帖被旧热帖顶掉。
        final keepNewest = tab == 'hot' &&
            _feedNewestFirst &&
            _plazaTabs[_tabIndex] == tab;
        final sort = (tab == 'hot' && !keepNewest) ? 'hot' : 'latest';
        var (list, nextPage, hasMore) = await _fetchFilteredFeed(1, sort);
        list = await CloudNotesService.instance.enrichFeedAuthors(list);
        if (!mounted) return;
        c.notes = list;
        c.page = nextPage;
        c.hasMore = hasMore;
        c.initial = false;
        c.error = false;
      } else if (tab == 'discuss') {
        unawaited(_loadHotDiscussions());
        var (list, nextPage, hasMore) = await _fetchFilteredFeed(1, 'latest',
            filter: _isDiscussionNote, maxPages: 8);
        list = await CloudNotesService.instance.enrichFeedAuthors(list);
        if (!mounted) return;
        c.notes = list;
        c.page = nextPage;
        c.hasMore = hasMore;
        c.initial = false;
        c.error = false;
      } else {
        // 关注：服务端按关注列表 + 屏蔽列表直接筛选。
        // 老实现是遍历整个广场分页（最多 50 页）在本地筛关注用户的帖子，
        // 每次 app 打开后台预取都会串行打 50 次云调用，非常慢且易超时。
        // 现在只拉前 3 页填满缓存，切到「关注」后再按需翻页。
        await CloudNotesService.instance.refreshFollowStates();
        if (!AuthService.instance.isLoggedIn) {
          if (!mounted) return;
          c.notes = const [];
          c.page = 1;
          c.hasMore = false;
          c.initial = false;
          c.error = false;
        } else {
          final all = <PlazaNote>[];
          final seen = <String>{};
          var page = 1;
          var hasMore = true;
          const maxBackgroundPages = 3;
          while (hasMore && page <= maxBackgroundPages) {
            final (list, more) = await CloudNotesService.instance
                .getFollowingNotes(page: page, pageSize: _feedPageSize);
            for (final n in list) {
              if (!_isBlockedContent(n) && !_isBannedNote(n) && seen.add(n.id)) {
                all.add(n);
              }
            }
            hasMore = more;
            page++;
          }
          if (!mounted) return;
          c.notes = all;
          c.page = page;
          c.hasMore = hasMore;
          c.initial = false;
          c.error = false;
        }
      }
      if (!mounted) return;
      if (_plazaTabs[_tabIndex] == tab) {
        _restoreFeedFromCache(tab);
        setState(() => _setNewPostCount(0));
        _updateNewPostPill();
      }
    } catch (_) {
      if (!mounted) return;
      c.error = true;
      c.initial = false;
      if (_plazaTabs[_tabIndex] == tab) {
        _restoreFeedFromCache(tab);
        setState(() => _setNewPostCount(0));
        _updateNewPostPill();
      }
    }
  }

  Future<void> _loadFollowedIds() async {
    if (!mounted) return;
    setState(() => _followedIds
      ..clear()
      ..addAll(CloudNotesService.instance.followingUserIds));
  }

  /// 关注 tab：服务端按关注列表 + 屏蔽列表直接筛选。
  /// 只拉第一页快速出首屏，后续翻页由 _loadMoreFeed 按需加载。
  /// 老实现会一次性串行翻完所有分页（最多 100 页，每页一次云调用），
  /// 弱网下要等几十秒甚至中途超时判「加载失败」——这是「关注特别慢」的根因。
  Future<void> _loadFollowingNotes() async {
    if (!AuthService.instance.isLoggedIn) {
      if (mounted) {
        setState(() {
          _feedLoading = false;
          _feedInitial = false;
        });
      }
      return;
    }
    setState(() => _feedLoading = true);
    try {
      final (list, more) = await CloudNotesService.instance
          .getFollowingNotes(page: 1, pageSize: _feedPageSize);
      if (!mounted) return;
      setState(() {
        _feedNotes
          ..clear()
          ..addAll(list);
        _feedPage = 2;
        _feedHasMore = more;
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
    if (tab == 'announce' ||
        _feedLoading ||
        !_feedHasMore ||
        _feedInitial) {
      return;
    }
    setState(() => _feedLoading = true);
    try {
      if (tab == 'follow') {
        final (list, more) = await CloudNotesService.instance
            .getFollowingNotes(page: _feedPage, pageSize: _feedPageSize);
        if (!mounted) return;
        setState(() {
          _feedNotes.addAll(list);
          _feedVersion++;
          _feedPage++;
          _feedHasMore = more;
          _feedLoading = false;
        });
        for (final n in list) {
          if (n.ownerUserId.isNotEmpty) UserAvatarCache.instance.request(n.ownerUserId);
          if (n.repostSourceUserId.isNotEmpty) UserAvatarCache.instance.request(n.repostSourceUserId);
        }
        return;
      }
      // 最新优先视图下继续按最新拉取，与顶部新帖保持一致排序。
      final sort = (tab == 'hot' && !_feedNewestFirst) ? 'hot' : 'latest';
      var (list, nextPage, hasMore) = await _fetchFilteredFeed(
        _feedPage,
        sort,
        filter: tab == 'discuss' ? _isDiscussionNote : null,
        maxPages: tab == 'discuss' ? 8 : 4,
      );
      list = await CloudNotesService.instance.enrichFeedAuthors(list);
      if (!mounted) return;
      setState(() {
        _feedNotes.addAll(list);
        _feedVersion++;
        _feedPage = nextPage;
        _feedHasMore = hasMore;
        _feedLoading = false;
      });
      // 预取新加载页的作者头像。
      for (final n in list) {
        if (n.ownerUserId.isNotEmpty) UserAvatarCache.instance.request(n.ownerUserId);
        if (n.repostSourceUserId.isNotEmpty) UserAvatarCache.instance.request(n.repostSourceUserId);
      }
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
      _feedNewestFirst = false;
      _setNewPostCount(0);
      _restoreFeedFromCache(_plazaTabs[i]);
    });
    _updateNewPostPill();
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
    // 点击回复帖（b 类）进入其原贴（a 类）的详情页并定位到该回复，
    // 与发现流里回复链节点的跳转行为保持一致（父帖不在列表里时回复帖
    // 会独立成根帖展示，点击同样回到原贴详情页）。
    if (note.repostKind == 'reply' && note.repostOf.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => NoteDetailPage(
            noteId: note.repostOf,
            scrollToReplyId: note.id,
          ),
        ),
      );
      return;
    }
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

    // 最近三天（今天 + 前两日）阅读的经文：按日期从新到旧、同日内最新在前
    // 聚合，同一部经书（可能跨天/多路径重复出现）只保留最近一次记录。
    final now = DateTime.now();
    final dayKeys = <String>[];
    for (var i = 0; i < 3; i++) {
      final d = now.subtract(Duration(days: i));
      dayKeys.add(
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
    }
    final seenTitles = <String>{};
    final sutras = <dynamic>[];
    for (final d in dayKeys) {
      final list = history[d];
      if (list is! List) continue;
      for (final s in list) {
        final title = s is Map ? (s['title']?.toString() ?? '') : '';
        if (title.isEmpty || !seenTitles.add(title)) continue;
        sutras.add(s);
      }
    }

    if (!mounted || sutras.isEmpty) return;

    // 用实时进度（progress_ 键，以规范路径键的最新值为准，缺失时才兼容
    // 绝对路径形式）替换历史快照进度，保证与精读卡/继续阅读卡一致，
    // 不随打开次数显示陈旧数值。
    final liveProgress = <String, double>{};
    for (final s in sutras) {
      final title = s['title']?.toString() ?? '';
      final fp = s['filePath']?.toString();
      if (title.isEmpty || fp == null || fp.isEmpty) continue;
      final variants =
          await SutraDownloader.pathKeyVariants(fp, title: title);
      final canonical = prefs.getDouble('progress_${variants.first}');
      var p = canonical ?? 0.0;
      if (canonical == null) {
        for (final v in variants) {
          final cur = prefs.getDouble('progress_$v') ?? 0.0;
          if (cur > p) p = cur;
        }
      }
      liveProgress[title] = p;
    }

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
                    Text('最近3天阅读',
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
                    final snap = (s['progress'] as num?)?.toDouble() ?? 0.0;
                    final progress =
                        liveProgress[title] ?? snap;
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
        title: GestureDetector(
          onDoubleTap: scrollToTop,
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Row(
              children: [
                GestureDetector(
                  // 与帖子卡头像一致：打开「我的」页（个人主页）。
                  // 不依赖 currentUser，避免冷启动会话未恢复时点击无反应。
                  onTap: widget.onOpenMyPage,
                  child: UserAvatar(
                    userId: AuthService.instance.currentUser.value?.id,
                    radius: 16,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  '功课',
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
                      fontSize: 12,
                    ),
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
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
          return Stack(
            children: [
              RefreshIndicator(
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
              ),
              // 滚动后顶部提醒条被隐藏时的悬浮按钮：回到顶部并刷新出新帖。
              Positioned(
                top: _headerHeight() + 8,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  ignoring: !_showNewPostPill,
                  child: _showNewPostPill ? _buildNewPostPill() : null,
                ),
              ),
            ],
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
        color: _overlay,
        borderRadius: BorderRadius.circular(16),
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
        color: _overlay,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
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
                const Expanded(
                  child: Text('精读经文',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _text)),
                ),
                if (_currentTitle != null) ...[
                  GestureDetector(
                    onTap: _toggleLock,
                    child: Icon(
                      _lockedTitle != null ? Icons.lock : Icons.lock_open,
                      size: 17,
                      color: const Color(0xFF71867A),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _toggleReadingShare(!_allowReadingShare),
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFCDB292),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Text(
                        _allowReadingShare ? '已允许' : '未允许',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
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
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: _currentRead
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: _currentRead
                                  ? const Color(0xFF71867A)
                                  : _textSec,
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
              // 左内边距 10 + 徽章内边距 10 = 时钟图标正好落在 x=20，
              // 与上方进度条/卡片左侧图标起始位置对齐。
              padding: const EdgeInsets.fromLTRB(10, 0, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 读经时长徽章：今日读经靠左（时钟图标与进度条起点对齐），
                  // 累积读经向右移动但保留固定间距，不贴卡片右缘，
                  // 时间文字始终完整显示；空间不足时自动换行。
                  Wrap(
                    alignment: WrapAlignment.start,
                    spacing: 30,
                    runSpacing: 8,
                    children: [
                      ValueListenableBuilder<int>(
                        valueListenable:
                            ReadingTimeService.instance.todaySeconds,
                        builder: (context, sec, _) => _buildTimeBadge(
                            Icons.timer_outlined,
                            '今日读经${_formatReadTime(sec)}'),
                      ),
                      ValueListenableBuilder<int>(
                        valueListenable:
                            ReadingTimeService.instance.totalSeconds,
                        builder: (context, sec, _) => _buildTimeBadge(
                            Icons.history, '累积读经${_formatReadTime(sec)}'),
                      ),
                    ],
                  ),
                  // 「最近阅读」入口：换行显示在右下角。
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _showRecentSutras,
                      style: TextButton.styleFrom(
                          foregroundColor: _textSec,
                          padding: const EdgeInsets.only(
                              left: 4, right: 4, top: 0, bottom: 0),
                          minimumSize: const Size(0, 26),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      child: const Text('最近阅读 ›',
                          style: TextStyle(fontSize: 13)),
                    ),
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
          const SizedBox(height: 7),
        ],
      ),
    );
  }

  /// 读经时长徽章：暖色底 + 图标 + 文字。
  Widget _buildTimeBadge(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
          color: _overlay, borderRadius: BorderRadius.circular(11)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: _primaryLight),
          const SizedBox(width: 4),
          Text(text,
              style: const TextStyle(
                  fontSize: 11,
                  color: _primaryLight,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  /// 读经时长格式化：不足 1 分钟显示秒，否则统一「x时x分」短格式
  /// （如 0时5分、2时15分），让今日/累积两枚徽章与「最近阅读」同行展示不换行。
  String _formatReadTime(int seconds) {
    if (seconds < 60) return '$seconds秒';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    return '$hours时$minutes分';
  }

  Widget _buildCheckInCard() {
    final types = _checkInTypes();
    final shownKeys = {for (final t in types) t['key']};
    final doneCount =
        _todayCheckIns.where((r) => shownKeys.contains(r['type'])).length;

    return Container(
      decoration: BoxDecoration(
        color: _overlay,
        borderRadius: BorderRadius.circular(16),
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
                      Text('打卡$_checkinTotalDays天',
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
          // 与精读经文卡「累积读经」一行到「最近阅读」的间距一致（紧贴）。
          const SizedBox(height: 0),
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
    // 讨论栏目的顶部热门卡片：置于笔记流最上方。
    final hotCard = tab == 'discuss' ? _buildHotCardSliver() : null;
    final feedGroups = _feedGroups;
    final hasNotes = feedGroups.isNotEmpty;
    final minFeed = math.max(0.0, viewportH - _headerHeight());

    if (!hasNotes) {
      if (_feedInitial || _feedLoading) {
        return [
          if (hotCard != null) hotCard,
          SliverFillRemaining(
            hasScrollBody: false,
            child: const AppLoadingIndicator(
              message: '正在加载内容...',
            ),
          ),
        ];
      }
if (_feedAuthDead) {
        return [
          if (hotCard != null) hotCard,
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: minFeed),
                child: _buildFeedAuthDead(),
              ),
            ),
          ),
        ];
      }
      if (_feedError) {
        return [
          if (hotCard != null) hotCard,
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
        if (hotCard != null) hotCard,
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

    final feedLen = feedGroups.length;
    final showFooter = _feedLoading || !_feedHasMore || _feedError;
    // 保守估计每条笔记高度，保证补足后的内容高度一定够吸顶。
    final feedEstimate = feedLen * 110.0 + (showFooter ? 70.0 : 0.0);
    final spacerH = math.max(0.0, minFeed - feedEstimate);
    return [
      if (hotCard != null) hotCard,
      if (_newPostCount > 0)
        SliverToBoxAdapter(child: _buildNewPostBanner()),
      SliverPadding(
        // 横向内边距放在列表层：分割线随内容缩进、不贴手机边缘（与话题页一致）。
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
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
                  // 帖子顶部分割线（首条不画，避免顶部多一条线）。
                  if (index > 0)
                    const Divider(
                        height: 1, thickness: 0.6, color: Color(0xFFE6DAC8)),
                  body,
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

  /// 「发现/关注/讨论」栏目顶部的新帖提醒：仅一行文字，点击立即把新帖插入列表顶部，
  /// 不切换全量重载，避免「整页刷新」的体感。
  Widget _buildNewPostBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: InkWell(
        onTap: _refreshNewPostsOnly,
        child: Text(
          '显示$_newPostCount帖子',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF70867A)),
        ),
      ),
    );
  }

  /// 悬浮的新帖按钮：白字 + 70867A 纯色椭圆胶囊，滚动后顶部落出屏幕时展示。
  Widget _buildNewPostPill() {
    return Center(
      child: Material(
        color: const Color(0xFF70867A),
        borderRadius: BorderRadius.circular(999),
        elevation: 4,
        child: InkWell(
          onTap: _refreshFromPill,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.arrow_upward, size: 15, color: Colors.white),
                const SizedBox(width: 5),
                Text('显示$_newPostCount帖子',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeedFooter() {
    if (_feedLoading) {
      return const AppLoadMoreIndicator();
    }
    if (_feedError) {
      return AppLoadMoreIndicator(
        hasError: true,
        onRetry: _loadFeed,
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
    final isDiscuss = _plazaTabs[_tabIndex] == 'discuss';
    final notLoggedIn = !AuthService.instance.isLoggedIn;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(isDiscuss ? Icons.forum_outlined : Icons.auto_awesome_outlined,
            size: 52, color: _textHint),
        const SizedBox(height: 14),
        Text(
          isDiscuss
              ? '还没有讨论'
              : (isFollowing
                  ? (notLoggedIn ? '登录后关注同修' : '还没有关注同修')
                  : '菩提空间还没有笔记'),
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w600, color: _text),
        ),
        const SizedBox(height: 6),
        Text(
          isDiscuss
              ? '发布带 #话题 或 \$经名 的帖子，就会出现在这里'
              : (isFollowing ? '关注同修后，这里会显示他们的新笔记' : '分享你的修学心得，让大家一起受益'),
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
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(minHeight: math.max(0.0, viewportH - _headerHeight())),
              child: const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: _gold),
              ),
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
        // 横向内边距放在列表层，公告卡片之间不放分割线。
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) =>
                _buildAnnouncementCard(_announcements[index]),
            childCount: _announcements.length,
          ),
        ),
      ),
      if (viewportH - _headerHeight() > 0)
        SliverToBoxAdapter(
          child: SizedBox(
            height: math.max(0, viewportH - _headerHeight() - 40),
          ),
        ),
    ];
  }

  /// 讨论栏目顶部的热门卡片，三行布局：
  /// 第一行 4 个经文；第二行 4 个经文 + 「更多经文」入口；
  /// 第三行 4 个话题 + 「更多话题」入口。整块无标题文案、无边框线条。
  /// 数据未就绪（加载中/失败）时返回 null 不渲染，避免占位闪烁。
  Widget? _buildHotCardSliver() {
    if (_hotTopics.isEmpty && _hotSutras.isEmpty) return null;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
        child: Container(
          decoration: BoxDecoration(
            color: _overlay,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 第一行：前 4 个热门经文（绿色系），第一个经文用火把替换 $ 前缀。
              _buildHotChips(
                _hotSutras.take(4).toList(),
                isSutra: true,
                showFirstFire: true,
              ),
              const SizedBox(height: 10),
              // 第二行：后 4 个热门经文 + 「更多经文」入口。
              _buildHotChips(
                _hotSutras.skip(4).toList(),
                isSutra: true,
                moreLabel: '更多经文',
                onMore: _hotSutraAll.isEmpty
                    ? null
                    : () => _openHotListPage(
                        isSutra: true, title: '热门经文讨论'),
              ),
              const SizedBox(height: 10),
              // 第三行：4 个热门话题（金色系）+ 「更多话题」入口，第一个话题用火把替换 # 前缀。
              _buildHotChips(
                _hotTopics,
                isSutra: false,
                moreLabel: '更多话题',
                showFirstFire: true,
                onMore: _hotTopicAll.isEmpty
                    ? null
                    : () => _openHotListPage(
                        isSutra: false, title: '热门话题讨论'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 打开「更多」全量热门榜页面：按讨论帖子数从多到少排列。
  /// 返回后刷新热门榜与当前栏目（管理员可能删除了话题）。
  void _openHotListPage({required bool isSutra, required String title}) {
    final items = isSutra ? _hotSutraAll : _hotTopicAll;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HotDiscussionListPage(
          isSutra: isSutra,
          title: title,
          items: items,
        ),
      ),
    ).then((_) {
      if (!mounted) return;
      _loadHotDiscussions();
      _refreshCurrentSmooth();
    });
  }

  /// 热门胶囊行：一行横滑展示（最多 4 个胶囊，可带「更多」入口），
  /// 字数较多时左右滑动查看，不换行截断、不撑高卡片。
  /// 本行没有胶囊时：有「更多」入口就只渲染入口，否则整行收起。
  /// [showFirstFire] 为 true 时第一个胶囊用火把图标替换 $/# 前缀。
  Widget _buildHotChips(List<HotDiscussionItem> items,
      {required bool isSutra,
      String moreLabel = '更多',
      VoidCallback? onMore,
      bool showFirstFire = false}) {
    if (items.isEmpty) {
      if (onMore == null) return const SizedBox.shrink();
      return Row(children: [_buildHotMoreChip(onMore, label: moreLabel)]);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _buildHotChip(
                items[i],
                isSutra: isSutra,
                showFire: i == 0 && showFirstFire,
              ),
            ),
          if (onMore != null) _buildHotMoreChip(onMore, label: moreLabel),
        ],
      ),
    );
  }

  Widget _buildHotChip(HotDiscussionItem it,
      {required bool isSutra, bool showFire = false}) {
    final color = isSutra ? const Color(0xFF71867A) : const Color(0xFF9A6B3F);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openHotDiscussion(it, isSutra: isSutra),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showFire)
              const Icon(Icons.local_fire_department,
                  size: 15, color: Color(0xFFD93B28))
            else
              Text(isSutra ? '\$' : '#',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: color)),
            Text(it.name,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }

  /// 「更多 ›」胶囊：置灰、无描边，与热门胶囊同一圆角规格。
  Widget _buildHotMoreChip(VoidCallback onMore, {String label = '更多'}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onMore,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 12, color: _textSec)),
            const Icon(Icons.chevron_right, size: 14, color: _textSec),
          ],
        ),
      ),
    );
  }

  /// 点击热门话题 / 经文胶囊：进入对应的话题页 / 经书讨论页。
  void _openHotDiscussion(HotDiscussionItem it, {required bool isSutra}) {
    if (isSutra) {
      final entry = NoteSutraCatalog.cachedTitleMap?[it.name];
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SutraDiscussionPage(
            title: it.name,
            filePath: entry?.filePath ?? '',
          ),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => TopicPage(topic: it.name)),
      );
    }
  }

  Widget _buildAnnouncementCard(AnnouncementItem item) {
    return Padding(
      // 横向内边距已由列表层提供，这里只保留纵向间距。
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => NoteDetailPage(
                    noteId: item.id,
                    isAnnouncement: true)),
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

  Widget _buildFeedAuthDead() {
    return Padding(
      padding: const EdgeInsets.only(top: 60, bottom: 40),
      child: Column(
        children: [
          Icon(Icons.lock_clock_outlined, size: 52, color: _textHint),
          const SizedBox(height: 14),
          const Text('登录已失效',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
          const SizedBox(height: 6),
          const Text('请退出后重新登录，关注内容才能恢复显示',
              style: TextStyle(fontSize: 13, color: _textSec)),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LoginPage()),
            ),
            icon: const Icon(Icons.login, size: 17),
            label: const Text('重新登录',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            style: FilledButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeedError() {
    return AppLoadError(
      onRetry: _loadFeed,
    );
  }

  /// 分组：非回复为根，回复（含回复的回复）递归挂到对应父帖下面，根只显示一次。
  /// 与「我的 → 回复」页一致，原贴一次展示、下面用头像连线串起所有评论。
  /// 广场列表只保留自己发出的回复以及自己关注的用户发出的回复：头像连线挂到原帖下；
  /// 其余他人回复一律不展示，统一在笔记详情页按帖查看，
  /// 避免热门帖上百条回复的头像连线刷屏。
  List<(PlazaNote, List<PlazaNote>)> get _feedGroups {
    final me = AuthService.instance.currentUser.value;
    final followed = CloudNotesService.instance.followingUserIds;
    final byId = {for (final n in _feedNotes) n.id: n};
    final children = <String, List<PlazaNote>>{};
    final roots = <PlazaNote>[];
    for (final n in _feedNotes) {
      // 被屏蔽用户的内容（含原贴与被转发来源）一律不展示，避免缓存中残留数据仍可见；
      // 含被管理员删除话题的帖子同样隐藏。
      if (_isBlockedContent(n) || _isBannedNote(n)) continue;
      if (n.repostKind != 'reply') {
        roots.add(n);
        continue;
      }
      // 只展示自己发出的回复、以及自己关注的用户发出的回复；他人回复折叠在详情页。
      final isMine = n.ownerUserId == me?.id;
      final isFollowed = me != null &&
          n.ownerUserId.isNotEmpty &&
          followed.contains(n.ownerUserId);
      if (!isMine && !isFollowed) continue;
      final parentId =
          _visibleReplyParent(n, byId, me?.id, followed);
      if (parentId != null) {
        children.putIfAbsent(parentId, () => []).add(n);
      } else if (_repostSourceBlocked(n)) {
        // 评论的原帖作者已被屏蔽：生成「已屏蔽用户」占位根帖，保留自己这条评论。
        final id = n.repostOf;
        if (!children.containsKey(id)) {
          roots.add(PlazaNote(
            id: id,
            ownerUserId: n.repostSourceUserId,
            title: '',
            content: '',
            authorName: n.repostSourceAuthor,
            visibility: 'public',
            status: 'normal',
            likeCount: 0,
            commentCount: 0,
            createdAt: 0,
            updatedAt: 0,
          ));
        }
        children.putIfAbsent(id, () => []).add(n);
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

  /// 回复帖往上找在列表内可见的最近祖先（根帖、自己的回复或关注用户的回复）：
  /// 中间经过的他人回复不可见时继续向上，最终挂到可见祖先下。
  String? _visibleReplyParent(
      PlazaNote n, Map<String, PlazaNote> byId, String? meId,
      Set<String> followed) {
    var cur = n;
    final visited = <String>{};
    while (cur.repostOf.isNotEmpty && visited.add(cur.repostOf)) {
      final parent = byId[cur.repostOf];
      if (parent == null) return null;
      if (parent.repostKind != 'reply' ||
          parent.ownerUserId == meId ||
          followed.contains(parent.ownerUserId)) {
        return parent.id;
      }
      cur = parent;
    }
    return null;
  }

  /// 分组卡片：根帖用「帖子」页同款样式（头像+昵称+指标+三点菜单），
  /// 其下所有回复用「回复」页同款头像连线串起。
  Widget _buildFeedGroupCard(PlazaNote root, List<PlazaNote> replies) {
    final me = AuthService.instance.currentUser.value;
    // 根帖作者被屏蔽：上方显示「已屏蔽用户」占位，自己的评论仍连线在下方。
    if (_isBlockedContent(root)) {
      return _buildBlockedGroupCard(root, replies);
    }
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
      // 点击自己的头像/昵称：与主页右上角头像一致，打开「我的」页。
      onOpenSelf: widget.onOpenMyPage,
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
            // 连接线：原贴头像底部 → 下面第一个回复头像之间。
            // top:68 = 根帖外层顶内边距(6) + 头像区顶内边距(12) + 头像高(44) + 线上端留白(6)；
            // bottom:6 = 线下端距 ReplyChain 首个头像 6px。
            Positioned(
              left: 21,
              top: 68,
              bottom: 6,
              child: Container(width: 1, color: const Color(0xFFC9C9C9)),
            ),
            // 与无回复时同款 vertical:6 外边距：原帖与上方分割线的间隔不因回复出现而变小。
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: rootWidget,
            ),
          ],
        ),
        ReplyChain(
          replies: replies,
          parentAccounts: {
            root.id: root.authorAccount,
            for (final r in replies) r.id: r.authorAccount,
          },
          // 点击回复节点进入原贴详情页，该回复排到评论列表第一条。
          detailNoteId: root.id,
          onComment: (n) => replyToNote(context, n, _refreshCurrentSmooth),
          onLike: (n) => likeTargetNote(context, n, _refreshCurrentSmooth),
          onRepost: (n) => forwardNote(context, n, _refreshCurrentSmooth),
          onMore: (n) => _showFeedReplyMenu(n),
          // 点击自己的头像/昵称：与主页右上角头像一致，打开「我的」页。
          onOpenSelf: widget.onOpenMyPage,
        ),
      ],
    );
  }

  /// 根帖作者被屏蔽时的分组卡片：上方显示「已屏蔽用户」占位，
  /// 下方仍用头像连线展示自己的评论，点击占位可进入该用户主页取消屏蔽。
  Widget _buildBlockedGroupCard(PlazaNote root, List<PlazaNote> replies) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            // top:58 = 外层顶内边距(6) + 头像上内边距(2) + 头像高(44) + 线上端留白(6)；
            // bottom:6 = 线下端距 ReplyChain 首个头像 6px（与 _buildFeedGroupCard 一致）。
            Positioned(
              left: 21,
              top: 58,
              bottom: 6,
              child: Container(width: 1, color: const Color(0xFFC9C9C9)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: CircleAvatar(
                      radius: 22,
                      backgroundColor: Color(0x1A8B6B5A),
                      child: Icon(Icons.block, size: 22, color: _textSec),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      onTap: root.ownerUserId.isNotEmpty
                          ? () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => UserSpacePage(
                                    userId: root.ownerUserId,
                                    userName: root.authorName,
                                  ),
                                ),
                              )
                          : null,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          border: Border.all(color: _border),
                          borderRadius: BorderRadius.circular(8),
                          color: _bg,
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.block, size: 16, color: _textSec),
                            SizedBox(width: 8),
                            Text('已屏蔽用户',
                                style:
                                    TextStyle(fontSize: 14, color: _textSec)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (replies.isNotEmpty)
          ReplyChain(
            replies: replies,
            parentAccounts: {
              root.id: root.authorAccount,
              for (final r in replies) r.id: r.authorAccount,
            },
            // 点击回复节点进入原贴详情页，该回复排到评论列表第一条。
            detailNoteId: root.id,
            onComment: (n) => replyToNote(context, n, _refreshCurrentSmooth),
            onLike: (n) => likeTargetNote(context, n, _refreshCurrentSmooth),
            onRepost: (n) => forwardNote(context, n, _refreshCurrentSmooth),
            onMore: (n) => _showFeedReplyMenu(n),
            // 点击自己的头像/昵称：与主页右上角头像一致，打开「我的」页。
            onOpenSelf: widget.onOpenMyPage,
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
        // 屏蔽/关注后刷新当前栏目，让被屏蔽用户的帖子立即消失。
        _refreshCurrentSmooth();
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
      {'key': 'reading', 'label': '诵经', 'icon': Icons.chrome_reader_mode_outlined},
      {'key': 'nianfo', 'label': '念佛', 'icon': Icons.local_florist_outlined},
      {'key': 'buddha', 'label': '称名', 'icon': Icons.spa_outlined},
      {'key': 'mantra', 'label': '持咒', 'icon': Icons.notifications_none_outlined},
      {'key': 'copying', 'label': '抄经', 'icon': Icons.edit_outlined},
      {'key': 'meditation', 'label': '静坐', 'icon': Icons.self_improvement_outlined},
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
        case 'nianfo':
          return _hasNonEmptyNamed(prefs, 'setting_nianfo_items');
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
        case 'nianfo':
          for (final e in _decodeNamedList(prefs.getString('setting_nianfo_items'))) {
            if (e.$1.isNotEmpty) {
              lines.add('念佛 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}声' : ''}');
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
      case 'nianfo':
        return _sumNamedCount(prefs.getString('setting_nianfo_items'));
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
    final labelChars = widget.label.characters;
    final label = labelChars.length > 2
        ? '${labelChars.take(2)}…'
        : widget.label;
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
            color: checked ? _gold : _card,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: checked ? 0.10 : 0.07),
                blurRadius: checked ? 4 : 6,
                offset: const Offset(0, 2),
              ),
            ],
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
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
