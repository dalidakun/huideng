import 'package:flutter/material.dart';
import 'note_sutra_links.dart';
import 'sutra_downloader.dart';
import 'sutra_list_page.dart';

import 'app_palette.dart';
Color get _accent => AppPalette.p.readingAccent;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;

/// 稍后阅读页：展示标记为稍后阅读的经书，点击进入阅读，长按可收藏/置顶等。
class RecentSutrasPage extends StatefulWidget {
  const RecentSutrasPage({super.key, this.parent});

  /// 经藏页状态引用：长按菜单、置顶/收藏/完成阅读等操作都复用经藏页逻辑。
  final SutraListPageState? parent;

  @override
  State<RecentSutrasPage> createState() => _RecentSutrasPageState();
}

class _RecentSutrasPageState extends State<RecentSutrasPage>
    with RouteAware {
  List<Sutra> _readLaterSutras = [];
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

  @override
  void didPopNext() {
    _refresh();
  }

  void _onParentChanged() {
    if (mounted) _loadReadLater();
  }

  Future<void> _refresh() async {
    await widget.parent?.syncDownloadedIdsFromDisk();
    if (mounted) _loadReadLater();
  }

  void _loadReadLater() {
    final parent = widget.parent;
    if (parent == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      final all = parent.allSutras;
      final list = all.where((s) => s.isReadLater).toList();
      list.sort((a, b) {
        if (a.readLaterTime == null && b.readLaterTime == null) return 0;
        if (a.readLaterTime == null) return 1;
        if (b.readLaterTime == null) return -1;
        return b.readLaterTime!.compareTo(a.readLaterTime!);
      });
      _readLaterSutras = list;
      _loading = false;
    });
  }

  String _displayTitle(String title, {String? filePath}) =>
      widget.parent?.displayTitle(title, filePath: filePath) ??
      sutraDisplayTitleWithPath(title,
          filePath: filePath,
          multiVolumeBases: NoteSutraCatalog.cachedMultiVolumeBases);

  String _metaLabel(Sutra s) {
    final parent = widget.parent;
    final folderName = (parent != null && s.folder != null)
        ? (parent.folderDisplayNames[s.folder] ?? s.folder ?? '')
        : (s.folder ?? '');
    final charLabel = s.charCount > 0 ? '${s.charCount} 字' : '';
    if (folderName.isEmpty && charLabel.isEmpty) return '';
    if (folderName.isEmpty) return charLabel;
    if (charLabel.isEmpty) return folderName;
    return '$folderName · $charLabel';
  }

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
        ? Center(child: CircularProgressIndicator(color: _accent))
        : _readLaterSutras.isEmpty
            ? _buildEmpty()
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
                itemCount: _readLaterSutras.length,
                itemBuilder: (context, index) =>
                    _buildSutraTile(_readLaterSutras[index]),
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
              Text('稍后阅读', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
              const Spacer(),
              Text('${_readLaterSutras.length} 部', style: TextStyle(fontSize: 13, color: _textSec)),
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
          Icon(Icons.bookmark_border, size: 48, color: _textHint.withValues(alpha: 0.6)),
          const SizedBox(height: 14),
          Text('暂无稍后阅读', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
          const SizedBox(height: 6),
          Text('标记的经书会出现在这里，方便你随时阅读', style: TextStyle(fontSize: 13, color: _textSec)),
        ],
      ),
    );
  }

  Widget _buildSutraTile(Sutra sutra) {
    final isRead = sutra.isRead;
    final isPinned = sutra.isPinned;
    final meta = _metaLabel(sutra);
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
          onTap: () => widget.parent?.openRecentSutra(sutra.title, sutra.filePath),
          onLongPress: () {
            final parent = widget.parent;
            if (parent == null) return;
            parent.showSutraMenu(context, sutra, showPin: true);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: _accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                  child: Icon(Icons.bookmark_rounded, size: 18, color: _accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayTitle(sutra.title, filePath: sutra.filePath),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          color: isRead ? _accent : _text,
                          fontWeight: isRead ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: _textSec),
                        ),
                      ],
                    ],
                  ),
                ),
                if (isPinned) ...[
                  Icon(Icons.push_pin, color: _accent, size: 16),
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

  Widget _buildDownloadState(Sutra sutra) {
    final parent = widget.parent;
    if (parent == null) return const SizedBox.shrink();
    final id = SutraDownloader.extractId(sutra.title, sutra.filePath);
    if (id == null) return const SizedBox.shrink();
    final p = parent.downloadProgressOf(id);
    if (p != null && p < 1.0) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(value: p, strokeWidth: 2, color: _accent),
        ),
      );
    }
    if (parent.isSutraDownloaded(id)) {
      return const Padding(
        padding: EdgeInsets.only(right: 8),
        child: Icon(Icons.check_circle, size: 16, color: Color(0xFF8FBC8F)),
      );
    }
    return const SizedBox.shrink();
  }
}
