import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'reading_page.dart';
import 'sutra_asset_path.dart';
import 'sutra_downloader.dart';
import 'sutra_list_page.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _readTeal = Color(0xFF71867A);

class FavoriteSutrasPage extends StatefulWidget {
  /// [embedded] 为 true 时不显示自己的 Scaffold/头部，用于嵌入标签页。
  const FavoriteSutrasPage({super.key, this.embedded = false, this.parent});

  final bool embedded;

  /// 经藏页状态引用：长按菜单、置顶/收藏/完成阅读等操作都复用经藏页逻辑。
  final SutraListPageState? parent;

  @override
  State<FavoriteSutrasPage> createState() => _FavoriteSutrasPageState();
}

class _FavoriteSutrasPageState extends State<FavoriteSutrasPage>
    with RouteAware {
  List<Sutra> _favoriteSutras = [];
  bool _loading = true;

  /// 无父页面（独立收藏页）时，用于判断多卷经书的基础经名集合。
  Set<String> _multiVolumeBases = const {};

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

  /// 从阅读页返回时刷新收藏列表，保证新收藏/取消收藏立即生效。
  @override
  void didPopNext() {
    _refresh();
  }

  void _onParentChanged() {
    if (mounted) _loadFavorites();
  }

  Future<void> _refresh() async {
    // 补齐阅读页直接下载的经书状态，保证「下载完成」对号正确显示。
    await widget.parent?.syncDownloadedIdsFromDisk();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    try {
      if (widget.parent != null) {
        final sutras = List<Sutra>.from(widget.parent!.getFavoriteSutras());
        if (!mounted) return;
        setState(() {
          _favoriteSutras = sutras;
          _loading = false;
        });
        return;
      }
      final docs = await getApplicationDocumentsDirectory();
      final file = File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (!await file.exists()) {
        if (!mounted) return;
        setState(() => _loading = false);
        return;
      }
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      final all = decoded.map((e) => Sutra.fromJson(e as Map<String, dynamic>)).toList();
      final multi = collectMultiVolumeBases(all);
      final sutras = all.where((s) => s.isFavorite).toList();
      sutras.sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        if (a.favoriteTime == null && b.favoriteTime == null) return 0;
        if (a.favoriteTime == null) return 1;
        if (b.favoriteTime == null) return -1;
        return b.favoriteTime!.compareTo(a.favoriteTime!);
      });
      if (!mounted) return;
      setState(() {
        _favoriteSutras = sutras;
        _multiVolumeBases = multi;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _displayTitle(String title) {
    final parent = widget.parent;
    if (parent != null) return parent.displayTitle(title);
    return sutraDisplayTitle(title, multiVolumeBases: _multiVolumeBases);
  }

  Future<bool> _assetExists(String path) async {
    try {
      await rootBundle.load(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _openReading(Sutra sutra, String filePath) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReadingPage(
          title: sutra.title,
          filePath: filePath,
        ),
      ),
    );
  }

  Future<void> _openSutra(Sutra sutra) async {
    final parent = widget.parent;
    if (parent != null) {
      // 走经藏页统一逻辑：下载中显示进度小圆圈，下载完成弹「下载完成」提示。
      await parent.openSutraFromChild(sutra);
      return;
    }
    final id = SutraDownloader.extractId(sutra.title, sutra.filePath);
    if (id == null) {
      _openReading(sutra, sutra.filePath ?? '');
      return;
    }
    if (await SutraDownloader.isDownloaded(id)) {
      // 传规范资产路径（assets/sutras_ascii/...）而不是本地绝对路径：
      // 绝对路径会被写进 current_sutra_file_path 等 prefs 并同步到云端，
      // 换机/重新登录后会被误判为「未下载」。
      _openReading(sutra,
          SutraAssetPath.resolve(title: sutra.title, filePath: sutra.filePath));
      return;
    }
    final assetPath = SutraAssetPath.resolve(title: sutra.title, filePath: sutra.filePath);
    if (await _assetExists(assetPath)) {
      _openReading(sutra, assetPath);
      return;
    }
    if (!mounted) return;
    final shouldDownload = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('经文尚未下载', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Text('《${_displayTitle(sutra.title)}》的正文尚未下载（约 ${sutra.size}），是否现在下载？下载完成即可阅读。', style: const TextStyle(color: _textSec)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: _textSec))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _gold),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('下载', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (shouldDownload != true || !mounted) return;
    try {
      await SutraDownloader.download(id);
      if (!mounted) return;
      _openReading(sutra,
          SutraAssetPath.resolve(title: sutra.title, filePath: sutra.filePath));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return _buildBody();
    }
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
        ? const Center(child: CircularProgressIndicator(color: _gold))
        : _favoriteSutras.isEmpty
            ? _buildEmpty()
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
                itemCount: _favoriteSutras.length,
                itemBuilder: (context, index) =>
                    _buildSutraTile(_favoriteSutras[index]),
              );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF3E8DB), Color(0xFFF9F1E7)],
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
                icon: const Icon(Icons.arrow_back_ios_new, color: _text, size: 20),
              ),
              const SizedBox(width: 4),
              const Text('我的收藏', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
              const Spacer(),
              Text('${_favoriteSutras.length} 部', style: const TextStyle(fontSize: 13, color: _textSec)),
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
          Icon(Icons.star_border_rounded, size: 48, color: _textHint.withValues(alpha: 0.6)),
          const SizedBox(height: 14),
          const Text('暂无收藏', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
          const SizedBox(height: 6),
          const Text('在经藏中点击收藏，即可在这里快速阅读', style: TextStyle(fontSize: 13, color: _textSec)),
        ],
      ),
    );
  }

  Widget _buildSutraTile(Sutra sutra) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openSutra(sutra),
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
                width: 36, height: 36,
                decoration: BoxDecoration(color: _gold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.auto_stories_rounded, size: 18, color: _gold),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _displayTitle(sutra.title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    color: sutra.isRead ? _readTeal : _text,
                    fontWeight: sutra.isRead ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (sutra.isPinned) ...[
                const Icon(Icons.push_pin, color: _gold, size: 16),
                const SizedBox(width: 6),
              ],
              if (widget.parent != null) ...[
                _buildDownloadState(sutra),
              ],
              const Icon(Icons.chevron_right, color: _textHint, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  /// 下载中显示小圆进度圈（刚启动还没收到字节时转圈动画），已下载显示「下载完成」对号。
  Widget _buildDownloadState(Sutra sutra) {
    final id = SutraDownloader.extractId(sutra.title, sutra.filePath);
    final parent = widget.parent;
    if (id == null || parent == null) return const SizedBox.shrink();
    final p = parent.downloadProgressOf(id);
    if (p != null && p < 1.0) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            // 尚未收到任何进度时用 null 走转圈动画，收到进度后显示具体百分比弧。
            value: p > 0 ? p : null,
            strokeWidth: 2,
            color: _gold,
            backgroundColor: _gold.withValues(alpha: 0.12),
          ),
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
