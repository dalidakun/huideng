import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_palette.dart';
import 'cloud_notes_service.dart';
import 'sutra_downloader.dart';
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
  bool _positioned = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.content);
    _focusNode = FocusNode();
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

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final path = await editedSutraFilePath(widget.keyPath);
    await File(path).writeAsString(_controller.text);

    // 管理员保存时把最新排版同步到云端 / GitHub，供所有用户「更新排版」拉取。
    // GitHub 由云函数代写（凭据存云函数环境变量，不进客户端）。
    final id = SutraDownloader.extractId(null, widget.keyPath);
    if (id != null && id.isNotEmpty) {
      try {
        await CloudNotesService.instance.saveSutraEdit(id, _controller.text);
        if (mounted) {
          messenger.showSnackBar(
            const SnackBar(content: Text('已保存并发布最新排版')),
          );
        }
      } catch (e) {
        if (mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text('已保存到本地，但发布失败：$e')),
          );
        }
      }
    }
    if (mounted) navigator.pop({
      'changed': true,
      'progress': _controller.text.isEmpty
          ? 0.0
          : (_controller.selection.end / _controller.text.length).clamp(0.0, 1.0),
    });
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
