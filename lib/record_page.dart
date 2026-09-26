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

  /// 云端回填进度。
  bool _backfilling = false;
  int _backfillDone = 0;
  int _backfillTotal = 0;

  bool _menuOpen = false;

  List<RecordItem> _items = const [];

  /// 多卷经书基础经名集合（来自随包目录），决定经名是否补「卷X」。
  Set<String> _multiVolumeBases = const {};

  /// 目录里的完整经名（含编号），用于只有编号时反查经名。
  List<String> _rawTitles = const [];

  /// sutraKey -> 显示名，避免每帧重复计算。
  final Map<String, String> _nameCache = {};

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
    _searchCtrl.dispose();
    _searchFocus.dispose();
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

  static List<RecordItem> _sorted(List<RecordItem> src) {
    final out = List<RecordItem>.of(src);
    out.sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return out;
  }

  // ── 过滤与分组 ────────────────────────────────────────

  List<RecordItem> get _filtered {
    final q = _query.trim();
    if (q.isEmpty) return _items;
    return _items.where((i) {
      // 经名按显示名匹配（用户看到的是「地藏菩萨本愿经卷二」而不是编号）。
      if (_sutraNameOf(i).contains(q)) return true;
      if (i.sutraKeys.any((k) => k.contains(q))) return true;
      return i.text.contains(q) || i.paraText.contains(q);
    }).toList();
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

  // ── 云端回填 ───────────────────────────────────────────

  Future<void> _backfill() async {
    if (_backfilling) return;
    if (!AuthService.instance.isLoggedIn) {
      _toast('登录后才能从云端补全历史记录');
      return;
    }
    setState(() {
      _menuOpen = false;
      _backfilling = true;
      _backfillDone = 0;
      _backfillTotal = 0;
    });
    final added = await RecordIndex.instance.backfillFromCloud(
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _backfillDone = done;
          _backfillTotal = total;
        });
      },
    );
    if (!mounted) return;
    setState(() => _backfilling = false);
    await reload();
    if (!mounted) return;
    _toast(added > 0 ? '已补全 $added 条历史记录' : '没有新的历史记录');
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ── 构建 ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final items = _filtered;
    final rows = _buildRows(items);
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: IconThemeData(color: p.text),
        titleSpacing: 0,
        title: Row(
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
              '记录',
              style: TextStyle(
                color: p.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        actions: [
          Stack(
            children: [
              IconButton(
                tooltip: '补全历史',
                icon: Icon(Icons.more_horiz, size: 22, color: p.text),
                onPressed: () => setState(() => _menuOpen = !_menuOpen),
              ),
              if (_menuOpen)
                Positioned(
                  top: 46,
                  right: 8,
                  child: Material(
                    elevation: 6,
                    borderRadius: BorderRadius.circular(12),
                    color: p.card,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _menuTile(
                          icon: const Icon(Icons.cloud_sync_outlined, size: 18),
                          label: '从云端补全历史',
                          onTap: _backfill,
                        ),
                        _menuTile(
                          icon: const Icon(Icons.refresh, size: 18),
                          label: '刷新',
                          onTap: () {
                            setState(() => _menuOpen = false);
                            unawaited(reload(syncNotes: true));
                          },
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: _buildSearchField(p),
          ),
          if (_backfilling)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _backfillTotal > 0
                          ? '正在补全历史记录 $_backfillDone/$_backfillTotal 部经…'
                          : '正在补全历史记录…',
                      style: TextStyle(fontSize: 14, color: p.textSec),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
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
          suffixIcon: _query.isEmpty
              ? null
              : GestureDetector(
                  onTap: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Icon(Icons.close, color: p.textHint, size: 18),
                  ),
                ),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        onChanged: (v) => setState(() => _query = v),
        onSubmitted: (_) => _searchFocus.unfocus(),
      ),
    );
  }

  Widget _menuTile({
    required Widget icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final p = AppPalette.p;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconTheme(data: IconThemeData(color: p.text), child: icon),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: p.text, fontSize: 14)),
          ],
        ),
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
