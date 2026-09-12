import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_palette.dart';
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

  const SutraEditPage({
    super.key,
    required this.title,
    required this.content,
    required this.keyPath,
    this.scrollProgress = 0.0,
    this.topParagraphText,
  });

  @override
  State<SutraEditPage> createState() => _SutraEditPageState();
}

class _SutraEditPageState extends State<SutraEditPage> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _positioned = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.content);
    _focusNode = FocusNode();
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
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
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

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final path = await editedSutraFilePath(widget.keyPath);
    await File(path).writeAsString(_controller.text);

    if (mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('已保存到本地')),
      );
    }
    if (mounted) {
      String? cursorParagraphText;
      if (_controller.text.isNotEmpty) {
        final cursor = _controller.selection.end.clamp(0, _controller.text.length);
        final lastNewline = _controller.text.lastIndexOf('\n', cursor - 1);
        final nextNewline = _controller.text.indexOf('\n', cursor);
        final start = lastNewline + 1;
        final end = nextNewline < 0 ? _controller.text.length : nextNewline;
        final para = _controller.text.substring(start, end).trim();
        if (para.isNotEmpty) cursorParagraphText = para;
      }
      navigator.pop({
        'changed': true,
        'progress': _controller.text.isEmpty
            ? 0.0
            : (_controller.selection.end / _controller.text.length).clamp(0.0, 1.0),
        'cursorParagraphText': cursorParagraphText,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: IconThemeData(color: p.text),
        title: Text(
          widget.title,
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
