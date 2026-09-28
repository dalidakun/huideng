import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'sect_page.dart';
import 'sect_profile_card.dart';
import 'sect_profiles.dart';
import 'sect_sutra_manifest.dart';
import 'sutra_list_page.dart';

/// 经典区的固定色：译本题前的竖杠一律绿（素白外观的主色绿），译本题名一律黑。
/// 不随外观切换，扫一眼就能分清「这是哪一版」。
const Color _kSectGreen = Color(0xFF5D7C5A);
const Color _kEditionName = Color(0xFF1A1A1A);

/// 文件夹切图边长与它到经名的间距；「几译本 · 几卷」副行按这个整体左缩进，
/// 于是副行与经名的首字同一条竖线。
const double _kFolderIconSize = 19;
const double _kFolderIconGap = 8;

/// 译本竖杠（3）+ 竖杠到题名的间距（8）：卷行按它左缩进，与译本题名首字对齐。
const double _kEditionIndent = 11;

/// 展开中的经典文件夹专用阴影：比 App 常规卡片阴影略重，
/// 经名文件夹可以同时展开多个，靠这层阴影就能一眼看出当前在读哪一部。
const Color _kActiveShadow = Color(0x14000000);
const double _kActiveShadowBlur = 12;
const Offset _kActiveShadowOffset = Offset(0, 3);

/// 宗门/法门核心经典详情页。
///
/// 结构是「经典文件夹 → 译本 → 分卷」：同一部经的不同译者收在同一个文件夹下，
/// 译本题名为「金刚经·鸠摩罗什译」，点卷进入阅读页。宗门与法门共用本页。
///
/// 正文不在本页加载，统一点击后交给经藏页的 [SutraListPageState.openSutraFromChild]，
/// 复用其下载进度、已下载判断与「下载完成」提示。
class SectDetailPage extends StatefulWidget {
  const SectDetailPage({super.key, required this.sect, this.parent});

  final SectInfo sect;

  /// 经藏页 State，用于复用下载/阅读逻辑。
  final SutraListPageState? parent;

  @override
  State<SectDetailPage> createState() => _SectDetailPageState();
}

class _SectDetailPageState extends State<SectDetailPage> {
  Future<SectSutraManifest> _future = SectSutraManifest.load();

  /// 展开的文件夹（经典）名，用清单里的稳定 key 而非显示名，
  /// 免得同名文件夹在不同宗门/法门下互相串状态。
  final Set<String> _expanded = <String>{};

  /// 当前栏目的介绍；法门为 null（详情页据此跳过介绍块）。
  SectProfile? get _profile => sectProfileOf(widget.sect);

  @override
  void didUpdateWidget(SectDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sect.name != widget.sect.name) {
      _expanded.clear();
      _future = SectSutraManifest.load();
    }
  }

  void _toggle(String groupKey) {
    setState(() {
      if (!_expanded.remove(groupKey)) _expanded.add(groupKey);
    });
  }

  void _openVolume(SectSutraVolume volume) {
    final parent = widget.parent;
    if (parent == null) return;
    parent.openSutraFromChild(
      Sutra(
        volume.title,
        volume.id,
        charCount: volume.words,
        filePath: volume.assetPath,
        folder: widget.sect.name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(p),
            Expanded(child: _buildBodyWithProgress(p)),
          ],
        ),
      ),
    );
  }

  /// 顶栏：返回键 + 宗名/法门名 + 副标题（其余菜单页无返回键，本页为二级页）。
  Widget _buildTopBar(PaletteData p) {
    return SizedBox(
      width: double.infinity,
      height: 46,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: Icon(Icons.arrow_back_ios_new, size: 18, color: p.primary),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            const SizedBox(width: 6),
            Text(
              widget.sect.name,
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
            Expanded(
              child: Text(
                '核心经典',
                style: TextStyle(color: p.textSec, fontSize: 12),
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessage(PaletteData p, String text) {
    return Center(
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: p.textHint, letterSpacing: 0.6),
      ),
    );
  }

  /// 卷行的已下载打勾与下载进度来自经藏页，随其 [SutraListPageState.sutraDataVersion]
  /// 一起刷新，否则点下载后本页状态不会动。
  Widget _buildBodyWithProgress(PaletteData p) {
    final version = widget.parent?.sutraDataVersion;
    if (version == null) return _buildManifest(p);
    return ValueListenableBuilder<int>(
      valueListenable: version,
      builder: (context, _, __) => _buildManifest(p),
    );
  }

  Widget _buildManifest(PaletteData p) {
    return FutureBuilder<SectSutraManifest>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 1.2, color: p.textHint),
            ),
          );
        }
        if (snap.hasError) {
          return _buildMessage(p, '经典清单加载失败');
        }
        final manifest = snap.data ?? SectSutraManifest.empty;
        final data = manifest.byName(widget.sect.name);
        if (data == null || data.groups.isEmpty) {
          return _buildMessage(p, '核心经典整理中');
        }
        return _buildBody(p, data);
      },
    );
  }

  /// 概览在前、介绍次之，之后才是经典文件夹。
  Widget _buildBody(PaletteData p, SectSutraSect sect) {
    final profile = _profile;
    // 有介绍时头部占两格（概览 + 介绍），否则只有概览。
    final head = profile == null ? 1 : 2;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 28),
      itemCount: sect.groups.length + head,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == 0) return _buildSummary(p, sect);
        if (profile != null && index == 1) {
          return SectProfileCard(
            profile: profile,
            title: widget.sect.kind == SectMenuKind.gate ? '法门介绍' : '宗派介绍',
          );
        }
        return _buildGroup(p, sect.groups[index - head]);
      },
    );
  }

  /// 概览：经典文件夹数、译本数、分卷数、总字数。
  Widget _buildSummary(PaletteData p, SectSutraSect sect) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.sect.desc,
            style: TextStyle(
              fontSize: 12.5,
              color: p.textSec,
              height: 1.8,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${sect.groups.length} 部经典 · ${sect.totalEditions} 译本 · '
            '${sect.totalVolumes} 卷 · ${_formatWords(sect.totalWords)}',
            style: TextStyle(fontSize: 12, color: p.textHint, letterSpacing: 0.3),
          ),
        ],
      ),
    );
  }

  /// 一个经典文件夹：折叠时是经名，展开后按译本分区列出分卷。
  Widget _buildGroup(PaletteData p, SectSutraGroup group) {
    final open = _expanded.contains(group.key);
    return Container(
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.borderSoft, width: 0.8),
        // 展开的那一个给一层阴影：经名文件夹可以同时展开多个，
        // 收起时全靠阴影就能一眼看出当前在看哪一部。
        boxShadow: open
            ? const [
                BoxShadow(
                  color: _kActiveShadow,
                  blurRadius: _kActiveShadowBlur,
                  offset: _kActiveShadowOffset,
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _toggle(group.key),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
                // 图标、经名、折叠箭头同一行（Row 默认垂直居中），
                // 「几译本 · 几卷」退到第二行并左对齐经名，不再把图标拽偏。
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _buildFolderIcon(),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            group.name,
                            style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                              color: p.text,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        AnimatedRotation(
                          turns: open ? 0.5 : 0,
                          duration: const Duration(milliseconds: 180),
                          child:
                              Icon(Icons.expand_more, size: 20, color: p.textHint),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(
                          left: _kFolderIconSize + _kFolderIconGap),
                      child: Text(
                        _groupMeta(group),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: p.textHint,
                          letterSpacing: 0.2,
                        ),
                      ),
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
            for (final ed in group.editions)
              _buildEdition(p, ed, group.hasMultipleEditions),
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
        width: _kFolderIconSize,
        height: _kFolderIconSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  /// 文件夹副行：译本数 + 卷数 + 字数。多译本时提示可切换。
  String _groupMeta(SectSutraGroup group) {
    final parts = <String>[
      if (group.hasMultipleEditions) '${group.editions.length} 译本',
      '${group.totalVolumes} 卷',
      _formatWords(group.totalWords),
    ];
    return parts.join(' · ');
  }

  /// 译本分区：单卷译本直接一行（行标题即「经名·某某译」）；
  /// 多卷译本先出小标题，再逐卷列出。
  ///
  /// [marked] = 这个文件夹有多个译本：此时每一版都按译本样式标出来
  /// （绿竖杠 + 黑色加粗题名），单卷的靠行标题、多卷的靠小标题，两种结构同一套语言。
  Widget _buildEdition(
    PaletteData p,
    SectSutraEdition edition,
    bool marked,
  ) {
    if (edition.isSingleUnit) {
      return _buildVolume(p, edition, edition.volumes.single, marked);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildEditionHeader(p, edition),
        for (final v in edition.volumes)
          // 上方有译本小标题，卷行按竖杠宽度缩进，与题名首字左对齐。
          _buildVolume(p, edition, v, false, inset: _kEditionIndent),
      ],
    );
  }

  /// 译本小标题：题名 + 右侧 CBETA 编号。仅多分卷译本才有。
  /// 题名黑体加粗、前置竖杠染绿，与下面的卷行拉开一级，看得出是「译本」而不是某一卷。
  Widget _buildEditionHeader(PaletteData p, SectSutraEdition edition) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Row(
        children: [
          Container(width: 3, height: 12, color: _kSectGreen),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              edition.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _kEditionName,
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
    PaletteData p,
    SectSutraEdition edition,
    SectSutraVolume volume,
    bool marked, {
    double inset = 0,
  }) {
    final parent = widget.parent;
    final downloaded = parent?.isSutraDownloaded(volume.id) ?? false;
    final progress = parent?.downloadProgressOf(volume.id);

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
                          Container(width: 3, height: 12, color: _kSectGreen),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            edition.rowTitle(volume),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: marked
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: marked ? _kEditionName : p.text,
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
                          ? [if (edition.cbeta.isNotEmpty) edition.cbeta,
                              _formatWords(volume.words)].join(' · ')
                          : '${volume.translator} · ${_formatWords(volume.words)}',
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
              _buildStatus(p, downloaded, progress),
            ],
          ),
        ),
      ),
    );
  }

  /// 卷行右侧状态：已下载打勾、下载中转圈、其余显示卷序号。
  Widget _buildStatus(PaletteData p, bool downloaded, double? progress) {
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

  /// 字数：过万折算为「x.x 万字」，与经藏页量级一致。
  String _formatWords(int n) {
    if (n < 10000) return '$n 字';
    final w = n / 10000;
    return '${w.toStringAsFixed(w >= 100 ? 0 : 1)} 万字';
  }
}
