import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, ValueListenable;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'reading_page.dart';
import 'sutra_asset_path.dart';
import 'sutra_downloader.dart';
import 'sutra_favorites.dart';
import 'favorite_sutras_page.dart';
import 'recent_sutras_page.dart';

/// 用于监听路由返回（例如从阅读页 pop 回来时刷新“最近阅读”）。
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

class Sutra {
  final String title;
  final String size;
  final bool isPinned;
  final bool isRead;
  final bool isFavorite;
  final String? filePath;
  final String? folder;
  final DateTime? favoriteTime; // 收藏时间
  final DateTime? readTime; // 标记已读时间

  Sutra(this.title, this.size, {this.isPinned = false, this.isRead = false, this.isFavorite = false, this.filePath, this.folder, this.favoriteTime, this.readTime});

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'size': size,
      'isPinned': isPinned,
      'isRead': isRead,
      'isFavorite': isFavorite,
      'filePath': filePath,
      'folder': folder,
      'favoriteTime': favoriteTime?.toIso8601String(),
      'readTime': readTime?.toIso8601String(),
    };
  }

  factory Sutra.fromJson(Map<String, dynamic> json) {
    return Sutra(
      json['title'] as String,
      json['size'] as String,
      isPinned: json['isPinned'] as bool? ?? false,
      isRead: json['isRead'] as bool? ?? false,
      isFavorite: json['isFavorite'] as bool? ?? false,
      filePath: json['filePath'] as String?,
      folder: json['folder'] as String?,
      favoriteTime: json['favoriteTime'] != null ? DateTime.parse(json['favoriteTime'] as String) : null,
      readTime: json['readTime'] != null ? DateTime.parse(json['readTime'] as String) : null,
    );
  }
}

class SutraListPage extends StatefulWidget {
  /// 底部 Tab 索引变化通知。当切换回经藏页（索引值变化）时刷新“最近阅读”。
  final ValueListenable<int>? activeTab;

  /// 搜索激活/退出状态回调（供底部「搜索」菜单同步高亮）。
  final ValueChanged<bool>? onSearchModeChanged;

  /// 右上角「助手」入口点击回调。
  final VoidCallback? onOpenAssistant;

  const SutraListPage({
    super.key,
    this.activeTab,
    this.onSearchModeChanged,
    this.onOpenAssistant,
  });

  @override
  State<SutraListPage> createState() => SutraListPageState();
}

class SutraListPageState extends State<SutraListPage>
    with SingleTickerProviderStateMixin, RouteAware {
  static const MethodChannel _appChannel = MethodChannel('app_channel');
  static const String _kApkLastUpdateTimeKey = 'apk_last_update_time';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  /// 主页内容滚动控制器：双击顶部 AppBar 时回到顶部。
  final ScrollController _scrollController = ScrollController();
  bool _drawerOpen = false;
  late final AnimationController _drawerController;
  late final Animation<Offset> _drawerSlide;
  late final Animation<double> _overlayOpacity;
  String? _lastReadTitle;
  String? _lastReadFilePath;
  double _lastReadProgress = 0.0;
  int _readDays = 0;
  int _todayReadCount = 0;
  List<Map<String, String>> _recentSutras = [];

  /// 随缘读经预览用的随机经书（保持稳定，避免每次重建都换）。
  Sutra? _randomSutra;

  /// 从全部经书中随机抽取一部。
  Sutra? _rollRandomSutra() {
    if (_allSutras.isEmpty) return null;
    return _allSutras[Random().nextInt(_allSutras.length)];
  }

  /// 「换一部」轮换选中的部类（保持稳定，避免每次重建都换）。
  String? _randomFolder;

  /// 从全部部类（56 部）中随机抽取一部，尽量不与当前重复。
  String? _rollRandomFolder() {
    if (_folders.isEmpty) return null;
    final candidates = (_folders.length > 1 && _randomFolder != null)
        ? _folders.where((f) => f != _randomFolder).toList()
        : _folders;
    return candidates[Random().nextInt(candidates.length)];
  }

  Set<String>? _assetKeys;
  // Cache: resolved asset key -> exists?
  final Map<String, bool> _resolvedPathExistsCache = {};
  // Cache: sutra title -> best existing asset key (null means none found)
  final Map<String, String?> _bestAssetPathByTitleCache = {};
  Future<AssetManifest>? _manifestFuture;
  Set<String> _missingSutraTitles = {};
  bool _missingComputed = false;

  String _normalizeAssetKey(String p) => p.replaceAll('\\', '/').trim();

  List<String> _candidateAssetPathsForSutra(Sutra sutra) {
    final out = <String>{};
    final fp = sutra.filePath;
    if (fp != null && fp.startsWith('assets/')) {
      out.add(_normalizeAssetKey(fp));
    }
    // ASCII-mapped path (preferred when packaged).
    out.add(_normalizeAssetKey(_resolveSutraPath(sutra)));
    return out.toList();
  }

  String? _bestExistingAssetPathForSutra(Sutra sutra) {
    final keys = _assetKeys;
    if (keys == null) return null;

    final cached = _bestAssetPathByTitleCache[sutra.title];
    if (_bestAssetPathByTitleCache.containsKey(sutra.title)) return cached;

    for (final c in _candidateAssetPathsForSutra(sutra)) {
      if (keys.contains(c)) {
        _bestAssetPathByTitleCache[sutra.title] = c;
        return c;
      }
    }
    _bestAssetPathByTitleCache[sutra.title] = null;
    return null;
  }

  String _filePathForReading(Sutra sutra) {
    final fp = sutra.filePath;
    if (fp != null && !fp.startsWith('assets/')) return fp;

    final best = _bestExistingAssetPathForSutra(sutra);
    return best ?? _normalizeAssetKey(_resolveSutraPath(sutra));
  }

  Future<void> _loadAssetManifest() async {
    try {
      _manifestFuture ??= AssetManifest.loadFromAssetBundle(rootBundle);
      final manifest = await _manifestFuture!;
      final assets = manifest.listAssets();
      if (!mounted) return;
      setState(() {
        // Normalize keys to forward-slash to avoid platform-specific separators.
        _assetKeys = assets.map(_normalizeAssetKey).toSet();
        _resolvedPathExistsCache.clear();
        _bestAssetPathByTitleCache.clear();
      });
      _recomputeMissingSutrasIfReady();
    } catch (_) {
      // If manifest can't be read for some reason, don't block the UI.
      if (!mounted) return;
      setState(() {
        _assetKeys = null;
        _resolvedPathExistsCache.clear();
        _bestAssetPathByTitleCache.clear();
        _missingSutraTitles = {};
        _missingComputed = false;
      });
    }
  }

  void _recomputeMissingSutrasIfReady() {
    final keys = _assetKeys;
    if (keys == null) return;
    if (_allSutras.isEmpty) return;

    // Avoid repeated full scans; we recompute only when assets are loaded and sutras list is ready.
    if (_missingComputed) return;

    final missing = <String>{};
    for (final sutra in _allSutras) {
      final fp = sutra.filePath;
      final isAssetLike = fp == null || fp.startsWith('assets/');
      if (!isAssetLike) {
        if (!kIsWeb) {
          try {
            if (!File(fp).existsSync()) {
              missing.add(sutra.title);
            }
          } catch (_) {
            missing.add(sutra.title);
          }
        }
        continue;
      }

      // For asset-backed sutras, consider multiple candidate paths (ascii-mapped + legacy).
      final best = _bestExistingAssetPathForSutra(sutra);
      if (best == null) {
        missing.add(sutra.title);
      }
    }

    if (!mounted) return;
    setState(() {
      _missingSutraTitles = missing;
      _missingComputed = true;
    });
  }

  bool _isSutraContentMissing(Sutra sutra) {
    if (_missingComputed) {
      return _missingSutraTitles.contains(sutra.title);
    }

    // Not ready yet: don't mark anything until we have the manifest.
    final keys = _assetKeys;
    if (keys == null) return false;

    // If this sutra comes from a user-picked local file, validate file existence.
    final fp = sutra.filePath;
    final isAssetLike = fp == null || fp.startsWith('assets/');
    if (!isAssetLike) {
      if (kIsWeb) return false;
      try {
        return !File(fp).existsSync();
      } catch (_) {
        return true;
      }
    }

    // Otherwise validate packaged asset existence using resolved ASCII asset path.
    // We cache by the (normalized) resolved key, but still accept legacy key if present.
    final resolved = _normalizeAssetKey(_resolveSutraPath(sutra));
    final cached = _resolvedPathExistsCache[resolved];
    if (cached != null) return !cached;

    final best = _bestExistingAssetPathForSutra(sutra);
    final exists = best != null;
    _resolvedPathExistsCache[resolved] = exists;
    return !exists;
  }

  void _dismissKeyboard() {
    // 关键：TextField 仍处于 focus 时（即使用户手动收起了输入法），后续 setState / 弹窗
    // 可能会重新建立输入连接导致键盘再次弹出。这里统一释放焦点，保证只有再次点搜索框才弹键盘。
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// 底部「搜索」菜单：进入搜索激活状态，弹出搜索框并拉起键盘。
  void activateSearch() {
    if (!mounted) return;
    if (_drawerOpen) _closeDrawer();
    setState(() {
      _searchActive = true;
    });
    widget.onSearchModeChanged?.call(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  /// 底部菜单切换：退出搜索激活状态。
  void deactivateSearch() {
    if (!mounted) return;
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _searchActive = false;
    });
    _dismissKeyboard();
  }

  /// 页内清空按钮：退出搜索激活状态并通知主页面。
  void _exitSearch() {
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _searchActive = false;
    });
    widget.onSearchModeChanged?.call(false);
    _dismissKeyboard();
  }

  String _resolveSutraPath(Sutra sutra) {
    return SutraAssetPath.resolve(
      title: sutra.title,
      filePath: sutra.filePath,
    );
  }

  Future<void> _loadDownloadedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_kDownloadedIdsKey) ?? const [];
    if (!mounted) return;
    setState(() {
      _downloadedIds
        ..clear()
        ..addAll(ids);
    });
  }

  Future<void> _persistDownloadedIds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kDownloadedIdsKey, _downloadedIds.toList());
  }

  void _markDownloaded(String id) {
    if (!mounted) return;
    setState(() {
      _downloadedIds.add(id);
      _downloadProgress.remove(id);
    });
    _sutraDataVersion.value++;
  }

  Future<void> _downloadSingle(Sutra sutra, String id) async {
    setState(() {
      _downloadProgress[id] = 0;
    });
    try {
      await SutraDownloader.download(id, onProgress: (received, total) {
        if (!mounted) return;
        final p = total > 0 ? received / total : 0.0;
        final prev = _downloadProgress[id] ?? 0;
        if (p < 1.0 && (p - prev).abs() < 0.02) return;
        setState(() {
          _downloadProgress[id] = p;
        });
        _sutraDataVersion.value++;
      });
      _markDownloaded(id);
      await _persistDownloadedIds();
      if (!mounted) return;
      final shouldRead = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('下载完成'),
          content: Text('《${_displayTitle(sutra.title)}》已下载完成，是否现在阅读？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD4A06A)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('阅读'),
            ),
          ],
        ),
      );
      if (shouldRead == true && mounted) {
        _openReading(sutra);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloadProgress.remove(id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$e')),
      );
    }
  }

  Future<void> _downloadFolder(String folderName) async {
    final targets = <Sutra>[];
    for (final s in _getAllSutrasInFolder(folderName)) {
      final id = SutraDownloader.extractId(s.title, s.filePath);
      if (id != null && !_downloadedIds.contains(id)) targets.add(s);
    }
    if (targets.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本卷经文已全部下载')),
      );
      return;
    }
    setState(() {
      _folderDownloadDone[folderName] = 0;
      _folderDownloadTotal[folderName] = targets.length;
    });
    for (var i = 0; i < targets.length; i++) {
      final s = targets[i];
      final id = SutraDownloader.extractId(s.title, s.filePath)!;
      setState(() {
        _downloadProgress[id] = 0;
      });
      try {
        await SutraDownloader.download(id, onProgress: (received, total) {
          if (!mounted) return;
          final p = total > 0 ? received / total : 0.0;
          final prev = _downloadProgress[id] ?? 0;
          if (p < 1.0 && (p - prev).abs() < 0.02) return;
          setState(() {
            _downloadProgress[id] = p;
          });
        });
        _markDownloaded(id);
      } catch (_) {
        // 单本失败不中断整卷下载。
      }
      if (mounted) {
        setState(() {
          _folderDownloadDone[folderName] = i + 1;
        });
        _sutraDataVersion.value++;
      }
    }
    await _persistDownloadedIds();
    if (!mounted) return;
    setState(() {
      _folderDownloadDone.remove(folderName);
      _folderDownloadTotal.remove(folderName);
    });
    _sutraDataVersion.value++;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('《${_folderDisplayNames[folderName] ?? folderName}》下载完成')),
    );
  }

  Widget _buildDownloadTrailing(Sutra sutra) {
    final id = SutraDownloader.extractId(sutra.title, sutra.filePath);
    if (id == null || kIsWeb) return const SizedBox(width: 28);
    final progress = _downloadProgress[id];
    if (progress != null) {
      return SizedBox(
        width: 34,
        height: 30,
        child: Center(
          child: progress >= 1.0
              ? const Icon(Icons.check_circle, size: 15, color: Color(0xFF8FBC8F))
              : SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: progress > 0 ? progress : null,
                    color: const Color(0xFF71867A),
                  ),
                ),
        ),
      );
    }
    if (_downloadedIds.contains(id)) {
      return const SizedBox(
        width: 34,
        height: 30,
        child: Center(
          child: Icon(Icons.check_circle, size: 15, color: Color(0xFF8FBC8F)),
        ),
      );
    }
    return SizedBox(
      width: 34,
      height: 30,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        iconSize: 17,
        tooltip: '下载',
        icon: const Icon(Icons.download, color: Color(0xFF71867A)),
        onPressed: () => _downloadSingle(sutra, id),
      ),
    );
  }

  void _showMissingSutrasSheet() {
    if (!_missingComputed) return;
    if (_missingSutraTitles.isEmpty) return;

    final titles = _missingSutraTitles.toList()..sort();
    final fullText = titles.join('\n');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (ctx) {
        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.85,
            minChildSize: 0.35,
            maxChildSize: 0.95,
            builder: (ctx, controller) {
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Text(
                          '缺失经文 (${titles.length})',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF212121),
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: fullText));
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制缺失经文列表')),
                            );
                          },
                          child: const Text('复制全部'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      controller: controller,
                      itemCount: titles.length,
                      itemBuilder: (ctx, i) {
                        final t = titles[i];
                        return ListTile(
                          dense: true,
                          visualDensity: const VisualDensity(horizontal: 0, vertical: -3),
                          title: Text(
                            t,
                            style: const TextStyle(color: Colors.red, fontSize: 14),
                          ),
                          trailing: IconButton(
                            tooltip: '复制',
                            icon: const Icon(Icons.copy, size: 18, color: Color(0xFF616161)),
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: t));
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已复制')),
                              );
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
    }

  List<Sutra> _defaultSutras = [];
  List<Sutra> _allSutras = [];
  List<Sutra> _filteredSutras = [];
  List<File> txtFiles = [];

  bool _isReadExpanded = false;
  bool _isFavoriteExpanded = false;

  /// 是否处于搜索激活状态（底部「搜索」菜单进入，页内清空退出）。
  bool _searchActive = false;

  static const String _kDownloadedIdsKey = 'downloaded_sutra_ids';
  /// 数据版本号：下载进度/经书状态变化时递增，供子页面（分部详情页）监听刷新。
  final ValueNotifier<int> _sutraDataVersion = ValueNotifier<int>(0);
  final Set<String> _downloadedIds = {};
  final Map<String, double> _downloadProgress = {};
  final Map<String, int> _folderDownloadDone = {};
  final Map<String, int> _folderDownloadTotal = {};

  // 文件夹名称映射
  final Map<String, String> _folderDisplayNames = {
    'T01阿含部类': 'T01阿含部类',
    'T02阿含部类': 'T02阿含部类',
    'T03本缘部': 'T03本缘部',
    'T04本缘部': 'T04本缘部',
    'T05般若部': 'T05般若部',
    'T06般若部': 'T06般若部',
    'T07般若部': 'T07般若部',
    'T08般若部': 'T08般若部',
    'T09法华部·华严部': 'T09法华部·华严部',
    'T10法华部·华严部': 'T10法华部·华严部',
    'T11宝积部·涅槃部': 'T11宝积部·涅槃部',
    'T12宝积部·涅槃部': 'T12宝积部·涅槃部',
    'T13大集部': 'T13大集部',
    'T14经集部': 'T14经集部',
    'T15经集部': 'T15经集部',
    'T16经集部': 'T16经集部',
    'T17经集部': 'T17经集部',
    'T18密教部': 'T18密教部',
    'T19密教部': 'T19密教部',
    'T20密教部': 'T20密教部',
    'T21密教部': 'T21密教部',
    'T22律部': 'T22律部',
    'T23律部': 'T23律部',
    'T24律部': 'T24律部',
    'T25释经论部·毗昙部': 'T25释经论部·毗昙部',
    'T26释经论部·毗昙部': 'T26释经论部·毗昙部',
    'T27释经论部·毗昙部': 'T27释经论部·毗昙部',
    'T28释经论部·毗昙部': 'T28释经论部·毗昙部',
    'T29释经论部·毗昙部': 'T29释经论部·毗昙部',
    'T30中观部·瑜伽部': 'T30中观部·瑜伽部',
    'T31中观部·瑜伽部': 'T31中观部·瑜伽部',
    'T32论集部': 'T32论集部',
    'T33经疏部': 'T33经疏部',
    'T34经疏部': 'T34经疏部',
    'T35经疏部': 'T35经疏部',
    'T36经疏部': 'T36经疏部',
    'T37经疏部': 'T37经疏部',
    'T38经疏部': 'T38经疏部',
    'T39经疏部': 'T39经疏部',
    'T40律疏部·论疏部': 'T40律疏部·论疏部',
    'T41律疏部·论疏部': 'T41律疏部·论疏部',
    'T42律疏部·论疏部': 'T42律疏部·论疏部',
    'T43律疏部·论疏部': 'T43律疏部·论疏部',
    'T44律疏部·论疏部': 'T44律疏部·论疏部',
    'T45诸宗部': 'T45诸宗部',
    'T46诸宗部': 'T46诸宗部',
    'T47诸宗部': 'T47诸宗部',
    'T48诸宗部': 'T48诸宗部',
    'T49史传部': 'T49史传部',
    'T50史传部': 'T50史传部',
    'T51史传部': 'T51史传部',
    'T52史传部': 'T52史传部',
    'T53事汇部·外教部·目录部': 'T53事汇部·外教部·目录部',
    'T54事汇部·外教部·目录部': 'T54事汇部·外教部·目录部',
    'T55事汇部·外教部·目录部': 'T55事汇部·外教部·目录部',
    'T85图象部': 'T85图象部',
  };

  @override
  void initState() {
    super.initState();
    _initFolders();
    _loadSutras();
    _loadLastRead();
    _loadReadingStats();
    _loadRecentSutras();
    _loadAssetManifest();
    _loadDownloadedIds();
    widget.activeTab?.addListener(_onActiveTabChanged);    _searchController.addListener(_filterSutras);
    _drawerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    final drawerCurve = CurvedAnimation(
      parent: _drawerController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _drawerSlide =
        Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero).animate(drawerCurve);
    _overlayOpacity = Tween<double>(begin: 0, end: 1).animate(drawerCurve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  /// 从阅读页等路由返回时刷新“最近阅读”与收藏状态，保证卡片始终是最新的。
  @override
  void didPopNext() {
    reload();
  }

  void _onActiveTabChanged() {
    _loadLastRead();
  }

  @override
  void dispose() {
    widget.activeTab?.removeListener(_onActiveTabChanged);
    routeObserver.unsubscribe(this);
    _drawerController.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _sutraDataVersion.dispose();
    super.dispose();
  }

  List<String> _folders = [];

  void _initFolders() {
    _folders = _folderDisplayNames.values.toList();
  }

  Future<void> _loadSutras() async {
    // 1) 优先读本地 JSON 文件（快速，避免大键塞进 SharedPreferences 拖慢启动）。
    final file = await _sutraListFile();
    try {
      if (await file.exists()) {
        final loaded = await _parseSutraListFile(file);
        if (loaded.isNotEmpty) {
          _applySutraList(loaded);
          await _maybeRestoreDefaultsAfterApkUpdate();
          await _applyRestoredSutraStates();
          return;
        }
      }
    } catch (_) {
      // 文件损坏则回退到 prefs / 打包目录。
    }

    // 2) 从旧版 SharedPreferences 迁移（首次升级后执行一次）。
    final prefs = await SharedPreferences.getInstance();
    final sutraJsonList = prefs.getStringList('sutras');
    if (sutraJsonList != null && sutraJsonList.isNotEmpty) {
      final loaded = sutraJsonList
          .map((jsonStr) => Sutra.fromJson(jsonDecode(jsonStr)))
          .toList();
      await _writeSutraListFile(loaded);
      await prefs.remove('sutras');
      _applySutraList(loaded);
      await _maybeRestoreDefaultsAfterApkUpdate();
      await _applyRestoredSutraStates();
      return;
    }

    // 3) 首次启动：从打包的目录 JSON 加载。
    final catalog = await _loadCatalogFromAsset();
    _applySutraList(catalog);
    await _writeSutraListFile(catalog);
    // 初始化安装标记（避免第一次启动就触发“恢复默认”）。
    await _shouldRestoreDefaultsAfterApkUpdate(prefs);
    await _applyRestoredSutraStates();
  }

  /// 将云端同步下来的经书状态（已读/收藏/置顶/时间）合并进本地列表。
  /// 以标题匹配，采用并集（OR）语义：本地缺失的状态补上，已有状态绝不覆盖。
  /// 幂等：重复合并不会产生副作用。
  Future<void> _applyRestoredSutraStates() async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('sutra_states');
      if (raw == null || raw.isEmpty) return;
      final states = jsonDecode(raw);
      if (states is! Map || states.isEmpty) return;

      var changed = false;
      final list = List<Sutra>.from(_allSutras);
      for (var i = 0; i < list.length; i++) {
        final st = states[list[i].title];
        if (st is! Map) continue;
        final s = list[i];
        final r = st['r'] == true;
        final f = st['f'] == true;
        final p = st['p'] == true;
        final rt = st['rt']?.toString();
        final ft = st['ft']?.toString();
        if (!r && !f && !p && rt == null && ft == null) continue;
        final timeSame =
            (rt == null || s.readTime?.toIso8601String() == rt) &&
                (ft == null || s.favoriteTime?.toIso8601String() == ft);
        if (r == s.isRead && f == s.isFavorite && p == s.isPinned && timeSame) {
          continue;
        }
        list[i] = Sutra(
          s.title,
          s.size,
          isPinned: s.isPinned || p,
          isRead: s.isRead || r,
          isFavorite: s.isFavorite || f,
          filePath: s.filePath,
          folder: s.folder,
          favoriteTime:
              (s.favoriteTime != null || ft == null) ? s.favoriteTime : DateTime.tryParse(ft),
          readTime: (s.readTime != null || rt == null) ? s.readTime : DateTime.tryParse(rt),
        );
        changed = true;
      }
      if (changed) {
        _applySutraList(list);
        await _writeSutraListFile(list);
      }
    } catch (_) {
      // 状态合并失败不影响列表加载。
    }
  }

  void _applySutraList(List<Sutra> list) {
    setState(() {
      _allSutras = List.from(list);
      // 搜索激活时保持过滤（reload 会重置 _filteredSutras 为全量，
      // 若不重新过滤，搜索结果会和搜索框字符不一致）。
      _filteredSutras = _searchActive
          ? _filterListBySearch(List.from(list))
          : List.from(list);
    });
    _randomSutra ??= _rollRandomSutra();
    unawaited(_ensureRandomFolder());
    _bestAssetPathByTitleCache.clear();
    _missingComputed = false;
    _recomputeMissingSutrasIfReady();
  }

  /// 按当前搜索框内容过滤 [list]，空查询返回全量。
  List<Sutra> _filterListBySearch(List<Sutra> list) {
    final q = _searchController.text.trim();
    if (q.isEmpty) return list;
    final filtered = list.where((sutra) {
      if (sutra.title.contains(q)) return true;
      return (_folderDisplayNames[sutra.folder] ?? '').contains(q);
    }).toList();
    filtered.sort((a, b) {
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;
      return 0;
    });
    return filtered;
  }

  /// 默认在「全部经典」下方随机展示一部（与随缘读经一致），优先恢复上次展示的部类。
  Future<void> _ensureRandomFolder() async {
    if (_randomFolder != null) return;
    String? restored;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('last_random_folder');
      if (saved != null && saved.isNotEmpty && _folders.contains(saved)) {
        restored = saved;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _randomFolder = restored ?? _rollRandomFolder();
    });
    if (restored == null) {
      await _persistRandomFolder();
    }
  }

  /// 记录当前展示的部类，便于下次打开恢复。
  Future<void> _persistRandomFolder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_random_folder', _randomFolder ?? '');
    } catch (_) {}
  }

  /// 云端同步拉取后刷新经书列表与最近阅读。
  Future<void> reload() async {
    await _loadSutras();
    await _loadLastRead();
    await _loadReadingStats();
    await _loadRecentSutras();
  }

  Future<File> _sutraListFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}${Platform.pathSeparator}sutras_list.json');
  }

  Future<List<Sutra>> _parseSutraListFile(File file) async {
    final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
    return decoded.map((e) => Sutra.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> _writeSutraListFile(List<Sutra> list) async {
    if (kIsWeb) return;
    try {
      final file = await _sutraListFile();
      await file.writeAsString(
        jsonEncode(list.map((s) => s.toJson()).toList()),
        flush: true,
      );
    } catch (_) {
      // 写入失败不影响内存中的列表。
    }
  }

  Future<List<Sutra>> _loadCatalogFromAsset() async {
    if (_defaultSutras.isNotEmpty) return List.from(_defaultSutras);
    try {
      final raw = await rootBundle.loadString('assets/sutras_catalog.json');
      final decoded = jsonDecode(raw) as List<dynamic>;
      final list = decoded.map((e) {
        final m = e as Map<String, dynamic>;
        return Sutra(
          m['t'] as String,
          m['s'] as String,
          folder: m['f'] as String?,
        );
      }).toList();
      _defaultSutras = list;
      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _maybeRestoreDefaultsAfterApkUpdate() async {
    if (kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    final shouldRestore = await _shouldRestoreDefaultsAfterApkUpdate(prefs);
    if (!shouldRestore) return;
    await _loadCatalogFromAsset();
    if (_defaultSutras.isEmpty) return;
    final restored = _mergeMissingDefaultSutras(_allSutras);
    _applySutraList(restored);
    await _writeSutraListFile(restored);
  }

  Future<bool> _shouldRestoreDefaultsAfterApkUpdate(SharedPreferences prefs) async {
    if (kIsWeb) return false;
    if (!Platform.isAndroid) return false;
    try {
      final current = await _appChannel.invokeMethod<int>('getLastUpdateTime');
      if (current == null) return false;
      final last = prefs.getInt(_kApkLastUpdateTimeKey);
      if (last == null) {
        await prefs.setInt(_kApkLastUpdateTimeKey, current);
        return false;
      }
      if (last != current) {
        await prefs.setInt(_kApkLastUpdateTimeKey, current);
        return true;
      }
    } catch (_) {
      // ignore
    }
    return false;
  }

  List<Sutra> _mergeMissingDefaultSutras(List<Sutra> current) {
    // 用标题作为唯一键（目录 JSON 中默认经书没有 filePath）。
    final existingTitles = <String>{};
    for (final s in current) {
      existingTitles.add(s.title);
    }

    final merged = List<Sutra>.from(current);
    for (final d in _defaultSutras) {
      if (!existingTitles.contains(d.title)) {
        merged.add(d);
      }
    }
    return merged;
  }

  Future<void> _saveSutras() async {
    await _writeSutraListFile(_allSutras);
    _sutraDataVersion.value++;
  }

  void _filterSutras() {
    setState(() {
      _filteredSutras = _filterListBySearch(List.from(_allSutras));
    });
  }

  void _showBottomSheet(BuildContext context, Sutra sutra, {bool showPin = false}) {
    _dismissKeyboard();
    var index = _allSutras.indexOf(sutra);
    if (index < 0) {
      // 列表重新加载后对象引用可能失效（如随缘读经的随机经书），按标题回退查找。
      index = _allSutras.indexWhere((s) => s.title == sutra.title);
    }
    if (index < 0) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildMenuItem(
                icon: sutra.isFavorite ? Icons.favorite : Icons.favorite_border,
                title: sutra.isFavorite ? '取消收藏' : '收藏',
                onTap: () {
                  _toggleFavorite(index);
                  Navigator.pop(context);
                },
              ),
              if (showPin)
                _buildMenuItem(
                  icon: sutra.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  title: sutra.isPinned ? '取消置顶' : '置顶',
                  onTap: () {
                    _togglePin(index);
                    Navigator.pop(context);
                  },
                ),
              _buildMenuItem(
                icon: sutra.isRead ? Icons.mark_chat_unread : Icons.mark_chat_read,
                title: sutra.isRead ? '取消完成阅读' : '标记完成阅读',
                onTap: () {
                  _toggleRead(index);
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// 供子页面（收藏页等）复用：弹出经书长按菜单。
  void showSutraMenu(BuildContext context, Sutra sutra, {bool showPin = false}) {
    _showBottomSheet(context, sutra, showPin: showPin);
  }

  /// 供子页面监听的经书数据版本号。
  ValueListenable<int> get sutraDataVersion => _sutraDataVersion;

  /// 供子页面读取收藏列表（置顶优先）。
  List<Sutra> getFavoriteSutras() => _getFavoriteSutras();

  /// 供子页面查询某本经书当前的下载进度（null 表示未在下载）。
  double? downloadProgressOf(String id) => _downloadProgress[id];

  /// 供子页面判断某本经书是否已下载到本地。
  bool isSutraDownloaded(String id) => _downloadedIds.contains(id);

  Widget _buildMenuItem({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF212121), size: 24),
            const SizedBox(width: 16),
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFF212121),
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _togglePin(int index) async {
    setState(() {
      _allSutras[index] = Sutra(
        _allSutras[index].title,
        _allSutras[index].size,
        isPinned: !_allSutras[index].isPinned,
        isRead: _allSutras[index].isRead,
        isFavorite: _allSutras[index].isFavorite,
        filePath: _allSutras[index].filePath,
        folder: _allSutras[index].folder,
      );
      _filterSutras();
    });
    await _saveSutras();
    await SutraFavorites.syncStatePref(_allSutras[index].title);
  }

  Future<void> _toggleFavorite(int index) async {
    setState(() {
      _allSutras[index] = Sutra(
        _allSutras[index].title,
        _allSutras[index].size,
        isPinned: _allSutras[index].isPinned,
        isRead: _allSutras[index].isRead,
        isFavorite: !_allSutras[index].isFavorite,
        filePath: _allSutras[index].filePath,
        folder: _allSutras[index].folder,
        favoriteTime: !_allSutras[index].isFavorite ? DateTime.now() : null,
        readTime: _allSutras[index].readTime,
      );
      _filterSutras();
    });
    await _saveSutras();
    await SutraFavorites.syncStatePref(_allSutras[index].title);
  }

  Future<void> _toggleRead(int index) async {
    setState(() {
      _allSutras[index] = Sutra(
        _allSutras[index].title,
        _allSutras[index].size,
        isPinned: _allSutras[index].isPinned,
        isRead: !_allSutras[index].isRead,
        isFavorite: _allSutras[index].isFavorite,
        filePath: _allSutras[index].filePath,
        folder: _allSutras[index].folder,
        favoriteTime: _allSutras[index].favoriteTime,
        readTime: !_allSutras[index].isRead ? DateTime.now() : null,
      );
      _filterSutras();
    });
    await _saveSutras();
    await SutraFavorites.syncStatePref(_allSutras[index].title);
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      setState(() {
        for (var file in result.files) {
          if (file.path != null) {
            String fileName = file.path!;
            if (fileName.toLowerCase().endsWith('.txt')) {
              File f = File(file.path!);
              txtFiles.add(f);
              String name = fileName.split('/').last.split('\\').last.replaceAll('.txt', '');
              int size = f.lengthSync();
              String sizeStr = size < 1024 ? '${size}B' : size < 1024 * 1024 ? '${(size / 1024).toStringAsFixed(1)}k' : '${(size / (1024 * 1024)).toStringAsFixed(1)}M';
              _allSutras.add(Sutra(name, sizeStr, filePath: file.path, folder: 'T01'));
              print('Added sutra: $name, path: ${file.path}');
            }
          }
        }
        _filteredSutras = List.from(_allSutras);
      });
      _saveSutras();
    }
  }

  List<Sutra> _getReadSutras() {
    List<Sutra> readSutras = _filteredSutras.where((sutra) => sutra.isRead).toList();
    readSutras.sort((a, b) {
      if (a.readTime == null && b.readTime == null) return 0;
      if (a.readTime == null) return 1;
      if (b.readTime == null) return -1;
      return b.readTime!.compareTo(a.readTime!);
    });
    return readSutras;
  }

  /// 某部分类下的全部经书（含已读）。
  List<Sutra> _getAllSutrasInFolder(String folder) {
    return _allSutras.where((s) => s.folder == folder).toList();
  }

  /// 我的收藏：置顶优先，其余按收藏时间倒序。
  List<Sutra> _getFavoriteSutras() {
    final list = _allSutras.where((s) => s.isFavorite).toList();
    list.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      if (a.favoriteTime == null && b.favoriteTime == null) return 0;
      if (a.favoriteTime == null) return 1;
      if (b.favoriteTime == null) return -1;
      return b.favoriteTime!.compareTo(a.favoriteTime!);
    });
    return list;
  }

  Future<void> _loadLastRead() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString('last_read_title');
    final fp = prefs.getString('last_read_filePath');
    var progress = 0.0;
    if (fp != null) {
      progress = prefs.getDouble('progress_$fp') ?? 0.0;
    }
    if (!mounted) return;
    setState(() {
      _lastReadTitle = t;
      _lastReadFilePath = fp;
      _lastReadProgress = progress;
    });
  }

  /// 阅读统计：已读天数与今日已读册数（依据每日诵经历史）。
  Future<void> _loadReadingStats() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('daily_sutra_history') ?? '{}';
    var readDays = 0;
    var todayCount = 0;
    try {
      final history = jsonDecode(raw);
      if (history is Map) {
        readDays = history.length;
        final now = DateTime.now();
        final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        final todayList = history[today];
        if (todayList is List) todayCount = todayList.length;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _readDays = readDays;
      _todayReadCount = todayCount;
    });
  }

  /// 最近阅读记录（来自 recent_sutras）。
  Future<void> _loadRecentSutras() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('recent_sutras') ?? [];
    final list = raw.map((e) {
      final parts = e.split('|||');
      return {'title': parts[0], 'filePath': parts.length > 1 ? parts[1] : ''};
    }).toList();
    if (!mounted) return;
    setState(() {
      _recentSutras = list;
    });
  }

  String _displayTitle(String title) =>
      title.replaceAll(RegExp(r'T\d+n[0-9a-z]+_\d+$'), '');

  Sutra? _findSutra(String title) {
    for (final s in _allSutras) {
      if (s.title == title) return s;
    }
    return null;
  }

  /// 供子页面（最近阅读页等）按标题查找经书。
  Sutra? findSutra(String title) => _findSutra(title);

  /// 供子页面读取最近阅读记录。
  List<Map<String, String>> getRecentSutras() =>
      List<Map<String, String>>.from(_recentSutras);

  /// 供子页面刷新最近阅读记录。
  Future<void> reloadRecentSutras() => _loadRecentSutras();

  Future<bool> _canOpenSutra(Sutra sutra) async {
    final fp = sutra.filePath;
    final isAssetLike = fp == null || fp.startsWith('assets/');
    if (isAssetLike) {
      final id = SutraDownloader.extractId(sutra.title, sutra.filePath);
      if (id == null) return false;
      if (_downloadedIds.contains(id)) return true;
      // 以磁盘实际文件为准（prefs 标记可能缺失/过期），避免“已可读却提示下载”。
      return await SutraDownloader.isDownloaded(id);
    }
    return !_isSutraContentMissing(sutra);
  }

  void _openReading(Sutra sutra) {
    _dismissKeyboard();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReadingPage(
          title: sutra.title,
          filePath: _filePathForReading(sutra),
        ),
      ),
    );
  }

  Future<void> _openSutra(Sutra sutra) async {
    _dismissKeyboard();
    if (await _canOpenSutra(sutra)) {
      _openReading(sutra);
      return;
    }
    final id = SutraDownloader.extractId(sutra.title, sutra.filePath);
    if (id == null) {
      _openReading(sutra);
      return;
    }
    // 该经书正在下载中时，避免重复启动下载。
    final inFlight = _downloadProgress[id];
    if (inFlight != null && inFlight < 1.0) return;
    await _downloadSingle(sutra, id);
  }

  Widget _buildContinueReadingCard() {
    final title = _lastReadTitle;
    if (title == null) return const SizedBox.shrink();
    final pct = (_lastReadProgress * 100).clamp(0.0, 100.0);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Material(
        color: const Color(0xFFFFFAF5),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _openLastRead,
        onLongPress: () {
          final sutra = _findSutra(title);
          if (sutra != null) {
            _showBottomSheet(context, sutra);
          }
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFEFE6DA), width: 0.8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: const Color(0xFF5d4037).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: const Icon(Icons.play_circle_fill, color: Color(0xFF5d4037), size: 15),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '继续阅读',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Color(0xFF5d4037),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _openLastRead,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE5A12E),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '立即进入',
                            style: TextStyle(
                              color: Color(0xFF3E2723),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(width: 2),
                          Icon(Icons.arrow_forward, color: Color(0xFF3E2723), size: 12),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _displayTitle(title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF3E2723),
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _lastReadProgress.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: const Color(0xFF5d4037).withValues(alpha: 0.16),
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFD4A06A)),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '已读 ${pct.toStringAsFixed(1)}%',
                style: const TextStyle(
                  color: Color(0xFFB8860B),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  void _openLastRead() {
    final title = _lastReadTitle;
    if (title == null) return;
    openRecentSutra(title, _lastReadFilePath);
  }

  /// 打开一部经书：优先走本地列表（保持已读/收藏等状态），否则直接进入阅读页。
  void openRecentSutra(String title, String? filePath) {
    _dismissKeyboard();
    final sutra = _findSutra(title);
    if (sutra != null) {
      _openSutra(sutra);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ReadingPage(title: title, filePath: filePath),
        ),
      );
    }
  }

  Widget _buildSearchBar() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE8E0D5), width: 0.8),
      ),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          hintText: '搜索经文 · 支持书名与部类',
          hintStyle: const TextStyle(color: Color(0xFFB8B8B8), fontSize: 13),
          prefixIcon: const Padding(
            padding: EdgeInsets.only(left: 8, right: 4),
            child: Icon(Icons.search, color: Color(0xFF616161), size: 18),
          ),
          suffixIcon: GestureDetector(
            onTap: _exitSearch,
            child: const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.close, color: Color(0xFFB8B8B8), size: 18),
            ),
          ),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        style: const TextStyle(color: Color(0xFF212121), fontSize: 14),
        onSubmitted: (_) => _dismissKeyboard(),
      ),
    );
  }

  Widget _buildProgressCard() {
    final total = _allSutras.length;
    final read = _allSutras.where((s) => s.isRead).length;
    final pct = total == 0 ? 0.0 : read / total * 100;
    if (pct >= 100) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _maybeShowCompletionDialog(),
      );
    }
    const milestones = [25, 50, 75, 100];
    final remainVolumes = total - read;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF8D6E63), Color(0xFFBCAAA4)],
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: const Color(0xFF8D6E63).withValues(alpha: 0.25), blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_stories, color: Color(0xFF4E342E), size: 16),
              const SizedBox(width: 6),
              const Text('阅藏进度', style: TextStyle(color: Color(0xFF4E342E), fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                '${pct.toStringAsFixed(1)}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              return SizedBox(
                width: constraints.maxWidth,
                height: 10,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                  Container(
                    height: 10,
                    decoration: BoxDecoration(
                      color: const Color(0xFF5d4037).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  if (pct > 0)
                    FractionallySizedBox(
                      widthFactor: pct / 100,
                      child: Container(
                        height: 10,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD4A06A),
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ),
                  for (final m in milestones)
                    if (m < 100)
                      Positioned(
                        left: constraints.maxWidth * m / 100 - 0.75,
                        top: 2,
                        bottom: 2,
                        child: Container(
                          width: 1.5,
                          color: const Color(0xFF5d4037).withValues(alpha: 0.55),
                        ),
                      ),
                ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              return SizedBox(
                width: constraints.maxWidth,
                height: 16,
                child: ClipRect(
                  child: Stack(
                    children: [
                      for (final m in milestones)
                        if (m == 100)
                          Positioned(
                            right: 0,
                            top: 1,
                            child: Text(
                              '圆满',
                              style: TextStyle(
                                color: pct >= m
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.6),
                                fontSize: 11,
                                fontWeight: pct >= m
                                    ? FontWeight.w700
                                    : FontWeight.normal,
                              ),
                            ),
                          )
                        else
                          Positioned(
                            left: constraints.maxWidth * m / 100,
                            top: 1,
                            child: FractionalTranslation(
                              translation: const Offset(-0.5, 0),
                              child: Text(
                                '$m%',
                                style: TextStyle(
                                  color: pct >= m
                                      ? Colors.white
                                      : Colors.white.withValues(alpha: 0.6),
                                  fontSize: 11,
                                  fontWeight: pct >= m
                                      ? FontWeight.w700
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          Text(
            '已阅 $read 册 · 共 ${_folders.length} 部 · $total 册',
            style: const TextStyle(color: Color(0xFF4E342E), fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            '已读 $_readDays 天 · 今日已读 $_todayReadCount 册 · 剩余 $remainVolumes 册',
            style: const TextStyle(
              color: Color(0xFF5d4037),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  bool _completionDialogShown = false;

  /// 阅藏进度达到 100% 时，在页面中间弹出一次「阅藏圆满」庆祝弹窗（终生仅一次）。
  Future<void> _maybeShowCompletionDialog() async {
    if (_completionDialogShown) return;
    _completionDialogShown = true;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('sutra_reading_complete_shown') ?? false) return;
    await prefs.setBool('sutra_reading_complete_shown', true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF5d4037), Color(0xFF7a5c4e)],
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.emoji_events_rounded,
                  color: Color(0xFFE8C48A), size: 56),
              const SizedBox(height: 12),
              const Text(
                '阅藏圆满',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '功德无量',
                style: TextStyle(
                  color: Color(0xFFE8C48A),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '你已读完所有经文，随喜赞叹！',
                style: TextStyle(color: Color(0xFFE8D9C4), fontSize: 13),
              ),
              const SizedBox(height: 18),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE8C48A),
                  foregroundColor: const Color(0xFF5d4037),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  '随喜赞叹',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickGrid() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 24, 14, 12),
          child: Row(
            children: [
              const Icon(Icons.grid_view_rounded, color: Color(0xFFba8e82), size: 18),
              const SizedBox(width: 6),
              const Text(
                '经典入口',
                style: TextStyle(
                  color: Color(0xFF5d4037),
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            height: 132,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _buildFavoriteTile()),
                      const SizedBox(height: 10),
                      Expanded(child: _buildRecentTile()),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: _buildRandomTile()),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(child: _buildAllSutrasBar()),
              const SizedBox(width: 8),
              _buildChangeFolderButton(),
            ],
          ),
        ),
        if (_randomFolder != null) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _buildRandomFolderSection(),
          ),
        ],
      ],
    );
  }

  /// 全部经典通栏窄条：点击展开全部部类浏览。
  Widget _buildAllSutrasBar() {
    return Material(
      color: const Color(0xFFFFFAF5),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _dismissKeyboard();
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => AllSutrasPage(parent: this)),
          );
        },
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFEFE6DA), width: 0.8),
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: const Color(0xFF8B6B5A).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.menu_book_rounded, size: 16, color: Color(0xFF8B6B5A)),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '全部经典',
                  style: TextStyle(
                    color: Color(0xFF5d4037),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${_folders.length} 个部类',
                style: const TextStyle(color: Color(0xFF999999), fontSize: 11),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: Color(0xFFC4B5A8), size: 16),
            ],
          ),
        ),
      ),
    );
  }

  /// 「换一部」按钮：刷新图标 + 文案，随机轮换一部，将该部经书全部展开显示。
  Widget _buildChangeFolderButton() {
    return Material(
      color: const Color(0xFFFFFAF5),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _dismissKeyboard();
          setState(() {
            _randomFolder = _rollRandomFolder();
          });
        },
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFEFE6DA), width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.autorenew, color: Color(0xFF71867A), size: 14),
              const SizedBox(width: 3),
              const Text(
                '换一部',
                style: TextStyle(
                  color: Color(0xFF71867A),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 随机选中部类的全部经书列表：展示在该部类下全部经书，供逐一阅读。
  Widget _buildRandomFolderSection() {
    final folder = _randomFolder;
    if (folder == null) return const SizedBox.shrink();
    final sutras = _getAllSutrasInFolder(folder);
    final name = _folderDisplayNames[folder] ?? folder;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAF5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF5d4037),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '共 ${sutras.length} 册',
                  style: const TextStyle(color: Color(0xFF999999), fontSize: 11),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 0.6, color: Color(0xFFEFE6DA)),
          if (sutras.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  '暂无内容',
                  style: TextStyle(color: Color(0xFF999999), fontSize: 12),
                ),
              ),
            )
          else
            ...sutras.map((s) => _buildSutraTile(context, s)),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 我的收藏宫格：仅入口（跳转收藏列表）。
  Widget _buildFavoriteTile() {
    return Material(
      color: const Color(0xFFFFFAF5),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _dismissKeyboard();
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => FavoriteSutrasPage(parent: this)),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFEFE6DA), width: 0.8),
          ),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: const Color(0xFFD4A06A).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(Icons.star_rounded, size: 14, color: Color(0xFFD4A06A)),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '我的收藏',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(0xFF5d4037),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFFC4B5A8), size: 14),
            ],
          ),
        ),
      ),
    );
  }

  /// 最近阅读宫格：仅入口（跳转最近阅读列表）。
  Widget _buildRecentTile() {
    return Material(
      color: const Color(0xFFFFFAF5),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _dismissKeyboard();
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => RecentSutrasPage(parent: this)),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFEFE6DA), width: 0.8),
          ),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: const Color(0xFF5d4037).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(Icons.history_rounded, size: 14, color: Color(0xFF5d4037)),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '最近阅读',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(0xFF5d4037),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFFC4B5A8), size: 14),
            ],
          ),
        ),
      ),
    );
  }

  /// 随缘读经宫格：标题 + 随机经书信息（书名 + 部类 + 大小，可点书名阅读、点「换一本」重抽）。
  Widget _buildRandomTile() {
    final sutra = _randomSutra;
    final folderName = sutra != null
        ? (_folderDisplayNames[sutra.folder] ?? sutra.folder)
        : null;
    final info = [
      if (folderName != null && folderName.isNotEmpty) folderName,
      if (sutra?.size != null && sutra!.size.isNotEmpty) sutra.size,
    ].join(' · ');
    return Material(
      color: const Color(0xFFFFFAF5),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _dismissKeyboard();
          if (_randomSutra != null) _openSutra(_randomSutra!);
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFEFE6DA), width: 0.8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: const Color(0xFF71867A).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: const Icon(Icons.casino_rounded, size: 14, color: Color(0xFF71867A)),
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      '随缘读经',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Color(0xFF5d4037),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      setState(() {
                        _randomSutra = _rollRandomSutra();
                      });
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.autorenew, color: Color(0xFF71867A), size: 13),
                          SizedBox(width: 2),
                          Text(
                            '换一册',
                            style: TextStyle(
                              color: Color(0xFF71867A),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                sutra != null ? _displayTitle(sutra.title) : '随机一部经典',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF3E2723),
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
              if (info.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  info,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF8B6B5A),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                  ),
                ),
              ],
              const Spacer(),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (sutra != null) _buildRandomDownloadIndicator(sutra),
                    const SizedBox(width: 6),
                    const Text(
                      '开始阅读 ›',
                      style: TextStyle(
                        color: Color(0xFFE5A12E),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 随缘读经卡片「开始阅读」前的下载状态标记：
  /// 下载中显示进度小圆圈（刚启动还没收到字节时转圈动画，避免看起来像卡住），
  /// 已下载显示「下载完成」图标。
  Widget _buildRandomDownloadIndicator(Sutra sutra) {
    final id = SutraDownloader.extractId(sutra.title, sutra.filePath);
    if (id == null) return const SizedBox.shrink();
    final p = _downloadProgress[id];
    if (p != null && p < 1.0) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          // 尚未收到任何进度时用 null 走转圈动画，收到进度后显示具体百分比弧。
          value: p > 0 ? p : null,
          strokeWidth: 2,
          color: const Color(0xFF71867A),
          backgroundColor: const Color(0xFF71867A).withValues(alpha: 0.12),
        ),
      );
    }
    if (_downloadedIds.contains(id)) {
      return const Icon(Icons.check_circle, size: 16, color: Color(0xFF8FBC8F));
    }
    return const SizedBox.shrink();
  }

  Widget _buildFolderCard(String folder) {
    final list = _getAllSutrasInFolder(folder);
    final total = list.length;
    final read = list.where((s) => s.isRead).length;
    final pct = total == 0 ? 0.0 : read / total * 100;
    final name = _folderDisplayNames[folder] ?? folder;
    return Material(
      color: const Color(0xFFFFFAF5),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _dismissKeyboard();
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SutraFolderPage(
                parent: this,
                folderName: folder,
                displayName: name,
              ),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFEFE6DA), width: 0.8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  const Icon(Icons.menu_book, color: Color(0xFFba8e82), size: 15),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF5d4037),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '已读 ${pct.toStringAsFixed(0)}%',
                    style: const TextStyle(
                      color: Color(0xFFD4A06A),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: total == 0 ? 0 : read / total,
                  minHeight: 8,
                  backgroundColor: const Color(0xFFF0E6D8),
                  color: const Color(0xFFD4A06A),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '共 $total 册 · 已阅 $read 册',
                style: const TextStyle(color: Color(0xFF8B6B5A), fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_searchController.text.trim().isEmpty) {
      return const Center(
        child: Text(
          '输入书名或部类，开始搜索经文',
          style: TextStyle(color: Color(0xFF999999), fontSize: 13),
        ),
      );
    }
    if (_filteredSutras.isEmpty) {
      return const Center(
        child: Text('未找到相关经文', style: TextStyle(color: Color(0xFF999999), fontSize: 13)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 40),
      itemCount: _filteredSutras.length,
      itemBuilder: (ctx, i) => _buildSutraTile(ctx, _filteredSutras[i], showFolder: true),
    );
  }

  Widget _buildSutraTile(BuildContext ctx, Sutra sutra, {bool showFolder = false}) {
    final folderName = _folderDisplayNames[sutra.folder] ?? sutra.folder;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        dense: true,
        minVerticalPadding: 4,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        title: Text(
          _displayTitle(sutra.title),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF5d4037),
            fontSize: 14.5,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: showFolder && folderName != null
            ? Text(folderName, style: const TextStyle(color: Color(0xFF999999), fontSize: 11))
            : null,
        trailing: _buildDownloadTrailing(sutra),
        onTap: () => _openSutra(sutra),
        onLongPress: () => _showBottomSheet(ctx, sutra),
      ),
    );
  }

  Widget _buildFolder({
    required String title,
    required List<Sutra> sutras,
    required bool isExpanded,
    required VoidCallback onToggle,
    required IconData icon,
    required bool showPin,
  }) {
    return Column(
      children: [
        GestureDetector(
          onTap: onToggle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: const Color(0xFFcec6c3),
            child: Row(
              children: [
                Icon(icon, color: const Color(0xFF5d4037), size: 20),
                const SizedBox(width: 8),
                Text(
                  '$title (${sutras.length})',
                  style: const TextStyle(
                    color: Color(0xFF5d4037),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Icon(
                  isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  color: const Color(0xFF999999),
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        if (isExpanded && sutras.isNotEmpty)
          Container(
            padding: const EdgeInsets.only(left: 8, right: 8, top: 0, bottom: 20),
            child: Column(
              children: sutras.map((sutra) {
                return Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  height: 38,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Center(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                      minVerticalPadding: 0,
                      dense: true,
                      title: Text(
                        sutra.title,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.2,
                          color: Color(0xFF616161),
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      onTap: () {
                        _openSutra(sutra);
                      },
                      onLongPress: () => _showBottomSheet(context, sutra, showPin: showPin),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        if (isExpanded && sutras.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text(
                '暂无内容',
                style: TextStyle(
                  color: const Color(0xFF999999),
                  fontSize: 12,
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final drawerWidth = MediaQuery.of(context).size.width * 0.82;
    return Stack(
      children: [
        Scaffold(
          backgroundColor: const Color(0xFFF5EDE3),
          appBar: AppBar(
            backgroundColor: const Color(0xFFF5EDE3),
            elevation: 0,
            shadowColor: Colors.transparent,
            iconTheme: const IconThemeData(color: Color(0xFF212121)),
            title: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () {
                if (_scrollController.hasClients) {
                  _scrollController.animateTo(
                    0,
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                  );
                }
              },
              child: Row(
              children: [
                Text(
                  _searchActive ? '搜索' : '经藏',
                  style: const TextStyle(
                    color: Color(0xFF5d4037),
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
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
                Flexible(
                  child: Text(
                    _searchActive ? '谛听，谛听，善思念之。' : '诸行无常，一切皆苦；诸法无我，寂灭为乐。',
                    style: const TextStyle(
                      color: Color(0xFF9E9588),
                      fontSize: 12,
                    ),
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              ),
            ),
            actions: [
              // 搜索激活时隐藏右上角「助手」入口。
              if (!_searchActive)
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: IconButton(
                    tooltip: '助手',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Image.asset(
                      'assets/images/assistant.png',
                      width: 18,
                      height: 18,
                    ),
                    onPressed: widget.onOpenAssistant,
                  ),
                ),
            ],
          ),
          body: Column(
            children: [
              if (_searchActive) _buildSearchBar(),
              Expanded(
                child: _searchActive
                    ? _buildSearchResults()
                    : SingleChildScrollView(
                        controller: _scrollController,
                        padding: const EdgeInsets.only(bottom: 40),
                        child: Column(
                          children: [
                            _buildProgressCard(),
                            _buildContinueReadingCard(),
                            _buildQuickGrid(),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_drawerOpen,
            child: FadeTransition(
              opacity: _overlayOpacity,
              child: GestureDetector(
                onTap: _closeDrawer,
                child: const ColoredBox(color: Colors.black38),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          width: drawerWidth,
          child: SlideTransition(
            position: _drawerSlide,
            child: _buildDrawerPanel(),
          ),
        ),
      ],
    );
  }

  void _toggleDrawer() {
    if (_drawerOpen) {
      _closeDrawer();
    } else {
      _openDrawer();
    }
  }

  void _openDrawer() {
    if (_searchActive) {
      _searchController.clear();
      _searchFocusNode.unfocus();
      setState(() {
        _searchActive = false;
      });
      widget.onSearchModeChanged?.call(false);
      _dismissKeyboard();
    }
    setState(() {
      _drawerOpen = true;
    });
    _drawerController.forward();
  }

  void _closeDrawer() {
    FocusScope.of(context).unfocus();
    _drawerController.reverse();
    setState(() {
      _drawerOpen = false;
      _isReadExpanded = false;
    });
  }

  Widget _buildDrawerPanel() {
    return Material(
      color: Colors.white,
      elevation: 16,
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  const Text(
                    '经藏',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF5d4037),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF616161), size: 20),
                    tooltip: '关闭',
                    onPressed: _closeDrawer,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _buildFolder(
                    title: '已阅经文',
                    sutras: _getReadSutras(),
                    isExpanded: _isReadExpanded,
                    onToggle: () {
                      setState(() {
                        _isReadExpanded = !_isReadExpanded;
                      });
                    },
                    icon: Icons.check_circle,
                    showPin: false,
                  ),
                  _buildFolder(
                    title: '我的收藏',
                    sutras: _getFavoriteSutras(),
                    isExpanded: _isFavoriteExpanded,
                    onToggle: () {
                      setState(() {
                        _isFavoriteExpanded = !_isFavoriteExpanded;
                      });
                    },
                    icon: Icons.star,
                    showPin: true,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.upload_file, color: Color(0xFF5d4037), size: 20),
                    title: const Text(
                      '导入经书（TXT）',
                      style: TextStyle(
                        color: Color(0xFF5d4037),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    onTap: () {
                      _closeDrawer();
                      _pickFile();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.error_outline, color: Color(0xFF5d4037), size: 20),
                    title: const Text(
                      '缺失经文',
                      style: TextStyle(
                        color: Color(0xFF5d4037),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    onTap: () {
                      _closeDrawer();
                      if (!_missingComputed || _missingSutraTitles.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('暂无缺失经文')),
                        );
                        return;
                      }
                      _showMissingSutrasSheet();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分部详情页：展示某一部类下的全部经书与阅读进度。
class SutraFolderPage extends StatefulWidget {
  final SutraListPageState parent;
  final String folderName;
  final String displayName;

  const SutraFolderPage({
    super.key,
    required this.parent,
    required this.folderName,
    required this.displayName,
  });

  @override
  State<SutraFolderPage> createState() => _SutraFolderPageState();
}

class _SutraFolderPageState extends State<SutraFolderPage> {
  List<Sutra> get _sutras =>
      widget.parent._getAllSutrasInFolder(widget.folderName);

  @override
  void initState() {
    super.initState();
    widget.parent._sutraDataVersion.addListener(_onParentChanged);
  }

  @override
  void dispose() {
    widget.parent._sutraDataVersion.removeListener(_onParentChanged);
    super.dispose();
  }

  void _onParentChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final total = _sutras.length;
    final read = _sutras.where((s) => s.isRead).length;
    final downloading = widget.parent._folderDownloadTotal[widget.folderName] != null;
    return Scaffold(
      backgroundColor: const Color(0xFFF5EDE3),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF5EDE3),
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Color(0xFF5d4037)),
        actionsPadding: const EdgeInsets.only(right: 24),
        title: Row(
          children: [
            Flexible(
              child: Text(
                widget.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF5d4037),
                  fontSize: 16.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '已读 $read/$total 册',
              style: const TextStyle(
                color: Color(0xFFba8e82),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        actions: [
          if (downloading)
            Center(
              child: Text(
                '${widget.parent._folderDownloadDone[widget.folderName] ?? 0}/${widget.parent._folderDownloadTotal[widget.folderName]}',
                style: const TextStyle(
                  color: Color(0xFFba8e82),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            SizedBox(
              width: 34,
              height: 30,
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: 17,
                tooltip: '下载本卷全部经文',
                icon: const Icon(Icons.download_for_offline_outlined, color: Color(0xFF71867A)),
                onPressed: () => widget.parent._downloadFolder(widget.folderName),
              ),
            ),
        ],
      ),
      body: total == 0
          ? const Center(
              child: Text('暂无经文', style: TextStyle(color: Color(0xFF999999), fontSize: 13)),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: total,
              itemBuilder: (ctx, i) => widget.parent._buildSutraTile(ctx, _sutras[i]),
            ),
    );
  }
}

/// 全部经典页：按部类浏览全部经书。
class AllSutrasPage extends StatefulWidget {
  final SutraListPageState parent;

  const AllSutrasPage({super.key, required this.parent});

  @override
  State<AllSutrasPage> createState() => _AllSutrasPageState();
}

class _AllSutrasPageState extends State<AllSutrasPage> {
  @override
  void initState() {
    super.initState();
    widget.parent._sutraDataVersion.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.parent._sutraDataVersion.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final folders = widget.parent._folders;
    return Scaffold(
      backgroundColor: const Color(0xFFF5EDE3),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF5EDE3),
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Color(0xFF5d4037)),
        title: Row(
          children: [
            const Text(
              '全部经典',
              style: TextStyle(
                color: Color(0xFF5d4037),
                fontSize: 16.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${folders.length} 个部类',
              style: const TextStyle(
                color: Color(0xFFba8e82),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.6,
        ),
        itemCount: folders.length,
        itemBuilder: (ctx, i) => widget.parent._buildFolderCard(folders[i]),
      ),
    );
  }
}
