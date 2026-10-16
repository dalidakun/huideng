import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'sect_community_page.dart';
import 'sect_page.dart';
import 'sect_profile_card.dart';
import 'sect_profiles.dart';
import 'sect_sutra_list.dart';
import 'sect_sutra_manifest.dart';
import 'sect_switch.dart';
import 'sutra_list_page.dart';

/// 顶部水墨背景图 assets/menpai/bj.webp（原始 PNG 1376×473，约 293 KB，
/// 已转 WebP q95 压到 67 KB，PSNR 74 dB 肉眼无差）。
/// 山峰/叶脉是白底上的淡墨，直接压在页面底色上会露白块，
/// 所以整体用页面底色做一次正片叠底（modulate），两种外观下都与页面无缝。
const String _kHeaderBg = 'assets/menpai/bj.webp';

/// 高宽比 473/1376：标题区按原图比例取高，山峰与叶尖都不被裁掉。
const double _kHeaderAspect = 473 / 1376;

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

class _SectDetailPageState extends State<SectDetailPage> with RouteAware {
  Future<SectSutraManifest> _future = SectSutraManifest.load();

  /// 订阅 [routeObserver] 一次的标记：didChangeDependencies 可能多次触发。
  bool _routeSubscribed = false;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null && !_routeSubscribed) {
      _routeSubscribed = true;
      routeObserver.subscribe(this, route);
    }
  }

  /// 从阅读页返回本页（在那里可能「标记完成」）：
  /// 重读已读标记并重绘，让完成的册子显示统一的完成色。
  @override
  void didPopNext() => _syncReadFlags();

  Future<void> _syncReadFlags() async {
    await widget.parent?.reloadReadFlags();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (_routeSubscribed) routeObserver.unsubscribe(this);
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
    final fixed = widget.sect.icon.fixedAsset;
    if (fixed.isNotEmpty) {
      return Image.asset(
        fixed,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
    }
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
        if (index == 1) {
          return _pad(SectStatsBar(
            classics: sect.groups.length,
            editions: sect.totalEditions,
            volumes: sect.totalVolumes,
            words: sect.totalWords,
          ));
        }
        if (profile != null && index == 2) {
          return _pad(SectProfileCard(
            profile: profile,
            title: widget.sect.kind == SectMenuKind.gate ? '法门介绍' : '宗派介绍',
          ));
        }
        final group = sect.groups[index - 1 - head];
        return _pad(SectSutraGroupCard(
          group: group,
          open: _expanded.contains(group.key),
          onToggle: () => _toggle(group.key),
          parent: widget.parent,
          sutraFolder: widget.sect.name,
        ));
      },
    );
  }
}

