import 'package:flutter/material.dart';

import 'cloud_notes_service.dart';
import 'note_sutra_links.dart';
import 'post_rich_content.dart';

const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _gold = Color(0xFFD4A06A);

/// 热门经文/话题全量榜（「更多」页）：按讨论帖子数从多到少排列，
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

  @override
  void initState() {
    super.initState();
    // 按热度分从高到低排列：越靠上的热度越大，火把越多。
    // 已被管理员删除的话题直接剔除，避免热门榜残留展示。
    final bans = CloudNotesService.instance.bannedTopicNames;
    _items = (bans.isEmpty
            ? widget.items
            : widget.items.where((it) => !bans.contains(it.name)))
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    NoteSutraCatalog.load();
    CloudNotesService.instance.isAdmin().then((ok) {
      if (mounted) setState(() => _isAdmin = ok);
    });
  }

  /// 按名次取火把数：第 1 名 5 把，依次递减到第 5 名 1 把，第 6 名及之后都是 1 把。
  static int _flamesByRank(int index) => index < 5 ? 5 - index : 1;

  /// 火把：按名次取数量，颜色从橙黄到红渐变，模拟真实火簇。
  static const List<Color> _flameColors = [
    Color(0xFFF6A93B),
    Color(0xFFF0812B),
    Color(0xFFE45B2E),
    Color(0xFFD93B28),
  ];

  Widget _buildFlames(int level) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < level; i++)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Icon(Icons.local_fire_department,
                size: 15, color: _flameColors[i % _flameColors.length]),
          ),
      ],
    );
  }

  Color get _accent => widget.isSutra
      ? const Color(0xFF71867A)
      : const Color(0xFF9A6B3F);

  String get _prefix => widget.isSutra ? r'$' : '#';

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
            style: const TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: _textSec))),
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
  Widget _buildHeader() {
    final colors = widget.isSutra
        ? const [Color(0xFFE5F0EA), Color(0xFFF2F8F4)]
        : const [Color(0xFFF7E7CE), Color(0xFFFCF4E6)];
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
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFF70867A),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                  widget.isSutra
                      ? Icons.menu_book_rounded
                      : Icons.local_fire_department,
                  size: 20,
                  color: Colors.white),
            ),
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
                  Text('近 14 天 · 互动越多越靠前 · 共 ${_items.length} 个',
                      style: const TextStyle(fontSize: 12, color: _textSec)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 名次牌：金色胶囊——第 1 名「奖杯 + NO.1」，第 2/3 名「NO.2/NO.3」，
  /// 无圆环线框，纯渐变胶囊 + 光晕；第 4 名起灰色数字。
  Widget _rankBadge(int index) {
    const gold =
        LinearGradient(colors: [Color(0xFFF6C57E), Color(0xFFD4A06A)]);
    if (index == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          gradient: gold,
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
                color: const Color(0xFFD4A06A).withValues(alpha: 0.45),
                blurRadius: 8,
                offset: const Offset(0, 2)),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.emoji_events_rounded,
                color: Colors.white, size: 16),
            SizedBox(width: 4),
            Text('NO.1',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 0.5)),
          ],
        ),
      );
    }
    if (index < 3) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          gradient: gold,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text('NO.${index + 1}',
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: 0.5)),
      );
    }
    return SizedBox(
      width: 34,
      child: Text('${index + 1}',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w500, color: _textHint)),
    );
  }

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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                _rankBadge(index),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '$_prefix${it.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _accent),
                  ),
                ),
                const SizedBox(width: 8),
                _buildFlames(_flamesByRank(index)),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, size: 16, color: _textHint),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 第 4 名起的普通行：名次 + 名称 + 火把 + 箭头，行间无边线。
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
                '$_prefix${it.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _accent),
              ),
            ),
            const SizedBox(width: 8),
            _buildFlames(_flamesByRank(index)),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, size: 16, color: _textHint),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: Text(widget.title,
            style: const TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        actions: [
          // 只有管理员、且是话题榜才显示回收站入口。
          if (_isAdmin && !widget.isSutra)
            IconButton(
              onPressed: _openTrash,
              tooltip: '回收站',
              icon: const Icon(Icons.delete_outline,
                  color: _textSec, size: 22),
            ),
        ],
      ),
      body: _items.isEmpty
          ? const Center(
              child: Text('暂无数据',
                  style: TextStyle(fontSize: 14, color: _textHint)),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(top: 6, bottom: 24),
              itemCount: _items.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) return _buildHeader();
                final index = i - 1;
                final it = _items[index];
                if (index < 3) return _buildTopCard(it, index);
                return _buildPlainRow(it, index);
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
        title: const Text('回收站',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(strokeWidth: 2, color: _gold))
          : _topics.isEmpty
              ? const Center(
                  child: Text('回收站是空的',
                      style: TextStyle(fontSize: 14, color: _textHint)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: _topics.length,
                  separatorBuilder: (_, __) => const Divider(
                      height: 1, thickness: 0.6, color: Color(0xFFD8CCBC)),
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
                                    style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF9A6B3F))),
                                if (e.value > 0)
                                  Text('删除于 ${_fmt(e.value)}',
                                      style: const TextStyle(
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
