import 'dart:async';

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'cloud_notes_service.dart';
import 'note_sutra_links.dart';
import 'post_rich_content.dart';
import 'sutra_list_page.dart';

/// 展示位按天轮流的口径：以「自 1970-01-01 起的整日数」取奇偶，
/// 偶数日放经文热门讨论、奇数日放话题热门讨论（今天经文、明天话题，循环）。
///
/// 用整日序号而不是「几号」，避免 31 号接 1 号时连着两天放同一类。
bool hotSpotShowsSutraOn(DateTime now) {
  final days = DateTime.utc(now.year, now.month, now.day)
          .millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;
  return days.isEven;
}

/// 今日是否轮到经文热门讨论。
bool get hotSpotShowsSutraToday => hotSpotShowsSutraOn(DateTime.now());

/// 展示位的固定色：经文用门派/法门页同一个绿（#5D7C5A），话题沿用其金，
/// 火把红也同款，扫一眼就知道这块位放的是经文还是话题。
const Color _kSutraAccent = Color(0xFF5D7C5A);
const Color _kTopicAccent = Color(0xFFcf9e66);
const Color _kFire = Color(0xFFD93B28);

/// 素白外观下「进入讨论」按钮的固定色（与素白强调色同值）：
/// 经文位、话题位都用它，底色取 10% 淡色、字色取它本身。
const Color _kPlainButton = _kSutraAccent;

/// 展示位的字号：栏目标题（这块位是什么）与下面的经文/话题名。
const double _kLabelSize = 13.5;
/// 经文名与话题名共用，两类都用这一个字号。
const double _kNameSize = 17;

/// 热门讨论展示位：一个固定位置，轮流展示「最热门经文讨论」与「最热门话题讨论」。
///
/// 热度口径与菩提空间讨论栏目一致：经文取「最近 30 天提及数」榜首（广场帖
/// $经名 引用 + 经书讨论页讨论），话题取互动热度榜首。两类都取回，
/// 跨零点换天时不必再等一次请求；当天那一类没有数据时回退到另一类，不留空位。
class HotDiscussionSpot extends StatefulWidget {
  const HotDiscussionSpot({super.key});

  @override
  State<HotDiscussionSpot> createState() => _HotDiscussionSpotState();
}

/// 展示位上的一条内容（已解析好展示名）。
class _SpotData {
  final HotDiscussionItem item;

  /// 展示名：经文带卷标（如「高僧传卷一」），话题即原名。
  final String name;
  final bool isSutra;

  const _SpotData(this.item, this.name, {required this.isSutra});
}

class _HotDiscussionSpotState extends State<HotDiscussionSpot> {
  _SpotData? _sutra;
  _SpotData? _topic;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final results =
        await Future.wait<_SpotData?>([_fetchSutra(), _fetchTopic()]);
    if (!mounted) return;
    setState(() {
      _sutra = results[0];
      _topic = results[1];
    });
  }

  /// 最热门经文：最近 30 天提及数榜首。
  /// 经名须命中经书目录才展示；多卷经书按卷拆分，与讨论页的计数口径一致。
  Future<_SpotData?> _fetchSutra() async {
    try {
      await NoteSutraCatalog.load();
      final titleMap = NoteSutraCatalog.cachedTitleMap ?? const {};
      final raw = await CloudNotesService.instance.getHotSutraMentions();
      final items = mergeHotSutraItems(raw,
              catalogNames: titleMap.keys.toSet(),
              multiVolumeBases: NoteSutraCatalog.cachedMultiVolumeBases)
          .where((s) => titleMap.containsKey(splitHotSutraName(s.name).$1))
          .toList()
        ..sort((a, b) => b.posts != a.posts
            ? b.posts.compareTo(a.posts)
            : b.score.compareTo(a.score));
      if (items.isEmpty) return null;
      final top = items.first;
      final names = await buildSutraDisplayNameMap(items, isSutra: true);
      return _SpotData(top, names[top.name] ?? top.name, isSutra: true);
    } catch (_) {
      // 单类失败只让这一类退回空位，不影响另一类展示。
      return null;
    }
  }

  /// 最热门话题：互动热度榜首；已被管理员删除的话题不展示。
  Future<_SpotData?> _fetchTopic() async {
    try {
      final (topics, _) = await CloudNotesService.instance.getHotDiscussions();
      final bans = CloudNotesService.instance.bannedTopicNames;
      final valid = (bans.isEmpty
              ? topics
              : topics.where((t) => !bans.contains(t.name)))
          .toList()
        ..sort((a, b) => b.score != a.score
            ? b.score.compareTo(a.score)
            : b.posts.compareTo(a.posts));
      if (valid.isEmpty) return null;
      final top = valid.first;
      return _SpotData(top, top.name, isSutra: false);
    } catch (_) {
      return null;
    }
  }

  /// 点击卡片或「进入讨论」：经文进对应卷的经书讨论页，话题进话题页。
  /// 返回后刷新热度，保证看到的讨论数是新的。
  void _open(_SpotData data) {
    final route = data.isSutra
        ? MaterialPageRoute(
            builder: (_) {
              // 条目名可能带卷标（「XX经卷二」）：解析出基础经名与该卷正文路径。
              final (base, path) = resolveHotSutraTarget(data.item.name);
              return SutraDiscussionPage(title: base, filePath: path);
            },
          )
        : MaterialPageRoute(builder: (_) => TopicPage(topic: data.item.name));
    Navigator.push(context, route).then((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final sutraToday = hotSpotShowsSutraToday;
    // 当天该放的那类没数据时回退到另一类，标题跟着实际内容走。
    final data = sutraToday ? (_sutra ?? _topic) : (_topic ?? _sutra);
    // 两类都没取到（接口失败，或云端确实还没有讨论）：退回原来的引语卡，
    // 不显示「暂无热门讨论」这类占位文案。
    if (data == null) return _buildHero(p);
    final isSutra = data.isSutra;
    final accent = isSutra ? _kSutraAccent : _kTopicAccent;
    return Padding(
      // 不画实体边框，卡片再往两侧边缘铺开一些（页面其余内容仍留 20）；
      // 底部留 16，与其下的「八大宗派」段标题合计约 22。
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      child: Material(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _open(data),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Stack(
              children: [
                // 淡墨远山整铺满整张卡片（cover + 贴底，裁掉上方空白天空），
                // 卡上所有字都浮在这座山的背景之上。
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.2,
                    child: Image.asset(
                      'assets/menpai/mih.png',
                      fit: BoxFit.cover,
                      alignment: Alignment.bottomRight,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildLabel(p, isSutra),
                    const SizedBox(height: 10),
                    Text(
                      data.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: _kNameSize,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // 讨论数在左、「进入讨论」在右下角同一行：既贴住卡片下缘，
                    // 又不另起一行，左下角不留空。
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            _countText(data),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: p.textSec,
                              height: 1.5,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        _buildButton(p, accent, data),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 栏目标题：火把 + 「热门经文讨论 / 热门话题讨论」（与菩提空间同一叫法）。
  Widget _buildLabel(PaletteData p, bool isSutra) {
    return Row(
      children: [
        const Icon(Icons.local_fire_department, size: 16, color: _kFire),
        const SizedBox(width: 5),
        Text(
          isSutra ? '热门经文讨论' : '热门话题讨论',
          style: TextStyle(
            fontSize: _kLabelSize,
            fontWeight: FontWeight.w600,
            color: p.textSec,
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
  }

  /// 引语卡：大标题 + 两行小字，右下贴一幅淡墨远山。
  /// 热门讨论一类都没取到时顶在页面最上面，替代「暂无热门讨论」占位文案。
  /// 远山与热门讨论卡同图同铺法（mih.png 整铺贴底、20% 淡墨）。
  Widget _buildHero(PaletteData p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 16, 16),
      child: Stack(
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: 0.2,
              child: Image.asset(
                'assets/menpai/mih.png',
                fit: BoxFit.cover,
                alignment: Alignment.bottomRight,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '法门无量，各有方便。',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                  letterSpacing: 1.4,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '宗门有别，方便有异；',
                style: TextStyle(
                  fontSize: 13,
                  color: p.textSec,
                  height: 1.85,
                  letterSpacing: 0.6,
                ),
              ),
              Text(
                '究竟之法，本无二三。',
                style: TextStyle(
                  fontSize: 13,
                  color: p.textSec,
                  height: 1.85,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 讨论数：经文榜统计最近 30 天的提及，话题榜是话题下的帖子数。
  String _countText(_SpotData? data) {
    if (data == null) return '';
    return data.isSutra
        ? '近 30 天 ${data.item.posts} 条讨论'
        : '${data.item.posts} 条讨论';
  }

  /// 「进入讨论 ›」按钮：可点开讨论详情页；无内容时置灰不可点。
  ///
  /// 素白外观下不论这块位放的是经文还是话题，底色/字色统一用 5D7C5A
  /// （底色取它的 10% 淡色、字色取它本身）；米黄外观保持原样，
  /// 仍按经文绿、话题金各走各的色相。
  Widget _buildButton(PaletteData p, Color accent, _SpotData? data) {
    final enabled = data != null;
    final tone = AppPalette.instance.isPlain ? _kPlainButton : accent;
    final color = enabled ? tone : p.textHint;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () => _open(data) : null,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
        decoration: BoxDecoration(
          color: enabled ? tone.withValues(alpha: 0.10) : p.tintBg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '进入讨论',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
                letterSpacing: 0.4,
              ),
            ),
            Icon(Icons.chevron_right, size: 15, color: color),
          ],
        ),
      ),
    );
  }
}
