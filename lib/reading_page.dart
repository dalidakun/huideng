import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sutra_asset_path.dart';
import 'sutra_downloader.dart';
import 'sutra_edit_page.dart';
import 'sutra_favorites.dart';
import 'app_state.dart';
import 'reader_preferences.dart';
import 'note_edit_page.dart';
import 'reading_time_service.dart';
import 'sutra_list_page.dart' show routeObserver;
import 'reading_guide_page.dart';

import 'app_palette.dart';
class ReadingPage extends StatefulWidget {
  final String title;
  final String? filePath;
  final bool fromAssistant;

  const ReadingPage({
    super.key,
    required this.title,
    this.filePath,
    this.fromAssistant = false,
  });

  @override
  State<ReadingPage> createState() => _ReadingPageState();
}

class _ReadingPageState extends State<ReadingPage>
    with WidgetsBindingObserver, RouteAware {
  String _content = '';
  double _fontSize = 16.0;
  double _lineHeight = 1.8;
  int _pageMode = ReaderPreferences.pageModeScroll;
  bool _isDarkMode = false;
  late ScrollController _scrollController;
  PageController? _pageController;
  final TextEditingController _searchController = TextEditingController();
  bool _showSearchBar = false;
  bool _showMoreMenu = false;
  final GlobalKey _moreMenuKey = GlobalKey();
  List<int> _searchMatches = [];
  int _currentMatchIndex = 0;
  double _scrollProgress = 0.0;
  late final String? _resolvedFilePath;
  bool _isLoadingContent = true;
  bool _isEdited = false;
  bool _needsDownload = false;
  bool _isDownloading = false;
  double _downloadProgress = 0;
  bool _isFavorite = false;
  double? _savedPosition;
  double? _savedProgress;
  int _restoreAttempts = 0;

  // 翻页模式：分页结果与缓存，避免每帧重算。
  List<String> _flipPages = [];
  String _flipCacheKey = '';
  int _currentFlipPage = 0;
  bool _flipPageRestored = false;

  /// 顶部标题双击回到顶部：记录上次点击时间。
  DateTime? _lastTitleTap;

  /// 是否已订阅路由生命周期（用于读经计时）。
  bool _subscribed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ReadingTimeService.instance.start();
    _resolvedFilePath =
        widget.filePath == null ? null : _canonicalFilePath(widget.filePath!);
    _scrollController = ScrollController();
    _scrollController.addListener(_scrollListener);
    _pageController = PageController();
    _saveCurrentSutra();
    _loadSettings();
    _loadSavedScrollState();
    _loadContent();
    _loadFavoriteState();
  }

  /// 把任意形式的经书路径规范化为打包资产路径（assets/sutras_ascii/...）：
  ///  - 打包资产路径（含旧版中文路径）按经书 ID 重新定位；
  ///  - 本机真实存在的文件（用户自选导入等）保持原样直接读取；
  ///  - 其余（如换机/重新登录后从云端同步回来的旧设备绝对路径）按经书 ID
  ///    归一到本地下载目录对应的资产路径，保证本地副本检查能命中。
  String _canonicalFilePath(String p) {
    if (p.startsWith('assets/')) {
      return SutraAssetPath.resolve(title: widget.title, filePath: p);
    }
    if (File(p).existsSync()) return p;
    final resolved = SutraAssetPath.resolve(title: widget.title, filePath: p);
    return resolved.startsWith('assets/') ? resolved : p;
  }

  void _saveCurrentSutra() {
    final savePath = _resolvedFilePath ?? widget.filePath;
    if (savePath == null) return;
    SharedPreferences.getInstance().then((prefs) async {
      await prefs.setString('current_sutra_title', widget.title);
      await prefs.setString('current_sutra_file_path', savePath);
      final recent = prefs.getStringList('recent_sutras') ?? [];
      recent.removeWhere((e) => e.startsWith('${widget.title}|||'));
      recent.insert(0, '${widget.title}|||$savePath');
      if (recent.length > 20) recent.removeRange(20, recent.length);
      await prefs.setStringList('recent_sutras', recent);

      final now = DateTime.now();
      final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final raw = prefs.getString('daily_sutra_history') ?? '{}';
      final Map<String, dynamic> history = jsonDecode(raw);
      final List<dynamic> dayList = (history[today] as List<dynamic>?) ?? [];
      dayList.removeWhere((e) => e['filePath'] == savePath);
      final progress = prefs.getDouble('progress_$savePath') ?? 0.0;
      dayList.insert(0, {'title': widget.title, 'filePath': savePath, 'progress': progress});
      history[today] = dayList;
      await prefs.setString('daily_sutra_history', jsonEncode(history));
    });
  }

  Future<void> _loadSavedScrollState() async {
    final prefs = await SharedPreferences.getInstance();
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath == null) return;
    // 兼容旧版本用本机绝对路径命名的 scroll_ 键（换机/重装后
    // 云端同步回来的可能是这类键）：取首个候选键的滚动位置。
    final variants =
        await SutraDownloader.pathKeyVariants(keyPath, title: widget.title);
    double? savedPos;
    for (final v in variants) {
      savedPos ??= prefs.getDouble('scroll_$v');
    }
    // 进度以规范路径键的最新值（阅读页实时写入，离开时即保存）为准，
    // 规范键缺失时兼容旧键名并回退每日阅读历史，避免换机/重装后进度清零。
    final savedProg = await SutraDownloader.latestProgressForPath(
        prefs, keyPath,
        title: widget.title);
    _savedPosition = savedPos;
    _savedProgress = savedProg > 0 ? savedProg : null;

    if (mounted && _savedProgress != null) {
      setState(() {
        _scrollProgress = _savedProgress!;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null && !_subscribed) {
      _subscribed = true;
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didPush() => ReadingTimeService.instance.start();

  @override
  void didPopNext() => ReadingTimeService.instance.start();

  @override
  void didPushNext() => ReadingTimeService.instance.stop();

  @override
  void didPop() => ReadingTimeService.instance.stop();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ReadingTimeService.instance.start();
    } else {
      ReadingTimeService.instance.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_subscribed) routeObserver.unsubscribe(this);
    ReadingTimeService.instance.stop();
    _scrollController.dispose();
    _pageController?.dispose();
    _searchController.dispose();
    // 离开阅读页时收起 AI 面板（WebView 本身常驻，不销毁）。
    assistantVisible.value = false;
    super.dispose();
  }

  void _scheduleRestoreScroll() {
    if (!mounted) return;
    if (!_scrollController.hasClients) return;

    // Wait until content is laid out. Large texts can take a few frames.
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) {
      if (_restoreAttempts < 20) {
        _restoreAttempts++;
        WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRestoreScroll());
      }
      return;
    }

    final savedProgress = _savedProgress;
    final savedPosition = _savedPosition;
    double? target;
    if (savedProgress != null && savedProgress > 0) {
      target = (savedProgress * maxScroll).clamp(0, maxScroll);
    } else if (savedPosition != null && savedPosition > 0) {
      target = savedPosition.clamp(0, maxScroll);
    }

    if (target != null) {
      _scrollController.jumpTo(target);
      // Sync displayed progress to real position.
      setState(() {
        _scrollProgress = maxScroll <= 0 ? 0.0 : (_scrollController.offset / maxScroll).clamp(0.0, 1.0);
      });
    }
  }

  void _scrollListener() {
    if (_scrollController.hasClients) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      if (maxScroll > 0) {
        final newProgress = _scrollController.offset / maxScroll;
        setState(() {
          _scrollProgress = newProgress;
        });
        _saveScrollPosition();
      }
      if (_scrollController.offset >= maxScroll) {
        _markAsRead();
      }
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      // 兼容历史数据里存成 int 的取值（如 fontSize），统一转 double。
      _fontSize = (prefs.get('fontSize') as num?)?.toDouble() ?? 16.0;
      _isDarkMode = prefs.getBool('isDarkMode') ?? false;
      _lineHeight = (prefs.get('reader_line_height') as num?)?.toDouble() ?? 1.8;
      _pageMode = prefs.getInt('reader_page_mode') ?? ReaderPreferences.pageModeScroll;
    });
    // 同步全局夜间模式信号，消息中心等页面跟随切换浅色/深色配色。
    appDarkMode.value = _isDarkMode;
  }

  Future<void> _saveScrollPosition() async {
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath != null && _scrollController.hasClients) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('scroll_$keyPath', _scrollController.offset);
      await prefs.setDouble('progress_$keyPath', _scrollProgress);
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('fontSize', _fontSize);
    await prefs.setBool('isDarkMode', _isDarkMode);
    await prefs.setDouble('reader_line_height', _lineHeight);
    await prefs.setInt('reader_page_mode', _pageMode);
  }

  Future<void> _loadContent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_read_title', widget.title);
    if (_resolvedFilePath != null) {
      await prefs.setString('last_read_filePath', _resolvedFilePath!);
    } else if (widget.filePath != null) {
      await prefs.setString('last_read_filePath', widget.filePath!);
    }
    final filePath = _resolvedFilePath ?? widget.filePath;
    if (filePath != null) {
      // 1. 优先加载已编辑的副本（如果存在）
      final editedPath = await editedSutraFilePath(filePath);
      final editedFile = File(editedPath);
      final hasEdited = await editedFile.exists();
      if (hasEdited) {
        try {
          final content = await editedFile.readAsString();
          if (mounted) {
            setState(() {
              _content = content;
              _isEdited = true;
              _isLoadingContent = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRestoreScroll());
          }
          return;
        } catch (_) {
          // 读取失败则回退到原始文件
        }
      }
      _isEdited = false;

      // 2. 其次加载已下载到本地的副本
      File? localCopy;
      if (filePath.startsWith('assets/sutras_ascii/')) {
        localCopy = await SutraDownloader.localFileForAssetPath(filePath);
      }
      // 兜底：任何形式的路径（如换机/重新登录后从云端同步回来的旧设备
      // 绝对路径）只要能从标题/路径中识别出经书 ID，就去本地下载目录找副本，
      // 避免已下载的经书被误判为「未下载」而反复提示重新下载。
      if (localCopy == null) {
        final id = SutraDownloader.extractId(widget.title, filePath);
        if (id != null &&
            id.isNotEmpty &&
            await SutraDownloader.isDownloaded(id)) {
          localCopy = await SutraDownloader.localFile(id);
        }
      }
      if (localCopy != null) {
        try {
          final content = await localCopy.readAsString();
          if (mounted) {
            setState(() {
              _content = content;
              _isLoadingContent = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRestoreScroll());
          }
          return;
        } catch (_) {
          // 读取失败则回退到打包资源
        }
      }

      // 3. 再回退到打包资源
      if (filePath.startsWith('assets/')) {
        try {
          String content = await rootBundle.loadString(filePath);
          if (mounted) {
            setState(() {
              _content = content;
              _isLoadingContent = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRestoreScroll());
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _content = '该经文正文尚未下载，请点击上方“下载”按钮获取后再阅读。';
              _isLoadingContent = false;
              _needsDownload = true;
            });
          }

        }
      } else {
        try {
          File file = File(filePath);
          if (await file.exists()) {
            String content = await file.readAsString();
            if (mounted) {
              setState(() {
                _content = content;
                _isLoadingContent = false;
              });
              WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRestoreScroll());
            }
          } else if (mounted) {
            setState(() {
              _content = '该经文正文尚未下载。';
              _isLoadingContent = false;
              _needsDownload = true;
            });
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _content = '无法加载文件内容';
              _isLoadingContent = false;
            });
          }
        }
      }
    } else {
      if (mounted) {
        setState(() {
          _content = '这是《${widget.title}》的预览内容。\n\n暂无实际文件，请添加本地文件。';
          _isLoadingContent = false;
        });
      }
    }
  }

  Future<void> _downloadContent() async {
    if (_isDownloading) return;
    final id = SutraDownloader.extractId(widget.title, _resolvedFilePath ?? widget.filePath);
    if (id == null) return;
    // 本地已有完整文件时直接重新加载内容，不重新下载。
    // 防止上游误判 _needsDownload=true（如路径恢复竞态）导致已下载经文被重下。
    if (await SutraDownloader.isDownloaded(id)) {
      if (!mounted) return;
      setState(() {
        _needsDownload = false;
      });
      await _loadContent();
      return;
    }
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
    });
    try {
      await SutraDownloader.download(id, onProgress: (received, total) {
        if (!mounted) return;
        setState(() {
          _downloadProgress = total > 0 ? received / total : 0;
        });
      });
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _needsDownload = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载完成')),
      );
      await _loadContent();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$e')),
      );
    }
  }

  Widget _buildDownloadBanner() {
    if (!_needsDownload) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _isDarkMode ? const Color(0xFF2c2c2c) : AppPalette.p.tintBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: _isDownloading
                ? Text(
                    '下载中… ${(_downloadProgress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      color: _isDarkMode ? Colors.white : AppPalette.p.primary,
                      fontSize: 13,
                    ),
                  )
                : Text(
                    '该经文正文未打包，需要联网下载。',
                    style: TextStyle(
                      color: _isDarkMode ? Colors.white : AppPalette.p.primary,
                      fontSize: 13,
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          if (_isDownloading)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: _downloadProgress > 0 ? _downloadProgress : null,
                color: AppPalette.p.accent,
              ),
            )
          else
            SizedBox(
              height: 30,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppPalette.p.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  textStyle: const TextStyle(fontSize: 13),
                ),
                onPressed: _downloadContent,
                child: const Text('下载'),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openEditor() async {
    final filePath = _resolvedFilePath ?? widget.filePath;
    if (filePath == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SutraEditPage(
          title: widget.title,
          content: _content,
          keyPath: filePath,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _loadContent();
    }
  }

  void _scrollToStart() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 打开笔记编辑页：预填「$经书名」在顶部，可写笔记并发布到菩提空间。
  void _openNoteEditor() {
    final readable = widget.title
        .replaceAll(RegExp(r'T\d+n[0-9A-Za-z]+_\d+$'), '')
        .trim();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditPage(presetContent: '\$$readable '),
      ),
    );
  }

  Future<void> _exportTxt() async {
    final trimmed = _content.trim();
    if (trimmed.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可导出的内容'), duration: Duration(seconds: 2)),
        );
      }
      return;
    }

    final safeTitle = widget.title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '');
    final filename = '$safeTitle.txt';

    // UTF-8 BOM 防乱码
    final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(trimmed)];

    // 优先：用原生保存对话框选择位置，由插件直接写入
    try {
      final savedPath = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          data: Uint8List.fromList(bytes),
          fileName: filename,
          mimeTypesFilter: const ['text/plain'],
        ),
      );
      if (savedPath != null && savedPath.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已保存：$savedPath'), duration: const Duration(seconds: 3)),
          );
        }
        return;
      }
    } catch (_) {
      // ignore and fallback
    }

    // 兜底1：file_picker 保存对话框
    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '导出TXT',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['txt'],
      );
      if (savePath != null && savePath.isNotEmpty && !savePath.startsWith('content:')) {
        final file = File(savePath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已保存：$savePath'), duration: const Duration(seconds: 3)),
          );
        }
        return;
      }
    } catch (_) {
      // ignore
    }

    // 兜底2：保存到应用文档目录
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$filename');
      await file.writeAsBytes(bytes, flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存到应用目录：${file.path}'), duration: const Duration(seconds: 4)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e'), duration: const Duration(seconds: 4)),
        );
      }
    }
  }

  Future<void> _markAsRead() async {
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('read_$keyPath', true);
  }

  void _showFontSizeDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择字号'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [12, 14, 16, 18, 20, 22, 24, 28, 32].map((size) {
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              minVerticalPadding: 0,
              dense: true,
              title: Text('$size', style: TextStyle(fontSize: size.toDouble())),
              onTap: () {
                setState(() {
                  _fontSize = size.toDouble();
                });
                _saveSettings();
                Navigator.pop(context);
              },
              trailing: _fontSize == size ? Icon(Icons.check, color: AppPalette.p.primary) : null,
            );
          }).toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // AI 面板展开时，系统返回先收起它（回到阅读页）；否则正常退出阅读页。
        if (assistantVisible.value) {
          assistantVisible.value = false;
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
            backgroundColor: _isDarkMode ? const Color(0xFF121212) : AppPalette.p.tintBg,
            appBar: AppBar(
              backgroundColor: _isDarkMode ? const Color(0xFF121212) : AppPalette.p.tintBg,
              elevation: 0,
              leadingWidth: 48,
              titleSpacing: 0,
              iconTheme: IconThemeData(color: _isDarkMode ? Colors.white.withOpacity(0.7) : const Color(0xFF212121)),
              title: GestureDetector(
                onTap: () {
                  final now = DateTime.now();
                  final last = _lastTitleTap;
                  _lastTitleTap = now;
                  if (last != null &&
                      now.difference(last) < const Duration(milliseconds: 350)) {
                    _scrollToStart();
                  }
                },
                onLongPress: () {
                  Clipboard.setData(ClipboardData(text: widget.title));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制到剪贴板'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.title,
                        style: TextStyle(
                          color: _isDarkMode ? Colors.white.withOpacity(0.7) : const Color(0xFF212121),
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_isEdited)
                      Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Text(
                          '已编辑',
                          style: TextStyle(color: AppPalette.p.accent, fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    icon: const Icon(Icons.search, size: 18),
                    onPressed: _toggleSearch,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    splashRadius: 16,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      icon: const Icon(Icons.more_horiz, size: 20),
                      onPressed: _toggleMoreMenu,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      splashRadius: 16,
                    ),
                  ),
                ),
              ],
            ),
            body: SafeArea(
              child: Listener(
                onPointerDown: (event) {
                  if (_showMoreMenu && !_isPointerInsideMenu(event.position)) {
                    setState(() {
                      _showMoreMenu = false;
                    });
                  }
                },
                child: Stack(
                children: [
                  Column(
                    children: [
                      if (_showSearchBar)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          color: Colors.transparent,
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _searchController,
                                  decoration: InputDecoration(
                                    hintText: '搜索内容',
                                    hintStyle: TextStyle(
                                      color: _isDarkMode ? Colors.white.withOpacity(0.38) : const Color(0xFF999999),
                                      fontSize: 14,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide.none,
                                    ),
                                    filled: true,
                                    fillColor: _isDarkMode ? const Color(0xFF2c2c2c) : const Color(0xFFf5f5f5),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    isDense: true,
                                  ),
                                  style: TextStyle(
                                    color: _isDarkMode ? Colors.white : const Color(0xFF212121),
                                    fontSize: 14,
                                  ),
                                  onChanged: _performSearch,
                                ),
                              ),
                              if (_searchMatches.isNotEmpty)
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      child: Text(
                                        '${_currentMatchIndex + 1}/${_searchMatches.length}',
                                        style: TextStyle(
                                          color: _isDarkMode ? Colors.white.withOpacity(0.7) : const Color(0xFF212121),
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                                      onPressed: _goToPreviousMatch,
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                                      onPressed: _goToNextMatch,
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      _buildDownloadBanner(),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _showMoreMenu = false;
                                if (_showSearchBar) {
                                  _showSearchBar = false;
                                  _searchController.clear();
                                  _searchMatches.clear();
                                  _currentMatchIndex = 0;
                                }
                              });
                            },
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                if (_isLoadingContent) {
                                  return const Center(child: CircularProgressIndicator());
                                }
                                if (_pageMode == ReaderPreferences.pageModeFlip &&
                                    _searchController.text.isEmpty) {
                                  final pages = _getFlipPages(
                                      constraints.maxWidth, constraints.maxHeight);
                                  return PageView.builder(
                                    controller: _pageController,
                                    itemCount: pages.length,
                                    onPageChanged: _onFlipPageChanged,
                                    itemBuilder: (context, index) =>
                                        _buildFlipPage(pages[index]),
                                  );
                                }
                                return SingleChildScrollView(
                                  controller: _scrollController,
                                  child: _searchController.text.isEmpty
                                      ? SelectableText(
                                          _content,
                                          style: TextStyle(
                                            color: _isDarkMode ? Colors.white : const Color(0xFF212121),
                                            fontSize: _fontSize,
                                            height: _lineHeight,
                                            letterSpacing: 0.5,
                                          ),
                                        )
                                      : SelectableText.rich(
                                          TextSpan(
                                            style: TextStyle(
                                              color: _isDarkMode ? Colors.white : const Color(0xFF212121),
                                              fontSize: _fontSize,
                                              height: _lineHeight,
                                              letterSpacing: 0.5,
                                            ),
                                            children: _highlightText(_content),
                                          ),
                                      contextMenuBuilder: (context, editableTextState) {
                                        return AdaptiveTextSelectionToolbar(
                                          anchors: editableTextState.contextMenuAnchors,
                                          children: [
                                            TextSelectionToolbarTextButton(
                                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                              onPressed: () {
                                                final selection = editableTextState.textEditingValue.selection;
                                                final selectedText = _content.substring(selection.start, selection.end);
                                                Clipboard.setData(ClipboardData(text: selectedText));
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  const SnackBar(content: Text('已复制到剪贴板')),
                                                );
                                                editableTextState.hideToolbar();
                                              },
                                              child: const Text('复制'),
                                            ),
                                          ],
                                        );
                                      },
                                     ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                    AppPalette.instance.isPlain && !_isDarkMode ? 2 : 3),
                                child: LinearProgressIndicator(
                                  value: _scrollProgress,
                                  minHeight: 5,
                                  backgroundColor: _isDarkMode
                                      ? Colors.white.withOpacity(0.15)
                                      : AppPalette.instance.isPlain
                                          ? AppPalette.p.border
                                          : const Color(0xFFE8D9C4),
                                  valueColor:
                                      AlwaysStoppedAnimation<Color>(!_isDarkMode &&
                                              AppPalette.instance.isPlain
                                          ? const Color(0xFF4A4A4A)
                                          : AppPalette.p.accent),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${(_scrollProgress * 100).toStringAsFixed(1)}%',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _isDarkMode
                                    ? Colors.white.withOpacity(0.7)
                                    : AppPalette.p.textSec,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                if (_showMoreMenu)
                  Positioned(
                    top: 4,
                    right: 16,
                    child: Material(
                      key: _moreMenuKey,
                      elevation: 6,
                      borderRadius: BorderRadius.circular(12),
                      color: _isDarkMode ? const Color(0xFF2c2c2c) : Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildMoreMenuItem(
                              icon: Icon(
                                _isDarkMode ? Icons.light_mode : Icons.dark_mode,
                                size: 18,
                              ),
                              label: _isDarkMode ? '日间模式' : '夜间模式',
                              onTap: _toggleTheme,
                            ),
                            _buildMoreMenuItem(
                              icon: const Icon(Icons.text_fields, size: 18),
                              label: '字体',
                              onTap: _showFontSizeDialog,
                            ),
                            _buildMoreMenuItem(
                              icon: const Icon(Icons.save_alt, size: 18),
                              label: '导出TXT',
                              onTap: _exportTxt,
                            ),
                            _buildMoreMenuItem(
                              icon: const Icon(Icons.edit, size: 18),
                              label: '编辑',
                              onTap: _openEditor,
                            ),
                            _buildMoreMenuItem(
                              icon: Icon(
                                _isFavorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                size: 18,
                              ),
                              label: _isFavorite ? '取消收藏' : '收藏',
                              onTap: _toggleFavorite,
                            ),
                            _buildMoreMenuItem(
                              icon: const Icon(Icons.help_outline, size: 18),
                              label: '使用说明',
                              onTap: _openUsageGuide,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  right: 16,
                  bottom: 111,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: _buildFloatingIcon(
                      tooltip: 'AI 助手',
                      heroTag: 'sutra_ai_assistant',
                      onTap: _openAssistant,
                      child: const Text(
                        'AI',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: 57,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: _buildFloatingIcon(
                      tooltip: '写笔记',
                      heroTag: 'sutra_note',
                      onTap: _openNoteEditor,
                      child: const Icon(Icons.edit_note, size: 18),
                    ),
                  ),
                ),
                ],
              ),
            ),
          ),
      ),
    );
  }

  /// 判断点击位置是否落在「⋯」展开菜单内。
  bool _isPointerInsideMenu(Offset position) {
    final ctx = _moreMenuKey.currentContext;
    if (ctx == null) return false;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return false;
    final local = box.globalToLocal(position);
    return local.dx >= 0 &&
        local.dy >= 0 &&
        local.dx <= box.size.width &&
        local.dy <= box.size.height;
  }

  void _toggleSearch() {
    setState(() {
      _showSearchBar = !_showSearchBar;
      if (!_showSearchBar) {
        _searchController.clear();
        _searchMatches.clear();
        _currentMatchIndex = 0;
      }
    });
  }

  void _toggleTheme() {
    setState(() {
      _isDarkMode = !_isDarkMode;
    });
    appDarkMode.value = _isDarkMode;
    _saveSettings();
  }

  void _toggleMoreMenu() {
    setState(() {
      _showMoreMenu = !_showMoreMenu;
    });
  }

  /// 打开「使用说明」页面。
  void _openUsageGuide() {
    setState(() {
      _showMoreMenu = false;
    });
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ReadingGuidePage()),
    );
  }

  /// 加载当前经书收藏状态（菜单图标/文字随状态切换）。
  Future<void> _loadFavoriteState() async {
    final fav = await SutraFavorites.isFavorite(
        widget.title, _resolvedFilePath ?? widget.filePath);
    if (mounted) {
      setState(() {
        _isFavorite = fav;
      });
    }
  }

  /// 收藏 / 取消收藏当前经书，并同步到「我的收藏」。
  Future<void> _toggleFavorite() async {
    final nowFav = await SutraFavorites.toggle(
        widget.title, _resolvedFilePath ?? widget.filePath);
    if (!mounted) return;
    setState(() {
      _showMoreMenu = false;
      _isFavorite = nowFav;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nowFav ? '已收藏，可在「我的收藏」中查看' : '已取消收藏'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 右下角浮动图标：与助手页底部圆圈按钮同款（浅色圆底 + 阴影）。
  Widget _buildFloatingIcon({
    required Widget child,
    required String tooltip,
    required String heroTag,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: FloatingActionButton(
        heroTag: heroTag,
        onPressed: onTap,
        backgroundColor: _isDarkMode ? Colors.white : const Color(0xFFf7f7f7),
        elevation: 8,
        highlightElevation: 12,
        shape: const CircleBorder(),
        child: IconTheme(
          data: IconThemeData(
            color: AppPalette.p.primary,
          ),
          child: child,
        ),
      ),
    );
  }

  void _openAssistant() {
    // 唤出全局常驻的 AI 面板（WebView 不销毁，会话跨页面延续）；再次点击收起。
    assistantVisible.value = !assistantVisible.value;
  }

  /// 更多菜单里的带文字条目。
  Widget _buildMoreMenuItem({
    required Widget icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final fg = _isDarkMode ? Colors.white : AppPalette.p.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconTheme(data: IconThemeData(color: fg), child: icon),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: fg, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  void _performSearch(String query) {
    if (query.isEmpty) {
      setState(() {
        _searchMatches.clear();
        _currentMatchIndex = 0;
      });
      return;
    }

    final matches = <int>[];
    final content = _content.toLowerCase();
    final lowerQuery = query.toLowerCase();

    int index = content.indexOf(lowerQuery);
    while (index != -1) {
      matches.add(index);
      index = content.indexOf(lowerQuery, index + 1);
    }

    setState(() {
      _searchMatches = matches;
      _currentMatchIndex = matches.isNotEmpty ? 0 : -1;
    });

    if (matches.isNotEmpty) {
      _scrollToMatch(0);
    }
  }

  void _scrollToMatch(int index) {
    if (index >= 0 && index < _searchMatches.length && _scrollController.hasClients) {
      final position = _searchMatches[index];
      _scrollController.animateTo(
        position.toDouble(),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToPreviousMatch() {
    if (_searchMatches.isNotEmpty) {
      final newIndex = _currentMatchIndex > 0 ? _currentMatchIndex - 1 : _searchMatches.length - 1;
      setState(() {
        _currentMatchIndex = newIndex;
      });
      _scrollToMatch(newIndex);
    }
  }

  void _goToNextMatch() {
    if (_searchMatches.isNotEmpty) {
      final newIndex = (_currentMatchIndex + 1) % _searchMatches.length;
      setState(() {
        _currentMatchIndex = newIndex;
      });
      _scrollToMatch(newIndex);
    }
  }

  List<TextSpan> _highlightText(String text) {
    if (_searchController.text.isEmpty) {
      return [TextSpan(text: text)];
    }

    final query = _searchController.text.toLowerCase();
    final spans = <TextSpan>[];
    final lowerText = text.toLowerCase();

    int start = 0;
    int index = lowerText.indexOf(query);
    while (index != -1) {
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }

      spans.add(TextSpan(
        text: text.substring(index, index + query.length),
        style: TextStyle(
          backgroundColor: _isDarkMode ? Colors.yellow.withOpacity(0.3) : Colors.yellow,
        ),
      ));

      start = index + query.length;
      index = lowerText.indexOf(query, start);
    }

    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start)));
    }

    return spans;
  }

  TextStyle get _flipTextStyle => TextStyle(
        color: _isDarkMode ? Colors.white : const Color(0xFF212121),
        fontSize: _fontSize,
        height: _lineHeight,
        letterSpacing: 0.5,
      );

  /// 把全文按视口高度切成若干页（按行分页，保证分页间不丢字）。
  List<String> _paginateContent(String text, double width, double height) {
    if (text.isEmpty) return [text];
    final tp = TextPainter(
      text: TextSpan(text: text, style: _flipTextStyle),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    final lines = tp.computeLineMetrics();
    if (lines.isEmpty) return [text];

    final totalHeight = lines.fold<double>(0.0, (s, l) => s + l.height);
    if (totalHeight <= height) return [text];

    final pages = <String>[];
    var startLine = 0;
    while (startLine < lines.length) {
      var endLine = startLine;
      var acc = 0.0;
      while (endLine < lines.length) {
        final h = lines[endLine].height;
        if (acc + h > height) break;
        acc += h;
        endLine++;
      }
      if (endLine == startLine) endLine = startLine + 1;

      var top = 0.0;
      for (var i = 0; i < startLine; i++) {
        top += lines[i].height;
      }
      final bottom = top + acc;

      final startPos = tp.getPositionForOffset(Offset(0, top + 1));
      final endPos = tp.getPositionForOffset(Offset(width - 1, bottom - 1));
      pages.add(text.substring(startPos.offset, endPos.offset));
      startLine = endLine;
    }
    return pages.isEmpty ? [text] : pages;
  }

  /// 获取（并缓存）翻页模式的页面列表，首次时恢复上次阅读进度。
  List<String> _getFlipPages(double width, double height) {
    final key =
        '$_fontSize|$_lineHeight|${width.toStringAsFixed(1)}|${height.toStringAsFixed(1)}';
    if (key == _flipCacheKey && _flipPages.isNotEmpty) return _flipPages;
    _flipCacheKey = key;
    _flipPages = _paginateContent(_content, width, height);

    if (!_flipPageRestored &&
        _savedProgress != null &&
        _flipPages.length > 1) {
      _flipPageRestored = true;
      final target = (_savedProgress! * _flipPages.length)
          .floor()
          .clamp(0, _flipPages.length - 1);
      _currentFlipPage = target;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (_pageController?.hasClients ?? false)) {
          _pageController?.jumpToPage(target);
        }
      });
      _scrollProgress = (target + 1) / _flipPages.length;
    } else if (_currentFlipPage >= _flipPages.length) {
      _currentFlipPage = _flipPages.length - 1;
    }
    return _flipPages;
  }

  void _onFlipPageChanged(int index) {
    setState(() {
      _currentFlipPage = index;
      _scrollProgress = _flipPages.length > 1 ? (index + 1) / _flipPages.length : 1.0;
    });
    _saveFlipProgress();
    if (index == _flipPages.length - 1) {
      _markAsRead();
    }
  }

  Future<void> _saveFlipProgress() async {
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('progress_$keyPath', _scrollProgress);
  }

  Widget _buildFlipPage(String text) {
    return SingleChildScrollView(
      child: SelectableText(
        text,
        style: _flipTextStyle,
      ),
    );
  }
}