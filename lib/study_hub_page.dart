import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'reading_page.dart';
import 'checkin_page.dart';
import 'checkin_settings_page.dart';
import 'notes_page.dart';
import 'sutra_list_page.dart';
import 'calendar_page.dart';

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

class StudyHubPage extends StatefulWidget {
  const StudyHubPage({super.key});

  @override
  State<StudyHubPage> createState() => StudyHubPageState();
}

class StudyHubPageState extends State<StudyHubPage> with TickerProviderStateMixin {
  void reload() => _loadData();
  String? _currentTitle;
  String? _currentFilePath;
  double _progress = 0.0;
  List<Map<String, String>> _todayCheckIns = [];
  List<Map<String, dynamic>> _recentNotes = [];
  int _checkinStreak = 0;
  int _studyDays = 0;
  int _notesCount = 0;
  String? _lockedTitle;
  String? _lockedFilePath;
  List<Map<String, dynamic>> _customTypes = [];
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.05).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _pulseController.repeat(reverse: true);
    _loadData();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();

    final lastDate = prefs.getString('study_last_date') ?? '';
    final today = _today();
    if (today != lastDate) {
      final count = prefs.getInt('study_day_count') ?? 0;
      await prefs.setInt('study_day_count', count + 1);
      await prefs.setString('study_last_date', today);
    }

    setState(() {
      final lockTitle = prefs.getString('locked_sutra_title');
      final lockPath = prefs.getString('locked_sutra_file_path');
      if (lockTitle != null) {
        _currentTitle = lockTitle;
        _currentFilePath = lockPath;
        _lockedTitle = lockTitle;
        _lockedFilePath = lockPath;
      } else {
        _currentTitle = prefs.getString('current_sutra_title');
        _currentFilePath = prefs.getString('current_sutra_file_path');
        _lockedTitle = null;
        _lockedFilePath = null;
      }
      if (_currentFilePath != null) {
        _progress = prefs.getDouble('progress_$_currentFilePath') ?? 0.0;
      }
      _todayCheckIns = _loadTodayCheckIns(prefs);
      _checkinStreak = _calcStreak(prefs);
      _studyDays = prefs.getInt('study_day_count') ?? 0;
      _recentNotes = _loadRecentNotes(prefs);
      _notesCount = (jsonDecode(prefs.getString('notes') ?? '[]') as List).length;
      final customRaw = prefs.getString('custom_checkin_types') ?? '[]';
      _customTypes = (jsonDecode(customRaw) as List<dynamic>).cast<Map<String, dynamic>>();
    });
  }

  List<Map<String, String>> _loadTodayCheckIns(SharedPreferences prefs) {
    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> allRecords = jsonDecode(raw);
    final today = _today();
    return allRecords.where((r) => r['date'] == today).map((r) => {'type': r['type'].toString(), 'label': r['label'].toString()}).toList();
  }

  int _calcStreak(SharedPreferences prefs) {
    final raw = prefs.getString('checkin_records') ?? '[]';
    final records = (jsonDecode(raw) as List<dynamic>).map((r) => r['date'].toString()).toSet().toList()..sort();
    if (records.isEmpty) return 0;
    int streak = 0;
    final today = DateTime.now();
    for (int i = 0; i < 365; i++) {
      final day = today.subtract(Duration(days: i));
      final ds = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      if (records.contains(ds)) { streak++; } else { break; }
    }
    return streak;
  }

  List<Map<String, dynamic>> _loadRecentNotes(SharedPreferences prefs) {
    final raw = prefs.getString('notes') ?? '[]';
    final notes = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    notes.sort((a, b) => b['updatedAt'].compareTo(a['updatedAt']));
    return notes.take(3).toList();
  }

  String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  void _openSutra() {
    if (_currentTitle == null) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => ReadingPage(title: _currentTitle!, filePath: _currentFilePath)));
  }

  Future<void> _openSutraByPath(String title, String? filePath) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ReadingPage(title: title, filePath: filePath)));
    _loadData();
  }

  Future<void> _showRecentSutras() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('daily_sutra_history') ?? '{}';
    final Map<String, dynamic> history = jsonDecode(raw);
    if (history.isEmpty) return;
    final dates = history.keys.toList()..sort((a, b) => b.compareTo(a));
    final latestDate = dates.first;
    final List<dynamic> sutras = history[latestDate] as List<dynamic>;

    if (!mounted || sutras.isEmpty) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Row(
                  children: [
                    Text('$latestDate 阅读', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
                    const Spacer(),
                    Text('${sutras.length} 部', style: TextStyle(fontSize: 13, color: _textHint)),
                  ],
                ),
              ),
              const Divider(height: 1, color: _border),
              ...sutras.map((s) {
                final title = s['title'] as String? ?? '';
                final fp = s['filePath'] as String?;
                final progress = (s['progress'] as num?)?.toDouble() ?? 0.0;
                return InkWell(
                  onTap: () {
                    Navigator.pop(ctx);
                    if (title.isNotEmpty) _openSutraByPath(title, fp);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _text)),
                              const SizedBox(height: 4),
                              Text('已读 ${(progress * 100).toStringAsFixed(1)}%', style: TextStyle(fontSize: 12, color: _textHint)),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right, color: _textHint, size: 20),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _toggleLock() async {
    if (_currentTitle == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (_lockedTitle != null) {
      await prefs.remove('locked_sutra_title');
      await prefs.remove('locked_sutra_file_path');
      setState(() {
        _lockedTitle = null;
        _lockedFilePath = null;
      });
    } else {
      await prefs.setString('locked_sutra_title', _currentTitle!);
      await prefs.setString('locked_sutra_file_path', _currentFilePath ?? '');
      _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Color(0xFF212121)),
        title: const Text(
          '诸行无常，一切皆苦；诸法无我，寂灭为乐。',
          style: TextStyle(
            color: Color(0xFF616161),
            fontSize: 12,
            fontWeight: FontWeight.normal,
          ),
          softWrap: false,
          overflow: TextOverflow.visible,
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.calendar_month_outlined, color: Color(0xFF616161), size: 20),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CalendarPage())),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          _buildCurrentSutraCard(),
          const SizedBox(height: 14),
          _buildCheckInCard(),
          const SizedBox(height: 14),
          _buildNotesCard(),
        ],
      ),
    );
  }

  Widget _buildCurrentSutraCard() {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
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
                  decoration: BoxDecoration(color: _primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.menu_book_rounded, size: 17, color: _primary),
                ),
                const SizedBox(width: 10),
                Text('当前读经', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
                const Spacer(),
                if (_currentTitle != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(color: _overlay, borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.today, size: 12, color: _primaryLight),
                        const SizedBox(width: 4),
                        Text('已学$_studyDays天', style: TextStyle(fontSize: 11, color: _primaryLight, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (_currentTitle != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: GestureDetector(
                onTap: _openSutra,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_currentTitle!, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: _progress,
                              minHeight: 5,
                              backgroundColor: _border,
                              valueColor: const AlwaysStoppedAnimation<Color>(_gold),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text('${(_progress * 100).toStringAsFixed(1)}%', style: TextStyle(fontSize: 12, color: _textHint, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _toggleLock,
                    style: TextButton.styleFrom(
                      foregroundColor: _lockedTitle != null ? _gold : _textSec,
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_lockedTitle != null ? Icons.lock : Icons.lock_open, size: 13),
                        const SizedBox(width: 4),
                        Text(_lockedTitle != null ? '已锁定' : '锁定经书', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _showRecentSutras,
                    style: TextButton.styleFrom(foregroundColor: _textSec, padding: const EdgeInsets.symmetric(horizontal: 16)),
                    child: Text('最近阅读 ›', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
          ] else ...[
            Center(
              child: Column(
                children: [
                  AnimatedBuilder(
                    animation: _pulseAnim,
                    builder: (context, child) => Transform.scale(scale: _pulseAnim.value, child: child),
                    child: Container(
                      width: 80, height: 80,
                      decoration: BoxDecoration(
                        color: _overlay,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Icon(Icons.auto_stories_rounded, size: 40, color: _primaryLight.withValues(alpha: 0.8)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('今日尚未开启经文之旅', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: _text)),
                  const SizedBox(height: 6),
                  Text('选择一部经文，开始今日修学', style: TextStyle(fontSize: 14, color: _textSec)),
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SutraListPage())),
                        icon: const Icon(Icons.explore, size: 18),
                        label: const Text('浏览经藏', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ],
          const SizedBox(height: 18),
        ],
      ),
    );
  }

  Widget _buildCheckInCard() {
    final types = [
      {'key': 'meditation', 'label': '静坐', 'icon': Icons.self_improvement_outlined},
      {'key': 'reading', 'label': '诵经', 'icon': Icons.chrome_reader_mode_outlined},
      {'key': 'mantra', 'label': '持咒', 'icon': Icons.notifications_none_outlined},
      {'key': 'buddha', 'label': '称名', 'icon': Icons.spa_outlined},
      {'key': 'copying', 'label': '抄经', 'icon': Icons.edit_outlined},
      ..._customTypes.map((t) => {'key': t['key'], 'label': t['label'], 'emoji': t['icon']}),
    ];
    final doneCount = _todayCheckIns.length;

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
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
                  decoration: BoxDecoration(color: _primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.check_circle_outline, size: 17, color: _primary),
                ),
                const SizedBox(width: 10),
                Text('功课打卡', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
                const Spacer(),
                Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(color: _overlay, borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.today, size: 12, color: _primaryLight),
                        const SizedBox(width: 4),
                        Text('打卡$_checkinStreak天', style: TextStyle(fontSize: 11, color: _primaryLight, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: types.map((t) {
                final checked = _todayCheckIns.any((r) => r['type'] == t['key']);
                return Expanded(
                  child: _CheckInButton(
                    icon: t['icon'] as IconData?,
                    emoji: t['emoji'] as String?,
                    label: t['label'] as String,
                    checked: checked,
                    onTap: () => _toggleCheckIn(t['key'] as String, t['label'] as String),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: doneCount / types.length,
                      minHeight: 4,
                      backgroundColor: _border,
                      valueColor: const AlwaysStoppedAnimation<Color>(_primary),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text('$doneCount/${types.length}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _primary)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CheckInSettingsPage())),
                  style: TextButton.styleFrom(foregroundColor: _textSec, padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune, size: 13),
                      const SizedBox(width: 4),
                      Text('设置功课', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CheckInPage())),
                  style: TextButton.styleFrom(foregroundColor: _textSec, padding: const EdgeInsets.symmetric(horizontal: 16)),
                  child: Text('查看详情 ›', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleCheckIn(String typeKey, String label) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> allRecords = jsonDecode(raw);
    final today = _today();

    final idx = allRecords.indexWhere((r) => r['date'] == today && r['type'] == typeKey);
    if (idx >= 0) {
      allRecords.removeAt(idx);
    } else {
      allRecords.add({'date': today, 'type': typeKey, 'label': label});
    }
    await prefs.setString('checkin_records', jsonEncode(allRecords));
    _loadData();
  }

  Widget _buildNotesCard() {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
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
                  decoration: BoxDecoration(color: _primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.edit_note_rounded, size: 17, color: _primary),
                ),
                const SizedBox(width: 10),
                Text('我的笔记', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
                const Spacer(),
                Text('共 $_notesCount 篇', style: TextStyle(fontSize: 12, color: _textHint)),
              ],
            ),
          ),
          if (_recentNotes.isEmpty) ...[
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  Container(
                    width: 72, height: 72,
                    decoration: BoxDecoration(
                      color: _overlay,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(Icons.auto_stories, size: 36, color: _primaryLight.withValues(alpha: 0.4)),
                        Positioned(
                          right: 16, bottom: 18,
                          child: Icon(Icons.edit, size: 18, color: _primaryLight.withValues(alpha: 0.6)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('笔记是修行的足迹', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: _text)),
                  const SizedBox(height: 4),
                  Text('记录你的心得与体悟吧', style: TextStyle(fontSize: 14, color: _textSec)),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotesPage())),
                        icon: const Icon(Icons.add_rounded, size: 20),
                        label: const Text('创建第一篇笔记', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            ..._recentNotes.asMap().entries.map((entry) {
              final note = entry.value;
              final content = (note['content'] as String? ?? '');
              final preview = content.length > 30 ? '${content.substring(0, 30)}...' : content;
              return Column(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotesPage())),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                                Text(note['title'] ?? '', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _text)),
                                const SizedBox(height: 4),
                                Text(preview, style: TextStyle(fontSize: 13, color: _textSec), maxLines: 1),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right, color: _textHint, size: 20),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }),
            TextButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotesPage())),
              style: TextButton.styleFrom(foregroundColor: _primary, padding: const EdgeInsets.symmetric(vertical: 14)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('查看全部笔记', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_forward_ios, size: 12, color: _primary),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CheckInButton extends StatefulWidget {
  final IconData? icon;
  final String? emoji;
  final String label;
  final bool checked;
  final VoidCallback onTap;

  const _CheckInButton({this.icon, this.emoji, required this.label, required this.checked, required this.onTap});

  @override
  State<_CheckInButton> createState() => _CheckInButtonState();
}

class _CheckInButtonState extends State<_CheckInButton> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));
    _scale = Tween<double>(begin: 1.0, end: 0.92).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapDown(_) => _ctrl.forward();
  void _onTapUp(_) {
    _ctrl.reverse();
    widget.onTap();
  }
  void _onTapCancel() => _ctrl.reverse();

  @override
  Widget build(BuildContext context) {
    final checked = widget.checked;
    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, child) => Transform.scale(scale: _scale.value, child: child),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: checked ? _primary : _overlay,
            borderRadius: BorderRadius.circular(14),
            boxShadow: checked
                ? [BoxShadow(color: _primary.withValues(alpha: 0.2), blurRadius: 8, offset: const Offset(0, 3))]
                : [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 4, offset: const Offset(0, 1))],
          ),
          child: Column(
            children: [
              if (widget.icon != null)
                Icon(widget.icon, size: 24, color: checked ? Colors.white : _primary)
              else
                Text(widget.emoji ?? '', style: TextStyle(fontSize: 22)),
              const SizedBox(height: 6),
              Text(widget.label, style: TextStyle(
                fontSize: 13,
                color: checked ? Colors.white : _textSec,
                fontWeight: checked ? FontWeight.w600 : FontWeight.w500,
              )),
            ],
          ),
        ),
      ),
    );
  }
}
