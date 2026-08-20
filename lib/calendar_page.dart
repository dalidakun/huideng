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

  /// 各类型每日功课的具体内容（诵的经、持的咒等），用于打卡明细展示。
  Map<String, List<String>> _recordDetails = {};

  /// 每日功课类型列表（key/label/unit），用于长按日期补充打卡。
  List<Map<String, String>> _backfillTypes = [];
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
    final recordDetails = _buildRecordDetails(prefs);
    final backfillTypes = _buildBackfillTypes(prefs);
    _selectedDate ??= _todayStr();
    setState(() {
      _checkInDates = records.map((r) => r['date'].toString()).toSet();
      _recordsByDate = recordsByDate;
      _customUnits = customUnits;
      _recordDetails = recordDetails;
      _backfillTypes = backfillTypes;
      _totalDays = _checkInDates.length;
      _longestStreak = _calcLongestStreak(recordsByDate.keys.toList());
    });
  }

  /// 读取每日功课配置，汇总各类型具体内容（诵的经、持的咒、抄的经等），
  /// 只保留名称（数量由打卡总量体现，不在此重复展示）。
  Map<String, List<String>> _buildRecordDetails(SharedPreferences prefs) {
    final out = <String, List<String>>{};
    out['meditation'] = [
      for (final e in _decodeStrList(prefs.getString('setting_meditation_minutes')))
        if (e.trim().isNotEmpty) '${e.trim()}分钟',
    ];
    out['reading'] = [
      for (final e in _decodeNamed(prefs.getString('setting_reading_titles')))
        if (e.$1.trim().isNotEmpty) e.$1.trim(),
    ];
    out['nianfo'] = [
      for (final e in _decodeNamed(prefs.getString('setting_nianfo_items')))
        if (e.$1.trim().isNotEmpty) e.$1.trim(),
    ];
    out['mantra'] = [
      for (final e in _decodeNamed(prefs.getString('setting_mantra_items')))
        if (e.$1.trim().isNotEmpty) e.$1.trim(),
    ];
    out['buddha'] = [
      for (final e in _decodeNamed(prefs.getString('setting_buddha_items')))
        if (e.$1.trim().isNotEmpty) e.$1.trim(),
    ];
    out['copying'] = [
      for (final e in _decodeStrList(prefs.getString('setting_copying_titles')))
        if (e.trim().isNotEmpty) e.trim(),
    ];
    return out;
  }

  List<String> _decodeStrList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final d = jsonDecode(raw);
      if (d is List) return d.map((e) => e.toString()).toList();
    } catch (_) {}
    return [];
  }

  /// 解析「名称 + 数量」配置：{name, count}，数量可能为空。
  List<(String, String)> _decodeNamed(String? raw) {
    final out = <(String, String)>[];
    if (raw == null || raw.isEmpty) return out;
    try {
      final d = jsonDecode(raw);
      if (d is List) {
        for (final e in d) {
          if (e is Map) {
            out.add(((e['name'] ?? '').toString(), (e['count'] ?? '').toString()));
          } else {
            out.add((e.toString(), ''));
          }
        }
      }
    } catch (_) {}
    return out;
  }

  /// 每日功课类型列表：已配置具体内容才展示；全部未配置时回退为固定五项。
  List<Map<String, String>> _buildBackfillTypes(SharedPreferences prefs) {
    const all = [
      {'key': 'reading', 'label': '诵经', 'unit': '遍'},
      {'key': 'nianfo', 'label': '念佛', 'unit': '声'},
      {'key': 'buddha', 'label': '称名', 'unit': '声'},
      {'key': 'mantra', 'label': '持咒', 'unit': '遍'},
      {'key': 'copying', 'label': '抄经', 'unit': '篇'},
      {'key': 'meditation', 'label': '静坐', 'unit': '分钟'},
    ];
    final customs =
        (jsonDecode(prefs.getString('custom_checkin_types') ?? '[]') as List<dynamic>)
            .cast<Map<String, dynamic>>();
    final configured = <Map<String, String>>[];
    for (final t in [
      ...all,
      ...customs.map((c) => {
            'key': c['key'].toString(),
            'label': (c['label'] ?? '').toString(),
            'unit': (c['unit'] ?? '遍').toString(),
          }),
    ]) {
      switch (t['key']) {
        case 'meditation':
          if (_hasNonEmptyItems(prefs, 'setting_meditation_minutes')) configured.add(t);
        case 'reading':
          if (_hasNonEmptyNamed(prefs, 'setting_reading_titles')) configured.add(t);
        case 'nianfo':
          if (_hasNonEmptyNamed(prefs, 'setting_nianfo_items')) configured.add(t);
        case 'mantra':
          if (_hasNonEmptyNamed(prefs, 'setting_mantra_items')) configured.add(t);
        case 'buddha':
          if (_hasNonEmptyNamed(prefs, 'setting_buddha_items')) configured.add(t);
        case 'copying':
          if (_hasNonEmptyItems(prefs, 'setting_copying_titles')) configured.add(t);
        default:
          configured.add(t); // 自定义类型始终展示。
      }
    }
    return configured.isEmpty ? all : configured;
  }

  bool _hasNonEmptyItems(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return false;
    try {
      final d = jsonDecode(raw);
      if (d is List) return d.any((e) => e.toString().trim().isNotEmpty);
    } catch (_) {}
    return false;
  }

  bool _hasNonEmptyNamed(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return false;
    try {
      final d = jsonDecode(raw);
      if (d is List) {
        return d.any((e) {
          final n = e is Map ? (e['name'] ?? '') : e;
          return n.toString().trim().isNotEmpty;
        });
      }
    } catch (_) {}
    return false;
  }

  /// 某类型当天的默认数量：按每日功课配置的各项内容求和，与主页打卡逻辑一致。
  double _defaultAmount(String typeKey, SharedPreferences prefs) {
    switch (typeKey) {
      case 'meditation':
        return _decodeStrList(prefs.getString('setting_meditation_minutes'))
            .fold<double>(0, (s, e) => s + (double.tryParse(e) ?? 0));
      case 'reading':
        return _sumNamed(prefs.getString('setting_reading_titles'));
      case 'nianfo':
        return _sumNamed(prefs.getString('setting_nianfo_items'));
      case 'mantra':
        return _sumNamed(prefs.getString('setting_mantra_items'));
      case 'buddha':
        return _sumNamed(prefs.getString('setting_buddha_items'));
      case 'copying':
        return _decodeStrList(prefs.getString('setting_copying_titles'))
            .length
            .toDouble();
      default:
        final customs =
            (jsonDecode(prefs.getString('custom_checkin_types') ?? '[]') as List<dynamic>)
                .cast<Map<String, dynamic>>();
        for (final c in customs) {
          if (c['key'] == typeKey) {
            return double.tryParse((c['count'] ?? '').toString()) ?? 0;
          }
        }
        return 0;
    }
  }

  double _sumNamed(String? raw) {
    var sum = 0.0;
    for (final e in _decodeNamed(raw)) {
      sum += double.tryParse(e.$2) ?? 0;
    }
    return sum;
  }

  /// 长按日期补充打卡：弹窗列出每日功课项目，手动输入数量后写入打卡记录。
  /// 未来的日期尚未开始，不允许补充。
  Future<void> _backfillDate(String dateStr) async {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    if (DateTime.parse(dateStr).isAfter(day)) return;
    final prefs = await SharedPreferences.getInstance();
    final date = DateTime.parse(dateStr);
    final existingOnDate = _recordsByDate[dateStr] ?? const [];
    final existing = <String, double>{};
    for (final r in existingOnDate) {
      existing[r['type'].toString()] =
          double.tryParse((r['amount'] ?? '1').toString()) ?? 1;
    }
    final ctrls = <String, TextEditingController>{};
    for (final t in _backfillTypes) {
      final key = t['key']!;
      final def = existing[key] ?? _defaultAmount(key, prefs);
      ctrls[key] =
          TextEditingController(text: def > 0 ? _fmt(def) : '');
    }
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('补充打卡 · ${date.month}月${date.day}日 星期${'一二三四五六日'[date.weekday - 1]}',
            style: TextStyle(color: _text, fontSize: 17, fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('按每日功课的项目填写当天实际完成的量，留空表示该项未做。',
                    style: const TextStyle(fontSize: 12, color: _textSec, height: 1.5)),
                const SizedBox(height: 12),
                for (final t in _backfillTypes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 56,
                          child: Text(t['label']!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, color: _text, fontWeight: FontWeight.w500)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: ctrls[t['key']],
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            style: const TextStyle(color: _text, fontSize: 14),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '0',
                              hintStyle: TextStyle(color: _textHint),
                              suffixText: t['unit'],
                              suffixStyle: const TextStyle(fontSize: 12, color: _textHint),
                              filled: true,
                              fillColor: _bg,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _border)),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _primary)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: _textSec))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存', style: TextStyle(color: _primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    final savedValues = <Map<String, String>>[];
    for (final t in _backfillTypes) {
      final key = t['key']!;
      savedValues.add({'key': key, 'label': t['label']!, 'value': ctrls[key]!.text});
    }
    for (final c in ctrls.values) {
      c.dispose();
    }
    if (ok != true || !mounted) return;

    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> allRecords = jsonDecode(raw);
    for (final e in savedValues) {
      final key = e['key']!;
      final value = double.tryParse(e['value']!.trim());
      final idx = allRecords
          .indexWhere((r) => r['date'] == dateStr && r['type'] == key);
      if (value != null && value > 0) {
        final rec = {
          'date': dateStr,
          'type': key,
          'label': e['label'],
          'amount': value,
        };
        if (idx >= 0) {
          allRecords[idx] = rec;
        } else {
          allRecords.add(rec);
        }
      } else if (idx >= 0) {
        // 填 0 或清空：移除该项记录。
        allRecords.removeAt(idx);
      }
    }
    await prefs.setString('checkin_records', jsonEncode(allRecords));
    if (mounted) {
      _selectedDate = dateStr;
      _loadData();
    }
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
        behavior: HitTestBehavior.opaque,
        onTap: () =>
            setState(() => _selectedDate = _selectedDate == dateStr ? null : dateStr),
        onLongPress: () => _backfillDate(dateStr),
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
    final now = DateTime.now();
    final isFuture = DateTime(date.year, date.month, date.day)
        .isAfter(DateTime(now.year, now.month, now.day));
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
                child: Text(
                    isFuture ? '当天还未打卡' : '当天还未打卡\n长按日历上的日期可补充',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: _textHint, height: 1.6)),
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
            final type = r['type'].toString();
            final label = r['label'].toString();
            final amount = double.tryParse((r['amount'] ?? '1').toString()) ?? 1;
            final unit = _unitFor(type);
            final details = _recordDetails[type] ?? const <String>[];
            return GestureDetector(
              onLongPress: () => _editRecord(r),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, size: 16, color: _primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        details.isEmpty
                            ? label
                            : '$label · ${details.join('·')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, color: _text),
                      ),
                    ),
                    Text('${_fmt(amount)}$unit',
                        style: TextStyle(fontSize: 13, color: _textSec)),
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
      case 'nianfo': return '声';
      case 'mantra': return '遍';
      case 'buddha': return '声';
      case 'copying': return '篇';
      default: return _customUnits[type] ?? '';
    }
  }

  String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }
}
