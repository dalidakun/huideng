import 'dart:io';

import 'package:flutter/material.dart';
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

  const SutraEditPage({
    super.key,
    required this.title,
    required this.content,
    required this.keyPath,
    this.scrollProgress = 0.0,
  });

  @override
  State<SutraEditPage> createState() => _SutraEditPageState();
}

class _SutraEditPageState extends State<SutraEditPage> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _hasEdited = false;
  bool _positioned = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.content);
    _focusNode = FocusNode();
    _checkEdited();
    // 将光标/滚动位置定位到与阅读进度一致的位置，便于直接编辑该处经文。
    final progress = widget.scrollProgress.clamp(0.0, 1.0);
    if (progress > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final length = _controller.text.length;
        final pos = (length * progress).round().clamp(0, length);
        _controller.selection = TextSelection.collapsed(offset: pos);
        if (!_positioned) {
          _positioned = true;
          _focusNode.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _checkEdited() async {
    final path = await editedSutraFilePath(widget.keyPath);
    if (mounted) {
      setState(() {
        _hasEdited = File(path).existsSync();
      });
    }
  }

  Future<void> _save() async {
    final path = await editedSutraFilePath(widget.keyPath);
    await File(path).writeAsString(_controller.text);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _restore() async {
    final path = await editedSutraFilePath(widget.keyPath);
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.p.bg,
      appBar: AppBar(
        backgroundColor: AppPalette.p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Color(0xFF212121)),
        title: Text(
          widget.title,
          style: const TextStyle(
            color: Color(0xFF212121),
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_hasEdited)
            TextButton(
              onPressed: _restore,
              child: Text(
                '恢复原文',
                style: TextStyle(color: AppPalette.p.textSec, fontSize: 13),
              ),
            ),
          TextButton(
            onPressed: _save,
            child: Text(
              '保存',
              style: TextStyle(color: AppPalette.p.primary, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
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
    );
  }
}
