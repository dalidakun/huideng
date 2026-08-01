import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'notes_page.dart';
import 'note_edit_page.dart';

const Color _primary = Color(0xFF5C4033);
const Color _primaryLight = Color(0xFF8B6B5A);
const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _border = Color(0xFFEBE1D6);
const Color _overlay = Color(0xFFFFF5EC);

class MyPage extends StatefulWidget {
  const MyPage({super.key});

  @override
  State<MyPage> createState() => MyPageState();
}

class MyPageState extends State<MyPage> {
  List<Map<String, dynamic>> _recentNotes = [];
  int _notesCount = 0;
  int _studyDays = 0;
  int _checkinStreak = 0;
  String? _avatarPath;
  String _nickname = '同修';
  String _tagline = '与经为伴，与法同行';

  void reload() => _loadData();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _recentNotes = _loadRecentNotes(prefs);
      _notesCount = (jsonDecode(prefs.getString('notes') ?? '[]') as List).length;
      _studyDays = prefs.getInt('study_day_count') ?? 0;
      _checkinStreak = _calcStreak(prefs);
      _avatarPath = prefs.getString('user_avatar_path');
      _nickname = prefs.getString('user_nickname') ?? '同修';
      _tagline = prefs.getString('user_tagline') ?? '与经为伴，与法同行';
    });
  }

  int _calcStreak(SharedPreferences prefs) {
    final raw = prefs.getString('checkin_records') ?? '[]';
    final records = (jsonDecode(raw) as List<dynamic>).map((r) => r['date'].toString()).toSet();
    int streak = 0;
    final today = DateTime.now();
    final startIndex = records.contains(_today()) ? 0 : 1;
    for (int i = startIndex; i < 365; i++) {
      final day = today.subtract(Duration(days: i));
      final ds = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      if (records.contains(ds)) { streak++; } else { break; }
    }
    return streak;
  }

  String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'gif'],
    );
    if (result == null || result.files.single.path == null) return;
    try {
      final src = File(result.files.single.path!);
      final ext = src.path.split('.').last;
      final docs = await getApplicationDocumentsDirectory();
      final dest = File('${docs.path}/avatar.$ext');
      if (dest.existsSync()) dest.deleteSync();
      await src.copy(dest.path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_avatar_path', dest.path);
      _loadData();
    } catch (_) {}
  }

  Future<void> _editProfile() async {
    final nameController = TextEditingController(text: _nickname);
    final taglineController = TextEditingController(text: _tagline);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('编辑个人资料', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              maxLength: 12,
              style: const TextStyle(color: _text),
              decoration: const InputDecoration(
                labelText: '昵称',
                labelStyle: TextStyle(color: _textSec),
                hintText: '输入你的昵称',
                hintStyle: TextStyle(color: _textHint),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: taglineController,
              maxLength: 20,
              style: const TextStyle(color: _text),
              decoration: const InputDecoration(
                labelText: '签名',
                labelStyle: TextStyle(color: _textSec),
                hintText: '一句修学感悟',
                hintStyle: TextStyle(color: _textHint),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消', style: TextStyle(color: _textSec))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, {
              'nickname': nameController.text.trim(),
              'tagline': taglineController.text.trim(),
            }),
            child: const Text('保存', style: TextStyle(color: _primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (result == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (result['nickname']!.isNotEmpty) await prefs.setString('user_nickname', result['nickname']!);
    await prefs.setString('user_tagline', result['tagline']!.isEmpty ? '与经为伴，与法同行' : result['tagline']!);
    _loadData();
  }

  List<Map<String, dynamic>> _loadRecentNotes(SharedPreferences prefs) {
    final raw = prefs.getString('notes') ?? '[]';
    final notes = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    notes.sort((a, b) => b['updatedAt'].compareTo(a['updatedAt']));
    return notes.take(3).toList();
  }

  Future<void> _deleteNote(Map<String, dynamic> note) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除笔记', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Text('确定删除「${note['title']}」吗？', style: const TextStyle(color: _textSec)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: _textSec))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (confirm != true) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('notes') ?? '[]';
    final notes = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    notes.removeWhere((n) => n['id'] == note['id']);
    await prefs.setString('notes', jsonEncode(notes));
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(0, 18, 0, 32),
              children: [
                _buildNotesCard(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF3E8DB), Color(0xFFF9F1E7)],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
          child: Column(
            children: [
              Row(
                children: [
                  GestureDetector(
                    onTap: _pickAvatar,
                    child: Container(
                      width: 62, height: 62,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _card,
                        boxShadow: [
                          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10, offset: const Offset(0, 2)),
                        ],
                        image: _avatarPath != null
                            ? DecorationImage(image: FileImage(File(_avatarPath!)), fit: BoxFit.cover)
                            : null,
                      ),
                      child: _avatarPath == null
                          ? const Icon(Icons.person, size: 32, color: _primaryLight)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_nickname, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: _text)),
                        const SizedBox(height: 5),
                        Text(
                          _tagline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, color: _textSec),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _editProfile,
                    icon: const Icon(Icons.edit_outlined, size: 18, color: _textHint),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  _HeaderStat(value: '$_studyDays', label: '学习天数'),
                  Container(width: 1, height: 30, color: _border),
                  _HeaderStat(value: '$_checkinStreak', label: '连续打卡'),
                  Container(width: 1, height: 30, color: _border),
                  _HeaderStat(value: '$_notesCount', label: '笔记'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotesCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Row(
              children: [
                Container(
                  width: 30, height: 30,
                  decoration: BoxDecoration(color: _primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.edit_note_rounded, size: 17, color: _primary),
                ),
                const SizedBox(width: 10),
                const Text('我的笔记', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
                const Spacer(),
                Text('共 $_notesCount 篇', style: const TextStyle(fontSize: 12, color: _textHint)),
              ],
            ),
          ),
          const SizedBox(height: 6),
          if (_recentNotes.isEmpty)
            _buildEmptyNotes()
          else ...[
            for (final note in _recentNotes) _buildNoteRow(note),
            Center(
              child: TextButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotesPage())).then((_) => reload()),
                style: TextButton.styleFrom(foregroundColor: _primary, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('查看全部笔记', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_forward_ios, size: 12, color: _primary),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyNotes() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color: _overlay,
                shape: BoxShape.circle,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(Icons.auto_stories_rounded, size: 28, color: _primaryLight.withValues(alpha: 0.55)),
                  Positioned(
                    right: 12, bottom: 13,
                    child: Icon(Icons.edit, size: 14, color: _primaryLight.withValues(alpha: 0.65)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Text('暂无笔记', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            const SizedBox(height: 6),
            const Text('记录每日心得，见证修学成长', style: TextStyle(fontSize: 13, color: _textSec)),
            const SizedBox(height: 18),
            ElevatedButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotesPage())).then((_) => reload()),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('创建第一篇笔记', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _buildNoteRow(Map<String, dynamic> note) {
    final content = (note['content'] as String? ?? '');
    final preview = content.length > 30 ? '${content.substring(0, 30)}...' : content;
    return InkWell(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NoteEditPage(note: note))).then((_) => reload()),
      onLongPress: () => _deleteNote(note),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 4, height: 44,
              decoration: BoxDecoration(color: _gold, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(note['title'] ?? '', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _text)),
                  const SizedBox(height: 4),
                  Text(preview, style: const TextStyle(fontSize: 13, color: _textSec), maxLines: 1),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: _textHint, size: 20),
          ],
        ),
      ),
    );
  }
}

class _HeaderStat extends StatelessWidget {
  final String value;
  final String label;

  const _HeaderStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: _text)),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(fontSize: 12, color: _textSec)),
        ],
      ),
    );
  }
}
