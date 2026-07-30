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
  int _streak = 0;
  int _totalDays = 0;

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
    setState(() {
      _checkInDates = records.map((r) => r['date'].toString()).toSet();
      _totalDays = _checkInDates.length;
      _streak = _calcStreak(records);
    });
  }

  int _calcStreak(List<dynamic> records) {
    final dates = records.map((r) => r['date'].toString()).toSet().toList()..sort();
    if (dates.isEmpty) return 0;
    int streak = 0;
    final today = DateTime.now();
    for (int i = 0; i < 365; i++) {
      final day = today.subtract(Duration(days: i));
      final ds = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      if (dates.contains(ds)) { streak++; } else { break; }
    }
    return streak;
  }

  void _prevMonth() => setState(() => _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1));
  void _nextMonth() => setState(() => _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1));

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
                    Text('$_streak', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: _gold)),
                  ],
                ),
                const SizedBox(height: 4),
                Text('连续打卡', style: TextStyle(fontSize: 13, color: _textSec)),
              ],
            ),
          ),
          Container(width: 1, height: 40, color: _border),
          Expanded(
            child: Column(
              children: [
                Text('${_currentMonth.year}', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: _textHint)),
                const SizedBox(height: 4),
                Text('当前年份', style: TextStyle(fontSize: 13, color: _textHint)),
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
          dayWidgets.add(_buildDayCell(day, hasCheckIn, isToday));
          dayCounter++;
        }
      }
      weeks.add(Row(children: dayWidgets));
    }
    return weeks;
  }

  Widget _buildDayCell(int day, bool hasCheckIn, bool isToday) {
    return Expanded(
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
    );
  }
}
