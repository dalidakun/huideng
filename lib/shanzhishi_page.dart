import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'note_sutra_links.dart';
import 'reading_page.dart';
import 'shanzhishi_edit_sheet.dart';
import 'shanzhishi_search_page.dart';
import 'shanzhishi_sphere.dart';
import 'shanzhishi_store.dart';
import 'ui_sound.dart';

/// 善知识页（底部菜单第 4 格）：
///
/// 上半是一颗立体的名号星球（透视投影 + 不透明球体 + 经纬网格）——
/// 正对球心的名号原地放大被选中，其余名号由近及远、由大到小渐隐成星点；
/// 松手有惯性，停稳后磁吸。页面可见时有入场转正与短暂缓速自转。
/// 下半显示当前名号出现过的经文，点卡片直接进阅读页。
///
/// 名号由用户自己录入（右上角 +），本地持久化，越聚越多；
/// 另有搜索与随机抽取，名单长了也找得到。
class ShanZhiShiPage extends StatefulWidget {
  /// 底部菜单当前索引：仅当等于 [tabIndex] 时球体才播入场/自转（省电）。
  final ValueListenable<int>? activeTab;

  /// 本页在主页页面列表里的索引（善知识 = 7）。
  final int tabIndex;

  const ShanZhiShiPage({super.key, this.activeTab, this.tabIndex = 7});

  @override
  State<ShanZhiShiPage> createState() => ShanZhiShiPageState();
}

class ShanZhiShiPageState extends State<ShanZhiShiPage> {
  final ShanZhiShiStore _store = ShanZhiShiStore.instance;
  final ShanZhiSphereController _sphereCtrl = ShanZhiSphereController();

  /// 仅在明确挂了 [activeTab] 且轮到本页时才允许球体入场/自转。
  bool get _isActive =>
      widget.activeTab != null && widget.activeTab!.value == widget.tabIndex;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    widget.activeTab?.addListener(_onTabChanged);
    unawaited(_store.load());
    // 经藏目录预热：经文卡片解析跳转路径要用（约九千部，首次解析耗时）。
    unawaited(NoteSutraCatalog.load());
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    widget.activeTab?.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  // ─────────────── 动作 ───────────────

  void _openRandom() {
    final idx = _store.randomIndex(exclude: _sphereCtrl.currentIndex);
    if (idx < 0) return;
    unawaited(UiSound.instance.playClick());
    _sphereCtrl.animateToIndex(idx);
  }

  Future<void> _openSearch() async {
    unawaited(UiSound.instance.playClick());
    final idx = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => ShanZhiShiSearchPage(entries: _store.entries),
      ),
    );
    if (idx == null || !mounted) return;
    _sphereCtrl.animateToIndex(idx);
  }

  Future<void> _openEdit({int? index, ShanyishiEntry? entry}) async {
    final saved = await ShanZhiShiEditSheet.show(
      context,
      index: index,
      entry: entry,
    );
    if (saved == null || !mounted) return;
    // 等名单变更落到球面布局后，再把新的一位转到球心。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sphereCtrl.animateToIndex(saved);
    });
  }

  /// 点中心当前名号 = 编辑它。
  void _openCurrentEdit() {
    final i = _sphereCtrl.currentIndex;
    final e = _store[i];
    if (e == null) return;
    unawaited(UiSound.instance.playClick());
    unawaited(_openEdit(index: i, entry: e));
  }

  void _openSutra(String sutra) {
    unawaited(UiSound.instance.playClick());
    final link = ShanZhiShiStore.resolveSutra(sutra);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReadingPage(
        // 能解析就用经藏里的正式经名，解析不到就按用户原文进阅读页自行兜底。
        title: link?.title ?? sutra,
        filePath: link?.filePath,
      ),
    ));
  }

  // ─────────────── 视图 ───────────────

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final names = [for (final e in _store.entries) e.name];
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        title: Row(
          children: [
            Text(
              '善知识',
              style: TextStyle(
                color: p.primary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '滑动球面，礼敬名号',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.textSec, fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '搜索',
            onPressed: _openSearch,
            icon: Icon(Icons.search, size: 21, color: p.text),
          ),
          IconButton(
            tooltip: '随机抽取',
            onPressed: _openRandom,
            icon: Icon(Icons.casino_outlined, size: 20, color: p.text),
          ),
          IconButton(
            tooltip: '添加',
            onPressed: () {
              unawaited(UiSound.instance.playClick());
              unawaited(_openEdit());
            },
            icon: Icon(Icons.add_circle_outline, size: 21, color: p.text),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              flex: 56,
              child: Stack(
                children: [
                  ShanZhiShiSphere(
                    names: names,
                    controller: _sphereCtrl,
                    spinEnabled: _isActive,
                    onCurrentChanged: (_) => setState(() {}),
                    onCurrentTap: _openCurrentEdit,
                    onSettled: (_) => unawaited(UiSound.instance.playClick()),
                  ),
                  if (names.isEmpty) _buildEmptySphere(p),
                ],
              ),
            ),
            Container(height: 1, color: p.divider),
            Expanded(flex: 44, child: _buildPanel(p, names)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptySphere(PaletteData p) {
    return IgnorePointer(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 90),
            Text(
              '球面还没有名号',
              style: TextStyle(fontSize: 14, color: p.textSec, letterSpacing: 1),
            ),
            const SizedBox(height: 6),
            Text(
              '点右上角「＋」记录第一位佛菩萨',
              style: TextStyle(fontSize: 12, color: p.textHint),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel(PaletteData p, List<String> names) {
    if (!_store.loaded) {
      return Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
              strokeWidth: 1.4, color: p.textHint),
        ),
      );
    }
    if (names.isEmpty) {
      return Center(
        child: Text(
          '名号下方会显示它出现过的经文',
          style: TextStyle(fontSize: 12.5, color: p.textHint, letterSpacing: 0.5),
        ),
      );
    }
    final idx = _sphereCtrl.currentIndex.clamp(0, names.length - 1);
    final entry = _store[idx];
    if (entry == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: Text(
                    entry.name,
                    key: ValueKey('$idx:${entry.name}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '第 ${idx + 1} / ${names.length} 位',
                style: TextStyle(fontSize: 11.5, color: p.textHint),
              ),
              IconButton(
                tooltip: '编辑',
                onPressed: _openCurrentEdit,
                icon: Icon(Icons.edit_outlined, size: 17, color: p.textSec),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 4),
          child: Text(
            '出现经文',
            style: TextStyle(fontSize: 12, color: p.textSec, letterSpacing: 0.8),
          ),
        ),
        Expanded(
          child: entry.sutras.isEmpty
              ? Center(
                  child: Text(
                    '尚未记录出处\n点上方「编辑」添加它出现过的经文',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12.5, color: p.textHint, height: 1.7),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  itemCount: entry.sutras.length,
                  itemBuilder: (ctx, i) => _sutraTile(p, entry.sutras[i]),
                ),
        ),
      ],
    );
  }

  Widget _sutraTile(PaletteData p, String sutra) {
    return InkWell(
      onTap: () => _openSutra(sutra),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.borderSoft),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                sutra,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14.5,
                  color: p.text,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text('去阅读', style: TextStyle(fontSize: 11.5, color: p.textHint)),
            Icon(Icons.chevron_right, size: 15, color: p.textHint),
          ],
        ),
      ),
    );
  }
}
