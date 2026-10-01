import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'sect_community_page.dart';
import 'sect_page.dart';
import 'sect_profile_card.dart';
import 'sect_profiles.dart';
import 'sect_sutra_manifest.dart';
import 'sutra_list_page.dart';

/// 经典区的固定色：译本题前的竖杠一律绿（素白外观的主色绿），译本题名一律黑。
/// 不随外观切换，扫一眼就能分清「这是哪一版」。
const Color _kSectGreen = Color(0xFF5D7C5A);
const Color _kEditionName = Color(0xFF1A1A1A);

/// 文件夹切图边长。
const double _kFolderIconSize = 19;

/// 译本竖杠（3）+ 竖杠到题名的间距（8）：卷行按它左缩进，与译本题名首字对齐。
const double _kEditionIndent = 11;

/// 顶部水墨背景图 assets/menpai/bj.png（1376×561，按标题区裁短过一版），
/// 山峰/叶脉是白底上的淡墨，直接压在页面底色上会露白块，
/// 所以整体用页面底色做一次正片叠底（modulate），两种外观下都与页面无缝。
const String _kHeaderBg = 'assets/menpai/bj.png';

/// 高宽比 561/1376：标题区按原图比例取高，山峰与叶尖都不被裁掉。
const double _kHeaderAspect = 561 / 1376;

/// 顶部社区入口：胶囊底色与社区页 banner 同色（communityTone）。


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

  /// 经典列表的滚动控制器：撑满一屏的经文文件夹展开后，
  /// 上滑翻卷很难再摸回顶栏，右下角的「回到顶部」箭头就靠它复位。
  final ScrollController _listScroll = ScrollController();

  /// 「回到顶部」箭头的显隐：只有打开了文件夹且往下滑过一段才出现，默认隐藏。
  bool _showBackToTop = false;

  /// 当前栏目的介绍；法门为 null（详情页据此跳过介绍块）。
  SectProfile? get _profile => sectProfileOf(widget.sect);

  @override
  void initState() {
    super.initState();
    _listScroll.addListener(_updateBackToTop);
  }

  @override
  void dispose() {
    _listScroll.removeListener(_updateBackToTop);
    _listScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(SectDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sect.name != widget.sect.name) {
      _expanded.clear();
      _future = SectSutraManifest.load();
      _updateBackToTop();
    }
  }

  void _toggle(String groupKey) {
    setState(() {
      if (!_expanded.remove(groupKey)) _expanded.add(groupKey);
    });
    // 文件夹开合会改变内容长度，显隐跟着重算。
    _updateBackToTop();
  }

  /// 「打开文件夹」与「上滑了一段」两个条件同时成立才露出箭头，
  /// 停在顶部或所有文件夹都收起时保持隐藏。
  void _updateBackToTop() {
    final show =
        _expanded.isNotEmpty && _listScroll.hasClients && _listScroll.offset > 60;
    if (show != _showBackToTop) {
      setState(() => _showBackToTop = show);
    }
  }

  /// 回到顶部：与菩提空间右下角那颗箭头同一套样式与位置。
  void _scrollToTop() {
    if (_listScroll.hasClients && _listScroll.offset > 0) {
      _listScroll.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  /// 42 圆钮 + top.png 白色上箭头，底色随外观切换（素白黑底 / 米黄青绿底）。
  /// 底距比菩提空间那颗再抬高一截，避开底部手势条与页面下缘。
  Widget _buildBackToTopButton() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 40),
      child: SizedBox(
        width: 42,
        height: 42,
        child: FloatingActionButton(
          onPressed: _scrollToTop,
          heroTag: 'sect_detail_back_to_top',
          backgroundColor: AppPalette.instance.isPlain
              ? const Color(0xFF1A1A1A)
              : const Color(0xFF71867A),
          elevation: 8,
          highlightElevation: 12,
          shape: const CircleBorder(),
          child: Image.asset(
            'assets/images/top.png',
            width: 21,
            height: 21,
          ),
        ),
      ),
    );
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
      // 文件夹展开、上滑一段后才露出；停在顶部时整颗按钮隐藏。
      floatingActionButton:
          _showBackToTop ? _buildBackToTopButton() : null,
      body: SafeArea(child: _buildBodyWithProgress(p)),
    );
  }

  /// 顶部标题区：水墨背景图铺满（降透明度让题字更清楚），返回键与社区入口浮在图上，
  /// 宗派/法门名与副标题在图中留白处上下居中（示意图同款，旧的 46px 顶栏取消）。
  /// 头部作为滚动区第一项，上滑时随内容一起移出屏幕，不固定在顶部。
  Widget _buildHeader(PaletteData p) {
    final width = MediaQuery.sizeOf(context).width;
    // 竖屏取原图比例整幅铺开；横屏/宽屏按上下限截断，免得标题区吃掉半屏或被压扁。
    final height = (width * _kHeaderAspect).clamp(140.0, 240.0);
    return SizedBox(
      width: double.infinity,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColorFiltered(
            colorFilter: ColorFilter.mode(p.bg, BlendMode.modulate),
            child: Opacity(
              opacity: 0.4,
              child: Image.asset(
                _kHeaderBg,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
          Positioned(
            top: 2,
            left: 6,
            child: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_ios_new,
                  size: 20, color: Color(0xFF1A1A1A)),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            ),
          ),
          // 题字压在图中留白带（原图 x512~896、y208~456 全白）并上下居中，
          // 左右山与叶子不抢字，读起来最清爽。
          Positioned(
            left: 24,
            right: 24,
            top: 0,
            bottom: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 名字长的栏目（如「普贤行愿法门 · 核心经典」）等比缩小，不出横向滚动。
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${widget.sect.name} · 核心经典',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                        letterSpacing: 1.5,
                        height: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    widget.sect.desc,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF9E9588),
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 「xx社区」挪到图右下角，与左上角返回键成对角；边距取 12，
          // 与图缘、题字块都留出呼吸位，不压居中的题字。
          Positioned(
            right: 12,
            bottom: 12,
            child: _buildCommunityEntry(p),
          ),
        ],
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
          return _headerShell(
            p,
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 1.2, color: p.textHint),
            ),
          );
        }
        if (snap.hasError) {
          return _headerShell(p, _buildMessage(p, '经典清单加载失败'));
        }
        final manifest = snap.data ?? SectSutraManifest.empty;
        final data = manifest.byName(widget.sect.name);
        if (data == null || data.groups.isEmpty) {
          return _headerShell(p, _buildMessage(p, '核心经典整理中'));
        }
        return _buildBody(p, data);
      },
    );
  }

  /// 加载/提示态同样把头部放进滚动区：上滑时背景图随内容一起走，不钉在顶部。
  Widget _headerShell(PaletteData p, Widget child) {
    return ListView(
      controller: _listScroll,
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        _buildHeader(p),
        SizedBox(height: 200, child: Center(child: child)),
      ],
    );
  }

  /// 头部整幅出血；其余条目自带左右边距，与旧版列表边距一致。
  Widget _pad(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: child,
      );

  /// 头部在最前随页滚动，统计条次之、介绍再次，之后才是经典文件夹。
  Widget _buildBody(PaletteData p, SectSutraSect sect) {
    final profile = _profile;
    // 有介绍时占两格（统计条 + 介绍），否则只有统计条；第 0 格固定给标题图。
    final head = profile == null ? 1 : 2;
    return ListView.separated(
      controller: _listScroll,
      padding: const EdgeInsets.only(bottom: 28),
      itemCount: sect.groups.length + head + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index == 0) return _buildHeader(p);
        if (index == 1) return _pad(_buildStatsBar(p, sect));
        if (profile != null && index == 2) {
          return _pad(SectProfileCard(
            profile: profile,
            title: widget.sect.kind == SectMenuKind.gate ? '法门介绍' : '宗派介绍',
          ));
        }
        return _pad(_buildGroup(p, sect.groups[index - 1 - head]));
      },
    );
  }

  /// 统计条：经典 / 译本 / 卷 / 字数四项。四项等宽均分铺满整行，右端不再空一块；
  /// 项多字长（如「24.6 万字」）时单项等比缩小，宁可小一号也不折行。
  Widget _buildStatsBar(PaletteData p, SectSutraSect sect) {
    final plain = AppPalette.instance.isPlain;
    final bg =
        plain ? const Color(0xFFF2F2F2) : const Color(0xFFEFE8DC);
    final fg = plain ? const Color(0xFF3C3C3C) : const Color(0xFF4A3F35);
    // 四项前面的图标：素白外观用墨绿，米黄外观用暖金。
    final icon = plain ? _kSectGreen : const Color(0xFFD09D66);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 13),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _statCell(_statItem(
              fg, icon, Icons.layers_outlined, '${sect.groups.length} 部经典')),
          _statDot(fg),
          _statCell(_statItem(fg, icon, Icons.menu_book_outlined,
              '${sect.totalEditions} 译本')),
          _statDot(fg),
          _statCell(_statItem(
              fg, icon, Icons.book_outlined, '${sect.totalVolumes} 卷')),
          _statCell(Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 1, height: 13, color: fg.withValues(alpha: 0.35)),
              const SizedBox(width: 6),
              _wordsGlyph(icon),
              const SizedBox(width: 5),
              Text(
                _formatWords(sect.totalWords),
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
        decoration:
            BoxDecoration(color: fg.withValues(alpha: 0.45), shape: BoxShape.circle),
      );

  /// 「字数」小徽标：描边方框里一个「字」，与示意图第四个图标一致。
  Widget _wordsGlyph(Color fg) {
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: fg, width: 1.2),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text('字',
          style: TextStyle(fontSize: 8.5, color: fg, height: 1.0)),
    );
  }

  /// 右下角「进入社区」入口：浅色本色胶囊（本宗名 + ›），与左上角返回键成对角。
  /// 底色取 communityTone 再向白色提亮三成——原色在水墨图上压得太重；
  /// 提亮后白字对比不够，字与箭头改用本页正文色，社区页 banner 仍用原色。
  Widget _buildCommunityEntry(PaletteData p) {
    final tone = Color.lerp(
        communityTone(AppPalette.instance.isPlain), Colors.white, 0.30)!;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openCommunity,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        decoration: BoxDecoration(
          color: tone,
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: tone.withValues(alpha: 0.35),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${widget.sect.name}社区',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: p.text,
                letterSpacing: 0.5,
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: p.text),
          ],
        ),
      ),
    );
  }

  /// 进入该宗门/法门的社区页。
  void _openCommunity() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SectCommunityPage(sect: widget.sect)),
    );
  }

  /// 一个经典文件夹：折叠时是经名，展开后按译本分区列出分卷。
  /// 收起态与示意图一致——图标、经名/副行、右侧居中的下箭头同一行。
  Widget _buildGroup(PaletteData p, SectSutraGroup group) {
    final open = _expanded.contains(group.key);
    return Container(
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.borderSoft, width: 0.8),
        // 展开的那一个阴影更重：经名文件夹可以同时展开多个，
        // 收起时全靠阴影就能一眼看出当前在看哪一部。
        boxShadow: [
          BoxShadow(
            color: open ? _kActiveShadow : const Color(0x0A000000),
            blurRadius: open ? _kActiveShadowBlur : 9,
            offset: open ? _kActiveShadowOffset : const Offset(0, 2),
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
              onTap: () => _toggle(group.key),
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
                            _groupMeta(group),
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
                      child: Icon(Icons.expand_more,
                          size: 22, color: p.textHint),
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
