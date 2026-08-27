import 'package:flutter/material.dart';

import 'cloud_notes_service.dart';
import 'loading_widgets.dart';
import 'note_sutra_links.dart';
import 'post_rich_content.dart';
import 'sutra_list_page.dart';

import 'app_palette.dart';
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
/// 右侧显示帖子数，点击进入对应的经书讨论页 / 话题页。样式仿新闻热搜榜。
/// 管理员在话题榜上长按话题可删除（进回收站），右上角回收站可恢复。
class HotDiscussionListPage extends StatefulWidget {
  final bool isSutra;
  final String title;
  final List<HotDiscussionItem> items;

  const HotDiscussionListPage({
    super.key,
    required this.isSutra,
    required this.title,
    required this.items,
  });

  @override
  State<HotDiscussionListPage> createState() => _HotDiscussionListPageState();
}

class _HotDiscussionListPageState extends State<HotDiscussionListPage> {
  late List<HotDiscussionItem> _items;
  bool _isAdmin = false;
  // 热门经文的基础经名 → 显示名（含卷标），用于榜单显示。
  Map<String, String> _displayNames = const {};
  // 每页 50 条，用户点击「查看更多」再展示下一页 50 条，
  // 直到全部展示完。避免一次性渲染超长榜单。
  static const int _pageStep = 50;
  int _visibleCount = _pageStep;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    // 按热度分从高到低排列：越靠上的热度越大，火把越多。
    // 已被管理员删除的话题直接剔除，避免热门榜残留展示。
    final bans = CloudNotesService.instance.bannedTopicNames;
    // 经文榜先按基础经名归一化合并：「XX经卷一」与「XX经」并入同一条目。
    final source =
        widget.isSutra ? mergeHotSutraItems(widget.items) : widget.items;
    final raw = (bans.isEmpty
            ? source
            : source.where((it) => !bans.contains(it.name)))
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    _items = raw;
    NoteSutraCatalog.load();
    CloudNotesService.instance.isAdmin().then((ok) {
      if (mounted) setState(() => _isAdmin = ok);
    });
    // 初始列表也构建卷标映射，避免 _refresh 完成前短暂显示无卷标名称。
    buildSutraDisplayNameMap(raw, isSutra: widget.isSutra).then((names) {
      if (mounted) setState(() => _displayNames = names);
    });
    // 主动重新拉取热门榜：父页传来的 widget.items 可能是旧快照
    // （刚发布带新 #话题/$经名的帖子，父页还没刷新），这里拉一次保证
    // 新发布的话题/经书能立即在被打开的热度榜页里展示。
    _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final (topics, sutras) =
          await CloudNotesService.instance.getHotDiscussions();
      // 经文榜按基础经名归一化合并，话题榜保持原样。
      final all = widget.isSutra ? mergeHotSutraItems(sutras) : topics;
      // 经文榜要再过一遍经书目录白名单（与 study_hub_page 同款），
      // 话题榜要剔掉管理员已删除的话题。
      final titleMap = NoteSutraCatalog.cachedTitleMap ?? const {};
      final bans = CloudNotesService.instance.bannedTopicNames;
      final valid = widget.isSutra
          ? all.where((s) => titleMap.containsKey(s.name)).toList()
          : (bans.isEmpty
              ? all
              : all.where((t) => !bans.contains(t.name)).toList())
        ..sort((a, b) => b.score.compareTo(a.score));
      final enhanced =
          await buildSutraDisplayNameMap(valid, isSutra: widget.isSutra);
      if (!mounted) return;
      setState(() {
        _items = valid;
        _displayNames = enhanced;
        _refreshing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _refreshing = false);
    }
  }

  /// 按名次取火把数：仅前三名显示火把——第 1 名 5 把、第 2 名 4 把、第 3 名 3 把；
  /// 第 4 名起不再显示火把，改在名称右侧展示「讨论x个」。
  static int _flamesByRank(int index) => index < 5 ? 5 - index : 1;

  /// 火把：按名次取数量，颜色从橙黄到红渐变，模拟真实火簇。
  /// 第一名整体用红色并放大，突出榜首。
  static const List<Color> _flameColors = [
    Color(0xFFF6A93B),
    Color(0xFFF0812B),
    Color(0xFFE45B2E),
    Color(0xFFD93B28),
  ];

  Widget _buildFlames(int level, {bool firstPlace = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < level; i++)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Icon(Icons.local_fire_department,
                size: firstPlace ? 18 : 15,
                color: firstPlace
                    ? const Color(0xFFD93B28)
                    : _flameColors[i % _flameColors.length]),
          ),
      ],
    );
  }

  Color get _accent => widget.isSutra
      ? const Color(0xFF71867A)
      : const Color(0xFFcf9e66);

  String get _prefix => widget.isSutra ? r'$' : '#';

  /// 顶部摘要文案：总榜单按客户端可见数显示，避免渲染超长数字。
  String get _totalLabel => '${_items.length}';

  void _open(HotDiscussionItem it) {
    if (widget.isSutra) {
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

  /// 管理员长按话题：删除话题，含该话题的帖子全端隐藏，可进回收站恢复。
  Future<void> _deleteTopic(HotDiscussionItem it) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: const Text('删除话题',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Text('删除 #${it.name} 后，含该话题的帖子将在广场、讨论、关注、发现中隐藏，可到右上角回收站恢复。',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('取消', style: TextStyle(color: _textSec))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Color(0xFFC0392B)))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await CloudNotesService.instance.deleteTopic(it.name);
      if (!mounted) return;
      setState(() => _items.removeWhere((x) => x.name == it.name));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已删除 #${it.name}，可到右上角回收站恢复')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    }
  }

  void _openTrash() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DeletedTopicsPage()),
    );
  }

  /// 顶部渐变摘要卡：色系与榜单一致（话题金、经文绿），暖色调不突兀。
  /// 左侧图标不加底框：经文/话题两页统一用与热门胶囊同款的火把（放大版）。
  Widget _buildHeader() {
    final colors = widget.isSutra
        ? const [Color(0xFFE5F0EA), Color(0xFFF2F8F4)]
        : [AppPalette.p.tintBg, AppPalette.p.tintBg];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
          child: Row(
          children: [
            Image.asset('assets/images/fire.png', width: 34, height: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.isSutra ? '经文讨论热度榜' : '话题讨论热度榜',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: _accent)),
                  const SizedBox(height: 3),
                  Text('近 14 天 · 互动越多越靠前 · 共 $_totalLabel 项',
                      style: TextStyle(fontSize: 12, color: _textSec)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 名次牌：第 1/2/3 名用字符01/02/03，颜色#6F877A，字号递减。第 4 名起灰色数字。
  Widget _rankBadge(int index) {
    if (index < 3) {
      final fontSize = index == 0 ? 26.0 : (index == 1 ? 22.0 : 19.0);
      return SizedBox(
        width: 34,
        child: Text(
          _rankLabel(index),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF6F877A),
            letterSpacing: 1,
          ),
        ),
      );
    }
    return SizedBox(
      width: 34,
      child: Text('${index + 1}',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w500, color: _textHint)),
    );
  }

  String _rankLabel(int index) => (index + 1).toString().padLeft(2, '0');

  /// 前三名：渐变底色卡片（无边线），名次奖牌 + 名称 + 火把 + 箭头。
  Widget _buildTopCard(HotDiscussionItem it, int index) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              _accent.withValues(alpha: 0.14),
              _accent.withValues(alpha: 0.05),
            ],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _open(it),
          onLongPress: (_isAdmin && !widget.isSutra)
              ? () => _deleteTopic(it)
              : null,
          child: Padding(
            // 竖向 10：26px 奖杯 + 20 内边距 ≈ 普通行（20 文本 + 26 边距）高度一致。
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                _rankBadge(index),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '$_prefix${_displayNames[it.name] ?? it.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: widget.isSutra ? _accent : const Color(0xFFcf9e66)),
                  ),
                ),
                const SizedBox(width: 8),
                if (index < 3)
                  _buildFlames(_flamesByRank(index), firstPlace: index == 0)
                else
                  Text('讨论${it.posts}个',
                      style: TextStyle(fontSize: 12, color: _textHint)),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right, size: 16, color: _textHint),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 第 4 名起的普通行：名次 + 名称 + 笔记数 + 箭头，行间无边线。
  Widget _buildPlainRow(HotDiscussionItem it, int index) {
    return InkWell(
      onTap: () => _open(it),
      onLongPress:
          (_isAdmin && !widget.isSutra) ? () => _deleteTopic(it) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            _rankBadge(index),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$_prefix${_displayNames[it.name] ?? it.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: widget.isSutra ? _accent : const Color(0xFFcf9e66)),
              ),
            ),
            const SizedBox(width: 8),
            if (index < 3)
              _buildFlames(_flamesByRank(index), firstPlace: index == 0)
            else
              Text('讨论${it.posts}个',
                  style: TextStyle(fontSize: 12, color: _textHint)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 16, color: _textHint),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 当前可见条目数：取总条数与已展开页数中较小者。
    final visibleCount =
        _visibleCount < _items.length ? _visibleCount : _items.length;
    final hasMore = visibleCount < _items.length;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: Text(widget.title,
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        actions: [
          // 只有管理员、且是话题榜才显示回收站入口。
          if (_isAdmin && !widget.isSutra)
            IconButton(
              onPressed: _openTrash,
              tooltip: '回收站',
              icon: Icon(Icons.delete_outline,
                  color: _textSec, size: 22),
            ),
        ],
      ),
      body: _items.isEmpty
          ? Center(
              child: Text('暂无数据',
                  style: TextStyle(fontSize: 14, color: _textHint)),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(top: 6, bottom: 24),
              // 1 个 header + 可见条目数 + (有更多时)1 个「查看更多」按钮。
              itemCount: visibleCount + 1 + (hasMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == 0) return _buildHeader();
                final index = i - 1;
                if (index < visibleCount) {
                  final it = _items[index];
                  if (index < 3) return _buildTopCard(it, index);
                  return _buildPlainRow(it, index);
                }
                // 「查看更多」按钮：展开下一页 50 条。
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _accent,
                      side: BorderSide(color: _accent.withValues(alpha: 0.4)),
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () {
                      setState(() {
                        _visibleCount = visibleCount + _pageStep;
                      });
                    },
                    child: Text(
                      '查看更多（剩 ${_items.length - visibleCount} 项）',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 话题回收站：被管理员删除的话题列表，可一键恢复。
class DeletedTopicsPage extends StatefulWidget {
  const DeletedTopicsPage({super.key});

  @override
  State<DeletedTopicsPage> createState() => _DeletedTopicsPageState();
}

class _DeletedTopicsPageState extends State<DeletedTopicsPage> {
  late final List<MapEntry<String, int>> _topics;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await CloudNotesService.instance.refreshBannedTopics();
    if (!mounted) return;
    setState(() {
      _topics = CloudNotesService.instance.bannedTopicAt.entries
          .toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      _loading = false;
    });
  }

  Future<void> _restore(String name) async {
    try {
      await CloudNotesService.instance.restoreTopic(name);
      if (!mounted) return;
      setState(() => _topics.removeWhere((e) => e.key == name));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已恢复 #$name')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('恢复失败：$e')));
      }
    }
  }

  String _fmt(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: Text('回收站',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const AppLoadingIndicator(
              message: '正在加载...',
            )
          : _topics.isEmpty
              ? Center(
                  child: Text('回收站是空的',
                      style: TextStyle(fontSize: 14, color: _textHint)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: _topics.length,
                   separatorBuilder: (_, __) => Divider(
                       height: 1, thickness: 0.5, color: AppPalette.p.divider),
                  itemBuilder: (context, index) {
                    final e = _topics[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('#${e.key}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: AppPalette.p.accentDeep)),
                                if (e.value > 0)
                                  Text('删除于 ${_fmt(e.value)}',
                                      style: TextStyle(
                                          fontSize: 11, color: _textHint)),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () => _restore(e.key),
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF71867A),
                            ),
                            child: const Text('恢复',
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
