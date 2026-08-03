import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_notes_service.dart';
import 'note_edit_page.dart';
import 'recycle_bin_page.dart';

const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _gold = Color(0xFFD4A06A);
const Color _divider = Color(0xFFEDE3D6);

class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  List<Map<String, dynamic>> _notes = [];

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('notes') ?? '[]';
    setState(() {
      _notes = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
      _notes.sort((a, b) => b['updatedAt'].compareTo(a['updatedAt']));
    });
  }

  void _openRecycleBin() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RecycleBinPage()),
    ).then((_) {
      _loadNotes();
    });
  }

  Future<void> _deleteNote(int index) async {
    final note = _notes[index];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除笔记', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Text('确定将这篇笔记移入回收站吗？', style: const TextStyle(color: _textSec)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: _textSec))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (confirm != true) return;

    final cloudId = note['cloudId'] as String?;
    if (note['shared'] == true && cloudId != null && cloudId.isNotEmpty) {
      try {
        await CloudNotesService.instance.hideCloudNote(cloudId);
      } catch (_) {}
    }

    final prefs = await SharedPreferences.getInstance();
    final trashRaw = prefs.getString('trash_notes') ?? '[]';
    final trash = (jsonDecode(trashRaw) as List<dynamic>).cast<Map<String, dynamic>>();
    trash.add({...note, 'deletedAt': DateTime.now().toIso8601String()});
    await prefs.setString('trash_notes', jsonEncode(trash));

    setState(() {
      _notes.removeAt(index);
    });
    await _saveNotes();
  }

  Future<void> _saveNotes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('notes', jsonEncode(_notes));
  }

  void _openEdit({int? index}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NoteEditPage(note: index != null ? _notes[index] : null),
      ),
    ).then((_) {
      _loadNotes();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('我的笔记'),
        actions: [
          IconButton(
            onPressed: _openRecycleBin,
            tooltip: '回收站',
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 36),
        child: SizedBox(
          width: 48,
          height: 48,
          child: FloatingActionButton(
            onPressed: () => _openEdit(),
            heroTag: 'notes_fab',
            backgroundColor: const Color(0xFF5D4037),
            elevation: 8,
            highlightElevation: 12,
            shape: const CircleBorder(),
            child: const Icon(Icons.add, color: Colors.white, size: 24),
          ),
        ),
      ),
      body: _notes.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.note_add_outlined, size: 48, color: _textHint),
                  const SizedBox(height: 12),
                  Text('还没有笔记', style: theme.textTheme.bodyMedium?.copyWith(color: _textSec)),
                  const SizedBox(height: 4),
                  Text('点击右下角 + 创建', style: theme.textTheme.bodyMedium?.copyWith(color: _textHint)),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(top: 4, bottom: 100),
              itemCount: _notes.length,
              itemBuilder: (context, index) {
                final note = _notes[index];
                final content = note['content'] as String? ?? '';
                final preview = content.length > 60 ? '${content.substring(0, 60)}...' : content;
                final date = note['updatedAt'].toString().substring(0, 10);
                return GestureDetector(
                  onTap: () => _openEdit(index: index),
                  onLongPress: () => _deleteNote(index),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: _divider, width: 0.5),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          preview,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, color: _textSec, height: 1.5),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Icon(Icons.schedule, size: 12, color: _textHint),
                            const SizedBox(width: 4),
                            Text(date, style: TextStyle(fontSize: 12, color: _textHint)),
                            const Spacer(),
                            if (note['shared'] == true) ...[
                              Container(
                                margin: const EdgeInsets.only(right: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: _gold.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text('菩提空间',
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Color(0xFF9A6B3F))),
                              ),
                            ],
                            Container(
                              width: 6, height: 6,
                              decoration: BoxDecoration(color: _gold, shape: BoxShape.circle),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
