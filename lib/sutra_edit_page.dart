import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_palette.dart';
import 'sutra_edit_drafts.dart';
Future<String> editedSutraFilePath(String keyPath) async {
  final dir = await getApplicationDocumentsDirectory();
  final folder = Directory('${dir.path}/edited_sutras');
  await folder.create(recursive: true);
  final sanitized = keyPath.replaceAll(RegExp(r'[\\/:*?"<>|.]'), '_');
  return '${folder.path}/$sanitized.txt';
}

class SutraEditPage extends StatefulWidget {
  final String title;
  final String content;
  final String keyPath;
  final double scrollProgress;
  final String? topParagraphText;

  /// 顶部标题输入框的默认值（当前展示的经名）；为空时回退 [title]。
  final String? initialTitle;

  const SutraEditPage({
    super.key,
    required this.title,
    required this.content,
    required this.keyPath,
    this.scrollProgress = 0.0,
    this.topParagraphText,
    this.initialTitle,
  });

  @override
  State<SutraEditPage> createState() => _SutraEditPageState();
}

class _SutraEditPageState extends State<SutraEditPage> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _positioned = false;

  /// 顶部经名（标题）输入框：管理员可订正显示名。
  late final TextEditingController _titleController;
  late final String _initialTitle;

  /// 进入编辑页时的原文（与之比较判断是否有未保存改动）。
  late final String _initialText;

  /// 最近一次确认已与本地编辑副本一致的正文：进入时等于原文（此时磁盘上
  /// 就是这份内容或尚无副本），每次成功写盘后更新为写入的内容。
  String? _writtenText;

  /// 防抖自动保存定时器：停笔片刻即落盘，避免「改完直接返回/杀进程」丢字。
  Timer? _autoSaveTimer;

  @override
  void initState() {
    super.initState();
    _initialText = widget.content;
    _writtenText = widget.content;
    _controller = TextEditingController(text: widget.content);
    _controller.addListener(_onTextChanged);
    _focusNode = FocusNode();
    _initialTitle = (widget.initialTitle ?? widget.title).trim();
    _titleController = TextEditingController(text: _initialTitle);
    _titleController.addListener(_onTitleChanged);
    final targetText = widget.topParagraphText;
    int? targetOffset;
    if (targetText != null && targetText.trim().isNotEmpty) {
      final key = targetText.trim().replaceAll(RegExp(r'\s+'), '').substring(0, 15.clamp(0, targetText.trim().replaceAll(RegExp(r'\s+'), '').length));
      if (key.length >= 5) {
        final raw = _controller.text.replaceAll(RegExp(r'\s+'), '');
        final idx = raw.indexOf(key);
        if (idx >= 0) {
          targetOffset = _offsetInOriginal(idx, raw.length);
        }
      }
    }
    final progress = widget.scrollProgress.clamp(0.0, 1.0);
    if (targetOffset != null || progress > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final pos = targetOffset ??
            (_controller.text.length * progress).round().clamp(0, _controller.text.length);
        _controller.selection = TextSelection.collapsed(offset: pos);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (!_positioned) {
            _positioned = true;
            _focusNode.requestFocus();
            _controller.selection = _controller.selection;
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    // 兜底：还有没落盘的改动（防抖未到点就被销毁）时补写一次，
    // 保证退出编辑页后正文一定在本地编辑副本里。
    if (_controller.text != _writtenText) {
      unawaited(_writeToDisk());
    }
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _titleController.removeListener(_onTitleChanged);
    _titleController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 标题变化：仅刷新 AppBar 显示。
  void _onTitleChanged() {
    if (mounted) setState(() {});
  }

  /// 文本变化：重置防抖定时器，停笔片刻后自动落盘。
  void _onTextChanged() {
    if (_controller.text == _writtenText) return;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      unawaited(_writeToDisk());
    });
  }

  /// 把当前正文写入本地编辑副本，并同步一份到可上云的草稿（重装不丢）。
  Future<void> _writeToDisk() async {
    final text = _controller.text;
    try {
      final path = await editedSutraFilePath(widget.keyPath);
      await File(path).writeAsString(text, flush: true);
      _writtenText = text;
      await SutraEditDraft.save(
        title: widget.title,
        filePath: widget.keyPath,
        content: text,
        displayTitle: _titleController.text.trim(),
      );
    } catch (_) {
      // 写盘失败（存储权限/空间等）：保留脏标记，下次变化或退出时重试。
    }
  }

  /// 返回给阅读页的结果：正文相对进入时有改动才让阅读页重新加载；
  /// 标题有改动则一并带回（正文没变时也会返回，供阅读页同步经名覆盖）。
  Map<String, dynamic>? _resultPayload() {
    final title = _titleController.text.trim();
    final titleChanged = title != _initialTitle;
    final contentChanged = _controller.text != _initialText;
    if (!contentChanged && !titleChanged) return null;
    String? cursorParagraphText;
    if (contentChanged && _controller.text.isNotEmpty) {
      final cursor =
          _controller.selection.end.clamp(0, _controller.text.length);
      final lastNewline = _controller.text.lastIndexOf('\n', cursor - 1);
      final nextNewline = _controller.text.indexOf('\n', cursor);
      final start = lastNewline + 1;
      final end =
          nextNewline < 0 ? _controller.text.length : nextNewline;
      final para = _controller.text.substring(start, end).trim();
      if (para.isNotEmpty) cursorParagraphText = para;
    }
    return {
      if (contentChanged) 'changed': true,
      'title': title,
      'titleChanged': titleChanged,
      'progress': _controller.text.isEmpty
          ? 0.0
          : (_controller.selection.end / _controller.text.length)
              .clamp(0.0, 1.0),
      'cursorParagraphText': cursorParagraphText,
    };
  }

  /// 点「保存」：立即落盘 + 提示，然后返回阅读页。
  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await _writeToDisk();

    if (mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('已保存到本地（已同步备份）')),
      );
    }
    if (mounted) {
      navigator.pop(_resultPayload());
    }
  }

  int _offsetInOriginal(int rawIdx, int rawLength) {
    final original = _controller.text;
    var rawCount = 0;
    for (var i = 0; i < original.length; i++) {
      if (!RegExp(r'\s').hasMatch(original[i])) rawCount++;
      if (rawCount > rawIdx) return i;
    }
    return original.length;
  }

  void _insertText(String text, {int cursorOffset = 0}) {
    final sel = _controller.selection;
    final start = sel.start.clamp(0, _controller.text.length);
    final end = sel.end.clamp(0, _controller.text.length);
    _controller.text = '${_controller.text.substring(0, start)}$text${_controller.text.substring(end)}';
    _controller.selection = TextSelection.collapsed(offset: start + (cursorOffset == 0 ? text.length : cursorOffset));
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // 返回键 / 手势返回：有未保存改动先落盘，再带结果返回阅读页，
        // 避免「编辑完直接返回（没点保存/完成排版）」导致改动丢失。
        if (_controller.text != _writtenText) {
          await _writeToDisk();
        }
        if (!context.mounted) return;
        Navigator.of(context).pop(_resultPayload());
      },
      child: _buildScaffold(p),
    );
  }

  Widget _buildScaffold(PaletteData p) {
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: IconThemeData(color: p.text),
        title: Text(
          _titleController.text.trim().isEmpty
              ? widget.title
              : _titleController.text.trim(),
          style: TextStyle(
            color: p.text,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              '保存',
              style: TextStyle(color: p.primary, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildTitleField(p),
            _buildToolbar(p),
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(
                    color: Color(0xFF212121),
                    fontSize: 16,
                    height: 1.8,
                    letterSpacing: 0.5,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部标题编辑栏：管理员可订正经名（显示名），保存后同步到云端，
  /// 所有用户的搜索/列表/最近阅读都会显示订正后的名称。
  Widget _buildTitleField(PaletteData p) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 8),
      color: p.bg,
      child: Row(
        children: [
          Text('标题', style: TextStyle(fontSize: 13, color: p.textSec)),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _titleController,
              textInputAction: TextInputAction.done,
              maxLines: 1,
              style: TextStyle(
                color: p.text,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: '输入经文标题',
                hintStyle: TextStyle(color: p.textHint, fontSize: 15),
                border: UnderlineInputBorder(
                  borderSide: BorderSide(color: p.border, width: 0.5),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(PaletteData p) {
    final items = [
      _ToolbarItem(symbol: '。。。', label: '隐藏翻译', tooltip: '隐藏操作栏'),
      _ToolbarItem(symbol: '///', label: '不分段', tooltip: '与下段连排'),
      _ToolbarItem(symbol: 'bbb', label: '加粗', tooltip: '加粗显示'),
      _ToolbarItem(symbol: '@@@@', label: '备注', tooltip: '插入备注（绿色小字）', cursorOffset: 2),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: p.tintBg,
        border: Border(
          bottom: BorderSide(color: p.border, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _buildToolButton(p, items[i]),
          ],
          const Spacer(),
          Text(
            '光标处插入',
            style: TextStyle(fontSize: 11, color: p.textHint),
          ),
        ],
      ),
    );
  }

  Widget _buildToolButton(PaletteData p, _ToolbarItem item) {
    return Tooltip(
      message: item.tooltip,
      child: GestureDetector(
        onTap: () => _insertText(item.symbol, cursorOffset: item.cursorOffset),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: p.border, width: 0.5),
          ),
          child: Text(
            item.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: p.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarItem {
  final String symbol;
  final String label;
  final String tooltip;
  final int cursorOffset;
  const _ToolbarItem({required this.symbol, required this.label, required this.tooltip, this.cursorOffset = 0});
}
