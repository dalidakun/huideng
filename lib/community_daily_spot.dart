import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'cloud_notes_service.dart';
import 'note_sutra_links.dart';

/// 往前回溯的天数上限。
///
/// 服务端 `getCommunityDailyTop` 只接受 0~7 天的统计窗口，这里与那个上限对齐；
/// 再往前就得改云函数，不如停在引语卡。
const int kMaxLookbackDays = 7;

/// [daysBack] 天前那一整天的毫秒区间 `[since, until)`（本地时区）。
///
/// 日界必须按本地时区切：服务端是拿 `createdAt` 落在这个区间来统计的，
/// 若用 UTC 切，晚上发的帖会被算进「今天」，昨天反而少了内容。
/// 月份交给 [DateTime] 自己进位（`day - daysBack` 为 0 或负时自动退到上月末）。
(int, int) dayRange(DateTime now, int daysBack) => (
      DateTime(now.year, now.month, now.day - daysBack).millisecondsSinceEpoch,
      DateTime(now.year, now.month, now.day - daysBack + 1)
          .millisecondsSinceEpoch,
    );

/// 前一天（本地时区）的毫秒区间 `[since, until)`：昨天零点 → 今天零点。
(int, int) previousDayRange(DateTime now) => dayRange(now, 1);

/// 展示位挑社区：取窗口内发帖最多的那个；并列第一时在并列者里随机挑一个。
///
/// 并列不写本地缓存、每次加载重抽：并列本身就说明几家一样热，
/// 让每位同修都有机会被推到首位，也不用维护「今天抽到过谁」。
/// [stats] 需已过滤成八大宗派 + 十二法门这 20 个社区；无人发帖时返回 null，
/// 由展示位继续往前找一天，或退回引语卡。
CommunityDailyStat? pickRandomTopCommunity(
  List<CommunityDailyStat> stats, {
  Random? random,
}) {
  var maxPosts = 0;
  for (final s in stats) {
    if (s.posts > maxPosts) maxPosts = s.posts;
  }
  if (maxPosts <= 0) return null;
  final tied = [for (final s in stats) if (s.posts == maxPosts) s];
  return tied[(random ?? Random()).nextInt(tied.length)];
}

/// 与社区页同一套色调（素白青绿 / 米黄暖金）。这里不引入社区页——
/// 社区页要引 [sect_page.dart] 的栏目表，再引回来就成循环依赖了，
/// 所以两个色值在这里各抄一份，改动时两处一起改。
const Color _kTonePlain = Color(0xFF5D7C5A);
const Color _kToneWarm = Color(0xFFD3A069);

/// 展示位固定色：社区名前那枚火把的红色，与旧热门讨论卡同款，
/// 扫一眼就知道这块位是「热门」性质。
const Color _kFire = Color(0xFFD93B28);

/// 展示位字号：社区名（这块位讲的是哪个社区）与正文下方的一行小字。
const double _kNameSize = 17;

/// 卡片圆角：底图铺满四边后由 ClipRRect 按它切角，所以圆角只在这里定义一次。
const double _kCardRadius = 12;

/// 宗门菜单页顶部展示位：在八大宗派 + 十二法门这 20 个社区里，
/// 挑出「最近一个有人发帖的日子」里发帖数量最多的那一个，把它的名号、
/// 当日发帖数和最热的一条帖子摆在这块位上，点一下直接进那个社区。
///
/// 先看昨天；昨天没人发帖就一天天往前找，最多回溯 [kMaxLookbackDays] 天——
/// 连着几天冷清时不该退回引语卡，该把最近一次热闹的那个社区和它的热帖
/// 继续摆出来（小字里会标明这是几天前的数据）。
///
/// 数据口径全在服务端：按客户端给的本地日窗口统计各社区发帖数，
/// 每个社区再按互动量（阅读 +1、赞×3、评论×5、转发×8）取窗内最热一条。
/// 一周内无人发帖、或接口尚未部署时才退回引语卡，不显示「暂无」这类占位文案。
class CommunityDailySpot extends StatefulWidget {
  const CommunityDailySpot({
    super.key,
    required this.communities,
    required this.onOpen,
  });

  /// 可参与展示的社区标记（`${栏目名}社区`，共 20 个），由栏目表生成。
  /// 服务端只按 community 字段统计，这里再挡一道，别的社区不进这块位。
  final Set<String> communities;

  /// 点击卡片或「进入社区」：把社区标记交回给栏目页去跳转。
  final void Function(String community)? onOpen;

  @override
  State<CommunityDailySpot> createState() => _CommunityDailySpotState();
}

class _CommunityDailySpotState extends State<CommunityDailySpot> {
  CommunityDailyStat? _stat;

  /// [_stat] 取自几天前的窗口（1 = 昨天）：只用于小字文案。
  int _daysBack = 1;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// 先查昨天；昨天没人发帖就一天天往前找，找到最近一个有发帖的日子为止。
  ///
  /// 冷清期（连着几天没人发帖）不该退回引语卡，那会让同修以为整个社区都空着；
  /// 该显示的是最近一次热闹时的那个社区与它的热帖，日期由小字点明。
  Future<void> _load() async {
    final now = DateTime.now();
    for (var back = 1; back <= kMaxLookbackDays; back++) {
      final (since, until) = dayRange(now, back);
      List<CommunityDailyStat> stats;
      try {
        stats = await CloudNotesService.instance
            .getCommunityDailyTop(sinceMs: since, untilMs: until);
      } catch (_) {
        // 接口没部署 / 网络异常：再往后试也是白试，直接退回引语卡。
        break;
      }
      // 只认栏目表里的 20 个社区；其余（历史脏数据、手改的 community）不进展示位。
      final known =
          stats.where((s) => widget.communities.contains(s.community)).toList();
      final picked = pickRandomTopCommunity(known);
      if (picked == null) continue;
      if (!mounted) return;
      setState(() {
        _stat = picked;
        _daysBack = back;
      });
      return;
    }
    if (!mounted) return;
    setState(() => _stat = null);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final stat = _stat;
    // 一周内都没人发帖（或接口没起来）：退回引语卡，不显示占位文案。
    if (stat == null) return _buildHero(p);
    final note = stat.top;
    return Padding(
      // 不画实体边框，卡片再往两侧边缘铺开一些（页面其余内容仍留 20）；
      // 底部留 16，与其下的「八大宗派」段标题合计约 22。
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_kCardRadius),
        child: Material(
          color: p.card,
          // 圆角由外层 ClipRRect 裁：底图要一直铺到卡片四边、贴着圆角切，
          // 不留内边距白边，也不能在圆角外溢出。
          child: InkWell(
            onTap: () => widget.onOpen?.call(stat.community),
            child: Stack(
              children: [
                // 淡墨远山整铺满整张卡片（cover + 贴底，裁掉上方空白天空），
                // 卡上所有字都浮在这座山的背景之上。内边距只加在文字层，
                // 底图不受它影响，所以图与卡片之间没有留白。
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                    // 社区名直接摆在标题位置，前面缀一枚火把：既点明这块位是
                    // 「热门」性质，又不用另起一行写「热门社区」做解释。
                    Row(
                      children: [
                        const Icon(
                          Icons.local_fire_department,
                          size: 18,
                          color: _kFire,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            stat.community,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: _kNameSize,
                              fontWeight: FontWeight.w700,
                              color: p.text,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 紧接着就是那条帖子本身：内容最多三行，超出的在第三行末尾省略。
                    if (note != null) ...[
                      Text(
                        '${_authorText(note)}：${_excerptText(note)}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: p.textSec,
                          height: 1.55,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    // 互动数在左、「进入社区」在右下角同一行：
                    // 既贴住卡片下缘，又不另起一行，左下角不留空。
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            _metaText(stat),
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
                        _buildButton(p),
                      ],
                    ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

/// 卡片下缘的一行小字：最热帖的发出时间 + 互动数。
  /// 没有帖子时只报发帖数，不留「0 赞 0 回复」这种空信息。
  /// 时间已带月日，几天的数据一眼看得出，不必再补「前天热门」这类标签。
  String _metaText(CommunityDailyStat stat) {
    final note = stat.top;
    if (note == null) return '${_dayWord()} ${stat.posts} 帖';
    final parts = <String>[
      if (note.createdAt > 0) _timeText(note.createdAt),
      if (note.likeCount > 0) '${note.likeCount} 赞',
      if (note.commentCount > 0) '${note.commentCount} 回复',
      if (note.viewCount > 0) '${note.viewCount} 阅读',
    ];
    return parts.isEmpty ? '${_dayWord()} ${stat.posts} 帖' : parts.join(' · ');
  }

  /// 这块位的数据是几天前的：昨日 / 前天 / N 天前。
  /// 只用在「只有发帖数、没有帖子可显示」的那行小字上。
  String _dayWord() {
    if (_daysBack <= 1) return '昨日';
    if (_daysBack == 2) return '前天';
    return '${_daysBack - 1} 天前';
  }

  /// 帖子的发出时间：月日 + 时分。数据可能来自前几天，所以月日不能省。
  String _timeText(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '${t.month}月${t.day}日 $h:$m';
  }

  /// 作者名：实名优先，其次 @账号，最后兜底「同修」（与广场同款口径）。
  String _authorText(PlazaNote note) {
    if (note.authorName.trim().isNotEmpty) return note.authorName.trim();
    if (note.authorAccount.trim().isNotEmpty) {
      return '@${note.authorAccount.trim()}';
    }
    return '同修';
  }

  /// 帖子摘要：社区帖都是无标题发的（服务端把空标题存成「无标题」），
  /// 所以默认取正文；万一带标题（历史数据）就用标题。
  /// 旧式 [@经名](路径) 标记先转成纯文本，末尾补一个省略号示意还有下文。
  String _excerptText(PlazaNote note) {
    final title = note.title.trim();
    final raw = title.isNotEmpty && title != '无标题' ? title : note.content;
    final text = NoteSutraLinks.plainText(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return '（无正文）';
    return text;
  }

  /// 「进入社区 ›」按钮：点一下进那个社区看全部帖子。
  /// 底色/字色随外观切换（素白青绿、米黄暖金），与社区页同一套色。
  Widget _buildButton(PaletteData p) {
    final tone =
        AppPalette.instance.isPlain ? _kTonePlain : _kToneWarm;
    final enabled = widget.onOpen != null;
    final color = enabled ? tone : p.textHint;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? () {
              final stat = _stat;
              if (stat != null) widget.onOpen?.call(stat.community);
            }
          : null,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
        decoration: BoxDecoration(
          color: enabled ? tone.withValues(alpha: 0.15) : p.tintBg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '进入社区',
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

  /// 引语卡：大标题 + 两行小字，右下贴一幅淡墨远山。
  /// 一周内无人发帖（或接口没起来）时顶在页面最上面，替代「暂无」占位文案。
  /// 远山与社区卡同图同铺法（mih.png 整铺贴底、20% 淡墨）。
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
}
