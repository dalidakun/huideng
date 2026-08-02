import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';

const Color _primary = Color(0xFF5C4033);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _gold = Color(0xFFD4A06A);

class NoteEditPage extends StatefulWidget {
  final Map<String, dynamic>? note;
  const NoteEditPage({super.key, this.note});

  @override
  State<NoteEditPage> createState() => _NoteEditPageState();
}

class _NoteEditPageState extends State<NoteEditPage> {
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  bool _hasChanges = false;
  String? _savedId;
  late bool _shared;
  String? _cloudId;
  bool _savingCloud = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note?['title'] ?? '');
    _contentController = TextEditingController(text: widget.note?['content'] ?? '');
    _shared = widget.note?['shared'] == true;
    _cloudId = widget.note?['cloudId'] as String?;
    _titleController.addListener(_onChange);
    _contentController.addListener(_onChange);
  }

  void _onChange() {
    if (!_hasChanges) setState(() => _hasChanges = true);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    if (title.isEmpty && content.isEmpty) return;

    if (_shared && !AuthService.instance.isLoggedIn) {
      _showToast('分享到菩提空间需要先登录');
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }

    setState(() => _savingCloud = true);
    String? newCloudId = _cloudId;
    bool cloudOk = true;

    if (_shared) {
      try {
        if (_cloudId == null || _cloudId!.isEmpty) {
          newCloudId = await CloudNotesService.instance.publishNote(
            title: title.isEmpty ? '无标题' : title,
            content: content,
          );
        } else {
          await CloudNotesService.instance.updateSharedNote(
            cloudId: _cloudId!,
            title: title.isEmpty ? '无标题' : title,
            content: content,
            isPublic: true,
          );
        }
        _cloudId = newCloudId;
      } catch (e) {
        cloudOk = false;
        if (mounted) _showToast('分享失败：${e.toString()}');
      }
    } else if (_cloudId != null && _cloudId!.isNotEmpty) {
      try {
        await CloudNotesService.instance.unpublishNote(_cloudId!);
      } catch (_) {}
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('notes') ?? '[]';
    final List<dynamic> notes = jsonDecode(raw);
    final now = DateTime.now().toIso8601String();
    final displayTitle = title.isEmpty ? '无标题' : title;

    final sharedNow =
        _shared && (cloudOk || (_cloudId != null && _cloudId!.isNotEmpty));
    final targetId = _savedId ?? widget.note?['id'] ?? now;
    final newNote = <String, dynamic>{
      'id': targetId,
      'title': displayTitle,
      'content': content,
      'updatedAt': now,
      'shared': sharedNow,
      'cloudId': sharedNow ? (_cloudId ?? newCloudId) : null,
    };
    final index = notes.indexWhere((n) => n['id'] == targetId);
    if (index >= 0) {
      notes[index] = newNote;
    } else {
      notes.add(newNote);
    }

    await prefs.setString('notes', jsonEncode(notes));
    if (mounted) {
      setState(() {
        _savedId = targetId;
        _hasChanges = false;
        _savingCloud = false;
      });
      _showSavedToast(sharedNow ? '已保存并分享' : '已保存');
    }
  }

  void _onShareChanged(bool value) {
    if (value && !AuthService.instance.isLoggedIn) {
      _showToast('分享到菩提空间需要先登录');
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }
    setState(() {
      _shared = value;
      if (!_hasChanges) _hasChanges = true;
    });
  }

  Widget _buildShareRow() {
    final iconBg =
        _shared ? _gold.withValues(alpha: 0.15) : _textHint.withValues(alpha: 0.12);
    final iconColor = _shared ? _gold : _textHint;
    final titleColor = _shared ? _text : _textSec;
    return Container(
      color: _card,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.people_outline, size: 16, color: iconColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('分享到菩提空间',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: titleColor)),
                  const SizedBox(height: 1),
                  Text(
                      _shared ? '已分享，保存后同步到菩提空间' : '开启后同修可在菩提空间看到',
                      style: const TextStyle(fontSize: 10, color: _textSec)),
                ],
              ),
            ),
            if (_savingCloud)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
              )
            else
              SwitchTheme(
                data: SwitchThemeData(
                  thumbColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                          ? const Color(0xFFFFFAF5)
                          : const Color(0xFFC9BFB2)),
                  trackColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                          ? _gold
                          : const Color(0xFFE8DED0)),
                  trackOutlineColor:
                      WidgetStateProperty.resolveWith((_) => Colors.transparent),
                ),
                child: Switch(
                  value: _shared,
                  onChanged: _savingCloud ? null : _onShareChanged,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showToast(String text) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final topInset = MediaQuery.of(ctx).padding.top;
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: EdgeInsets.only(top: topInset + kToolbarHeight + 10),
            child: Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: _primary,
                borderRadius: BorderRadius.circular(20),
                elevation: 0,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (entry.mounted) entry.remove();
    });
  }

  void _showSavedToast(String message) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final topInset = MediaQuery.of(ctx).padding.top;
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: EdgeInsets.only(top: topInset + kToolbarHeight + 10),
            child: Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: _primary,
                borderRadius: BorderRadius.circular(20),
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle, size: 14, color: Colors.white),
                      const SizedBox(width: 5),
                      Text(message,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.none,
                          decorationColor: Colors.transparent,
                        )),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (entry.mounted) entry.remove();
    });
  }

  Future<bool> _onWillPop() async {
    if (!_hasChanges) return true;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('放弃修改？', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: const Text('您有未保存的更改', style: TextStyle(color: _textSec)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: _textSec))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('放弃', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.note == null && _savedId == null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          elevation: 0,
          title: Text(isNew ? '新建笔记' : '编辑笔记',
              style: const TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: GestureDetector(
                onTap: _save,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                  decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Text('保存', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _primary)),
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: TextField(
                controller: _titleController,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _text),
                decoration: InputDecoration(
                  hintText: '标题',
                  hintStyle: TextStyle(color: _textHint),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Divider(height: 1, thickness: 0.5, color: Color(0xFFEBE1D6)),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _contentController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 15, color: _text, height: 1.6),
                  decoration: InputDecoration(
                    hintText: '开始记录...',
                    hintStyle: TextStyle(color: _textHint),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
            ),
            _buildShareRow(),
          ],
        ),
      ),
    );
  }
}
