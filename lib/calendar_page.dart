import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Color _primary = Color(0xFF5C4033);
const Color _primaryLight = Color(0xFF8B6B5A);
const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _border = Color(0xFFEBE1D6);

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late DateTime _currentMonth;
  Set<String> _checkInDates = {};
  Map<String, List<Map<String, dynamic>>> _recordsByDate = {};
  Map<String, String> _customUnits = {};
  int _longestStreak = 0;
  int _totalDays = 0;
  String? _selectedDate;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _currentMonth = DateTime(now.year, now.month);
    _loadData();
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> records = jsonDecode(raw);
    final customs = (jsonDecode(prefs.getString('custom_checkin_types') ?? '[]') as List<dynamic>).cast<Map<String, dynamic>>();
    final recordsByDate = <String, List<Map<String, dynamic>>>{};
    for (final r in records) {
      final d = r['date'].toString();
      recordsByDate.putIfAbsent(d, () => []).add(Map<String, dynamic>.from(r as Map));
    }
    final customUnits = <String, String>{};
    for (final c in customs) {
      customUnits[c['key'].toString()] = (c['unit'] ?? '遍').toString();
    }
    _selectedDate ??= _todayStr();
    setState(() {
      _checkInDates = records.map((r) => r['date'].toString()).toSet();
      _recordsByDate = recordsByDate;
      _customUnits = customUnits;
      _totalDays = _checkInDates.length;
      _longestStreak = _calcLongestStreak(recordsByDate.keys.toList());
    });
  }

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  int _calcLongestStreak(List<String> dateStrs) {
    final dates = dateStrs.toSet().toList()..sort();
    if (dates.isEmpty) return 0;
    int longest = 1;
    int current = 1;
    for (int i = 1; i < dates.length; i++) {
      final prev = DateTime.parse(dates[i - 1]);
      final cur = DateTime.parse(dates[i]);
      if (cur.difference(prev).inDays == 1) {
        current++;
      } else {
        if (current > longest) longest = current;
        current = 1;
      }
    }
    if (current > longest) longest = current;
    return longest;
  }

  void _prevMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
      _selectedDate = null;
    });
  }

  void _nextMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
      _selectedDate = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: const Text('打卡日历'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          _buildStatsRow(),
          const SizedBox(height: 16),
          _buildCalendarCard(),
          if (_selectedDate != null) ...[
            const SizedBox(height: 14),
            _buildDayDetailCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                Text('$_totalDays', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: _primary)),
                const SizedBox(height: 4),
                Text('总打卡天数', style: TextStyle(fontSize: 13, color: _textSec)),
              ],
            ),
          ),
          Container(width: 1, height: 40, color: _border),
          Expanded(
            child: Column(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.local_fire_department, size: 22, color: _gold),
                    const SizedBox(width: 4),
                    Text('$_longestStreak', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: _gold)),
                  ],
                ),
                const SizedBox(height: 4),
                Text('连续打卡最长天数', style: TextStyle(fontSize: 12, color: _textSec)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarCard() {
    final firstDay = DateTime(_currentMonth.year, _currentMonth.month, 1);
    final lastDay = DateTime(_currentMonth.year, _currentMonth.month + 1, 0);
    final weekdayOfFirst = firstDay.weekday % 7;
    final daysInMonth = lastDay.day;
    final today = DateTime.now();
    final isCurrentMonth = today.year == _currentMonth.year && today.month == _currentMonth.month;

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left, color: _primaryLight),
                  onPressed: _prevMonth,
                ),
                Text('${_currentMonth.year}年${_currentMonth.month}月',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
                IconButton(
                  icon: const Icon(Icons.chevron_right, color: _primaryLight),
                  onPressed: _nextMonth,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Divider(color: _border, thickness: 0.5),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: ['日', '一', '二', '三', '四', '五', '六'].map((d) =>
                Expanded(
                  child: Center(
                    child: Text(d, style: TextStyle(fontSize: 13, color: _textHint, fontWeight: FontWeight.w500)),
                  ),
                ),
              ).toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              children: _buildWeeks(firstDay, weekdayOfFirst, daysInMonth, today, isCurrentMonth),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildWeeks(DateTime firstDay, int weekdayOfFirst, int daysInMonth, DateTime today, bool isCurrentMonth) {
    final weeks = <Widget>[];
    var dayCounter = 1;
    for (var w = 0; w < 6 && dayCounter <= daysInMonth; w++) {
      final dayWidgets = <Widget>[];
      for (var d = 0; d < 7; d++) {
        if ((w == 0 && d < weekdayOfFirst) || dayCounter > daysInMonth) {
          dayWidgets.add(const Expanded(child: SizedBox(height: 40)));
        } else {
          final day = dayCounter;
          final dateStr = '${_currentMonth.year}-${_currentMonth.month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
          final hasCheckIn = _checkInDates.contains(dateStr);
          final isToday = isCurrentMonth && day == today.day;
          final isSelected = _selectedDate == dateStr;
          dayWidgets.add(_buildDayCell(day, hasCheckIn, isToday, isSelected, dateStr));
          dayCounter++;
        }
      }
      weeks.add(Row(children: dayWidgets));
    }
    return weeks;
  }

  Widget _buildDayCell(int day, bool hasCheckIn, bool isToday, bool isSelected, String dateStr) {
    return Expanded(
      child: GestureDetector(
        onTap: hasCheckIn ? () => setState(() => _selectedDate = _selectedDate == dateStr ? null : dateStr) : null,
        child: Container(
          height: 40,
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (isToday)
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: hasCheckIn ? _primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: isSelected ? Border.all(color: _gold, width: 2) : null,
                ),
                alignment: Alignment.center,
                child: Text('$day', style: TextStyle(
                  fontSize: 14,
                  color: hasCheckIn ? Colors.white : (isToday ? _primary : _text),
                  fontWeight: hasCheckIn || isToday ? FontWeight.w600 : FontWeight.w400,
                )),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDayDetailCard() {
    final records = _recordsByDate[_selectedDate] ?? [];
    final date = DateTime.parse(_selectedDate!);
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${date.month}月${date.day}日', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _text)),
              const SizedBox(width: 8),
              Text('星期${weekdays[date.weekday - 1]}', style: TextStyle(fontSize: 12, color: _textHint)),
              const Spacer(),
              Text('共 ${records.length} 项', style: TextStyle(fontSize: 12, color: _textHint)),
            ],
          ),
          const SizedBox(height: 12),
          if (records.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text('当天还未打卡', style: TextStyle(fontSize: 13, color: _textHint)),
              ),
            )
          else ...[
            Row(
              children: [
                Icon(Icons.edit_outlined, size: 12, color: _textHint),
                const SizedBox(width: 4),
                Text('长按任意一项可修改数量', style: TextStyle(fontSize: 11, color: _textHint)),
              ],
            ),
            const SizedBox(height: 10),
            ...records.map((r) {
            final label = r['label'].toString();
            final amount = double.tryParse((r['amount'] ?? '1').toString()) ?? 1;
            final unit = _unitFor(r['type'].toString());
            return GestureDetector(
              onLongPress: () => _editRecord(r),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, size: 16, color: _primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(label, style: TextStyle(fontSize: 14, color: _text))),
                    Text('${_fmt(amount)}$unit', style: TextStyle(fontSize: 13, color: _textSec)),
                  ],
                ),
              ),
              );
            }),
            ],
          ],
      ),
    );
  }

  Future<void> _editRecord(Map<String, dynamic> record) async {
    final type = record['type'].toString();
    final label = record['label'].toString();
    final unit = _unitFor(type);
    final current = double.tryParse((record['amount'] ?? '1').toString()) ?? 1;
    final ctrl = TextEditingController(text: _fmt(current));
    final result = await showDialog<dynamic>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(label, style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          style: TextStyle(color: _text),
          decoration: InputDecoration(
            labelText: '数量（$unit）',
            labelStyle: TextStyle(color: _textSec),
            hintText: '如：15',
            hintStyle: TextStyle(color: _textHint),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: _primary)),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: _border)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: _textSec))),
          TextButton(
            onPressed: () {
              if (ctrl.text.trim().isEmpty) return;
              Navigator.pop(ctx, ctrl.text.trim());
            },
            child: Text('确定', style: TextStyle(color: _primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (result == null) return;
    final newAmount = double.tryParse(result.toString()) ?? current;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> records = jsonDecode(raw);
    for (final r in records) {
      if (r['date'] == _selectedDate && r['type'] == type) {
        r['amount'] = newAmount;
        break;
      }
    }
    await prefs.setString('checkin_records', jsonEncode(records));
    _loadData();
  }

  String _unitFor(String type) {
    switch (type) {
      case 'meditation': return '分钟';
      case 'reading': return '遍';
      case 'mantra': return '遍';
      case 'buddha': return '遍';
      case 'copying': return '篇';
      default: return _customUnits[type] ?? '';
    }
  }

  String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }
}
