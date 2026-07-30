import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'note_edit_page.dart';

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

  Future<void> _deleteNote(int index) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定删除「${_notes[index]['title']}」吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm != true) return;
    _notes.removeAt(index);
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
    ).then((result) {
      if (result != null) {
        _loadNotes();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('我的笔记')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEdit(),
        backgroundColor: const Color(0xFF5D4037),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: _notes.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.note_add_outlined, size: 48, color: const Color(0xFFBDBDBD)),
                  const SizedBox(height: 12),
                  Text('还没有笔记', style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF757575))),
                  const SizedBox(height: 4),
                  Text('点击右下角 + 创建', style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFFBDBDBD))),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _notes.length,
              itemBuilder: (context, index) {
                final note = _notes[index];
                final content = note['content'] as String? ?? '';
                final preview = content.length > 80 ? '${content.substring(0, 80)}...' : content;
                final date = note['updatedAt'].toString().substring(0, 10);
                return Card(
                  child: ListTile(
                    title: Text(note['title'] ?? '', style: theme.textTheme.titleMedium),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text(preview, style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF757575)), maxLines: 2),
                        const SizedBox(height: 4),
                        Text(date, style: TextStyle(fontSize: 12, color: const Color(0xFFBDBDBD))),
                      ],
                    ),
                    isThreeLine: true,
                    onTap: () => _openEdit(index: index),
                    onLongPress: () => _deleteNote(index),
                  ),
                );
              },
            ),
    );
  }
}
