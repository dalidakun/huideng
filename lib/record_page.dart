import 'dart:async';

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'auth_service.dart';
import 'note_sutra_links.dart';
import 'record_cards.dart';
import 'record_index.dart';
import 'sutra_list_page.dart'
    show chineseVolumeSuffixRe, sutraDisplayNameWithVolume;
import 'user_avatar.dart';

/// 纯 CBETA 编号（如「T13n0412_002」），即记录里只存了编号、没有经名。
final RegExp _bareSutraIdRe = RegExp(r'^T\d+n[0-9A-Za-z]+_\d+$');

/// 经名展示名：与经藏列表 / 读经页统一为「经名 + 卷X」，页面上不出现 CBETA 编号。
///
/// 记录的 sutraKey 有三种来源形态，都归一到同一个显示名：
/// - 「地藏菩萨本本愿经T13n0412_002」：经藏列表进入，带编号 → 「地藏菩萨本愿经卷二」
/// - 「地藏菩萨本愿经卷二」：从 $引用 / 讨论帖进入，已经是显示名 → 原样
/// - 「T13n0412_002」：只有编号 → 按目录 [rawTitles] 反查经名后再套卷标
String recordSutraDisplayName(
  String key, {
  Set<String>? multiVolumeBases,
  Iterable<String> rawTitles = const [],
}) {
  final t = key.trim();
  if (t.isEmpty) return '';
  // 已经是「经名 + 中文卷标」，直接用（编号已在别处处理过）。
  if (chineseVolumeSuffixRe.hasMatch(t)) return t;
  var full = t;
  if (_bareSutraIdRe.hasMatch(t)) {
    for (final raw in rawTitles) {
      if (raw.endsWith(t)) {
        full = raw;
        break;
      }
    }
  }
  final name =
      sutraDisplayNameWithVolume(full, multiVolumeBases: multiVolumeBases);
  // 去掉编号后经名为空（未知编号 / 脏数据）：原样返回，别把内容显示没了。
  return name.isEmpty ? t : name;
}

/// 「记录」标签页：把读经时留下的**画线 / 感想 / 笔记**按时间先后汇成一条流水。
///
/// 数据源是本地 [RecordIndex]（写入时顺手记下的动作时间戳），因此首屏秒开、
/// 离线可用；三种记录各用各的版式（见 record_cards.dart）。
class RecordPage extends StatefulWidget {
  /// 左上角头像入口：打开左侧个人菜单。
  final VoidCallback? onOpenSideMenu;

  const RecordPage({super.key, this.onOpenSideMenu});

  @override
  State<RecordPage> createState() => RecordPageState();
}

class RecordPageState extends State<RecordPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scrollCtrl = ScrollController();

  String _query = '';
  bool _loading = true;

  /// 搜索框是否展开：默认收起，只在点右上角搜索按钮后于标题栏下方浮出。
  bool _searchVisible = false;

  /// 搜索防抖：每敲一键都重建上千行太浪费，攒到 [_debounceMs] 再真正过滤。
  static const Duration _debounceMs = Duration(milliseconds: 180);
  Timer? _searchDebounce;

  List<RecordItem> _items = const [];

  /// 多卷经书基础经名集合（来自随包目录），决定经名是否补「卷X」。
  Set<String> _multiVolumeBases = const {};

  /// 目录里的完整经名（含编号），用于只有编号时反查经名。
  List<String> _rawTitles = const [];

  /// sutraKey -> 显示名，避免每帧重复计算。
  final Map<String, String> _nameCache = {};

  /// 行列表的记忆化：只有「索引版本 / 关键词 / 经名表」三者之一变了才重算。
  ///
  /// [RecordIndex.items] 是**活的**零拷贝视图，读经页写入新记录时它会当场变化，
  /// 所以用索引自增的 [RecordIndex.revision] 做版本号来判定失效 ——
  /// 既不会在每次 reload 里为比较内容而多走一趟 O(n)，
  /// 也不会在索引变了之后拿旧行列表糊弄用户。
  int _rowsRevCache = -1;
  String _rowsQueryCache = '';
  List<_Row>? _rowsCache;

  /// 展开状态：经文引用、感想正文、笔记正文各自独立。
  final Set<String> _paraExpanded = {};
  final Set<String> _thoughtExpanded = {};
  final Set<String> _noteExpanded = {};

  @override
  void initState() {
    super.initState();
    // 首次进入即与本地 `notes` 全量对账，历史笔记直接出现在时间线上。
    unawaited(reload(syncNotes: true));
    unawaited(_loadSutraNames());
    // ListView.builder 没有 onScroll 参数，用控制器监听滚动位置放行下一页。
    _scrollCtrl.addListener(_onScroll);
  }

  /// 离底部还有一屏时预先放行下一批，避免滑到底看到空白。
  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - _pageSize * 80) {
      _loadMore();
    }
  }

  /// 收起搜索：关闭键盘、清空关键词并把搜索框收回头像旁那个按钮的状态。
  ///
  /// 点搜索框以外的区域（列表、标题空白处）时调用；已是收起态就直接返回，
  /// 免得每点一次列表都重建整页。
  void _dismissSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = null;
    if (_searchFocus.hasFocus) _searchFocus.unfocus();
    if (!_searchVisible && _query.isEmpty) return;
    _searchCtrl.clear();
    setState(() {
      _searchVisible = false;
      _query = '';
    });
  }

  /// 右上角搜索按钮：展开 / 收起搜索框，展开后顺带把光标放进输入框。
  void _toggleSearch() {
    if (_searchVisible) {
      _dismissSearch();
      return;
    }
    setState(() => _searchVisible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  /// 搜索框输入：只起防抖，不重建页面。列表按 [_query] 记忆化，
  /// 真正过滤推迟到 [_debounceMs] 之后。
  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_debounceMs, () {
      _searchDebounce = null;
      if (!mounted || _query == value) return;
      setState(() => _query = value);
    });
  }

  /// 点「搜索」键：立刻生效，不再等防抖。
  void _onSearchSubmitted(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = null;
    _searchFocus.unfocus();
    if (!mounted || _query == value) return;
    setState(() => _query = value);
  }

  /// 行列表记忆化失效：改关键词、或经名表补齐后都要重算。
  void _invalidateRows() {
    _rowsRevCache = -1;
    _rowsCache = null;
  }

  /// 加载随包目录里的多卷经名集合，供经名统一成「经名 + 卷X」。
  Future<void> _loadSutraNames() async {
    try {
      await NoteSutraCatalog.load();
    } catch (_) {
      // 目录读不到时按「不加卷标」降级，不影响记录本身。
    }
    if (!mounted) return;
    setState(() {
      _multiVolumeBases = NoteSutraCatalog.cachedMultiVolumeBases;
      _rawTitles = NoteSutraCatalog.cachedRawTitles;
      _nameCache.clear();
      // 经名显示变了，按经名匹配的搜索结果也要跟着重算。
      _invalidateRows();
    });
  }

  /// 一条记录的经名显示：通常只有一本经，多本时用「·」并列。
  String _sutraNameOf(RecordItem it) {
    if (it.sutraKeys.isEmpty) return '未标注经名';
    return it.sutraKeys.map(_displayName).join(' · ');
  }

  String _displayName(String key) => _nameCache.putIfAbsent(
        key,
        () => recordSutraDisplayName(
          key,
          multiVolumeBases: _multiVolumeBases,
          rawTitles: _rawTitles,
        ),
      );

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 重新载入索引；[syncNotes] 为 true 时顺带与本地 `notes` 全量对账。
  Future<void> reload({bool syncNotes = false}) async {
    if (!mounted) return;
    if (syncNotes) {
      await RecordIndex.instance.syncNotesFromPrefs();
    }
    await RecordIndex.instance.load();
    if (!mounted) return;
    setState(() {
      _items = _sorted(RecordIndex.instance.items);
      _loading = false;
      // 重新载入会带入新条目，分页进度回到首屏长度，让新内容可见；
      // 否则它可能落在已展开窗口之外，看起来像「同步了但什么都没多」。
      _visibleCount = _pageSize;
      _invalidateRows();
    });
    if (_scrollCtrl.hasClients) {
      // 列表变短时把滚动位置收回有效范围，避免空白。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollCtrl.hasClients) return;
        final pos = _scrollCtrl.offset;
        if (pos > _scrollCtrl.position.maxScrollExtent) {
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        }
      });
    }
  }

  /// 时间倒序、同刻按 id 升序。
  ///
  /// 索引本身已按时间升序维护，倒序几乎总是「已经有序」，所以先线性探一遍，
  /// 命中就直接复用原列表，省掉一次 n 元素的复制 + 排序。
  static List<RecordItem> _sorted(List<RecordItem> src) {
    for (var i = 1; i < src.length; i++) {
      if (_compareDesc(src[i - 1], src[i]) > 0) {
        final out = List<RecordItem>.of(src);
        out.sort(_compareDesc);
        return out;
      }
    }
    return src;
  }

  static int _compareDesc(RecordItem a, RecordItem b) {
    final byTime = b.createdAt.compareTo(a.createdAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  }

  // ── 过滤与分组 ────────────────────────────────────────

  /// 首屏只渲染 [_pageSize] 条，往下滚再逐步放出来。
  ///
  /// 时间线上万条很常见，全部铺进 ListView.builder 虽然能跑，但首次要过滤、
  /// 分组、展开 _Row，滑动时也一直背着这个开销。分批放行后首屏只剩几十条，
  /// 后续按需追加。
  static const int _pageSize = 30;
  int _visibleCount = _pageSize;

  List<RecordItem> get _filtered {
    final q = _query.trim();
    final list = q.isEmpty
        ? _items
        : _items.where((i) {
            // 经名按显示名匹配（用户看到的是「地藏菩萨本愿经卷二」而不是编号）。
            if (_sutraNameOf(i).contains(q)) return true;
            if (i.sutraKeys.any((k) => k.contains(q))) return true;
            return i.text.contains(q) || i.paraText.contains(q);
          }).toList();
    // 搜索时结果通常很少，截断反而会漏掉本该命中的条目，因此只在无搜索时分页。
    if (q.isNotEmpty) return list;
    return list.length > _visibleCount ? list.sublist(0, _visibleCount) : list;
  }

  /// 滚到底部时多放一屏。
  void _loadMore() {
    if (_visibleCount >= _items.length) return;
    setState(() => _visibleCount += _pageSize);
  }

  /// 展示用的行列表（日期分组头 + 记录），带记忆化。
  List<_Row> get _rows {
    final rev = RecordIndex.instance.revision.value;
    final cached = _rowsCache;
    if (cached != null && _rowsRevCache == rev && _rowsQueryCache == _query) {
      return cached;
    }
    final rows = _buildRows(_filtered);
    _rowsRevCache = rev;
    _rowsQueryCache = _query;
    _rowsCache = rows;
    return rows;
  }

  /// 把记录展平成「日期分组头 + 记录」的行列表，供 ListView.builder 使用。
  List<_Row> _buildRows(List<RecordItem> items) {
    final rows = <_Row>[];
    String? lastLabel;
    for (final it in items) {
      final label =
          _dateLabel(DateTime.fromMillisecondsSinceEpoch(it.createdAt));
      if (label != lastLabel) {
        rows.add(_Row.header(label));
        lastLabel = label;
      }
      rows.add(_Row.item(it));
    }
    return rows;
  }

  static String _dateLabel(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (dt.year == now.year) return '${dt.month}月${dt.day}日';
    return '${dt.year}年${dt.month}月${dt.day}日';
  }

  /// 卡片内时间：分组头已给出日期，这里只显示时分；跨日补上月日。
  String _timeLabel(RecordItem it) {
    final dt = DateTime.fromMillisecondsSinceEpoch(it.createdAt);
    final now = DateTime.now();
    final hm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return hm;
    }
    if (dt.year == now.year) return '${dt.month}/${dt.day} $hm';
    return '${dt.year}/${dt.month}/${dt.day}';
  }

  // ── 构建 ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final rows = _rows;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: IconThemeData(color: p.text),
        titleSpacing: 0,
        title: Padding(
          // 稍离左边缘，避免头像贴边。
          padding: const EdgeInsets.only(left: 14),
          // 点标题空白处也收起搜索与键盘（头像自身的点击在外层之内优先）。
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismissSearch,
            child: Row(
              children: [
                GestureDetector(
                  onTap: widget.onOpenSideMenu,
                  child: UserAvatar(
                    userId: AuthService.instance.currentUser.value?.id,
                    radius: 16,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '笔记',
                  style: TextStyle(
                    color: p.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
              Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  // 低饱和浅灰，弱化存在感。
                  color: Color(0xFFC6C6C6),
                  shape: BoxShape.circle,
                ),
              ),
                const SizedBox(width: 5),
                Text(
                  '应无所住，而生其心。',
                  style: TextStyle(color: p.textSec, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ),
        actions: [
          // 常态只留一个搜索入口，搜索框本身按需浮出。
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                tooltip: _searchVisible ? '收起搜索' : '搜索笔记',
                icon: Icon(
                  _searchVisible ? Icons.close : Icons.search,
                  size: 20,
                  color: p.text,
                ),
                onPressed: _toggleSearch,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                splashRadius: 16,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索框不再常驻顶部，展开时从标题栏下方浮出。
          if (_searchVisible)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: _buildSearchField(p),
            ),

          Expanded(
            // 点搜索框以外的列表/空白区域：收起搜索与键盘。
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _dismissSearch,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : rows.isEmpty
                      ? _buildEmpty(p)
                      : RefreshIndicator(
                          onRefresh: () => reload(syncNotes: true),
                          child: ListView.builder(
                            controller: _scrollCtrl,
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                            itemCount: rows.length,
                            itemBuilder: (context, i) {
                              final row = rows[i];
                              final item = row.item;
                              if (item == null) {
                                return RecordDateHeader(label: row.label!);
                              }
                              return _buildCard(item, p);
                            },
                          ),
                        ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(RecordItem item, PaletteData p) {
    final sutraName = _sutraNameOf(item);
    switch (item.type) {
      case RecordType.highlight:
        return HighlightRecordCard(
          item: item,
          sutraName: sutraName,
          timeText: _timeLabel(item),
        );
      case RecordType.thought:
        return ThoughtRecordCard(
          item: item,
          sutraName: sutraName,
          timeText: _timeLabel(item),
          paraExpanded: _paraExpanded.contains(item.id),
          noteExpanded: _thoughtExpanded.contains(item.id),
          onTogglePara: () => setState(() {
            _paraExpanded.contains(item.id)
                ? _paraExpanded.remove(item.id)
                : _paraExpanded.add(item.id);
          }),
          onToggleNote: () => setState(() {
            _thoughtExpanded.contains(item.id)
                ? _thoughtExpanded.remove(item.id)
                : _thoughtExpanded.add(item.id);
          }),
        );
      case RecordType.note:
        return SutraNoteRecordCard(
          item: item,
          sutraName: sutraName,
          timeText: _timeLabel(item),
          expanded: _noteExpanded.contains(item.id),
          onToggleExpand: () => setState(() {
            _noteExpanded.contains(item.id)
                ? _noteExpanded.remove(item.id)
                : _noteExpanded.add(item.id);
          }),
        );
    }
  }

  Widget _buildEmpty(PaletteData p) {
    final searching = _query.trim().isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                searching
                    ? '没有匹配「$_query」的记录'
                    : '还没有任何记录\n读经时选中文字「画线」、写下「感想」或「笔记」，都会按时间汇集到这里',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.7,
                  color: p.textHint,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField(PaletteData p) {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border, width: 0.8),
      ),
      child: TextField(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        textAlignVertical: TextAlignVertical.center,
        style: TextStyle(fontSize: 14, color: p.text),
        decoration: InputDecoration(
          hintText: '搜索经名或记录内容',
          hintStyle: TextStyle(fontSize: 14, color: p.textHint),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 10, right: 6),
            child: Icon(Icons.search, color: p.textHint, size: 18),
          ),
          // 不放清除叉号：搜索激活时右上角那个按钮本身就是叉号。
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        onChanged: _onSearchChanged,
        onSubmitted: _onSearchSubmitted,
      ),
    );
  }
}

/// 时间线的一行：要么是日期分组头，要么是一条记录。
class _Row {
  const _Row.header(this.label) : item = null;
  const _Row.item(this.item) : label = null;

  final String? label;
  final RecordItem? item;
}
