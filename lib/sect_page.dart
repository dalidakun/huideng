import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'auth_service.dart';
import 'community_daily_spot.dart';
import 'user_avatar.dart';

/// 栏目类别：八大宗派 / 十二法门。详情页据其把介绍标题写成「宗派介绍 / 法门介绍」。
enum SectMenuKind { sect, gate }

/// 宗门或法门（底部「宗门」栏）列表项。
class SectInfo {
  final String name;
  final String desc;
  final SectIconKind icon;

  /// 属于哪一栏，决定顶栏标题与行首图标样式。
  final SectMenuKind kind;

  const SectInfo(this.name, this.desc, this.icon,
      {this.kind = SectMenuKind.sect});
}

/// 宗门行首图标类型：宗门除律宗用线条手绘外，其余取 assets/menpai/ 切图；
/// 法门没有切图，改用内置 Material 图标（见 [SectIconKindAsset.gateIcon]）。
enum SectIconKind {
  zen, // 禅宗 · 圆相
  pureLand, // 净土宗 · 莲花
  tianTai, // 天台宗 · 山云
  huaYan, // 华严宗 · 华严花
  mi, // 密宗 · 金刚十字
  lv, // 律宗 · 戒门（手绘）
  faXiang, // 法相宗 · 眼
  sanLun, // 三论宗 · 中观旋
  gmDizang, // 地藏法门
  gmGuanyin, // 观世音法门
  gmYaoshi, // 药师法门
  gmMile, // 弥勒法门
  gmJingtu, // 净土法门
  gmBore, // 般若法门
  gmLengyan, // 楞严法门
  gmPuxian, // 普贤行愿法门
  gmBaichan, // 拜忏法门
  gmShishi, // 施食法门
  gmNianchu, // 四念处法门
  gmToutuo, // 头陀法门
}

extension SectIconKindAsset on SectIconKind {
  /// 宗门切图文件名前缀：assets/menpai/<code>1.png（素白）/ <code>2.png（米黄）。
  /// 空串表示没有切图，改用手绘。
  String get assetCode => switch (this) {
        SectIconKind.zen => 'cz',
        SectIconKind.pureLand => 'jt',
        SectIconKind.tianTai => 'tt',
        SectIconKind.huaYan => 'hy',
        SectIconKind.mi => 'mz',
        SectIconKind.lv => '',
        SectIconKind.faXiang => 'fx',
        SectIconKind.sanLun => 'sl',
        _ => '',
      };

  /// 法门切图文件名前缀（拼音）：assets/famen/<code>.png（素白）/ <code>2.png（米黄）。
  /// 宗门一律为空串。
  String get gateCode => switch (this) {
        SectIconKind.gmDizang => 'dizang',
        SectIconKind.gmGuanyin => 'guanyin',
        SectIconKind.gmYaoshi => 'yaoshi',
        SectIconKind.gmMile => 'mile',
        SectIconKind.gmJingtu => 'jingtu',
        SectIconKind.gmBore => 'bore',
        SectIconKind.gmLengyan => 'lengyan',
        SectIconKind.gmPuxian => 'puxianxingyuan',
        SectIconKind.gmBaichan => 'baichan',
        SectIconKind.gmShishi => 'shishi',
        SectIconKind.gmNianchu => 'sinianchu',
        SectIconKind.gmToutuo => 'toutuo',
        _ => '',
      };

  /// 是否法门图标（决定走 assets/famen/ 切图还是宗门切图/手绘）。
  bool get isGate => gateCode.isNotEmpty;

  /// 图标视觉缩放：只放大/缩小图形，不动行高与分割线位置。
  double get iconScale => switch (this) {
        // 宗门：各切图自带留白不同，这里的系数是在补偿留白，让视觉大小接近；
        // 2026-09 统一再缩小约 13%，保持彼此的相对关系。
        SectIconKind.zen => 1.05,
        SectIconKind.pureLand => 0.98,
        SectIconKind.tianTai => 0.88,
        SectIconKind.huaYan => 0.88,
        SectIconKind.mi => 1.05,
        SectIconKind.lv => 0.83,
        SectIconKind.faXiang => 0.72,
        SectIconKind.sanLun => 1.05,
        // 楞严法门起（普贤行愿除外）图形偏小，单独放大。
        SectIconKind.gmLengyan => 1.2,
        SectIconKind.gmBaichan => 1.2,
        SectIconKind.gmShishi => 1.2,
        SectIconKind.gmNianchu => 1.2,
        SectIconKind.gmToutuo => 1.2,
        _ => 1.0,
      };
}

const List<SectInfo> kSectList = [
  SectInfo('禅宗', '以禅修、参悟为核心', SectIconKind.zen),
  SectInfo('净土宗', '以信愿念佛，往生净土为主', SectIconKind.pureLand),
  SectInfo('天台宗', '教观并重，止观双修', SectIconKind.tianTai),
  SectInfo('华严宗', '以华严经为根本，圆融无碍', SectIconKind.huaYan),
  SectInfo('密宗', '以仪轨、真言、观想为主要修行', SectIconKind.mi),
  SectInfo('律宗', '以戒律为修行根本', SectIconKind.lv),
  SectInfo('法相宗', '以唯识思想为核心', SectIconKind.faXiang),
  SectInfo('三论宗', '以中观空义为核心', SectIconKind.sanLun),
];

/// 十二法门的一行副标题：不写经目，只说这个法门管什么事、替人解什么难。
/// 经目在详情页「核心经典」里已经按文件夹列全，副标题再堆经名只会挤掉重点。
const List<SectInfo> kGateList = [
  SectInfo('地藏法门', '超度亡灵，化解冤亲业障', SectIconKind.gmDizang,
      kind: SectMenuKind.gate),
  SectInfo('观世音法门', '消灾解厄，救难护身', SectIconKind.gmGuanyin,
      kind: SectMenuKind.gate),
  SectInfo('药师法门', '祛病消灾，化解疾苦', SectIconKind.gmYaoshi,
      kind: SectMenuKind.gate),
  SectInfo('弥勒法门', '解忧释怀，欢喜知足', SectIconKind.gmMile,
      kind: SectMenuKind.gate),
  SectInfo('净土法门', '一心念佛，了脱生死', SectIconKind.gmJingtu,
      kind: SectMenuKind.gate),
  SectInfo('般若法门', '看破放下，照见真相', SectIconKind.gmBore,
      kind: SectMenuKind.gate),
  SectInfo('楞严法门', '降伏魔障，守护道心', SectIconKind.gmLengyan,
      kind: SectMenuKind.gate),
  SectInfo('普贤行愿法门', '落实善行，利益众生', SectIconKind.gmPuxian,
      kind: SectMenuKind.gate),
  SectInfo('拜忏法门', '忏悔过愆，消业解冤', SectIconKind.gmBaichan,
      kind: SectMenuKind.gate),
  SectInfo('施食法门', '救济饿鬼，冥阳两利', SectIconKind.gmShishi,
      kind: SectMenuKind.gate),
  SectInfo('四念处法门', '洞察身心，止息烦恼', SectIconKind.gmNianchu,
      kind: SectMenuKind.gate),
  SectInfo('头陀法门', '简朴自持，克制物欲', SectIconKind.gmToutuo,
      kind: SectMenuKind.gate),
];

/// 宗派格子副标题区的高度：固定两行（11.5px × 1.4 × 2 ≈ 32.2，取 33）。
/// 写死是为了让两列四行的 8 个格子等高，不受副标题长短影响。
const double _kSectDescHeight = 33;

/// 八大宗派 + 十二法门共 20 个社区的标记（`${栏目名}社区`），
/// 与社区页 `PlazaNote.community` 的写法一致（见 sect_community_page）。
/// 顶部展示位只在这 20 个社区里挑昨日发帖最多的那个。
Set<String> get kCommunityKeys => {
      for (final s in [...kSectList, ...kGateList]) '${s.name}社区',
    };

/// 底部「宗门」菜单页：标题栏 + 昨日最热社区展示位 + 「八大宗派」两列格子 + 「十二法门」列表。
///
/// 宗门与法门不分栏切换，同页自上而下依次排布；两者共用 [onOpen] 与同一个
/// [SectDetailPage]，所以宗门与法门的详情页完全同构。
class SectPage extends StatefulWidget {
  const SectPage({
    super.key,
    this.onOpen,
    this.onOpenCommunity,
    this.onOpenSideMenu,
  });

  final void Function(SectInfo sect)? onOpen;

  /// 进入某个社区（展示位点「进入社区」时用）：回传社区标记（如「禅宗社区」）。
  /// 跳转交给宿主页做，本页不引社区页、也就不会与它形成循环依赖。
  final void Function(String community)? onOpenCommunity;

  final VoidCallback? onOpenSideMenu;

  @override
  State<SectPage> createState() => _SectPageState();
}

class _SectPageState extends State<SectPage> {
  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(p),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 28),
                children: [
                  // 顶部展示位：八大宗派 + 十二法门里，前一天发帖最多的那一个社区。
                  CommunityDailySpot(
                    communities: kCommunityKeys,
                    onOpen: widget.onOpenCommunity,
                  ),
                  _buildSectionTitle(p, '八大宗派'),
                  _buildSectGrid(p),
                  _buildSectionTitle(p, '十二法门'),
                  for (var i = 0; i < kGateList.length; i++) ...[
                    _buildRow(p, kGateList[i]),
                    if (i < kGateList.length - 1)
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: p.borderSoft,
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶栏：左头像 + 标题 + 圆点 + 经文（与其他菜单页同款；本页为菜单页，无返回键）。
  Widget _buildTopBar(PaletteData p) {
    return SizedBox(
      width: double.infinity,
      height: 46,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            GestureDetector(
              // 左上角头像：从左侧滑出个人菜单，与首页一致。
              onTap: widget.onOpenSideMenu,
              child: UserAvatar(
                userId: AuthService.instance.currentUser.value?.id,
                radius: 16,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '宗门',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: p.primary,
                letterSpacing: 1.5,
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
            const Flexible(
              child: Text(
                '是法平等，无有高下。',
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
    );
  }

  /// 分栏小标题：短竖杠 + 栏目名（「八大宗派」「十二法门」）。
  /// 示意图右侧的「了解各宗门 ›」入口不做，标题只作标识。
  /// 顶部只留 6，与上方卡片/格子挨得更近。
  Widget _buildSectionTitle(PaletteData p, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 15,
            decoration: BoxDecoration(
              color: p.primary,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 16.5,
              fontWeight: FontWeight.w700,
              color: p.text,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  /// 八大宗派两列四行格子：行内左右各一格（间距 10），行与行之间留 8，
  /// 左右外边距与其余内容同为 20。每格副标题区固定两行高
  /// （[_kSectDescHeight]），8 格因此等高。
  Widget _buildSectGrid(PaletteData p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        children: [
          for (var i = 0; i < kSectList.length; i += 2) ...[
            Row(
              children: [
                Expanded(child: _buildSectCell(p, kSectList[i])),
                const SizedBox(width: 10),
                Expanded(child: _buildSectCell(p, kSectList[i + 1])),
              ],
            ),
            if (i + 2 < kSectList.length) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  /// 格子：整格包一层浅色底（[PaletteData.tintBg]）与 10 圆角；
  /// 上行是行首图标（左）与 ›（右），下两行是经名与副标题。
  Widget _buildSectCell(PaletteData p, SectInfo sect) {
    return Material(
      color: p.tintBg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => widget.onOpen?.call(sect),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 9, 10, 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: Transform.scale(
                      scale: sect.icon.iconScale,
                      child: _buildIcon(p, sect),
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.chevron_right, size: 18, color: p.textHint),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                sect.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w600,
                  color: p.text,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 3),
              // 副标题区高度固定为两行：密宗/净土宗等长句要折行，
              // 律宗/法相宗等短句留白，8 个格子的高度因此完全一致。
              SizedBox(
                height: _kSectDescHeight,
                child: Text(
                  sect.desc,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: p.textSec,
                    height: 1.4,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单列行式样（十二法门列表用）：图标 + 经名/副标题 + ›，行间分割线由调用方加。
  Widget _buildRow(PaletteData p, SectInfo sect) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => widget.onOpen?.call(sect),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              SizedBox(
                width: 38,
                height: 38,
                child: Transform.scale(
                  scale: sect.icon.iconScale,
                  child: _buildIcon(p, sect),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sect.name,
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      sect.desc,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: p.textSec,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, size: 19, color: p.textHint),
            ],
          ),
        ),
      ),
    );
  }

  /// 行首图标：法门用 assets/famen/ 拼音切图（素白无后缀、米黄加 2）；
  /// 宗门优先用 assets/menpai/ 切图（素白 1 / 米黄 2），没有切图的律宗走手绘。
  Widget _buildIcon(PaletteData p, SectInfo sect) {
    final gate = sect.icon.gateCode;
    if (gate.isNotEmpty) {
      final suffix = AppPalette.instance.isPlain ? '' : '2';
      return Image.asset(
        'assets/famen/$gate$suffix.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
    }
    final code = sect.icon.assetCode;
    if (code.isEmpty) {
      // 律宗手绘图：素白用纯黑，米黄用暖金（其余门派走切图，不受影响）。
      final gateColor = AppPalette.instance.isPlain
          ? const Color(0xFF000000)
          : const Color(0xFFD3A069);
      return CustomPaint(painter: GatePainter(color: gateColor));
    }
    final suffix = AppPalette.instance.isPlain ? '1' : '2';
    return Image.asset(
      'assets/menpai/$code$suffix.png',
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }
}

// ─────────────── 图标绘制（律宗专属，暂无切图） ───────────────

class GatePainter extends CustomPainter {
  final Color color;

  GatePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final ink = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.045
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final w = size.width;
    final h = size.height;
    final frame = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.14, h * 0.14, w * 0.72, h * 0.7),
          Radius.circular(w * 0.06),
        ),
      );
    canvas.drawPath(frame, ink);
    canvas.drawLine(Offset(w * 0.14, h * 0.36), Offset(w * 0.86, h * 0.36), ink);
    canvas.drawLine(Offset(w * 0.38, h * 0.36), Offset(w * 0.38, h * 0.84), ink);
    canvas.drawLine(Offset(w * 0.62, h * 0.36), Offset(w * 0.62, h * 0.84), ink);
  }

  @override
  bool shouldRepaint(covariant GatePainter oldDelegate) =>
      color != oldDelegate.color;
}

