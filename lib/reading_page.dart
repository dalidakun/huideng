import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sutra_asset_path.dart';

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

class _ReadingPageState extends State<ReadingPage> {
  String _content = '';
  double _fontSize = 16.0;
  bool _isDarkMode = false;
  late ScrollController _scrollController;
  final TextEditingController _searchController = TextEditingController();
  bool _showSearchBar = false;
  List<int> _searchMatches = [];
  int _currentMatchIndex = 0;
  double _scrollProgress = 0.0;
  late final String? _resolvedFilePath;
  Future<AssetManifest>? _manifestFuture;
  bool _isLoadingContent = true;
  double? _savedPosition;
  double? _savedProgress;
  int _restoreAttempts = 0;

  Future<bool> _assetListedInManifest(String key) async {
    try {
      _manifestFuture ??= AssetManifest.loadFromAssetBundle(rootBundle);
      final manifest = await _manifestFuture!;
      final assets = await manifest.listAssets();
      return assets.contains(key);
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _resolvedFilePath = widget.filePath == null
        ? null
        : (widget.filePath!.startsWith('assets/')
            ? SutraAssetPath.resolve(title: widget.title, filePath: widget.filePath)
            : widget.filePath);
    _scrollController = ScrollController();
    _scrollController.addListener(_scrollListener);
    _saveCurrentSutra();
    _loadSettings();
    _loadSavedScrollState();
    _loadContent();
  }

  void _saveCurrentSutra() {
    if (widget.filePath == null) return;
    SharedPreferences.getInstance().then((prefs) async {
      await prefs.setString('current_sutra_title', widget.title);
      await prefs.setString('current_sutra_file_path', widget.filePath!);
      final recent = prefs.getStringList('recent_sutras') ?? [];
      recent.removeWhere((e) => e.startsWith('${widget.title}|||'));
      recent.insert(0, '${widget.title}|||${widget.filePath}');
      if (recent.length > 20) recent.removeRange(20, recent.length);
      await prefs.setStringList('recent_sutras', recent);

      final now = DateTime.now();
      final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final raw = prefs.getString('daily_sutra_history') ?? '{}';
      final Map<String, dynamic> history = jsonDecode(raw);
      final List<dynamic> dayList = (history[today] as List<dynamic>?) ?? [];
      dayList.removeWhere((e) => e['filePath'] == widget.filePath);
      final progress = prefs.getDouble('progress_${widget.filePath}') ?? 0.0;
      dayList.insert(0, {'title': widget.title, 'filePath': widget.filePath, 'progress': progress});
      history[today] = dayList;
      await prefs.setString('daily_sutra_history', jsonEncode(history));
    });
  }

  Future<void> _loadSavedScrollState() async {
    final prefs = await SharedPreferences.getInstance();
    final keyPath = _resolvedFilePath ?? widget.filePath;
    if (keyPath == null) return;
    _savedPosition = prefs.getDouble('scroll_$keyPath');
    _savedProgress = prefs.getDouble('progress_$keyPath');

    if (mounted && _savedProgress != null) {
      setState(() {
        _scrollProgress = _savedProgress!;
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
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
      _fontSize = prefs.getDouble('fontSize') ?? 16.0;
      _isDarkMode = prefs.getBool('isDarkMode') ?? false;
    });
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
          final inManifest = await _assetListedInManifest(filePath);
          if (mounted) {
            setState(() {
              _content = '无法加载assets文件内容\n\n路径: $filePath\nAssetManifest包含该路径: $inManifest\n错误: $e';
              _isLoadingContent = false;
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
              trailing: _fontSize == size ? const Icon(Icons.check, color: Color(0xFF5d4037)) : null,
            );
          }).toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
            backgroundColor: _isDarkMode ? const Color(0xFF121212) : const Color(0xFFededed),
            appBar: AppBar(
              backgroundColor: _isDarkMode ? const Color(0xFF121212) : const Color(0xFFededed),
              elevation: 0,
              iconTheme: IconThemeData(color: _isDarkMode ? Colors.white.withOpacity(0.7) : const Color(0xFF212121)),
              title: GestureDetector(
                onLongPress: () {
                  Clipboard.setData(ClipboardData(text: widget.title));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制到剪贴板'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                child: Text(
                  widget.title,
                  style: TextStyle(
                    color: _isDarkMode ? Colors.white.withOpacity(0.7) : const Color(0xFF212121),
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
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
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    icon: Icon(_isDarkMode ? Icons.light_mode : Icons.dark_mode, size: 18),
                    onPressed: _toggleTheme,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    splashRadius: 16,
                  ),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    icon: const Icon(Icons.text_fields, size: 18),
                    onPressed: _showFontSizeDialog,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    splashRadius: 16,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Text(
                    '${(_scrollProgress * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      color: _isDarkMode ? Colors.white.withOpacity(0.7) : const Color(0xFF212121),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            body: SafeArea(
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
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: GestureDetector(
                            onTap: () {
                              if (_showSearchBar) {
                                setState(() {
                                  _showSearchBar = false;
                                });
                                _searchController.clear();
                                _searchMatches.clear();
                                _currentMatchIndex = 0;
                              }
                            },
                            child: SingleChildScrollView(
                              controller: _scrollController,
                              child: _isLoadingContent
                                  ? const Center(
                                      child: CircularProgressIndicator(),
                                    )
                                  : (_searchController.text.isEmpty
                                      ? SelectableText(
                                          _content,
                                          style: TextStyle(
                                            color: _isDarkMode ? Colors.white : const Color(0xFF212121),
                                            fontSize: _fontSize,
                                            height: 1.8,
                                            letterSpacing: 0.5,
                                          ),
                                        )
                                      : SelectableText.rich(
                                          TextSpan(
                                            style: TextStyle(
                                              color: _isDarkMode ? Colors.white : const Color(0xFF212121),
                                              fontSize: _fontSize,
                                              height: 1.8,
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
                                    )),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

                ],
              ),
            ),
          );
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
    _saveSettings();
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
}