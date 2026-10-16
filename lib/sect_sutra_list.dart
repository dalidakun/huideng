import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'sect_sutra_manifest.dart';
import 'sutra_list_page.dart';

/// 核心经典列表的公共色/尺寸：宗门页、法门页与「读经指南」阶段页共用，
/// 保证「经典文件夹 → 译本 → 分卷」这套结构在各入口完全一致。
///
/// 经典区的固定色：译本题前的竖杠一律绿（素白外观的主色绿），译本题名一律黑。
/// 不随外观切换，扫一眼就能分清「这是哪一版」。
const Color kSectGreen = Color(0xFF5D7C5A);
const Color kSectEditionName = Color(0xFF1A1A1A);

/// 「已标记完成」经书的题名色（全站统一金棕，与经藏页已读书名一致）。
const Color kSectReadDone = Color(0xFFcf9e66);

/// 文件夹切图边长。
const double kSectFolderIconSize = 19;

/// 译本竖杠（3）+ 竖杠到题名的间距（8）：卷行按它左缩进，与译本题名首字对齐。
const double kSectEditionIndent = 11;

/// 展开中的经典文件夹专用阴影：比 App 常规卡片阴影略重，
/// 经名文件夹可以同时展开多个，靠这层阴影就能一眼看出当前在读哪一部。
const Color kSectActiveShadow = Color(0x14000000);
const double kSectActiveShadowBlur = 12;
const Offset kSectActiveShadowOffset = Offset(0, 3);

/// 字数：过万折算为「x.x 万字」，与经藏页量级一致。
String formatSutraWords(int n) {
  if (n < 10000) return '$n 字';
  final w = n / 10000;
  return '${w.toStringAsFixed(w >= 100 ? 0 : 1)} 万字';
}

/// 统计条：经典 / 译本 / 卷 / 字数四项。四项等宽均分铺满整行；
/// 项多字长（如「24.6 万字」）时单项等比缩小，宁可小一号也不折行。
class SectStatsBar extends StatelessWidget {
  const SectStatsBar({
    super.key,
    required this.classics,
    required this.editions,
    required this.volumes,
    required this.words,
  });

  /// 经典（文件夹）部数。
  final int classics;
  final int editions;
  final int volumes;
  final int words;

  @override
  Widget build(BuildContext context) {
    final plain = AppPalette.instance.isPlain;
    final bg = plain ? const Color(0xFFF2F2F2) : const Color(0xFFEFE8DC);
    final fg = plain ? const Color(0xFF3C3C3C) : const Color(0xFF4A3F35);
    // 四项前面的图标：素白外观用墨绿，米黄外观用暖金。
    final icon = plain ? kSectGreen : const Color(0xFFD09D66);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 13),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _statCell(
              _statItem(fg, icon, Icons.layers_outlined, '$classics 部经典')),
          _statDot(fg),
          _statCell(
              _statItem(fg, icon, Icons.menu_book_outlined, '$editions 译本')),
          _statDot(fg),
          _statCell(_statItem(fg, icon, Icons.book_outlined, '$volumes 卷')),
          _statCell(Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 1, height: 13, color: fg.withValues(alpha: 0.35)),
              const SizedBox(width: 6),
              _wordsGlyph(icon),
              const SizedBox(width: 5),
              Text(
                formatSutraWords(words),
                style:
                    TextStyle(fontSize: 11.5, color: fg, letterSpacing: 0.2),
              ),
            ],
          )),
        ],
      ),
    );
  }

  /// 单项指标占四分之一行宽：四项均分、内容居中，超宽时等比缩放不溢出。
  Widget _statCell(Widget child) => Expanded(
        child: FittedBox(fit: BoxFit.scaleDown, child: child),
      );

  Widget _statItem(Color fg, Color icon, IconData iconData, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(iconData, size: 14, color: icon),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(fontSize: 11.5, color: fg, letterSpacing: 0.2)),
      ],
    );
  }

  Widget _statDot(Color fg) => Container(
        width: 3,
        height: 3,
        decoration: BoxDecoration(
            color: fg.withValues(alpha: 0.45), shape: BoxShape.circle),
      );

  /// 「字数」小徽标：描边方框里一个「字」。
  Widget _wordsGlyph(Color fg) {
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: fg, width: 1.2),
        borderRadius: BorderRadius.circular(3),
      ),
      child:
          Text('字', style: TextStyle(fontSize: 8.5, color: fg, height: 1.0)),
    );
  }
}

/// 一个经典文件夹：折叠时是经名，展开后按译本分区列出分卷。
/// 收起态——图标、经名/副行、右侧居中的下箭头同一行。
///
/// 宗门页、法门页与「读经指南」阶段页共用本卡片，样式完全一致。
class SectSutraGroupCard extends StatelessWidget {
  const SectSutraGroupCard({
    super.key,
    required this.group,
    required this.open,
    required this.onToggle,
    this.parent,
    this.sutraFolder,
  });

  final SectSutraGroup group;
  final bool open;
  final VoidCallback onToggle;

  /// 经藏页 State，用于复用下载/阅读逻辑与已下载状态。
  final SutraListPageState? parent;

  /// 打开该卷时写入 [Sutra.folder] 的归属名（宗门名 / 阶段名）。
  final String? sutraFolder;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Container(
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.borderSoft, width: 0.8),
        // 展开的那一个阴影更重：经名文件夹可以同时展开多个，
        // 收起时全靠阴影就能一眼看出当前在看哪一部。
        boxShadow: [
          BoxShadow(
            color: open ? kSectActiveShadow : const Color(0x0A000000),
            blurRadius: open ? kSectActiveShadowBlur : 9,
            offset: open ? kSectActiveShadowOffset : const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                child: Row(
                  children: [
                    _buildFolderIcon(),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            group.name,
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w700,
                              color: p.text,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 5),
                          // 副行与经名首字同一条竖线（Column 对齐，不再靠缩进补）。
                          Text(
                            _groupMeta(),
                            style: TextStyle(
                              fontSize: 12.5,
                              color: p.textHint,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child:
                          Icon(Icons.expand_more, size: 22, color: p.textHint),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open) ...[
            Divider(height: 1, thickness: 1, color: p.borderSoft),
            if (group.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Text(
                  group.note,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: p.textSec,
                    height: 1.6,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            for (final ed in group.editions) _buildEdition(ed, group.hasMultipleEditions),
          ],
        ],
      ),
    );
  }

  /// 文件夹切图：assets/images/fojing.png（已导成绿色切图，两种外观共用一张）。
  /// 切图比字矮，跟经名齐着居中会显得浮在上面，所以往下压一点再落到字的中线上。
  Widget _buildFolderIcon() {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Image.asset(
        'assets/images/fojing.png',
        width: kSectFolderIconSize,
        height: kSectFolderIconSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  /// 文件夹副行：译本数 + 卷数 + 字数。多译本时提示可切换。
  String _groupMeta() {
    final parts = <String>[
      if (group.hasMultipleEditions) '${group.editions.length} 译本',
      '${group.totalVolumes} 卷',
      formatSutraWords(group.totalWords),
    ];
    return parts.join(' · ');
  }

  /// 译本分区：单卷译本直接一行（行标题即「经名·某某译」）；
  /// 多卷译本先出小标题，再逐卷列出。
  ///
  /// [marked] = 这个文件夹有多个译本：此时每一版都按译本样式标出来
  /// （绿竖杠 + 黑色加粗题名），单卷的靠行标题、多卷的靠小标题，两种结构同一套语言。
  Widget _buildEdition(SectSutraEdition edition, bool marked) {
    if (edition.isSingleUnit) {
      return _buildVolume(edition, edition.volumes.single, marked);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildEditionHeader(edition),
        for (final v in edition.volumes)
          // 上方有译本小标题，卷行按竖杠宽度缩进，与题名首字左对齐。
          _buildVolume(edition, v, false, inset: kSectEditionIndent),
      ],
    );
  }

  /// 译本小标题：题名 + 右侧 CBETA 编号。仅多分卷译本才有。
  /// 题名黑体加粗、前置竖杠染绿，与下面的卷行拉开一级，看得出是「译本」而不是某一卷。
  Widget _buildEditionHeader(SectSutraEdition edition) {
    final p = AppPalette.p;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Row(
        children: [
          Container(width: 3, height: 12, color: kSectGreen),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              edition.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: kSectEditionName,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${edition.cbeta} · ${edition.volumes.length} 卷',
            style: TextStyle(fontSize: 10.5, color: p.textHint),
          ),
        ],
      ),
    );
  }

  /// 一个分卷（单卷译本则整行就是它）。[marked] 见 [_buildEdition]；
  /// [inset] 是额外的左缩进，用来跟上方译本小标题的题名首字对齐。
  Widget _buildVolume(
    SectSutraEdition edition,
    SectSutraVolume volume,
    bool marked, {
    double inset = 0,
  }) {
    final p = AppPalette.p;
    final downloaded = parent?.isSutraDownloaded(volume.id) ?? false;
    final progress = parent?.downloadProgressOf(volume.id);
    // 已标记完成的册子：题名走全站统一的「完成」金棕色。
    final isRead = parent?.findSutra(volume.title)?.isRead ?? false;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: parent == null ? null : () => _openVolume(volume),
        child: Padding(
          padding: EdgeInsets.fromLTRB(14 + inset, 11, 14, 11),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 单卷译本在多译本文件夹里，行标题就是译本题名：
                    // 前面补一根绿竖杠、题名改黑色加粗，与多分卷译本的小标题对齐。
                    Row(
                      children: [
                        if (marked) ...[
                          Container(width: 3, height: 12, color: kSectGreen),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            edition.rowTitle(volume),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isRead
                                  ? FontWeight.w600
                                  : marked
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                              color: isRead
                                  ? kSectReadDone
                                  : marked
                                      ? kSectEditionName
                                      : p.text,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      // 单卷译本：译者已写在行标题里，副行改显 CBETA 编号。
                      // 多卷译本：编号在小标题上，副行补译者的完整署名（如朝代）。
                      edition.isSingleUnit
                          ? [
                              if (edition.cbeta.isNotEmpty) edition.cbeta,
                              formatSutraWords(volume.words)
                            ].join(' · ')
                          : '${volume.translator} · ${formatSutraWords(volume.words)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: p.textSec,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _buildStatus(downloaded, progress),
            ],
          ),
        ),
      ),
    );
  }

  /// 卷行右侧状态：已下载打勾、下载中转圈、其余显示卷序号。
  Widget _buildStatus(bool downloaded, double? progress) {
    final p = AppPalette.p;
    if (downloaded) {
      return Icon(Icons.check_circle, size: 17, color: p.readingAccent);
    }
    if (progress != null && progress < 1.0) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          value: progress <= 0 ? null : progress,
          strokeWidth: 1.4,
          color: p.textHint,
        ),
      );
    }
    return Icon(Icons.chevron_right, size: 17, color: p.textHint);
  }

  void _openVolume(SectSutraVolume volume) {
    final p = parent;
    if (p == null) return;
    p.openSutraFromChild(
      Sutra(
        volume.title,
        volume.id,
        charCount: volume.words,
        filePath: volume.assetPath,
        folder: sutraFolder,
      ),
    );
  }
}
