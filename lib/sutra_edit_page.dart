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

  const SutraEditPage({
    super.key,
    required this.title,
    required this.content,
    required this.keyPath,
  });

  @override
  State<SutraEditPage> createState() => _SutraEditPageState();
}

class _SutraEditPageState extends State<SutraEditPage> {
  late final TextEditingController _controller;
  bool _hasEdited = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.content);
    _checkEdited();
  }

  Future<void> _checkEdited() async {
    final path = await editedSutraFilePath(widget.keyPath);
    if (mounted) {
      setState(() {
        _hasEdited = File(path).existsSync();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
