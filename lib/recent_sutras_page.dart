import 'package:flutter/material.dart';
import 'sutra_downloader.dart';
import 'sutra_list_page.dart';

import 'app_palette.dart';
Color get _gold => AppPalette.p.accent;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
const Color _readTeal = Color(0xFFcf9e66);

/// 最近阅读页：展示最近读过的经书，点击进入阅读，长按可收藏/置顶等。
class RecentSutrasPage extends StatefulWidget {
  const RecentSutrasPage({super.key, this.parent});

  /// 经藏页状态引用：长按菜单、置顶/收藏/完成阅读等操作都复用经藏页逻辑。
  final SutraListPageState? parent;

  @override
  State<RecentSutrasPage> createState() => _RecentSutrasPageState();
}

class _RecentSutrasPageState extends State<RecentSutrasPage>
    with RouteAware {
  List<Map<String, String>> _recent = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.parent?.sutraDataVersion.addListener(_onParentChanged);
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    widget.parent?.sutraDataVersion.removeListener(_onParentChanged);
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  /// 从阅读页返回时刷新最近阅读记录。
  @override
  void didPopNext() {
    _refresh();
  }

  void _onParentChanged() {
    if (mounted) _loadRecent();
  }

  Future<void> _refresh() async {
    // 补齐阅读页直接下载的经书状态，保证「下载完成」对号正确显示。
    await widget.parent?.syncDownloadedIdsFromDisk();
    await widget.parent?.reloadRecentSutras();
    if (mounted) _loadRecent();
  }

  Future<void> _loadRecent() async {
    final parent = widget.parent;
    if (parent == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      final raw = parent.getRecentSutras();
      // 置顶的经书排在最上面，其余保持最近阅读顺序。
      final pinned = raw
          .where((e) => parent.findSutra(e['title'] ?? '')?.isPinned == true)
          .toList();
      final rest = raw
          .where((e) => parent.findSutra(e['title'] ?? '')?.isPinned != true)
          .toList();
      _recent = [...pinned, ...rest];
      _loading = false;
    });
  }

  String _displayTitle(String title) =>
      widget.parent?.displayTitle(title) ?? sutraDisplayTitle(title);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return _loading
        ? Center(child: CircularProgressIndicator(color: _gold))
        : _recent.isEmpty
            ? _buildEmpty()
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
                itemCount: _recent.length,
                itemBuilder: (context, index) =>
                    _buildSutraTile(_recent[index]),
              );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppPalette.p.gradTop, AppPalette.p.gradBot],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 20, 18),
          child: Row(
            children: [
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.arrow_back_ios_new, color: _text, size: 20),
              ),
              const SizedBox(width: 4),
              Text('最近阅读', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
              const Spacer(),
              Text('${_recent.length} 部', style: TextStyle(fontSize: 13, color: _textSec)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(Icons.history_rounded, size: 48, color: _textHint.withValues(alpha: 0.6)),
          const SizedBox(height: 14),
          Text('暂无阅读记录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
          const SizedBox(height: 6),
          Text('读过的经书会出现在这里，方便你随时回顾', style: TextStyle(fontSize: 13, color: _textSec)),
        ],
      ),
    );
  }

  Widget _buildSutraTile(Map<String, String> entry) {
    final title = entry['title'] ?? '';
    final sutra = widget.parent?.findSutra(title);
    final isRead = sutra?.isRead == true;
    final isPinned = sutra?.isPinned == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => widget.parent?.openRecentSutra(title, entry['filePath']),
          onLongPress: () {
            final parent = widget.parent;
            if (parent == null || sutra == null) return;
            parent.showSutraMenu(context, sutra, showPin: true);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: _gold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                  child: Icon(Icons.history_rounded, size: 18, color: _gold),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _displayTitle(title),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      color: isRead ? _readTeal : _text,
                      fontWeight: isRead ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (isPinned) ...[
                  Icon(Icons.push_pin, color: _gold, size: 16),
                  const SizedBox(width: 6),
                ],
                _buildDownloadState(sutra),
                Icon(Icons.chevron_right, color: _textHint, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 下载中显示小圆进度圈，已下载显示「下载完成」标记。
  Widget _buildDownloadState(Sutra? sutra) {
    final parent = widget.parent;
    if (sutra == null || parent == null) return const SizedBox.shrink();
    final id = SutraDownloader.extractId(sutra.title, sutra.filePath);
    if (id == null) return const SizedBox.shrink();
    final p = parent.downloadProgressOf(id);
    if (p != null && p < 1.0) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(value: p, strokeWidth: 2, color: _gold),
        ),
      );
    }
    if (parent.isSutraDownloaded(id)) {
      return const Padding(
        padding: EdgeInsets.only(right: 8),
        child: Icon(Icons.check_circle, color: Color(0xFF8FBC8F), size: 18),
      );
    }
    return const SizedBox.shrink();
  }
}
