import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  bool _fromAssistant = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadContent();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeScrollController();
    });
  }

  void _initializeScrollController() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPosition = prefs.getDouble('scroll_${widget.filePath}');
    final savedProgress = prefs.getDouble('progress_${widget.filePath}');

    // 直接使用widget.fromAssistant
    _fromAssistant = widget.fromAssistant;

    // 初始化ScrollController
    _scrollController = ScrollController();
    _scrollController.addListener(_scrollListener);

    // 设置进度显示
    if (savedProgress != null) {
      setState(() {
        _scrollProgress = savedProgress;
      });
    }

    // 确保在下一帧跳转到正确位置
    if (savedPosition != null && savedPosition > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 10), () {
          if (mounted && _scrollController.hasClients) {
            _scrollController.jumpTo(savedPosition);
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
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
    if (widget.filePath != null && _scrollController.hasClients) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('scroll_${widget.filePath}', _scrollController.offset);
      await prefs.setDouble('progress_${widget.filePath}', _scrollProgress);
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('fontSize', _fontSize);
    await prefs.setBool('isDarkMode', _isDarkMode);
  }

  Future<void> _loadContent() async {
    // 保存最近阅读的书籍信息
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_read_title', widget.title);
    if (widget.filePath != null) {
      await prefs.setString('last_read_filePath', widget.filePath!);
    }

    if (widget.filePath != null) {
      try {
        File file = File(widget.filePath!);
        if (await file.exists()) {
          String content = await file.readAsString();
          if (mounted) {
            setState(() {
              _content = content;
            });
          }
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _content = '无法加载文件内容';
          });
        }
      }
    } else {
      if (mounted) {
        setState(() {
          _content = '这是�?{widget.title}》的预览内容。\n\n暂无实际文件，请添加本地文件�?;
        });
      }
    }
  }

  Future<void> _markAsRead() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('read_${widget.filePath}', true);
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

  void _toggleTheme() {
    setState(() {
      _isDarkMode = !_isDarkMode;
    });
    _saveSettings();
  }

  void _toggleSearch() {
    setState(() {
      _showSearchBar = !_showSearchBar;
    });
    if (!_showSearchBar) {
      _searchController.clear();
      _searchMatches.clear();
      _currentMatchIndex = 0;
    }
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
    final lowerContent = _content.toLowerCase();
    final lowerQuery = query.toLowerCase();
    int index = 0;

    while (index < _content.length) {
      final foundIndex = lowerContent.indexOf(lowerQuery, index);
      if (foundIndex == -1) break;
      matches.add(foundIndex);
      index = foundIndex + lowerQuery.length;
    }

    setState(() {
      _searchMatches = matches;
      _currentMatchIndex = 0;
    });

    if (matches.isNotEmpty) {
      _scrollToMatch(0);
    }
  }

  void _scrollToMatch(int index) {
    if (index < 0 || index >= _searchMatches.length) return;

    final position = _searchMatches[index];

    // 估算匹配位置的垂直偏�?    final textBeforeMatch = _content.substring(0, position);
    final lines = textBeforeMatch.split('\n');
    final lineHeight = _fontSize * 1.8;
    final lineWidth = MediaQuery.of(context).size.width - 32;
    final avgCharsPerLine = lineWidth / _fontSize;

    double scrollPosition = 0.0;

    for (int i = 0; i < lines.length; i++) {
      final lineLength = lines[i].length;
      final estimatedLines = (lineLength / avgCharsPerLine).ceil();
      scrollPosition += estimatedLines * lineHeight + 4;
    }

    // 向上偏移一些，让匹配内容不会贴�?    scrollPosition = scrollPosition - 80;

    // 确保位置在有效范围内
    if (scrollPosition < 0) scrollPosition = 0;
    if (_scrollController.hasClients && scrollPosition > _scrollController.position.maxScrollExtent) {
      scrollPosition = _scrollController.position.maxScrollExtent;
    }

    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        scrollPosition,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToPreviousMatch() {
    if (_currentMatchIndex > 0) {
      setState(() {
        _currentMatchIndex--;
      });
      _scrollToMatch(_currentMatchIndex);
    }
  }

  void _goToNextMatch() {
    if (_currentMatchIndex < _searchMatches.length - 1) {
      setState(() {
        _currentMatchIndex++;
      });
      _scrollToMatch(_currentMatchIndex);
    }
  }

  List<TextSpan> _highlightText(String text) {
    if (_searchMatches.isEmpty) {
      return [TextSpan(text: text)];
    }

    final spans = <TextSpan>[];
    int lastIndex = 0;
    String currentQuery = _searchController.text;
    if (currentQuery.isEmpty) {
      return [TextSpan(text: text)];
    }

    for (final match in _searchMatches) {
      if (match > lastIndex) {
        spans.add(TextSpan(text: text.substring(lastIndex, match)));
      }

      if (match >= 0 && match + currentQuery.length <= text.length) {
        spans.add(TextSpan(
          text: text.substring(match, match + currentQuery.length),
          style: const TextStyle(
            backgroundColor: Color(0xFFFFEB3B),
            color: Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ));
        lastIndex = match + currentQuery.length;
      }
    }

    if (lastIndex < text.length) {
      spans.add(TextSpan(text: text.substring(lastIndex)));
    }

    return spans;
  }

  @override
  Widget build(BuildContext context) {
    return widget.fromAssistant
        ? WillPopScope(
            onWillPop: () async {
              // 从助手页面跳转过来，侧滑返回到助手页�?              Navigator.of(context).pop();
              return false;
            },
            child: Scaffold(
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
                        content: Text('已复制到剪贴�?),
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
                  IconButton(
                    icon: const Icon(Icons.text_fields, size: 18),
                    onPressed: _showFontSizeDialog,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    splashRadius: 16,
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
                            color: _isDarkMode ? const Color(0xFF121212) : const Color(0xFFededed),
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
                                child: _content.isEmpty
                                    ? const Center(
                                        child: CircularProgressIndicator(),
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
                                                    const SnackBar(content: Text('已复制到剪贴�?)),
                                                  );
                                                  editableTextState.hideToolbar();
                                                },
                                                child: const Text('复制'),
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Positioned(
                      right: 20,
                      bottom: 20,
                      child: Container(
                        width: 56,
                        height: 56,
                        child: FloatingActionButton(
                          onPressed: () {
                            _scrollController.animateTo(
                              0,
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeInOut,
                            );
                          },
                          backgroundColor: const Color(0xFF9d5f4b),
                          elevation: 8,
                          highlightElevation: 12,
                          shape: const CircleBorder(),
                          child: const Icon(
                            Icons.keyboard_arrow_up,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        : Scaffold(
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
                      content: Text('已复制到剪贴�?),
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
                              child: _content.isEmpty
                                  ? const Center(
                                      child: CircularProgressIndicator(),
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
                                                  const SnackBar(content: Text('已复制到剪贴�?)),
                                                );
                                                editableTextState.hideToolbar();
                                              },
                                              child: const Text('复制'),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    right: 16,
                    bottom: 80,
                    child: Container(
                      width: 48,
                      height: 48,
                      child: FloatingActionButton(
                        onPressed: () {
                          _scrollController.animateTo(
                            0,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          );
                        },
                        backgroundColor: const Color(0xFF9d5f4b),
                        elevation: 8,
                        highlightElevation: 12,
                        shape: const CircleBorder(),
                        child: const Icon(
                          Icons.keyboard_arrow_up,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
  }
}
