import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CheckInPage extends StatefulWidget {
  const CheckInPage({super.key});

  @override
  State<CheckInPage> createState() => _CheckInPageState();
}

class _CheckInPageState extends State<CheckInPage> {
  List<Map<String, String>> _types = [
    {'key': 'meditation', 'label': '静坐', 'icon': '🧘'},
    {'key': 'reading', 'label': '诵经', 'icon': '📖'},
    {'key': 'mantra', 'label': '持咒', 'icon': '🔔'},
    {'key': 'buddha', 'label': '称名', 'icon': '🙏'},
    {'key': 'copying', 'label': '抄经', 'icon': '✍️'},
  ];

  List<Map<String, dynamic>> _todayRecords = [];
  List<Map<String, dynamic>> _recentDays = [];
  int _streak = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> allRecords = jsonDecode(raw);

    final customRaw = prefs.getString('custom_checkin_types') ?? '[]';
    final List<dynamic> customTypes = jsonDecode(customRaw);
    final customList = customTypes.map((t) => {'key': t['key'].toString(), 'label': t['label'].toString(), 'icon': t['icon'].toString()}).toList();

    final today = _today();
    setState(() {
      _types = [
        {'key': 'meditation', 'label': '静坐', 'icon': '🧘'},
        {'key': 'reading', 'label': '诵经', 'icon': '📖'},
        {'key': 'mantra', 'label': '持咒', 'icon': '🔔'},
        {'key': 'buddha', 'label': '称名', 'icon': '🙏'},
        {'key': 'copying', 'label': '抄经', 'icon': '✍️'},
        ...customList,
      ];
      _todayRecords = allRecords.where((r) => r['date'] == today).cast<Map<String, dynamic>>().toList();
      _recentDays = _buildRecentDays(allRecords.cast<Map<String, dynamic>>());
      _streak = _calcStreak(allRecords.cast<Map<String, dynamic>>());
    });
  }

  List<Map<String, dynamic>> _buildRecentDays(List<Map<String, dynamic>> records) {
    final today = DateTime.now();
    final result = <Map<String, dynamic>>[];
    for (int i = 6; i >= 0; i--) {
      final day = today.subtract(Duration(days: i));
      final dateStr = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      final dayRecords = records.where((r) => r['date'] == dateStr).toList();
      result.add({'date': dateStr, 'records': dayRecords, 'isToday': i == 0});
    }
    return result;
  }

  int _calcStreak(List<Map<String, dynamic>> records) {
    if (records.isEmpty) return 0;
    final dates = records.map((r) => r['date'] as String).toSet().toList()..sort();
    int streak = 0;
    final today = DateTime.now();
    for (int i = 0; i < 365; i++) {
      final day = today.subtract(Duration(days: i));
      final dateStr = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      if (dates.contains(dateStr)) {
        streak++;
      } else {
        break;
      }
    }
    return streak;
  }

  Future<void> _toggleCheckIn(String typeKey, String label) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> allRecords = jsonDecode(raw);
    final today = _today();

    final existingIndex = allRecords.indexWhere((r) => r['date'] == today && r['type'] == typeKey);
    if (existingIndex >= 0) {
      allRecords.removeAt(existingIndex);
    } else {
      allRecords.add({'date': today, 'type': typeKey, 'label': label});
    }

    await prefs.setString('checkin_records', jsonEncode(allRecords));
    _loadData();
  }

  bool _isChecked(String typeKey) {
    return _todayRecords.any((r) => r['type'] == typeKey);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('功课打卡')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text('连续打卡 $_streak 天', style: theme.textTheme.titleMedium?.copyWith(color: const Color(0xFF5D4037))),
                  const SizedBox(height: 8),
                  Text(_today(), style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF757575))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('今日功课', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  ..._types.map((t) => CheckboxListTile(
                    title: Text('${t['icon']}  ${t['label']}'),
                    value: _isChecked(t['key']!),
                    onChanged: (_) => _toggleCheckIn(t['key']!, t['label']!),
                    activeColor: const Color(0xFF5D4037),
                    controlAffinity: ListTileControlAffinity.trailing,
                  )),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('近7天', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  ..._recentDays.map((day) {
                    final records = day['records'] as List<dynamic>;
                    final isToday = day['isToday'] as bool;
                    final dateLabel = day['date'].toString().substring(5);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 50,
                            child: Text(dateLabel,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isToday ? const Color(0xFF5D4037) : const Color(0xFF757575),
                                  fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                                )),
                          ),
                          const SizedBox(width: 8),
                          ..._types.map((t) {
                            final hasRecord = records.any((r) => r['type'] == t['key']);
                            return Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: hasRecord ? const Color(0xFF5D4037) : const Color(0xFFE0E0E0),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                alignment: Alignment.center,
                                child: Text(t['icon']!,
                                    style: TextStyle(fontSize: hasRecord ? 14 : 12, color: hasRecord ? Colors.white : const Color(0xFFBDBDBD))),
                              ),
                            );
                          }),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
