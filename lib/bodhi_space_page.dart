import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'loading_widgets.dart';
import 'login_page.dart';
import 'user_avatar.dart';
import 'user_avatar_cache.dart';
import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'note_stats_center.dart';
import 'reply_chain.dart';
import 'my_page.dart';
import 'user_space_page.dart';
import 'text_input_sheet.dart';
import 'note_edit_page.dart';
import 'note_sutra_links.dart';
import 'hot_discussion_list_page.dart';
import 'post_rich_content.dart';
import 'sutra_list_page.dart';

import 'app_palette.dart';
Color get _gold => AppPalette.p.accent;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _border => AppPalette.p.border;
Color get _overlay => AppPalette.p.tintBg;

const Map<String, String> _plazaTabMeta = {
  'discuss': '讨论',
  'hot': '推荐',
  'follow': '关注',
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

/// 自定义工具栏的单个条目：经文（$，可带卷标）或话题（#）。
class _CustomToolbarItem {
  final bool isSutra;
  final String name;
  final String path;

  const _CustomToolbarItem({
    required this.isSutra,
    required this.name,
    this.path = '',
  });

  Map<String, dynamic> toJson() => {
        'type': isSutra ? 'sutra' : 'topic',
        'name': name,
        'path': path,
      };

  static _CustomToolbarItem? fromJson(Map<String, dynamic> e) {
    final name = (e['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    return _CustomToolbarItem(
      isSutra: e['type'] == 'sutra',
      name: name,
      path: (e['path'] ?? '').toString(),
    );
  }
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

/// 「菩提空间」页面：承载广场栏目（热门/推荐/关注）及其内容流；
/// 公告不在栏目里，由右上角公告图标进入独立公告列表页。
class BodhiSpacePage extends StatefulWidget {
  /// 帖子卡点击自己头像/昵称的回调：打开「我的」页面。
  final VoidCallback? onOpenMyPage;

  const BodhiSpacePage({super.key, this.onOpenMyPage});

  @override
  State<BodhiSpacePage> createState() => BodhiSpacePageState();
}

class BodhiSpacePageState extends State<BodhiSpacePage>
    with RouteAware, WidgetsBindingObserver {
  void reload() {
    // 有新帖时只把新帖插入到顶部，避免「整页刷新」的体感。
    if (BodhiSpacePageState.newPostBadge.value > 0) {
      _refreshNewPostsOnly();
    } else {
      _refreshCurrentSmooth();
    }
  }

  /// 双击底部「菩提空间」菜单图标：无新帖时回到页面最顶部。
  void scrollToTop() {
    if (_feedScroll.hasClients && _feedScroll.offset > 0) {
      _feedScroll.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  int _tabIndex = 0;
  List<String> _plazaTabs = ['discuss', 'hot', 'follow'];
  /// 自定义工具栏：栏目名（默认「自定义」，可改名）+ 经文/话题条目（数量不限），
  /// 点击工具栏上的自定义栏目向下展开列表，点击条目进入对应讨论页。
  String _customTabName = '自定义';
  List<_CustomToolbarItem> _customItems = const [];
  bool _customTabOpen = false;
  /// 自定义面板悬浮层：锚定在工具栏下边缘（LayerLink 跟随滚动），
  /// 以 OverlayEntry 盖在帖子流上方，而不是占位把内容挤下去。
  final LayerLink _customPanelLink = LayerLink();
  OverlayEntry? _customPanelEntry;

  /// 自定义面板每条目的最新讨论数：键为「s:经名」/「t:话题」，
  /// 面板展开时异步拉取（经文=经书讨论总数，话题=话题下帖子总数）。
  final Map<String, int> _customCounts = {};
  final Map<String, _PlazaFeedCache> _tabCaches = {};
  final List<PlazaNote> _feedNotes = [];
  final Set<String> _followedIds = {};
  final ScrollController _feedScroll = ScrollController();
  int _feedPage = 1;
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
  /// 有未读公告：右上角公告图标显示实体圆点角标（打开公告页即视为已读）。
  bool _hasUnreadAnnouncement = false;
  static const int _feedPageSize = 20;
  /// 讨论栏目顶部的热门话题 / 热门经文（云端聚合，客户端经文取 8 个、话题取 4 个做当日轮换）。
  List<HotDiscussionItem> _hotTopics = [];
  List<HotDiscussionItem> _hotSutras = [];
  /// 全量热门榜（top50）：供「更多」页展示完整的经文/话题热度排行。
  List<HotDiscussionItem> _hotTopicAll = [];
  List<HotDiscussionItem> _hotSutraAll = [];
  /// 热门经文的基础经名 → 显示名（含卷标），用于热门榜胶囊显示。
  Map<String, String> _hotSutraDisplayNames = const {};
  /// 「热门/推荐/关注」新帖提醒：后台静默统计新帖数量，只更新「X条新帖子」提醒条，
  /// 不自动刷新列表，点击提醒或下拉才手动刷出，避免浏览时被打断。
  Timer? _newPostTimer;
  bool _newPostChecking = false;
  bool _appActive = true;
  int _newPostCount = 0;
  /// 滚动到顶部提醒条被隐藏时，是否显示悬浮的「显示X帖子」按钮。
  bool _showNewPostPill = false;
  /// 顶部栏目栏完全滚出视口时，右下角按钮切为「回到顶部」：
  /// 样式与添加笔记一致，仅白色图标不同；栏目栏再次露出时恢复添加笔记。
  bool _fabBackToTop = false;
  /// _loadFeed 重入闸门：防止点击「显示X帖子」时双击重入，
  /// 或后台轮询新帖与点击触发的加载同时跑导致请求/状态错乱。
  bool _feedRefreshing = false;
  /// 刚发布、服务端列表尚未返回的本地回复（回复id → 回复帖）：
  /// 后台刷新覆盖列表时重新补挂，直到服务端返回该回复（或父帖消失）才清除，
  /// 保证评论后头像连线不因刷新而闪没。
  final Map<String, PlazaNote> _pendingLocalReplies = {};
  /// 全局「有新帖未查看」标记：驱动底部「菩提空间」菜单图标上的 70867A 小圆点。
  static final ValueNotifier<int> newPostBadge = ValueNotifier<int>(0);
  static const Duration _newPostCheckInterval = Duration(seconds: 30);

  void _setNewPostCount(int v) {
    _newPostCount = v;
    newPostBadge.value = v;
  }

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
    _feedScroll.addListener(_onFeedScroll);
    final tabOrderFuture = _loadTabOrder();
    unawaited(_loadCustomTab());
    _loadFeed();
    // 静默拉取公告列表：只用于右上角公告图标的「新公告」角标判定。
    unawaited(_loadAnnouncements());
    // 等栏目顺序就绪后，并行预取其余栏目：热门加载的同时，
    // 推荐/关注也在后台刷新，之后切换栏目数据已就绪，不再转圈。
    tabOrderFuture.then((_) => _prefetchOtherTabs());
    // 后台静默统计新帖数量，只更新「X条新帖子」提醒，不自动刷新列表。
    WidgetsBinding.instance.addObserver(this);
    _newPostTimer =
        Timer.periodic(_newPostCheckInterval, (_) => _checkNewPosts());
    // 登录会话是异步恢复的：首次加载广场时可能还没登录，
    // 等登录态就绪后重新拉取屏蔽列表并刷新，让被屏蔽用户的帖子立即消失。
    AuthService.instance.currentUser.addListener(_onAuthChanged);
    // 评论发表后的即时连线：监听新回复广播，把回复乐观插入当前流。
    NoteStatsCenter.instance.lastReplyPosted.addListener(_onLocalReplyPosted);
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    // 直接换成新的可变列表：缓存里的列表可能来自 const []（不可变），
    // 对其 clear() 会抛 Unsupported operation 并在登录流程中炸出错误页。
    followCache.notes = <PlazaNote>[];
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

  /// 从详情页等路由返回时立即平滑刷新当前栏目。
  @override
  void didPopNext() {
    _appActive = true;
    _refreshCurrentSmooth();
    // 返回本页时顺带刷新公告角标（不阻塞界面）。
    unawaited(_loadAnnouncements());
  }

  /// 其他页面覆盖在本页上时暂停轮询，返回时再立即刷新。
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
    NoteStatsCenter.instance.lastReplyPosted
        .removeListener(_onLocalReplyPosted);
    WidgetsBinding.instance.removeObserver(this);
    _newPostTimer?.cancel();
    _newPostTimer = null;
    // 页面销毁时移除自定义悬浮面板，避免 OverlayEntry 泄漏。
    _customPanelEntry?.remove();
    _customPanelEntry = null;
    routeObserver.unsubscribe(this);
    _feedScroll.dispose();
    super.dispose();
  }

  /// 读取并迁移用户保存的栏目顺序（含历史版本兼容迁移）。
  Future<void> _loadTabOrder() async {
    final prefs = await SharedPreferences.getInstance();
    var plazaTabs = <String>['discuss', 'hot', 'follow'];
    // v3 一次性迁移：栏目改为 热门/推荐/关注（公告移到右上角图标入口），
    // 统一重置为新默认顺序；迁移完成后尊重用户手动排序。
    if (!(prefs.getBool('plaza_tab_order_v3') ?? false)) {
      await prefs.setBool('plaza_tab_order_v3', true);
      await prefs.setString('plaza_tab_order', jsonEncode(plazaTabs));
    } else {
      final tabOrderRaw = prefs.getString('plaza_tab_order');
      if (tabOrderRaw != null && tabOrderRaw.isNotEmpty) {
        try {
          final saved = (jsonDecode(tabOrderRaw) as List<dynamic>).cast<String>();
          final valid = <String>[];
          for (final k in saved) {
            if (k == 'discover') {
              // 旧版「发现」栏目残留，统一并入「推荐」。
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
    }
    if (!mounted) return;
    setState(() {
      _plazaTabs = plazaTabs;
    });
  }

  void _onFeedScroll() {
    if (_feedScroll.position.pixels >=
        _feedScroll.position.maxScrollExtent - 200) {
      _loadMoreFeed();
    }
    _updateNewPostPill();
    _updateFabMode();
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

  /// 把「我刚发布、还没过期」的帖子稳定地提到列表最前（组内保持原有热度序）。
  /// 只对刚发的这一条生效，历史帖子一律不置顶——否则发帖多的用户
  /// 一进发现页满屏都是自己的旧帖。仅在整页刷新/后台预取替换列表时应用；
  /// _loadMoreFeed 追加的分页不重排，避免浏览中列表突然跳动。
  /// 只影响自己客户端的展示顺序，其他用户看不到。
  List<PlazaNote> _hoistOwnNotes(List<PlazaNote> list) {
    if (list.isEmpty) return list;
    bool fresh(PlazaNote n) =>
        CloudNotesService.isRecentlyPublished(n.id);
    final mine = list.where(fresh).toList();
    if (mine.isEmpty || mine.length == list.length) return list;
    return [...mine, ...list.where((n) => !fresh(n))];
  }

  /// 加载当前 tab 的笔记流。发现：热度 + 时间衰减排序，
  /// 我刚发布的帖子额外短暂置顶（仅自己可见；历史帖不置顶）。
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
      if (!mounted) return;
      try {
        if (tab == 'latest' || tab == 'hot') {
          final sort = (tab == 'hot' && !newestFirst) ? 'hot' : 'latest';
          var (list, nextPage, hasMore) = await _fetchFilteredFeed(1, sort);
          // 与「关注」栏目同口径兜底：作者 @账号/认证/阅藏进度缺失时按 uid 补齐，
          // 避免发现页同一用户与关注页显示不一致（头像旁无 @账号、无百分比）。
          list = await CloudNotesService.instance.enrichFeedAuthors(list);
          // 我刚发布的帖子短暂置顶（仅自己可见），其余保持云端热度序。
          list = _hoistOwnNotes(list);
          if (mounted) {
            setState(() {
              _feedNotes.addAll(list);
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
      // 全量重载后补挂刚发布的本地回复：服务端索引延迟还没返回它时，
      // 保持根帖下方头像连线可见，不因刷新而闪没。
      if (mounted && _mergePendingLocalReplies()) {
        setState(() {});
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
    } catch (_) {
      // 静默：本方法常被 _onAuthChanged 等调用方以「不 await」方式触发，
      // 若异常外抛会变成未处理异步错误，被全局错误处理器弹成错误页面
      // （登录刚成功时尤其容易误触发）。失败时下次刷新自会重试。
    } finally {
      _feedRefreshing = false;
    }
  }

  /// 静默拉取公告列表：与本地「最后已读时间」比较，驱动右上角公告角标。
  /// 失败静默忽略，不影响主信息流。
  Future<void> _loadAnnouncements() async {
    try {
      final list = await CloudNotesService.instance.getAnnouncements();
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final seen = prefs.getInt('announce_last_seen_at') ?? 0;
      setState(() {
        _announcements = list;
        _hasUnreadAnnouncement = list.any((a) => a.createdAt > seen);
      });
    } catch (_) {
      // 静默：公告角标拉取失败不打扰主流程，下次进入页面自会重试。
    }
  }

  /// 打开公告列表页：进入即把当前最新公告标记为已读（角标消失），
  /// 返回后重新拉取，期间若又有新公告则角标重新出现。
  Future<void> _openAnnouncements() async {
    final latest = _announcements.fold<int>(
        0, (m, a) => a.createdAt > m ? a.createdAt : m);
    if (latest > 0) {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getInt('announce_last_seen_at') ?? 0;
      if (latest > seen) {
        await prefs.setInt('announce_last_seen_at', latest);
      }
    }
    if (!mounted) return;
    setState(() => _hasUnreadAnnouncement = false);
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AnnouncementListPage()),
    );
    if (mounted) unawaited(_loadAnnouncements());
  }

  _PlazaFeedCache _cacheFor(String tab) =>
      _tabCaches.putIfAbsent(tab, _PlazaFeedCache.new);

  /// 拉取讨论栏目的热门话题 / 热门经文。
  /// 话题沿用云端互动热度榜；经文榜改用「最近 30 天提及数」口径：
  /// 广场帖 $经名 引用 + 经书讨论页讨论，同一帖多次提及只算一次，提及越多越热。
  /// 轮换规则：前 N 名按当天日期确定性跳过少数几个 + 其余名次补足，
  /// 当天内稳定、跨天变化，避免永远同一批。经文名需命中经书目录才展示。
  Future<void> _loadHotDiscussions() async {
    try {
      await NoteSutraCatalog.load(); // 确保经书目录就绪，过滤有效经名
      final topicsFuture = CloudNotesService.instance.getHotDiscussions();
      final sutrasFuture = CloudNotesService.instance.getHotSutraMentions();
      final (topics, _) = await topicsFuture;
      final sutras = await sutrasFuture;
      final titleMap = NoteSutraCatalog.cachedTitleMap ?? const {};
      final mvBases = NoteSutraCatalog.cachedMultiVolumeBases;
      final now = DateTime.now();
      final daySeed = now.year * 10000 + now.month * 100 + now.day;
      // 多卷经书按卷拆分：「地藏菩萨本愿经卷一」「卷二」各成一条，卷拆分前的
      // 历史讨论与不带卷标的引用并入卷一，使榜单「提及X次」与点进对应卷讨论页
      // 看到的条数一致；传目录经名做最长前缀归一，让云端贪心提取的「经名+粘连
      // 文字」也计入真实经名（与讨论页口径一致）。
      final validSutras = mergeHotSutraItems(sutras,
              catalogNames: titleMap.keys.toSet(), multiVolumeBases: mvBases)
          .where((s) => titleMap.containsKey(splitHotSutraName(s.name).$1))
          .toList();
      // 从本地经书列表构建卷标显示映射（如「高僧传」→「高僧传卷一」）
      final sutraDisplayNames =
          await buildSutraDisplayNameMap(validSutras, isSutra: true);
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
        _hotSutraDisplayNames = sutraDisplayNames;
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
    final deleted = CloudNotesService.instance.locallyDeletedNoteIds;
    _feedNotes
      ..clear()
      ..addAll(c.notes.where((n) =>
          !_isBlockedContent(n) &&
          !_isBannedNote(n) &&
          !deleted.contains(n.id)));
    _mergePendingLocalReplies();
    _feedPage = c.page;
    _feedHasMore = c.hasMore;
    _feedInitial = c.initial;
    _feedError = c.error;
    _feedLoading = false;
  }

  /// 评论发表后的即时连线：把广播来的新回复乐观插入当前流，
  /// 挂到根帖下方让头像连线立即出现，不等后台刷新（云端索引可见性 +
  /// 网络往返会晚数秒）。根帖不在当前流时不插入，交给刷新后的分组逻辑。
  /// 父帖评论量就地 +1（替换列表对象，不改顺序），回复就地出现在
  /// 原帖下方，整条流不因刷新而跳动位置。
  void _onLocalReplyPosted() {
    final reply = NoteStatsCenter.instance.lastReplyPosted.value;
    if (!mounted || reply == null || reply.repostOf.isEmpty) return;
    _pendingLocalReplies[reply.id] = reply;
    final idx = _feedNotes.indexWhere((n) => n.id == reply.repostOf);
    if (idx < 0) return;
    PlazaNote? bumped;
    setState(() {
      _feedNotes.add(reply);
      final parent = _feedNotes[idx];
      bumped = parent.copyWith(commentCount: parent.commentCount + 1);
      _feedNotes[idx] = bumped!;
    });
    // 广播父帖新指标：连线里引用该父帖的节点数字同步刷新。
    NoteStatsCenter.instance.report(bumped!);
    _saveFeedToCache(_plazaTabs[_tabIndex]);
  }

  /// 列表被服务端数据覆盖/重载后补挂本地新回复：
  /// 服务端已返回该回复则清除待定项；父帖已不在列表则同样放弃（无法成组）。
  /// 返回是否有变更（调用方据此决定是否 setState）。
  bool _mergePendingLocalReplies() {
    if (_pendingLocalReplies.isEmpty) return false;
    final ids = _feedNotes.map((n) => n.id).toSet();
    var changed = false;
    final stale = <String>[];
    for (final entry in _pendingLocalReplies.entries) {
      final r = entry.value;
      if (ids.contains(r.id) || !ids.contains(r.repostOf)) {
        stale.add(entry.key);
        continue;
      }
      if (!_feedNotes.any((n) => n.id == r.id)) {
        _feedNotes.add(r);
        changed = true;
      }
    }
    for (final k in stale) {
      _pendingLocalReplies.remove(k);
    }
    return changed;
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

  /// 「显示X帖子」/ 双击「菩提空间」菜单图标的轻量刷新：
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
  void _scrollInstantTop() {
    if (!_feedScroll.hasClients) return;
    if (_feedScroll.offset > 0) {
      _feedScroll.jumpTo(0);
    }
  }

  /// 后台静默统计当前栏目新帖数量：只更新「X条新帖子」提醒，不刷新列表。
  /// 推荐：按热度规则倒序；热门：最新的带 #话题 或 $经名 帖子；关注：仅统计已关注同修的新帖。
  Future<void> _checkNewPosts() async {
    if (!mounted || !_appActive || _newPostChecking) return;
    final tab = _plazaTabs[_tabIndex];
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

  /// 计算悬浮「显示X帖子」按钮是否可见：有新帖且已滚过顶部栏与提醒条。
  void _updateNewPostPill() {
    final show = _newPostCount > 0 &&
        _feedScroll.hasClients &&
        _feedScroll.offset >= 140;
    if (show != _showNewPostPill) {
      setState(() => _showNewPostPill = show);
    }
  }

  /// 顶部栏（头像 + 标题 + 公告）高度：上内边距 6 + 头像高 32 + 下内边距 10。
  double get _topBarHeight => 6 + 32 + 10;

  /// 计算右下角按钮形态：顶部栏（头像/标题）完全滚出视口、
  /// 工具栏吸顶后切为「回到顶部」，滚回顶部时恢复「添加笔记」。
  void _updateFabMode() {
    if (!_feedScroll.hasClients) return;
    final backToTop = _feedScroll.offset >= _topBarHeight;
    if (backToTop != _fabBackToTop) {
      setState(() => _fabBackToTop = backToTop);
    }
  }

  /// 点击悬浮按钮：滚动到帖子列表区域顶部，并立即把新帖插入到列表顶部（不清空重载）。
  Future<void> _refreshFromPill() async {
    final animFuture = (_feedScroll.hasClients && _feedScroll.offset > 0)
        ? _feedScroll.animateTo(0,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut)
        : Future<void>.value();
    await _refreshNewPostsOnly();
    await animFuture;
  }

  /// 打开本页时并行预取其余栏目：热门加载的同时，推荐/关注在后台刷新，
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
    try {
      if (tab == 'latest' || tab == 'hot') {
        // 用户正停留在最新优先视图时，后台刷新也保持最新排序，避免新帖被旧热帖顶掉。
        final keepNewest = tab == 'hot' &&
            _feedNewestFirst &&
            _plazaTabs[_tabIndex] == tab;
        final sort = (tab == 'hot' && !keepNewest) ? 'hot' : 'latest';
        var (list, nextPage, hasMore) = await _fetchFilteredFeed(1, sort);
        list = await CloudNotesService.instance.enrichFeedAuthors(list);
        // 与 _loadFeed 同款：我刚发布的帖子短暂置顶（仅自己可见）。
        list = _hoistOwnNotes(list);
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
          // 必须是可变列表：_onAuthChanged 会整体替换/清空缓存内容，
          // 若放入 const []（不可变），后续修改会抛 Unsupported operation。
          c.notes = <PlazaNote>[];
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
    if (_feedLoading ||
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
          _feedPage++;
          _feedHasMore = more;
          _feedLoading = false;
        });
        for (final n in list) {
          if (n.ownerUserId.isNotEmpty) UserAvatarCache.instance.request(n.ownerUserId);
          if (n.repostSourceUserId.isNotEmpty) UserAvatarCache.instance.request(n.repostSourceUserId);
        }
        if (_mergePendingLocalReplies()) {
          setState(() {});
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
        _feedPage = nextPage;
        _feedHasMore = hasMore;
        _feedLoading = false;
      });
      // 预取新加载页的作者头像。
      for (final n in list) {
        if (n.ownerUserId.isNotEmpty) UserAvatarCache.instance.request(n.ownerUserId);
        if (n.repostSourceUserId.isNotEmpty) UserAvatarCache.instance.request(n.repostSourceUserId);
      }
      // 新加载的页里出现了待定回复的父帖时，把回复补挂成组。
      if (_mergePendingLocalReplies()) {
        setState(() {});
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
    // 切换固定栏目时收起自定义悬浮面板。
    _customPanelEntry?.remove();
    _customPanelEntry = null;
    setState(() {
      _tabIndex = i;
      _feedNewestFirst = false;
      _customTabOpen = false;
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

  /// 左右滑动切换固定栏目（讨论/推荐/关注）；自定义栏目不参与滑动切换。
  void _swipeToTab(int i) {
    if (_customTabOpen) return;
    if (i < 0 || i >= _plazaTabs.length || i == _tabIndex) return;
    _onTabChanged(i);
  }

  /// 加载自定义工具栏配置（栏目名 + 经文/话题条目）。
  Future<void> _loadCustomTab() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('plaza_custom_tab');
    if (raw == null || raw.isEmpty) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final name = (m['name'] ?? '').toString().trim();
      final items = (m['items'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(_CustomToolbarItem.fromJson)
          .whereType<_CustomToolbarItem>()
          .toList();
      if (!mounted) return;
      setState(() {
        _customTabName = name.isEmpty ? '自定义' : name;
        _customItems = items;
      });
    } catch (_) {}
  }

  /// 保存自定义工具栏配置并更新工具栏（条目为空时收起自定义栏目）。
  Future<void> _saveCustomTab(
      String name, List<_CustomToolbarItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'plaza_custom_tab',
        jsonEncode({
          'name': name,
          'items': items.map((e) => e.toJson()).toList(),
        }));
    if (!mounted) return;
    if (items.isEmpty) _closeCustomPanel();
    setState(() {
      _customTabName = name;
      _customItems = items;
    });
    // 面板正展开时条目有变动，同步刷新悬浮层内容。
    _customPanelEntry?.markNeedsBuild();
  }

  /// 展开/收起自定义悬浮面板：点击自定义栏目触发。
  /// 面板一旦展开会作为 OverlayEntry 叠在页面之上，需在打开弹窗等
  /// 需要交互的场景前先收起，否则会遮挡弹窗内容。
  void _toggleCustomTab() {
    if (_customTabOpen) {
      _closeCustomPanel();
    } else {
      _openCustomPanel();
    }
  }

  /// 展开自定义悬浮面板（插入 OverlayEntry 并拉取讨论计数）。
  void _openCustomPanel() {
    if (_customTabOpen) return;
    setState(() => _customTabOpen = true);
    _customPanelEntry =
        OverlayEntry(builder: (ctx) => _buildCustomOverlay(ctx));
    Overlay.of(context).insert(_customPanelEntry!);
    unawaited(_loadCustomCounts());
  }

  /// 拉取自定义面板每条目的最新讨论数（经文=经书讨论总数，话题=话题下帖子总数），
  /// 完成后刷新悬浮层。计数键与打开讨论页时的口径保持一致。
  Future<void> _loadCustomCounts() async {
    final items = List<_CustomToolbarItem>.from(_customItems);
    final results = await Future.wait<int?>(items.map((it) async {
      try {
        if (it.isSutra) {
          final (base, path) = resolveHotSutraTarget(it.name);
          final key = sutraDisplayTitleWithPath(
            base,
            filePath: path.isNotEmpty ? path : it.path,
            multiVolumeBases: NoteSutraCatalog.cachedMultiVolumeBases,
          );
          final (_, _, total) = await CloudNotesService.instance
              .getSutraDiscussions(sutraTitle: key, page: 1, pageSize: 1);
          return total;
        } else {
          final (_, _, _, total) = await CloudNotesService.instance
              .getTopicNotes(it.name, page: 1, pageSize: 1);
          return total;
        }
      } catch (_) {
        return null;
      }
    }));
    if (!mounted || !_customTabOpen) return;
    for (var i = 0; i < items.length; i++) {
      final c = results[i];
      if (c == null) continue;
      _customCounts['${items[i].isSutra ? 's' : 't'}:${items[i].name}'] = c;
    }
    _customPanelEntry?.markNeedsBuild();
  }

  /// 收起自定义悬浮面板（移除 OverlayEntry）。
  void _closeCustomPanel() {
    _customPanelEntry?.remove();
    _customPanelEntry = null;
    if (_customTabOpen) setState(() => _customTabOpen = false);
  }

  /// 供外部调用（如切到其他底部菜单页时）：自动收起自定义悬浮面板，
  /// 避免面板残留在其他页面上方。
  void closeCustomPanel() => _closeCustomPanel();

  /// 点击自定义列表条目：经文进对应经书讨论页，话题进话题页。
  void _openCustomItem(_CustomToolbarItem it) {
    _closeCustomPanel();
    if (it.isSutra) {
      final (base, path) = resolveHotSutraTarget(it.name);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SutraDiscussionPage(
            title: base,
            filePath: path.isNotEmpty ? path : it.path,
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

  /// 自定义栏目悬浮下拉面板：经 LayerLink 锚定在工具栏下边缘，
  /// 盖在帖子流上方（不挤动内容）；点击面板外任意处收起。
  Widget _buildCustomOverlay(BuildContext ctx) {
    return Stack(
      children: [
        // 透明遮罩：拦截背后交互，点击面板外区域即收起。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeCustomPanel,
          ),
        ),
        CompositedTransformFollower(
          link: _customPanelLink,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          showWhenUnlinked: false,
          child: SizedBox(
            width: MediaQuery.of(ctx).size.width,
            child: Material(
              color: _card,
              elevation: 3,
              shadowColor: Colors.black.withValues(alpha: 0.16),
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(12)),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final it in _customItems)
                    Builder(builder: (ctx2) {
                      final count =
                          _customCounts['${it.isSutra ? 's' : 't'}:${it.name}'];
                      return InkWell(
                        onTap: () => _openCustomItem(it),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              Text(it.isSutra ? r'$' : '#',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: it.isSutra
                                          ? const Color(0xFF71867A)
                                          : const Color(0xFFcf9e66))),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(it.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        TextStyle(fontSize: 15, color: _text)),
                              ),
                              if (count != null) ...[
                                const SizedBox(width: 8),
                                Text('$count讨论',
                                    style: TextStyle(
                                        fontSize: 12, color: _textSec)),
                              ],
                              const SizedBox(width: 4),
                              Icon(Icons.chevron_right,
                                  size: 16, color: _textHint),
                            ],
                          ),
                        ),
                      );
                    }),
                  // 面板内的添加行：无条目时即首行引导添加；
                  // 已有条目时排在最后一行，继续添加。点击进入添加面板。
                  InkWell(
                    onTap: _showCustomToolbarSheet,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          Icon(Icons.add, size: 17, color: _gold),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _customItems.isEmpty
                                  ? '添加关注的经文和话题'
                                  : '继续添加经文和话题',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  TextStyle(fontSize: 14, color: _textSec),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 面板底部分割线：跟随工具栏横线规则，仅素白外观显示。
                  if (AppPalette.instance.isPlain)
                    Divider(
                        height: 1,
                        thickness: 0.5,
                        color: AppPalette.p.divider),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 自定义工具栏的话题候选：本地用过的话题 + 广场热门话题聚合，
  /// 排除管理员已删除与含数字的话题；前缀匹配优先，最多 20 个。
  Future<List<String>> _searchTopicsForCustom(String q) async {
    await CloudNotesService.instance.refreshBannedTopics();
    final bans = CloudNotesService.instance.bannedTopicNames;
    final noiseRe = RegExp(r'\d');
    final prefs = await SharedPreferences.getInstance();
    final topics = <String>{
      ...(prefs.getStringList('note_topics') ?? const <String>[]),
    };
    try {
      final (list, _) = await CloudNotesService.instance.getHotDiscussions();
      for (final t in list) {
        if (t.name.isNotEmpty) topics.add(t.name);
      }
    } catch (_) {}
    final qq = q.trim().toLowerCase();
    final prefix = <String>[];
    final contains = <String>[];
    for (final t in topics) {
      if (bans.contains(t) || noiseRe.hasMatch(t)) continue;
      final lower = t.toLowerCase();
      if (qq.isEmpty || lower.startsWith(qq)) {
        prefix.add(t);
      } else if (lower.contains(qq)) {
        contains.add(t);
      }
    }
    return [...prefix, ...contains].take(20).toList();
  }

  /// 打开「自定义工具栏」面板：栏目改名、添加/删除经文或话题（数量不限）。
  /// 检索联想与笔记正文同款：输入 $ 出经文、输入 # 出话题。
  /// 完成后持久化并立即更新工具栏上的自定义栏目。
  Future<void> _showCustomToolbarSheet() async {
    // 先收起悬浮面板：面板的透明遮罩是整屏的，若在弹窗之上会挡住
    // 弹窗内列表/按钮的点击。保存后若原本展开再重新打开以显示新条目。
    final panelWasOpen = _customTabOpen;
    if (panelWasOpen) _closeCustomPanel();
    // 目录预热不阻塞面板打开；检索时 search() 内部会自行等待目录就绪。
    unawaited(NoteSutraCatalog.load());
    var items = List<_CustomToolbarItem>.from(_customItems);
    var searchSeq = 0;
    var sheetOpen = true; // 弹窗关闭后，未完成的搜索回调不得再 setSheet
    var trigger = ''; // 当前触发符：$ 经文 / # 话题，空表示未进入检索
    var sutraResults = <NoteSutraLink>[];
    var topicResults = <String>[];
    Timer? debounce;
    final nameCtrl = TextEditingController(text: _customTabName);
    final queryCtrl = TextEditingController();

    void onQueryChanged(StateSetter setSheet, String v) {
      final seq = ++searchSeq;
      var t = '';
      var q = v;
      if (v.startsWith(r'$')) {
        t = r'$';
        q = v.substring(1);
      } else if (v.startsWith('#')) {
        t = '#';
        q = v.substring(1);
      }
      trigger = t;
      debounce?.cancel();
      if (t.isEmpty || q.trim().isEmpty) {
        setSheet(() {
          sutraResults = const [];
          topicResults = const [];
        });
        return;
      }
      // 与笔记正文联想同款 250ms 防抖。
      debounce = Timer(const Duration(milliseconds: 250), () async {
        if (t == r'$') {
          final results = await NoteSutraCatalog.search(q);
          if (!sheetOpen || seq != searchSeq) return;
          setSheet(() => sutraResults = results);
        } else {
          final results = await _searchTopicsForCustom(q);
          if (!sheetOpen || seq != searchSeq) return;
          setSheet(() => topicResults = results);
        }
      });
    }

    void tryAdd(StateSetter setSheet, _CustomToolbarItem it) {
      if (items.any((e) => e.isSutra == it.isSutra && e.name == it.name)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已经添加过了')));
        return;
      }
      setSheet(() {
        items.add(it);
        queryCtrl.clear();
        trigger = '';
        sutraResults = const [];
        topicResults = const [];
      });
    }

    Widget hintRow(String msg) => Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Center(
            child: Text(msg, style: TextStyle(fontSize: 13, color: _textHint)),
          ),
        );

    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final topicQuery =
                trigger == '#' ? queryCtrl.text.substring(1).trim() : '';
            final canCreateTopic = topicQuery.isNotEmpty &&
                !topicResults.contains(topicQuery) &&
                !items.any((e) => !e.isSutra && e.name == topicQuery);
            return Padding(
              padding:
                  EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('添加经文或话题，数量不限',
                          style: TextStyle(fontSize: 12, color: _textSec)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: nameCtrl,
                        maxLength: 8,
                        style: TextStyle(color: _text, fontSize: 15),
                        decoration: InputDecoration(
                          isDense: true,
                          counterText: '',
                          hintText: '默认「自定义」，可改成你喜欢的名字',
                          hintStyle: TextStyle(color: _textHint, fontSize: 14),
                          filled: true,
                          fillColor: _bg,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: _border)),
                          focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: _gold)),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (items.isNotEmpty) ...[
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final it in items)
                              Container(
                                padding:
                                    const EdgeInsets.fromLTRB(10, 4, 2, 4),
                                decoration: BoxDecoration(
                                  color: _overlay,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(it.isSutra ? r'$' : '#',
                                        style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: it.isSutra
                                                ? const Color(0xFF71867A)
                                                : const Color(0xFFcf9e66))),
                                    const SizedBox(width: 4),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                          maxWidth: 150),
                                      child: Text(it.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 13, color: _text)),
                                    ),
                                    IconButton(
                                      onPressed: () =>
                                          setSheet(() => items.remove(it)),
                                      icon: Icon(Icons.close,
                                          size: 16, color: _textHint),
                                      tooltip: '移除',
                                      padding: EdgeInsets.zero,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                              width: 30, height: 30),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextField(
                        controller: queryCtrl,
                        style: TextStyle(color: _text, fontSize: 14),
                        onChanged: (v) => onQueryChanged(setSheet, v),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: r'输入 $ 搜索经文，输入 # 搜索话题',
                          hintStyle: TextStyle(color: _textHint),
                          prefixIcon: Icon(Icons.search,
                              size: 18, color: _textHint),
                          prefixIconConstraints:
                              const BoxConstraints.tightFor(
                                  width: 36, height: 36),
                          suffixIcon: queryCtrl.text.isEmpty
                              ? null
                              : GestureDetector(
                                  onTap: () {
                                    queryCtrl.clear();
                                    onQueryChanged(setSheet, '');
                                  },
                                  child: Icon(Icons.close,
                                      size: 16, color: _textHint),
                                ),
                          suffixIconConstraints:
                              const BoxConstraints.tightFor(
                                  width: 32, height: 32),
                          filled: true,
                          fillColor: _bg,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: _border)),
                          focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: _gold)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 190,
                        child: ListView(
                          children: [
                            if (trigger == r'$') ...[
                              if (sutraResults.isEmpty)
                                hintRow(queryCtrl.text.trim().length > 1
                                    ? '未找到相关经书'
                                    : r'输入经书名称开始搜索，例如：$地藏')
                              else
                                ...sutraResults.map((s) => InkWell(
                                      onTap: () => tryAdd(
                                          setSheet,
                                          _CustomToolbarItem(
                                              isSutra: true,
                                              name: s.title,
                                              path: s.filePath)),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 9),
                                        child: Row(
                                          children: [
                                            Icon(Icons.menu_book_rounded,
                                                size: 17, color: _gold),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(s.title,
                                                      maxLines: 1,
                                                      overflow: TextOverflow
                                                          .ellipsis,
                                                      style: TextStyle(
                                                          fontSize: 14,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: _text)),
                                                  if (s.folder.isNotEmpty) ...[
                                                    const SizedBox(height: 1),
                                                    Text(s.folder,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                            fontSize: 11,
                                                            color:
                                                                _textHint)),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )),
                            ] else if (trigger == '#') ...[
                              if (canCreateTopic)
                                InkWell(
                                  onTap: () => tryAdd(
                                      setSheet,
                                      _CustomToolbarItem(
                                          isSutra: false, name: topicQuery)),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 9),
                                    child: Row(
                                      children: [
                                        Icon(Icons.add, size: 17, color: _gold),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text('创建话题 #$topicQuery',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                  color: _text)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (topicResults.isEmpty && !canCreateTopic)
                                hintRow('输入话题名称，或从已有话题中选择')
                              else
                                ...topicResults.map((t) => InkWell(
                                      onTap: () => tryAdd(
                                          setSheet,
                                          _CustomToolbarItem(
                                              isSutra: false, name: t)),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 9),
                                        child: Row(
                                          children: [
                                            Icon(Icons.tag,
                                                size: 17, color: _gold),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text('#$t',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: _text)),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: FilledButton.styleFrom(
                            backgroundColor: _gold,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            elevation: 0,
                          ),
                          child:
                              const Text('完成', style: TextStyle(fontSize: 15)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    sheetOpen = false;
    debounce?.cancel();
    final savedName = nameCtrl.text.trim();
    // pop 之后底部弹窗仍在播放退出动画，TextField 还挂在树上；
    // 立即 dispose 控制器会触发「控制器被 dispose 后继续使用」红屏，
    // 故延迟到退出动画结束后再释放。
    Future.delayed(const Duration(milliseconds: 400), () {
      nameCtrl.dispose();
      queryCtrl.dispose();
    });
    if (result != true) {
      // 未保存（取消）：若原本展开则恢复面板。
      if (panelWasOpen) _openCustomPanel();
      return;
    }
    await _saveCustomTab(
        savedName.isEmpty ? '自定义' : savedName, List.of(items));
    // 保存后若原本展开且还有条目，重新展开面板以显示最新条目与「继续添加」行。
    if (panelWasOpen && items.isNotEmpty) _openCustomPanel();
  }

  void _openPlazaNote(PlazaNote note) {
    // 直接打开被点帖子自己的详情页：回复帖（b 类）的详情页本身就是
    // 「b 贴顶 + 祖先链藏在上方」的布局，无需再跳到原贴。
    // （旧逻辑跳 repostOf 指向的原贴：原贴刚被删除时会加载失败，
    // 回主页刷新后才能打开——已废弃。）
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)));
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
                    Icon(isError ? Icons.info_outline : Icons.check,
                        size: 16,
                        color: (!isError && AppPalette.instance.isPlain)
                            ? Colors.white
                            : _gold),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(
          width: 48,
          height: 48,
          child: FloatingActionButton(
            // 工具栏整行滚出视口后：按钮变为「回到顶部」；样式与添加笔记一致，仅图标不同。
            onPressed: _fabBackToTop
                ? scrollToTop
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const NoteEditPage()),
                    ).then((_) => _refreshCurrentSmooth()),
            heroTag: 'plaza_fab',
            // 素白外观下改黑色底 + 白色加号；暖黄保持青绿。
            backgroundColor: AppPalette.instance.isPlain
                ? const Color(0xFF1A1A1A)
                : const Color(0xFF71867A),
            elevation: 8,
            highlightElevation: 12,
            shape: const CircleBorder(),
            child: Image.asset(
              _fabBackToTop
                  ? 'assets/images/top.png'
                  : 'assets/images/write.png',
              width: 24,
              height: 24,
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: true,
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: _loadFeed,
              color: _gold,
              child: GestureDetector(
                // 左右滑动切换栏目：与纵向滚动在手势竞技场按方向共存；
                // 胶囊行等自身可横滑的区域会优先消费横向手势。
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v <= -300) _swipeToTab(_tabIndex + 1);
                  if (v >= 300) _swipeToTab(_tabIndex - 1);
                },
                child: CustomScrollView(
                  controller: _feedScroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    // 顶部栏（头像 + 图标 + 菩提空间）不固定：随内容一起向上滚走。
                    SliverToBoxAdapter(child: _buildTopBar()),
                    SliverPersistentHeader(
                      // 与个人主页同款：上滑时工具栏吸顶。
                      pinned: true,
                      delegate: _PlazaHeaderDelegate(
                        tabIndex: _tabIndex,
                        tabs: _plazaTabs,
                        onTabChanged: _onTabChanged,
                        customTabLabel: _customTabName,
                        customTabOpen: _customTabOpen,
                        onCustomTabPressed: _toggleCustomTab,
                        panelLink: _customPanelLink,
                        textScale: MediaQuery.textScalerOf(context).scale(1.0),
                      ),
                    ),
                    ..._buildFeedSlivers(),
                  ],
                ),
              ),
            ),
            // 滚动后顶部提醒条被隐藏时的悬浮按钮：回到顶部并刷新出新帖。
            // 工具栏吸顶后，提醒条需避开吸顶工具栏的高度。
            Positioned(
              top: (48 * MediaQuery.textScalerOf(context).scale(1.0))
                      .clamp(48.0, 88.0) +
                  8,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !_showNewPostPill,
                child: _showNewPostPill ? _buildNewPostPill() : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部栏：左侧头像（点击进入个人主页），「图标 + 菩提空间」整体水平居中，
  /// 右侧公告图标（有新公告时显示实体圆点角标，点击进入公告列表页）。
  /// 图标跟随外观：标题米黄 puti1 / 素白 puti2；公告米黄 gao1 / 素白 gao2。
  Widget _buildTopBar() {
    return GestureDetector(
      onDoubleTap: scrollToTop,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 居中：图标 + 菩提空间（不与头像挨着，图标 28、字号 19）。
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  AppPalette.instance.isPlain
                      ? 'assets/images/puti2.png'
                      : 'assets/images/puti1.png',
                  width: 28,
                  height: 28,
                ),
                const SizedBox(width: 6),
                Text(
                  '菩提空间',
                  style: TextStyle(
                    color: AppPalette.p.primary,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            // 左侧：头像（与主页左上角一致，打开「我的」页）。
            Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                // 不依赖 currentUser，避免冷启动会话未恢复时点击无反应。
                onTap: widget.onOpenMyPage,
                child: UserAvatar(
                  userId: AuthService.instance.currentUser.value?.id,
                  radius: 16,
                ),
              ),
            ),
            // 右侧：公告入口 + 未读角标。
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openAnnouncements,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Image.asset(
                        AppPalette.instance.isPlain
                            ? 'assets/images/gao2.png'
                            : 'assets/images/gao1.png',
                        width: 22,
                        height: 22,
                      ),
                      if (_hasUnreadAnnouncement)
                        Positioned(
                          top: -2,
                          right: -2,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFF70867A),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建当前栏目的笔记流 slivers。
  List<Widget> _buildFeedSlivers() {
    final tab = _plazaTabs[_tabIndex];
    // 热门栏目的顶部热门卡片：置于笔记流最上方。
    final hotCard = tab == 'discuss' ? _buildHotCardSliver() : null;
    final feedGroups = _feedGroups;
    final hasNotes = feedGroups.isNotEmpty;

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
            child: Center(child: _buildFeedAuthDead()),
          ),
        ];
      }
      if (_feedError) {
        return [
          if (hotCard != null) hotCard,
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: _buildFeedError()),
          ),
        ];
      }
      return [
        if (hotCard != null) hotCard,
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: _buildFeedEmpty()),
        ),
      ];
    }

    final feedLen = feedGroups.length;
    final showFooter = _feedLoading || !_feedHasMore || _feedError;
    return [
      if (hotCard != null) hotCard,
      if (_newPostCount > 0)
        SliverToBoxAdapter(child: _buildNewPostBanner()),
      SliverPadding(
        // 横向内边距放在列表层：分割线随内容缩进、不贴手机边缘（与话题页一致）。
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        sliver: SliverList(
          // 不用 ValueKey('feed_$version')：换 key 会销毁整个列表状态，
          // 新回复插入/后台刷新时表现为整页跳动。delegate 每次 build
          // 都会重建子项，无需 key 强制刷新；就地更新不改变滚动位置。
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final Widget body;
              if (index < feedLen) {
                final g = feedGroups[index];
                body = _buildFeedGroupCard(g);
              } else {
                body = _buildFeedFooter();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 帖子顶部分割线（首条不画，避免顶部多一条线）。
                  if (index > 0)
                    Divider(
                        height: 1, thickness: 0.5, color: AppPalette.p.divider),
                  body,
                ],
              );
            },
            childCount: feedLen + (showFooter ? 1 : 0),
            addRepaintBoundaries: true,
          ),
        ),
      ),
    ];
  }

  /// 「热门/推荐/关注」栏目顶部的新帖提醒：仅一行文字，点击立即把新帖插入列表顶部，
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
              style: TextStyle(fontSize: 12, color: _textHint)),
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
          style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w600, color: _text),
        ),
        const SizedBox(height: 6),
        Text(
          isDiscuss
              ? '发布带 #话题 或 \$经名 的帖子，就会出现在这里'
              : (isFollowing ? '关注同修后，这里会显示他们的新笔记' : '分享你的修学心得，让大家一起受益'),
          style: TextStyle(fontSize: 13, color: _textSec),
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

  /// 热门栏目顶部的热门卡片，三行布局：
  /// 第一行 4 个经文；第二行 4 个经文 + 「更多经文」入口；
  /// 第三行 4 个话题 + 「更多话题」入口。整块无标题文案、无边框线条。
  /// 数据未就绪（加载中/失败）时返回 null 不渲染，避免占位闪烁。
  Widget? _buildHotCardSliver() {
    if (_hotTopics.isEmpty && _hotSutras.isEmpty) return null;
    return SliverToBoxAdapter(
      child: Padding(
        // 与顶部栏目栏贴近：top 4。横向不留边距：
        // 胶囊行自身在滚动内容里带 16 内边距，左右滑动时可贴到屏幕边缘，
        // 不会在到达边缘前被裁切。
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 2),
        child: Container(
          // 两种外观均去掉包裹色块，仅由内部胶囊承载经文/话题。
          padding: const EdgeInsets.fromLTRB(0, 14, 0, 16),
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
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [_buildHotMoreChip(onMore, label: moreLabel)]),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // 左右内边距放在滚动内容里：初始位置仍缩进 16，
      // 但滑动时胶囊可一直贴到屏幕边缘，不会被提前裁切。
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 16),
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
      ),
    );
  }

  Widget _buildHotChip(HotDiscussionItem it,
      {required bool isSutra, bool showFire = false}) {
    final color = isSutra ? const Color(0xFF71867A) : const Color(0xFFcf9e66);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openHotDiscussion(it, isSutra: isSutra),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: AppPalette.instance.isPlain
              ? Colors.white
              : color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showFire)
              const Icon(Icons.local_fire_department,
                  size: 16, color: Color(0xFFD93B28))
            else
              Text(isSutra ? '\$' : '#',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: color)),
            Text(_hotSutraDisplayNames[it.name] ?? it.name,
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600, color: color)),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(fontSize: 13, color: _textSec)),
            Icon(Icons.chevron_right, size: 15, color: _textSec),
          ],
        ),
      ),
    );
  }

  /// 点击热门话题 / 经文胶囊：进入对应的话题页 / 经书讨论页。
  void _openHotDiscussion(HotDiscussionItem it, {required bool isSutra}) {
    if (isSutra) {
      // 条目名可能带卷标（「XX经卷二」）：解析出基础经名与该卷正文路径，
      // 打开对应卷的讨论页，保证与榜单计数口径一致。
      final (base, path) = resolveHotSutraTarget(it.name);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SutraDiscussionPage(
            title: base,
            filePath: path,
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

  Widget _buildFeedAuthDead() {
    return Padding(
      padding: const EdgeInsets.only(top: 60, bottom: 40),
      child: Column(
        children: [
          Icon(Icons.lock_clock_outlined, size: 52, color: _textHint),
          const SizedBox(height: 14),
          Text('登录已失效',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
          const SizedBox(height: 6),
          Text('请退出后重新登录，关注内容才能恢复显示',
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
  List<_FeedChainGroup> get _feedGroups {
    final me = AuthService.instance.currentUser.value;
    final followed = CloudNotesService.instance.followingUserIds;
    final byId = {for (final n in _feedNotes) n.id: n};
    final groups = <String, _FeedChainGroup>{};
    final order = <String>[];

    _FeedChainGroup groupFor(String attachId,
        {PlazaNote? note, bool deletedRoot = false}) {
      return groups.putIfAbsent(attachId, () {
        order.add(attachId);
        return _FeedChainGroup(note: note, deletedRoot: deletedRoot);
      });
    }

    for (final n in _feedNotes) {
      // 被屏蔽用户的内容（含原贴与被转发来源）一律不展示，避免缓存中残留数据仍可见；
      // 含被管理员删除话题的帖子同样隐藏。
      if (_isBlockedContent(n) || _isBannedNote(n)) continue;
      // 带墓碑记录的帖子（父帖被删后服务端转为 quote）仍按回复处理，
      // 以便在链中插入「这个帖子已删除」占位。
      if (n.repostKind != 'reply' && n.tombstoneAncestorIds.isEmpty) {
        groupFor(n.id, note: n);
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
        // 挂到可见祖先下。其墓碑记录（自上而下）即「祖先与本回复之间」
        // 被删掉的节点——如 b 删除后 c 重挂到 a：a → [b占位] → c。
        final g = groupFor(parentId, note: byId[parentId]);
        for (final t in n.tombstoneAncestorIds.reversed) {
          if (!g.tombs.contains(t)) g.tombs.add(t);
        }
        g.replies.add(n);
      } else if (_repostSourceBlocked(n)) {
        // 评论的原帖作者已被屏蔽：生成「已屏蔽用户」占位根帖，保留自己这条评论。
        final id = n.repostOf;
        final g = groupFor(id, note: PlazaNote(
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
        g.replies.add(n);
      } else if (n.tombstoneAncestorIds.isNotEmpty ||
          CloudNotesService.instance.locallyDeletedNoteIds
              .contains(n.repostOf)) {
        // 挂靠点已删除（服务端墓碑记录，或本机刚删除）：纯占位组，
        // 墓碑全列自上而下展示（a、b 都删时为 a占位 → b占位 → c）。
        final attachId = n.tombstoneAncestorIds.isNotEmpty
            ? n.tombstoneAncestorIds.first
            : n.repostOf;
        final g = groupFor(attachId, deletedRoot: true);
        for (final t in n.tombstoneAncestorIds.reversed) {
          if (!g.tombs.contains(t)) g.tombs.add(t);
        }
        if (g.tombs.isEmpty) g.tombs.add(attachId);
        g.replies.add(n);
      } else {
        groupFor(n.id, note: n);
      }
    }
    return [for (final id in order) groups[id]!];
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

  /// 分组卡片：根帖用「帖子」页同款样式（头像+昵称+指标+三点菜单），其下按
  /// 「『这个帖子已删除』占位行 → 回复链」顺序串起（占位行对应根与回复之间
  /// 被删掉的中间节点）；挂靠点已删除时整组只有占位行与回复。
  /// 所有连线下端到下一级头像统一留 6px。
  Widget _buildFeedGroupCard(_FeedChainGroup g) {
    final me = AuthService.instance.currentUser.value;
    // 根帖作者被屏蔽：上方显示「已屏蔽用户」占位，自己的评论仍连线在下方。
    if (g.note != null && _isBlockedContent(g.note!)) {
      return _buildBlockedGroupCard(g.note!, g.replies);
    }
    // 挂靠点已删除：纯占位组——一串占位行 + 下方回复。
    if (g.note == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < g.tombs.length; i++)
            Padding(
              // 首行留 6px 呼吸；行间零缝：端点间距由行内尾线处理。
              padding: EdgeInsets.only(top: i == 0 ? 6 : 0),
              child: _deletedPlaceholderRow(),
            ),
          if (g.replies.isNotEmpty) _groupReplyChain(g.replies),
        ],
      );
    }
    final root = g.note!;
    final hasBelow = g.tombs.isNotEmpty || g.replies.isNotEmpty;
    final isMine = me != null && root.ownerUserId == me.id;
    final rootWidget = PostFeedRow(
      note: root,
      onReplyPosted: (_) => _refreshCurrentSmooth(),
      onTap: () => _openPlazaNote(root),
      onEdit: isMine ? () => _editFeedNote(root) : null,
      onDelete: isMine ? () => _deleteFeedNote(root) : null,
      onMore: (n) => _showFeedReplyMenu(n),
      // 广场以浏览为主：他人帖子不显示关注按钮，关注/屏蔽收进三点菜单。
      showFollowButton: false,
      // 点击自己的头像/昵称：打开「我的」页。
      onOpenSelf: widget.onOpenMyPage,
    );
    if (!hasBelow) {
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
            // 连接线：原贴头像底部 → 下面第一个节点（占位行/回复）头像之间。
            // top:68 = 根帖外层顶内边距(6) + 头像区顶内边距(12) + 头像高(44) + 线上端留白(6)；
            // bottom:6 = 线下端距下一节点首个头像 6px。
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
        // 根与回复之间的「已删除」占位行（如 b 删除后：a → b占位 → c）。
        for (final _ in g.tombs) _deletedPlaceholderRow(),
        if (g.replies.isNotEmpty) _groupReplyChain(g.replies, root: root),
      ],
    );
  }

  Widget _groupReplyChain(List<PlazaNote> replies, {PlazaNote? root}) {
    return ReplyChain(
      replies: replies,
      parentAccounts: {
        if (root != null) root.id: root.authorAccount,
        for (final r in replies) r.id: r.authorAccount,
      },
      // 点击回复节点进入该回复自己的详情页（原贴在上），它的直接回复列在下方。
      onComment: (n) => replyToNote(context, n, (_) => _refreshCurrentSmooth()),
      onLike: (n) => likeTargetNote(context, n, (_) => _refreshCurrentSmooth()),
      onRepost: (n) => forwardNote(context, n, (_) => _refreshCurrentSmooth()),
      onMore: (n) => _showFeedReplyMenu(n),
      // 点击自己的头像/昵称：打开「我的」页。
      onOpenSelf: widget.onOpenMyPage,
    );
  }

  /// 「这个帖子已删除」占位行：垃圾桶头像 + 固定长度下延尾线（末端留 6px
  /// 到下一级头像）+ 与头像顶部对齐的提示框；内容不可见、不可点击。
  Widget _deletedPlaceholderRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: Color(0x1A8B6B5A),
              child: Icon(Icons.delete_outline, size: 22, color: _textSec),
            ),
            // 固定长度下延线段 + 末端 6px：占位卡矮，Expanded 会被压没；
            // 行间零缝拼接时靠这 6px 保持「线端点—头像」间距。
            const SizedBox(height: 6),
            Container(width: 1, height: 20, color: const Color(0xFFC9C9C9)),
            const SizedBox(height: 6),
          ],
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border.all(color: _border),
              borderRadius: BorderRadius.circular(8),
              color: _bg,
            ),
            child: Row(
              children: [
                Icon(Icons.delete_outline, size: 16, color: _textSec),
                const SizedBox(width: 8),
                Text('这个帖子已删除',
                    style: TextStyle(fontSize: 14, color: _textSec)),
              ],
            ),
          ),
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
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: Color(0x1A8B6B5A),
                    child: Icon(Icons.block, size: 22, color: _textSec),
                  ),
                  if (replies.isNotEmpty) ...[
                    // 固定长度下延线段 + 末端 6px：连向下方 ReplyChain 首个头像
                    //（占位卡矮，Stack 覆盖线会被压没；端点间距与删除占位一致）。
                    const SizedBox(height: 6),
                    Container(width: 1, height: 20, color: const Color(0xFFC9C9C9)),
                    const SizedBox(height: 6),
                  ],
                ],
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
                    child: Row(
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
        if (replies.isNotEmpty) _groupReplyChain(replies, root: root),
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
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            Divider(height: 1, color: _border),
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
        title: Text('删除帖子',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: Text('删除后帖子将从菩提空间移除，且无法恢复。确定删除吗？',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: _textSec)),
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
      // 同步当前栏目缓存：否则切走再切回时 _restoreFeedFromCache 会把
      // 已删除的帖子从旧缓存里恢复出来（表现为删了又跳回来）。
      _saveFeedToCache(_plazaTabs[_tabIndex]);
      _showTopToast('已删除');
    } catch (e) {
      if (mounted) _showTopToast(e.toString());
    }
  }
}

class _PlazaHeaderDelegate extends SliverPersistentHeaderDelegate {
  final int tabIndex;
  final List<String> tabs;
  final ValueChanged<int> onTabChanged;

  /// 自定义栏目名：常显；条目为空时点击进添加面板。
  final String customTabLabel;
  final bool customTabOpen;
  final VoidCallback onCustomTabPressed;

  /// 悬浮下拉面板的锚点：面板经此锚定在工具栏下边缘。
  final LayerLink panelLink;
  final double textScale;

  const _PlazaHeaderDelegate({
    required this.tabIndex,
    required this.tabs,
    required this.onTabChanged,
    required this.customTabLabel,
    this.customTabOpen = false,
    required this.onCustomTabPressed,
    required this.panelLink,
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
    return CompositedTransformTarget(
      // 悬浮下拉面板锚定在工具栏下边缘，随工具栏一起滚动。
      link: panelLink,
      child: Container(
        width: double.infinity,
        color: _bg,
        child: Column(
          children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
              child: Row(
                // 底对齐：选中态金色短横杆与工具栏底部横线刚好接触。
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 与个人主页同款分布：栏目均分整行宽度。
                  for (var i = 0; i < tabs.length; i++)
                    _buildTab(
                      context,
                      _plazaTabMeta[tabs[i]] ?? tabs[i],
                      // 自定义面板展开时固定栏目保持失活：
                      // 金色短杠只出现在自定义栏目下。
                      selected: tabIndex == i && !customTabOpen,
                      onTap: () => onTabChanged(i),
                    ),
                  if (customTabLabel.isNotEmpty)
                    _buildTab(
                      context,
                      customTabLabel,
                      selected: customTabOpen,
                      onTap: onCustomTabPressed,
                      // 自定义为三字栏目：短线比三字宽度再大一些才协调。
                      underlineWidth: 52,
                      trailingIcon: Icon(
                        customTabOpen
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 15,
                        color: customTabOpen ? _text : _textSec,
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 工具栏下边缘横线：仅素白外观显示（米黄外观不加横线），
          // 样式与帖子分割线一致、横向贴满手机两边，栏目按钮刚好位于其上方。
          if (AppPalette.instance.isPlain)
            Divider(height: 1, thickness: 0.5, color: AppPalette.p.divider),
          ],
        ),
      ),
    );
  }

  /// 与个人主页同款栏目按钮：均分宽度、字号 15、金色短线 36×3。
  /// [underlineWidth] 可按栏目字数加宽（如三字自定义栏目用更宽的短线）。
  Widget _buildTab(BuildContext context, String label,
      {required bool selected,
      required VoidCallback onTap,
      double underlineWidth = 36,
      Widget? trailingIcon}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected ? _text : _textSec,
                      ),
                    ),
                  ),
                  if (trailingIcon != null) trailingIcon,
                ],
              ),
              const SizedBox(height: 3),
              // 下行文字旁有箭头图标时，Column 会把短线居中在「文字 + 箭头」整体上，
              // 导致短线偏右、不居中文案。向左平移半箭头宽，让短线居中在文字正下方。
              Transform.translate(
                offset: Offset(trailingIcon != null ? -7.5 : 0, 0),
                child: Container(
                  width: underlineWidth,
                  height: 3,
                  decoration: BoxDecoration(
                    color: selected ? _gold : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _PlazaHeaderDelegate oldDelegate) =>
      oldDelegate.tabIndex != tabIndex ||
      oldDelegate.textScale != textScale ||
      oldDelegate.customTabLabel != customTabLabel ||
      oldDelegate.customTabOpen != customTabOpen ||
      oldDelegate.tabs.join(',') != tabs.join(',');
}

/// 菩提空间信息流分组视图模型：一个「根帖 + 其下回复链」的挂靠单元。
/// [note] 为空表示挂靠点本身已删除（纯占位组：只有占位行与回复）；
/// [tombs] 为根/挂靠点与回复之间被删节点 id（自上而下，渲染为占位行，
/// 如 b 删除后 c 重挂到 a：a → b占位 → c）；[deletedRoot] 仅作渲染分支标记。
class _FeedChainGroup {
  _FeedChainGroup({this.note, this.deletedRoot = false});
  final PlazaNote? note;
  final bool deletedRoot;
  final List<String> tombs = [];
  final List<PlazaNote> replies = [];
}

/// 公告列表页：菩提空间右上角公告图标进入，展示管理员公告（最新在前），
/// 点击单条进入公告详情页（可评论互动）。支持下拉刷新。
class AnnouncementListPage extends StatefulWidget {
  const AnnouncementListPage({super.key});

  @override
  State<AnnouncementListPage> createState() => _AnnouncementListPageState();
}

class _AnnouncementListPageState extends State<AnnouncementListPage> {
  List<AnnouncementItem> _announcements = [];
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = false;
      });
    }
    try {
      final list = await CloudNotesService.instance.getAnnouncements();
      if (!mounted) return;
      setState(() {
        _announcements = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
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
        iconTheme: IconThemeData(color: _text),
        title: Text(
          '公告',
          style: TextStyle(
            color: AppPalette.p.primary,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: _gold,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (_loading && _announcements.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child:
                        CircularProgressIndicator(strokeWidth: 2.2, color: _gold),
                  ),
                ),
              )
            else if (_error && _announcements.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cloud_off_outlined,
                          size: 44, color: _textHint),
                      const SizedBox(height: 12),
                      Text('加载失败，请下拉重试',
                          style: TextStyle(fontSize: 13, color: _textSec)),
                    ],
                  ),
                ),
              )
            else if (_announcements.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: _buildEmpty()),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _buildCard(_announcements[index]),
                    childCount: _announcements.length,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(AnnouncementItem item) {
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
                    noteId: item.id, isAnnouncement: true)),
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
                      child: Text('公告',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.p.accentDeep)),
                    ),
                    const Spacer(),
                    Text(_formatTime(item.createdAt),
                        style: TextStyle(fontSize: 11, color: _textHint)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  item.title,
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text),
                ),
                const SizedBox(height: 6),
                Text(
                  item.content,
                  style: TextStyle(fontSize: 14, color: _textSec, height: 1.6),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.forum_outlined, size: 14, color: _textHint),
                    const SizedBox(width: 4),
                    Text('点击查看评论与互动',
                        style: TextStyle(fontSize: 12, color: _textHint)),
                    const Spacer(),
                    Icon(Icons.chevron_right, size: 16, color: _textHint),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: _gold.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.campaign_outlined,
              size: 30, color: AppPalette.p.accentDeep),
        ),
        const SizedBox(height: 16),
        Text('暂无公告',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
        const SizedBox(height: 8),
        Text('管理员发布的公告将在这里显示',
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
}
