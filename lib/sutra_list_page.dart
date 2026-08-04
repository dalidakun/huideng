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
import 'favorite_sutras_page.dart';

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
  bool _drawerOpen = false;
  late final AnimationController _drawerController;
  late final Animation<Offset> _drawerSlide;
  late final Animation<double> _overlayOpacity;
  String? _lastReadTitle;
  String? _lastReadFilePath;

  Sutra? _randomSutra;

  /// 从全部经书中随机抽取一部。
  Sutra? _rollRandomSutra() {
    if (_allSutras.isEmpty) return null;
    return _allSutras[Random().nextInt(_allSutras.length)];
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《${sutra.title}》下载完成')),
      );
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
                    color: const Color(0xFFba8e82),
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
          child: Icon(Icons.check_circle_outline, size: 15, color: Color(0xFF8FBC8F)),
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
        icon: const Icon(Icons.download, color: Color(0xFFba8e82)),
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
      _filteredSutras = List.from(list);
    });
    _randomSutra ??= _rollRandomSutra();
    _bestAssetPathByTitleCache.clear();
    _missingComputed = false;
    _recomputeMissingSutrasIfReady();
  }

  /// 云端同步拉取后刷新经书列表与最近阅读。
  Future<void> reload() async {
    await _loadSutras();
    await _loadLastRead();
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
      final q = _searchController.text.trim();
      if (q.isEmpty) {
        _filteredSutras = List.from(_allSutras);
      } else {
        final filtered = _allSutras.where((sutra) {
          if (sutra.title.contains(q)) return true;
          return (_folderDisplayNames[sutra.folder] ?? '').contains(q);
        }).toList();
        filtered.sort((a, b) {
          if (a.isPinned && !b.isPinned) return -1;
          if (!a.isPinned && b.isPinned) return 1;
          return 0;
        });
        _filteredSutras = filtered;
      }
    });
  }

  void _showBottomSheet(BuildContext context, Sutra sutra) {
    _dismissKeyboard();
    final index = _allSutras.indexOf(sutra);
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
               _buildMenuItem(
                 icon: sutra.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                 title: sutra.isPinned ? '取消置顶' : '置顶',
                 onTap: () {
                   _togglePin(index);
                   Navigator.pop(context);
                 },
               ),
               _buildMenuItem(
                 icon: Icons.edit,
                 title: '编辑标题',
                 onTap: () {
                   Navigator.pop(context);
                   _editTitle(index);
                 },
               ),
               _buildMenuItem(
                 icon: sutra.isRead ? Icons.mark_chat_unread : Icons.mark_chat_read,
                 title: sutra.isRead ? '标记为未读' : '标记为已读',
                 onTap: () {
                   _toggleRead(index);
                   Navigator.pop(context);
                 },
               ),
               _buildMenuItem(
                 icon: Icons.delete,
                 title: '删除',
                 onTap: () {
                   _deleteSutra(index);
                   Navigator.pop(context);
                 },
               ),
            ],
          ),
        );
      },
    );
  }

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

  void _togglePin(int index) {
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
    _saveSutras();
  }

  void _editTitle(int index) async {
    TextEditingController controller = TextEditingController(
      text: _allSutras[index].title,
    );

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑标题'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '请输入标题',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                setState(() {
                  _allSutras[index] = Sutra(
                    controller.text,
                    _allSutras[index].size,
                    isPinned: _allSutras[index].isPinned,
                    isRead: _allSutras[index].isRead,
                    isFavorite: _allSutras[index].isFavorite,
                    filePath: _allSutras[index].filePath,
                    folder: _allSutras[index].folder,
                  );
                  _filterSutras();
                });
                _saveSutras();
              }
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _deleteSutra(int index) {
    setState(() {
      _allSutras.remove(_allSutras[index]);
      _filterSutras();
    });
    _saveSutras();
  }

  void _addSutraToFolder(String folderName) async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      int addedCount = 0;
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
              _allSutras.add(Sutra(name, sizeStr, filePath: file.path, folder: folderName));
              addedCount++;
            }
          }
        }
        _filteredSutras = List.from(_allSutras);
      });
      _saveSutras();
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已添加 $addedCount 本经书到 ${_folderDisplayNames[folderName] ?? folderName}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _toggleFavorite(int index) {
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
    _saveSutras();
  }

  void _toggleRead(int index) {
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
    _saveSutras();
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

  /// 我的收藏：按收藏时间倒序。
  List<Sutra> _getFavoriteSutras() {
    final list = _allSutras.where((s) => s.isFavorite).toList();
    list.sort((a, b) {
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
    if (!mounted) return;
    if (t != null && t.isNotEmpty) {
      setState(() {
        _lastReadTitle = t;
        _lastReadFilePath = fp;
      });
    }
  }

  String _displayTitle(String title) =>
      title.replaceAll(RegExp(r'T\d+n[0-9a-z]+_\d+$'), '');

  Sutra? _findSutra(String title) {
    for (final s in _allSutras) {
      if (s.title == title) return s;
    }
    return null;
  }

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
    final shouldDownload = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('经文尚未下载'),
        content: Text('《${_displayTitle(sutra.title)}》的正文尚未下载（约 ${sutra.size}），是否现在下载？下载完成即可阅读。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD4A06A)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    if (shouldDownload != true || !mounted) return;
    await _downloadSingle(sutra, id);
    if (!mounted) return;
    if (_downloadedIds.contains(id)) {
      _openReading(sutra);
    }
  }

  Widget _buildRecentReadCard() {
    if (_lastReadTitle == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF8EFE2),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          final sutra = _findSutra(_lastReadTitle!);
          if (sutra != null) {
            _openSutra(sutra);
          } else {
            _dismissKeyboard();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ReadingPage(
                  title: _lastReadTitle!,
                  filePath: _lastReadFilePath,
                ),
              ),
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF5d4037).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.history, color: Color(0xFF5d4037), size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '最近阅读 · 继续上次',
                      style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _displayTitle(_lastReadTitle!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF5d4037),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFF999999), size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRandomSutraCard() {
    final sutra = _randomSutra;
    if (sutra == null) return const SizedBox.shrink();
    final folderName = _folderDisplayNames[sutra.folder] ?? sutra.folder;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF5d4037), Color(0xFF7a5c4e)],
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: const Color(0xFF5d4037).withValues(alpha: 0.2), blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.casino, color: Color(0xFFF4E6D3), size: 16),
              const SizedBox(width: 6),
              const Text('随缘读经', style: TextStyle(color: Color(0xFFF4E6D3), fontSize: 12)),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() {
                    _randomSutra = _rollRandomSutra();
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.autorenew, color: Color(0xFFF4E6D3), size: 14),
                      SizedBox(width: 4),
                      Text('换一本', style: TextStyle(color: Color(0xFFF4E6D3), fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              _dismissKeyboard();
              _openSutra(sutra);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _displayTitle(sutra.title),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  [if (folderName != null) folderName, sutra.size].join(' · '),
                  style: const TextStyle(color: Color(0xFFE8D9C4), fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerRight,
                  child: Text('开始阅读 ›', style: TextStyle(color: Color(0xFFF4E6D3), fontSize: 12)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
    int? next;
    for (final m in milestones) {
      if (pct < m) {
        next = m;
        break;
      }
    }
    final remain = next == null ? 0 : ((next / 100 * total).ceil() - read);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF5d4037), Color(0xFF7a5c4e)],
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: const Color(0xFF5d4037).withValues(alpha: 0.2), blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_stories, color: Color(0xFFF4E6D3), size: 16),
              const SizedBox(width: 6),
              const Text('阅藏进度', style: TextStyle(color: Color(0xFFF4E6D3), fontSize: 13)),
              const Spacer(),
              Text(
                '${pct.toStringAsFixed(1)}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
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
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  if (pct > 0)
                    FractionallySizedBox(
                      widthFactor: pct / 100,
                      child: Container(
                        height: 10,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFF4E6D3), Color(0xFFE8C48A)],
                          ),
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ),
                  for (final m in milestones)
                    if (m < 100)
                      Positioned(
                        left: constraints.maxWidth * m / 100 - 0.5,
                        top: 0,
                        bottom: 0,
                        child: Container(
                          width: 1,
                          color: Colors.white.withValues(alpha: 0.45),
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
                                    ? const Color(0xFFF4E6D3)
                                    : Colors.white.withValues(alpha: 0.45),
                                fontSize: 11,
                                fontWeight: pct >= m
                                    ? FontWeight.w600
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
                                      ? const Color(0xFFF4E6D3)
                                      : Colors.white.withValues(alpha: 0.45),
                                  fontSize: 11,
                                  fontWeight: pct >= m
                                      ? FontWeight.w600
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
            '已阅 $read 部 · 共 $total 部',
            style: const TextStyle(color: Color(0xFFE8D9C4), fontSize: 12),
          ),
          const SizedBox(height: 4),
          if (next != null)
            Text(
              '再读 $remain 部即可到达 $next%',
              style: const TextStyle(
                color: Color(0xFFF4E6D3),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            )
          else
            const Row(
              children: [
                Icon(Icons.emoji_events, color: Color(0xFFF4E6D3), size: 14),
                SizedBox(width: 4),
                Text(
                  '阅藏圆满，功德无量',
                  style: TextStyle(
                    color: Color(0xFFF4E6D3),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
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

  Widget _buildFavoriteSection() {
    final favorites = _getFavoriteSutras();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: Row(
            children: [
              const Icon(Icons.star_rounded, color: Color(0xFFD4A06A), size: 18),
              const SizedBox(width: 6),
              const Text(
                '我的收藏',
                style: TextStyle(
                  color: Color(0xFF5d4037),
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${favorites.length} 部',
                style: const TextStyle(color: Color(0xFF999999), fontSize: 12),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () {
                  _dismissKeyboard();
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const FavoriteSutrasPage()),
                  );
                },
                child: const Row(
                  children: [
                    Text(
                      '查看全部',
                      style: TextStyle(color: Color(0xFFba8e82), fontSize: 12),
                    ),
                    Icon(Icons.chevron_right, color: Color(0xFFba8e82), size: 16),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (favorites.isEmpty)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFAF5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFEFE6DA), width: 0.8),
            ),
            child: const Row(
              children: [
                Icon(Icons.star_border_rounded, color: Color(0xFFC4B5A8), size: 18),
                SizedBox(width: 8),
                Text(
                  '暂无收藏，在经文中点击 ♥ 收藏后即可在此快速阅读',
                  style: TextStyle(color: Color(0xFF8B6B5A), fontSize: 12.5),
                ),
              ],
            ),
          )
        else
          SizedBox(
            height: 108,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              itemCount: favorites.length,
              itemBuilder: (ctx, i) => _buildFavoriteCard(ctx, favorites[i]),
            ),
          ),
      ],
    );
  }

  Widget _buildFavoriteCard(BuildContext ctx, Sutra sutra) {
    return Container(
      width: 118,
      margin: const EdgeInsets.only(right: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAF5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEFE6DA), width: 0.8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openSutra(sutra),
        onLongPress: () => _showBottomSheet(ctx, sutra),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD4A06A).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.auto_stories_rounded,
                        size: 13, color: Color(0xFFD4A06A)),
                  ),
                  const Spacer(),
                  Icon(
                    sutra.isRead
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 13,
                    color: sutra.isRead
                        ? const Color(0xFF71867A)
                        : const Color(0xFFC4B5A8),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _displayTitle(sutra.title),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF5d4037),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategorySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: Row(
            children: [
              const Text(
                '分类阅览',
                style: TextStyle(
                  color: Color(0xFF5d4037),
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${_folders.length} 个部类',
                style: const TextStyle(color: Color(0xFF999999), fontSize: 12),
              ),
            ],
          ),
        ),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.8,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: _folders.map((f) => _buildFolderCard(f)).toList(),
        ),
      ],
    );
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
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: pct / 100,
                        minHeight: 4,
                        backgroundColor: const Color(0xFFF0E6D8),
                        color: const Color(0xFFD4A06A),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$read/$total',
                    style: const TextStyle(color: Color(0xFF999999), fontSize: 11),
                  ),
                ],
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
                      onLongPress: () => _showBottomSheet(context, sutra),
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
            title: Row(
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
                    _searchActive ? '输入经名，快速查找' : '诸行无常，一切皆苦；诸法无我，寂灭为乐。',
                    style: const TextStyle(
                      color: Color(0xFF9E9588),
                      fontSize: 10.5,
                    ),
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
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
                        padding: const EdgeInsets.only(bottom: 40),
                        child: Column(
                          children: [
                            _buildProgressCard(),
                            _buildRecentReadCard(),
                            _buildFavoriteSection(),
                            _buildRandomSutraCard(),
                            _buildCategorySection(),
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF5d4037),
                fontSize: 16.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '已读 $read / $total',
              style: const TextStyle(color: Color(0xFF999999), fontSize: 11),
            ),
          ],
        ),
        actions: [
          if (downloading)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  '${widget.parent._folderDownloadDone[widget.folderName] ?? 0}/${widget.parent._folderDownloadTotal[widget.folderName]}',
                  style: const TextStyle(
                    color: Color(0xFFba8e82),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          else ...[
            IconButton(
              tooltip: '导入经书到本卷',
              icon: const Icon(Icons.library_add_outlined, color: Color(0xFFba8e82), size: 20),
              onPressed: () => widget.parent._addSutraToFolder(widget.folderName),
            ),
            IconButton(
              tooltip: '下载本卷全部经文',
              icon: const Icon(Icons.download_for_offline_outlined, color: Color(0xFFba8e82), size: 20),
              onPressed: () => widget.parent._downloadFolder(widget.folderName),
            ),
          ],
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
