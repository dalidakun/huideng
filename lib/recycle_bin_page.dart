import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_notes_service.dart';

import 'app_palette.dart';
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _gold => AppPalette.p.accent;
class RecycleBinPage extends StatefulWidget {
  const RecycleBinPage({super.key});

  @override
  State<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends State<RecycleBinPage> {
  List<Map<String, dynamic>> _trash = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadTrash();
  }

  Future<void> _loadTrash() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('trash_notes') ?? '[]';
    setState(() {
      _trash = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
      _trash.sort((a, b) => b['deletedAt'].toString().compareTo(a['deletedAt'].toString()));
    });
  }

  Future<void> _saveTrash() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('trash_notes', jsonEncode(_trash));
  }

  Future<void> _restore(int index) async {
    final note = _trash[index];
    final cloudId = note['cloudId'] as String?;
    if (note['shared'] == true && cloudId != null && cloudId.isNotEmpty) {
      try {
        await CloudNotesService.instance.unhideCloudNote(cloudId);
      } catch (_) {}
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('notes') ?? '[]';
    final notes = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    final restored = Map<String, dynamic>.from(note)..remove('deletedAt');
    notes.add(restored);
    await prefs.setString('notes', jsonEncode(notes));

    setState(() => _trash.removeAt(index));
    await _saveTrash();
  }

  Future<void> _deleteForever(int index) async {
    final note = _trash[index];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('彻底删除', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Text('将彻底删除这篇笔记，且不可恢复，确定吗？', style: TextStyle(color: _textSec)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: TextStyle(color: _textSec))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (confirm != true) return;

    final cloudId = note['cloudId'] as String?;
    if (note['shared'] == true && cloudId != null && cloudId.isNotEmpty) {
      try {
        await CloudNotesService.instance.deleteCloudNote(cloudId);
      } catch (_) {}
    }

    setState(() => _trash.removeAt(index));
    await _saveTrash();
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('清空回收站', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Text('回收站中的全部笔记将被彻底删除，且不可恢复，确定吗？', style: TextStyle(color: _textSec)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: TextStyle(color: _textSec))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      final copy = List<Map<String, dynamic>>.from(_trash);
      for (final note in copy) {
        final cloudId = note['cloudId'] as String?;
        if (note['shared'] == true && cloudId != null && cloudId.isNotEmpty) {
          try {
            await CloudNotesService.instance.deleteCloudNote(cloudId);
          } catch (_) {}
        }
      }
      setState(() => _trash = []);
      await _saveTrash();
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('回收站'),
        actions: [
          if (_trash.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 24),
              child: TextButton(
                onPressed: _busy ? null : _clearAll,
                child: const Text('清空回收站', style: TextStyle(color: Colors.red)),
              ),
            ),
        ],
      ),
      body: _trash.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline, size: 48, color: _textHint),
                  const SizedBox(height: 12),
                  Text('回收站为空', style: theme.textTheme.bodyMedium?.copyWith(color: _textSec)),
                  const SizedBox(height: 4),
                  Text('删除的笔记会先进入这里', style: theme.textTheme.bodyMedium?.copyWith(color: _textHint)),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _trash.length,
              itemBuilder: (context, index) {
                final note = _trash[index];
                final content = note['content'] as String? ?? '';
                final preview = content.length > 60 ? '${content.substring(0, 60)}...' : content;
                final date = note['deletedAt'].toString().substring(0, 10);
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2)),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              preview,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 14, color: _textSec, height: 1.5),
                            ),
                          ),
                          if (note['shared'] == true)
                            Container(
                              margin: const EdgeInsets.only(left: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: _gold.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('菩提空间',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: AppPalette.p.accentDeep)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(Icons.schedule, size: 12, color: _textHint),
                          const SizedBox(width: 4),
                          Text('$date 删除', style: TextStyle(fontSize: 12, color: _textHint)),
                          const Spacer(),
                          IconButton(
                            onPressed: _busy ? null : () => _restore(index),
                            tooltip: '还原',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(Icons.replay, color: AppPalette.p.primary, size: 20),
                          ),
                          IconButton(
                            onPressed: _busy ? null : () => _deleteForever(index),
                            tooltip: '彻底删除',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.delete_forever, color: Colors.red, size: 20),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
