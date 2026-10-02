import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'sect_community_page.dart';
import 'sect_page.dart';
import 'sect_profile_card.dart';
import 'sect_profiles.dart';
import 'sect_sutra_manifest.dart';
import 'sect_switch.dart';
import 'sutra_list_page.dart';

/// 经典区的固定色：译本题前的竖杠一律绿（素白外观的主色绿），译本题名一律黑。
/// 不随外观切换，扫一眼就能分清「这是哪一版」。
const Color _kSectGreen = Color(0xFF5D7C5A);
const Color _kEditionName = Color(0xFF1A1A1A);

/// 文件夹切图边长。
const double _kFolderIconSize = 19;

/// 译本竖杠（3）+ 竖杠到题名的间距（8）：卷行按它左缩进，与译本题名首字对齐。
const double _kEditionIndent = 11;

/// 顶部水墨背景图 assets/menpai/bj.webp（原始 PNG 1376×473，约 293 KB，
/// 已转 WebP q95 压到 67 KB，PSNR 74 dB 肉眼无差）。
/// 山峰/叶脉是白底上的淡墨，直接压在页面底色上会露白块，
/// 所以整体用页面底色做一次正片叠底（modulate），两种外观下都与页面无缝。
const String _kHeaderBg = 'assets/menpai/bj.webp';

/// 高宽比 473/1376：标题区按原图比例取高，山峰与叶尖都不被裁掉。
const double _kHeaderAspect = 473 / 1376;

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
  const SectDetailPage({
    super.key,
    required this.sect,
    this.parent,
    this.initialTab = 0,
  });

  final SectInfo sect;

  /// 经藏页 State，用于复用下载/阅读逻辑。
  final SutraListPageState? parent;

  /// 进来先停在哪一侧：0 核心经典，1 xx社区。
  /// 从菩提空间/顶部展示位点「进入社区」时传 1，直接落在社区那一半。
  final int initialTab;

  @override
  State<SectDetailPage> createState() => _SectDetailPageState();
}

class _SectDetailPageState extends State<SectDetailPage> {
  Future<SectSutraManifest> _future = SectSutraManifest.load();

  /// 0 = 核心经典（左），1 = xx社区（右）。两半既是 [SectSwitch] 点出来的，
  /// 也是左右拖出来的，两条路都落到这个 [index] 上。
  late int _tab = widget.initialTab;

  /// 当前这次横向拖拽累计走过的横向距离：往左拖过 [_dragThreshold] 切到社区，
  /// 往右拖过就切回经典。拖的过程中**不搬动任何东西**，松手直接换内容。
  double _dragX = 0;

  /// 换边所需的横向拖拽距离（逻辑像素）。取 56：比控件最小可拖距离大、比半屏小，
  /// 轻轻一带不至于误切，拇指一划又能到位。
  static const double _dragThreshold = 56;

  /// 社区内容的 State：外层要用它的 [CommunitySectionState.openCompose] 挂发帖浮钮。
  final GlobalKey<CommunitySectionState> _communityKey =
      GlobalKey<CommunitySectionState>();

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

  /// 换边：点胶囊或横向拖过阈值都走这里。[_tab] 一变，右下角浮钮与社区侧的
  /// [CommunitySection.active] 立刻跟着换；两半各自留着自己的滚动位置，切回来还在原处。
  void _goTo(int i) {
    if (i == _tab) return;
    setState(() => _tab = i);
  }

  /// 横向拖拽换边：只累计距离、**不跟着手指搬动画面**，松手才决定换不换。
  /// 竖向滚动照旧由两半自己的滚动区处理（竖直手势赢不了这里的手势竞技场）。
  void _onDragStart(DragStartDetails _) {
    _dragX = 0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _dragX += d.delta.dx;
  }

  void _onDragEnd(DragEndDetails _) {
    if (_dragX <= -_dragThreshold) {
      _goTo(1);
    } else if (_dragX >= _dragThreshold) {
      _goTo(0);
    }
    _dragX = 0;
  }

  @override
  void didUpdateWidget(SectDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sect.name != widget.sect.name) {
      // 栏目页原地换 sect 时，State 是被复用的：不 setState 的话这一帧仍是
      // 旧栏目的经典与展开状态（_updateBackToTop 不一定触发 setState）。
      setState(() {
        _expanded.clear();
        _future = SectSutraManifest.load();
      });
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
      // 浮钮跟着当前这一侧走：经典侧是「回到顶部」，社区侧是「发帖」。
      floatingActionButton: _tab == 0
          ? (_showBackToTop ? _buildBackToTopButton() : null)
          : _buildComposeButton(p),
      body: SafeArea(child: _buildTabBody(p)),
    );
  }

  /// 社区那一侧的「发帖」浮钮：与「我的」页发帖浮钮同款配色，只换 heroTag。
  Widget _buildComposeButton(PaletteData p) {
    return Padding(
      padding: const EdgeInsets.only(left: 18, bottom: 30),
      child: SizedBox(
        width: 42,
        height: 42,
        child: FloatingActionButton(
          heroTag: 'sect_detail_compose_fab',
          onPressed: () => _communityKey.currentState?.openCompose(),
          backgroundColor:
              AppPalette.instance.isPlain ? const Color(0xFF1A1A1A) : const Color(0xFF71867A),
          elevation: 8,
          highlightElevation: 12,
          shape: const CircleBorder(),
          child: Image.asset('assets/images/write.png', width: 21, height: 21),
        ),
      ),
    );
  }

  /// 页顶结构：标题图 + 切换胶囊 + 下方内容，三者同属一页。
  ///
  /// 左右**不推整页**：拖动只累计距离（[_onDragUpdate]），松手才把 [_tab] 换过去，
  /// 画面上没有任何东西跟着手指横移——换的只是「菜单选中哪一段 + 下方是哪份内容」。
  ///
  /// 头部（标题图 + 胶囊）放在两半各自的内容里，所以上滑内容时它跟着一起滚走、隐藏；
  /// 切到另一半时换成那一半自己的头。非当前侧用 [Offstage] 留在树上：既不画也不参与
  /// 命中测试，切回来时滚动位置还在原地。
  Widget _buildTabBody(PaletteData p) {
    // 换边的横向手势**只在经典那一侧参赛**：社区侧的横滑由它内部三个选项卡的
    // PageView 认领，两边同时挂横向手势会一起进手势竞技场，一次滑动可能切两层。
    // 社区停在最左（热门）再往右滑时，由 CommunitySection 通过 onSwipeBack 外传。
    final bool classicSide = _tab == 0;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: classicSide ? _onDragStart : null,
      onHorizontalDragUpdate: classicSide ? _onDragUpdate : null,
      onHorizontalDragEnd: classicSide ? _onDragEnd : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: _tab != 0,
            child: _buildBodyWithProgress(p),
          ),
          Offstage(
            offstage: _tab != 1,
            child: CommunitySection(
              key: _communityKey,
              sect: widget.sect,
              active: _tab == 1,
              header: _buildHeader(p),
              onSwipeBack: () => _goTo(0),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部标题区：通用水墨背景图铺满（降透明度让题字更清楚），返回键浮在图上，
  /// 宗派/法门名与副标题在图中留白处上下居中，**图下方**挂一颗左右切换胶囊。
  /// 它是内容滚动区的第一项，所以上滑时连图带胶囊一起滚走、隐藏；
  /// 旧版右下角那个「xx社区」入口已由胶囊取代，删掉。
  Widget _buildHeader(PaletteData p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBanner(p),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 14, 28, 14),
          child: SectSwitch(
            index: _tab,
            onChanged: _goTo,
            leftLabel: '核心经典',
            rightLabel: '${widget.sect.name}社区',
            tone: communityTone(AppPalette.instance.isPlain),
          ),
        ),
      ],
    );
  }

  /// 标题图本体（水墨背景 + 返回键 + 栏目图标 + 栏目名 + 副标题）。
  /// 由 [_buildHeader] 摆在切换条上方，两半各挂各的，都随自己那半内容滚动。
  Widget _buildBanner(PaletteData p) {
    final width = MediaQuery.sizeOf(context).width;
    // 竖屏按裁短后的原图比例整幅铺开（约 0.34 倍屏宽）；横屏/宽屏按上下限截断。
    // 下限压到 118：图矮了，图标+题字+副标题仍放得下，但不再白占一截屏幕。
    final height = (width * _kHeaderAspect).clamp(118.0, 190.0);
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 通用水墨图：淡淡压一层页面底色（正片叠底），两种外观下都与页面无缝。
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
          Positioned(
            left: 24,
            right: 24,
            top: 0,
            bottom: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 栏目图标压在配图正中偏上，题字与副标题依次落在它下面。
// 跟着裁短后的图一起收小到 40，保证图标+题字+副标题在 118pt 里排得下。
                  Opacity(
                    opacity: 0.92,
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: _buildSectIcon(),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 名字长的栏目（如「普贤行愿法门」）等比缩小，不出横向滚动。
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      // 不再缀「· 核心经典」：当前停在哪一侧由钉住的切换条说明。
                      widget.sect.name,
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
        ],
      ),
    );
  }

  /// 栏目图标：与宗门菜单页同一套切图规则（法门走 `assets/famen/`、
  /// 宗门走 `assets/menpai/`、律宗没有切图改手绘）。
  /// 原先这块在社区页 banner 上，社区并进本页后跟着挪到顶图上。
  Widget _buildSectIcon() {
    final isPlain = AppPalette.instance.isPlain;
    final gate = widget.sect.icon.gateCode;
    if (gate.isNotEmpty) {
      final suffix = isPlain ? '' : '2';
      return Image.asset(
        'assets/famen/$gate$suffix.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
    }
    final code = widget.sect.icon.assetCode;
    if (code.isEmpty) {
      // 律宗：没有切图，用页面既有的手绘门形兜住。
      return CustomPaint(
        painter: GatePainter(
          color: isPlain ? const Color(0xFF000000) : kCommunityWarm,
        ),
      );
    }
    final suffix = isPlain ? '1' : '2';
    return Image.asset(
      'assets/menpai/$code$suffix.png',
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
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

  /// 加载/提示态把头部一并放进滚动区：上滑时背景图与胶囊跟着走。
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

  /// 头部在最前随内容上滑滚走，统计条次之、介绍再次，之后才是经典文件夹。
  Widget _buildBody(PaletteData p, SectSutraSect sect) {
    final profile = _profile;
    // 有介绍时占两格（统计条 + 介绍），否则只有统计条；第 0 格固定给标题图 + 胶囊。
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
