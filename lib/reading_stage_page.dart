import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'note_sutra_links.dart' show sutraVolumeLabel;
import 'reading_stage_data.dart';
import 'sect_sutra_list.dart';
import 'sect_sutra_manifest.dart';
import 'sutra_asset_path.dart';
import 'sutra_downloader.dart';
import 'sutra_list_page.dart';

/// 顶部水墨背景图：与宗门/法门核心经典详情页同一张。
const String _kHeaderBg = 'assets/menpai/bj.webp';

/// 高宽比 473/1376：标题区按原图比例取高，山峰与叶尖都不被裁掉。
const double _kHeaderAspect = 473 / 1376;

/// 「百册经论指南」某一阶段的读经页。
///
/// 从经藏页「百册经论指南」的阶段卡片滑入（[slideInFromLeft]）。列表结构与
/// [SectDetailPage] 的「核心经典」完全一致：经典文件夹 → 译本 → 分卷，
/// 展开文件夹时在顶部显示该经介绍；点分卷进入阅读，复用经藏页的下载/已读逻辑。
class ReadingStagePage extends StatefulWidget {
  const ReadingStagePage({
    super.key,
    required this.stage,
    this.parent,
    this.headerTitle,
    this.headerSubtitle,
    this.headerIcon,
    this.showGroupProgress = false,
  });

  final ReadingStage stage;

  /// 经藏页 State，用于复用下载/阅读逻辑与已下载状态。
  final SutraListPageState? parent;

  /// banner 标题覆盖：非空时显示该文案（如「廿册精选典籍」），
  /// 否则沿用「阶段X · 阶段名」。同时作为「是否自定义 banner」的开关。
  final String? headerTitle;

  /// banner 副标题覆盖：为空时沿用 [ReadingStage.title]。
  final String? headerSubtitle;

  /// banner 图标覆盖：自定义 banner 时用它（为空则不显示图标）。
  final String? headerIcon;

  /// 是否在每个经典文件夹副标题追加「已完成 已读/总卷」进度
  /// （廿册页与百册阶段页开启；宗门/法门详情页不用本页、保持原样式）。
  final bool showGroupProgress;

  @override
  State<ReadingStagePage> createState() => _ReadingStagePageState();
}

class _ReadingStagePageState extends State<ReadingStagePage> with RouteAware {
  /// 展开的经典文件夹名（用阶段内稳定的 key）。
  final Set<String> _expanded = <String>{};

  final ScrollController _listScroll = ScrollController();

  bool _showBackToTop = false;

  bool _routeSubscribed = false;

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

  void _toggle(String groupKey) {
    setState(() {
      if (!_expanded.remove(groupKey)) _expanded.add(groupKey);
    });
    _updateBackToTop();
  }

  void _updateBackToTop() {
    final show = _expanded.isNotEmpty &&
        _listScroll.hasClients &&
        _listScroll.offset > 60;
    if (show != _showBackToTop) {
      setState(() => _showBackToTop = show);
    }
  }

  void _scrollToTop() {
    if (_listScroll.hasClients && _listScroll.offset > 0) {
      _listScroll.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  /// 与宗门/法门核心经典详情页同一套「回到顶部」浮钮。
  Widget _buildBackToTopButton() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 40),
      child: SizedBox(
        width: 42,
        height: 42,
        child: FloatingActionButton(
          onPressed: _scrollToTop,
          heroTag: 'reading_stage_back_to_top',
          backgroundColor: AppPalette.instance.isPlain
              ? const Color(0xFF1A1A1A)
              : const Color(0xFF71867A),
          elevation: 8,
          highlightElevation: 12,
          shape: const CircleBorder(),
          child: Image.asset('assets/images/top.png', width: 21, height: 21),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final version = widget.parent?.sutraDataVersion;
    return Scaffold(
      backgroundColor: p.bg,
      floatingActionButton: _showBackToTop ? _buildBackToTopButton() : null,
      body: SafeArea(
        child: version == null
            ? _buildBody(p)
            : ValueListenableBuilder<int>(
                valueListenable: version,
                builder: (context, _, __) => _buildBody(p),
              ),
      ),
    );
  }

  Widget _pad(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: child,
      );

  Widget _buildBody(PaletteData p) {
    final groups = _buildGroups();
    if (groups.isEmpty) {
      return ListView(
        controller: _listScroll,
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          _buildBanner(p),
          const SizedBox(height: 200),
          Center(
            child: Text(
              '本阶段经典整理中',
              style: TextStyle(fontSize: 13, color: p.textHint),
            ),
          ),
        ],
      );
    }

    var editions = 0;
    var volumes = 0;
    var words = 0;
    for (final g in groups) {
      editions += g.editions.length;
      volumes += g.totalVolumes;
      words += g.totalWords;
    }

    return ListView.separated(
      controller: _listScroll,
      padding: const EdgeInsets.only(bottom: 28),
      itemCount: groups.length + 2,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index == 0) return _buildBanner(p);
        if (index == 1) {
          return _pad(SectStatsBar(
            classics: groups.length,
            editions: editions,
            volumes: volumes,
            words: words,
          ));
        }
        final group = groups[index - 2];
        return _pad(SectSutraGroupCard(
          group: group,
          open: _expanded.contains(group.key),
          onToggle: () => _toggle(group.key),
          parent: widget.parent,
          sutraFolder: widget.stage.badgeName,
          showProgress: widget.showGroupProgress,
        ));
      },
    );
  }

  /// 标题图本体：水墨背景 + 返回键 + 图标 + 标题 + 标语。
  Widget _buildBanner(PaletteData p) {
    final width = MediaQuery.sizeOf(context).width;
    final height = (width * _kHeaderAspect).clamp(118.0, 190.0);
    final custom = widget.headerTitle != null;
    final icon = custom ? widget.headerIcon : widget.stage.icon;
    final title = custom
        ? widget.headerTitle!
        : '${widget.stage.stageNo} · ${widget.stage.badgeName}';
    final subtitle = custom
        ? (widget.headerSubtitle ?? '')
        : widget.stage.title;
    return SizedBox(
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
          Positioned(
            left: 24,
            right: 24,
            top: 0,
            bottom: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null && icon.isNotEmpty) ...[
                    Opacity(
                      opacity: 0.92,
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: Image.asset(
                          icon,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                          color: p.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                        letterSpacing: 1.5,
                        height: 1.2,
                      ),
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      subtitle,
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 把阶段编排 + 经藏页全部经书目录，解析成核心经典同款的「文件夹」列表。
  ///
  /// 卷数/卷标题/字数全部取自 [SutraListPageState.allSutras]（App 实际数据）。
  List<SectSutraGroup> _buildGroups() {
    final all = widget.parent?.allSutras ?? const <Sutra>[];

    // 按 CBETA 编号主干（去掉卷序号）索引目录条目。
    final byBase = <String, List<Sutra>>{};
    for (final s in all) {
      final id = SutraDownloader.extractId(s.title, s.filePath);
      if (id == null) continue;
      final base = _baseId(id);
      if (base == null) continue;
      byBase.putIfAbsent(base, () => <Sutra>[]).add(s);
    }

    final groups = <SectSutraGroup>[];
    for (final sutra in widget.stage.sutras) {
      final editions = <SectSutraEdition>[];
      for (final ed in sutra.editions) {
        final volumes = <SectSutraVolume>[];
        for (final base in ed.ids) {
          for (final entry in byBase[base] ?? const <Sutra>[]) {
            final id = SutraDownloader.extractId(entry.title, entry.filePath);
            if (id == null) continue;
            final vol = sutraVolumeOf(id);
            if (ed.volFrom != null && vol < ed.volFrom!) continue;
            if (ed.volTo != null && vol > ed.volTo!) continue;
            volumes.add(SectSutraVolume(
              title: entry.title,
              id: id,
              assetPath: SutraAssetPath.resolve(title: entry.title),
              translator: ed.translator,
              base: sutra.name,
              partName: vol > 0 ? sutraVolumeLabel(vol) : '',
              vol: vol,
              words: entry.charCount,
            ));
          }
        }
        if (volumes.isEmpty) continue;
        volumes.sort((a, b) => a.vol.compareTo(b.vol));
        editions.add(SectSutraEdition(
          name: '${sutra.name}·${ed.label}',
          label: ed.label,
          cbeta: ed.cbeta,
          note: '',
          translator: ed.translator,
          volumes: volumes,
        ));
      }
      if (editions.isEmpty) continue;
      groups.add(SectSutraGroup(
        key: 'stage:${widget.stage.stageNo}#${sutra.name}',
        name: sutra.name,
        note: sutra.intro,
        editions: editions,
      ));
    }
    return groups;
  }

  /// 从 `T04n0209_001` 取出主干 `T04n0209`。
  String? _baseId(String id) {
    final i = id.lastIndexOf('_');
    if (i <= 0) return null;
    return id.substring(0, i);
  }
}
