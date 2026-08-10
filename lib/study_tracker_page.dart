import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'reading_page.dart';
import 'sutra_downloader.dart';

class StudyTrackerPage extends StatefulWidget {
  const StudyTrackerPage({super.key});

  @override
  State<StudyTrackerPage> createState() => _StudyTrackerPageState();
}

class _StudyTrackerPageState extends State<StudyTrackerPage> {
  String? _currentTitle;
  String? _currentFilePath;
  double _progress = 0.0;
  List<Map<String, String>> _recentSutras = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    var progress = 0.0;
    final fp = prefs.getString('current_sutra_file_path');
    final title = prefs.getString('current_sutra_title');
    // 进度以阅读页实时写入的规范路径键为准；规范键缺失时兼容旧键名，
    // 并回退每日阅读历史，避免换机/重装后进度清零。
    if (fp != null) {
      progress = await SutraDownloader.latestProgressForPath(prefs, fp,
          title: title);
    } else {
      progress = SutraDownloader.progressFromDailyHistory(prefs, title);
    }
    setState(() {
      _currentTitle = title;
      _currentFilePath = fp;
      _progress = progress;
      _recentSutras = _loadRecentSutras(prefs);
    });
  }

  List<Map<String, String>> _loadRecentSutras(SharedPreferences prefs) {
    final raw = prefs.getStringList('recent_sutras') ?? [];
    return raw.map((e) {
      final parts = e.split('|||');
      return {'title': parts[0], 'filePath': parts.length > 1 ? parts[1] : ''};
    }).toList();
  }

  void _selectSutra(String title, String filePath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_sutra_title', title);
    await prefs.setString('current_sutra_file_path', filePath);
    // 进度以规范路径键的最新值为准（缺失时兼容旧键名）。
    final progress =
        await SutraDownloader.latestProgressForPath(prefs, filePath, title: title);
    setState(() {
      _currentTitle = title;
      _currentFilePath = filePath;
      _progress = progress;
    });
  }

  void _openSutra() {
    if (_currentTitle == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingPage(title: _currentTitle!, filePath: _currentFilePath),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('当前学佛经')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _currentTitle != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_currentTitle!, style: theme.textTheme.titleMedium),
                        const SizedBox(height: 16),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _progress,
                            minHeight: 8,
                            backgroundColor: const Color(0xFFE0E0E0),
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF5D4037)),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('已读 ${(_progress * 100).toStringAsFixed(1)}%',
                            style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF757575))),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _openSutra,
                            icon: const Icon(Icons.menu_book),
                            label: const Text('继续阅读'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF5D4037),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        Icon(Icons.book_outlined, size: 48, color: const Color(0xFFBDBDBD)),
                        const SizedBox(height: 12),
                        Text('尚未选择学习的经书', style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF757575))),
                        const SizedBox(height: 8),
                        Text('阅读经书后会自动记录', style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFFBDBDBD))),
                      ],
                    ),
            ),
          ),
          if (_recentSutras.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('最近阅读', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ..._recentSutras.map((s) => Card(
              child: ListTile(
                leading: const Icon(Icons.history, color: Color(0xFF757575)),
                title: Text(s['title'] ?? ''),
                trailing: const Icon(Icons.check_circle_outline, color: Color(0xFF5D4037)),
                onTap: () => _selectSutra(s['title']!, s['filePath']!),
              ),
            )),
          ],
        ],
      ),
    );
  }
}
