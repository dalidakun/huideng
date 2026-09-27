import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'auth_service.dart';
import 'user_avatar.dart';

/// 宗门（底部第二栏）列表项。
class SectInfo {
  final String name;
  final String desc;
  final SectIconKind icon;

  const SectInfo(this.name, this.desc, this.icon);
}

/// 宗门行首图标类型：除律宗用线条手绘外，其余取 assets/menpai/ 切图。
enum SectIconKind {
  zen, // 禅宗 · 圆相
  pureLand, // 净土宗 · 莲花
  tianTai, // 天台宗 · 山云
  huaYan, // 华严宗 · 华严花
  mi, // 密宗 · 金刚十字
  lv, // 律宗 · 戒门（手绘）
  faXiang, // 法相宗 · 眼
  sanLun, // 三论宗 · 中观旋
}

extension SectIconKindAsset on SectIconKind {
  /// 切图文件名前缀：assets/menpai/<code>1.png（素白）/ <code>2.png（米黄）。
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
      };

  /// 图标视觉缩放：只放大/缩小图形，不动行高与分割线位置。
  double get iconScale => switch (this) {
        SectIconKind.zen => 1.2,
        SectIconKind.pureLand => 1.12,
        SectIconKind.faXiang => 0.82,
        SectIconKind.sanLun => 1.2,
        SectIconKind.mi => 1.2,
        SectIconKind.lv => 0.95,
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

/// 底部「宗门」菜单页：标题栏 + 引语 + 宗门列表。
///
/// [onOpen] 点击宗门行，后续接详情页；[onOpenSideMenu] 点击左上头像滑出个人菜单。
class SectPage extends StatelessWidget {
  const SectPage({super.key, this.onOpen, this.onOpenSideMenu});

  final void Function(SectInfo sect)? onOpen;
  final VoidCallback? onOpenSideMenu;

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
                  _buildHero(p),
                  for (var i = 0; i < kSectList.length; i++) ...[
                    _buildRow(p, kSectList[i]),
                    if (i < kSectList.length - 1)
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
              onTap: onOpenSideMenu,
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

  /// 引语区：大标题 + 两行小字，底部贴着一幅淡墨远山（assets/menpai/zm.png）。
  Widget _buildHero(PaletteData p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 16, 24),
      child: Stack(
        children: [
          Positioned.fill(
            child: Align(
              alignment: Alignment.bottomRight,
              child: Opacity(
                opacity: 0.6,
                child: Image.asset(
                  'assets/menpai/zm.png',
                  height: 76,
                  fit: BoxFit.contain,
                  alignment: Alignment.bottomRight,
                  filterQuality: FilterQuality.medium,
                ),
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

  Widget _buildRow(PaletteData p, SectInfo sect) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onOpen?.call(sect),
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

  /// 行首图标：优先用切图（素白 1 / 米黄 2），没有切图的律宗走手绘。
  Widget _buildIcon(PaletteData p, SectInfo sect) {
    final code = sect.icon.assetCode;
    if (code.isEmpty) {
      // 律宗手绘图：素白用纯黑，米黄用暖金（其余门派走切图，不受影响）。
      final gateColor = AppPalette.instance.isPlain
          ? const Color(0xFF000000)
          : const Color(0xFFD3A069);
      return CustomPaint(painter: _GatePainter(color: gateColor));
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

class _GatePainter extends CustomPainter {
  final Color color;

  _GatePainter({required this.color});

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
  bool shouldRepaint(covariant _GatePainter oldDelegate) =>
      color != oldDelegate.color;
}

