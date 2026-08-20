import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'checkin_history_stats.dart';
import 'sync_service.dart';

const Color _primary = Color(0xFF5C4033);
const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _border = Color(0xFFEBE1D6);

class CheckInGoalsPage extends StatefulWidget {
  const CheckInGoalsPage({super.key});

  @override
  State<CheckInGoalsPage> createState() => _CheckInGoalsPageState();
}

class _CheckInGoalsPageState extends State<CheckInGoalsPage> {
  List<_GoalType> _types = [];
  Map<String, double> _goals = {};
  Map<String, double> _totals = {};

  /// 各类型在每日功课中配置的具体内容（如诵的经、持的咒），用于历史统计明细。
  Map<String, List<String>> _details = {};

  /// 是否允许他人在主页查看我的「功课」（打卡设置与目标）。
  bool _showCheckinOnHome = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();

    _showCheckinOnHome = prefs.getBool('privacy_show_checkin') ?? false;
    if (mounted) setState(() {});

    final customs = (jsonDecode(prefs.getString('custom_checkin_types') ?? '[]') as List<dynamic>).cast<Map<String, dynamic>>();
    final types = <_GoalType>[
      _GoalType(key: 'reading', label: '诵经', unit: '遍', icon: Icons.chrome_reader_mode_outlined),
      _GoalType(key: 'nianfo', label: '念佛', unit: '声', icon: Icons.local_florist_outlined),
      _GoalType(key: 'buddha', label: '称名', unit: '声', icon: Icons.spa_outlined),
      _GoalType(key: 'mantra', label: '持咒', unit: '遍', icon: Icons.notifications_none_outlined),
      _GoalType(key: 'copying', label: '抄经', unit: '篇', icon: Icons.edit_outlined),
      _GoalType(key: 'meditation', label: '静坐', unit: '分钟', icon: Icons.self_improvement_outlined),
      ...customs.map((c) => _GoalType(
        key: c['key'].toString(),
        label: c['label'].toString(),
        unit: (c['unit'] ?? '遍').toString(),
        icon: Icons.playlist_add,
      )),
    ];

    final goalsRaw = prefs.getString('checkin_goals') ?? '{}';
    final goalsJson = jsonDecode(goalsRaw) as Map<String, dynamic>;
    final goals = goalsJson.map((k, v) => MapEntry(k, double.tryParse(v.toString()) ?? 0));

    final raw = prefs.getString('checkin_records') ?? '[]';
    final records = jsonDecode(raw) as List<dynamic>;
    final totals = <String, double>{};
    for (final r in records) {
      final key = r['type'].toString();
      final amt = double.tryParse((r['amount'] ?? '1').toString()) ?? 1;
      totals[key] = (totals[key] ?? 0) + amt;
    }

    final details = _buildDetails(prefs);

    if (!mounted) return;
    setState(() {
      _types = types;
      _goals = goals;
      _totals = totals;
      _details = details;
    });
  }

  /// 读取每日功课配置，汇总各类型的具体内容（诵的经、持的咒、抄的经等），
  /// 只保留名称（数量由历史总量体现，不在此重复展示）。
  Map<String, List<String>> _buildDetails(SharedPreferences prefs) {
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

  Future<void> _setGoal(_GoalType t) async {
    final current = _goals[t.key] ?? 0;
    final ctrl = TextEditingController(text: current > 0 ? _fmt(current) : '');
    final result = await showDialog<dynamic>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('设置目标', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          style: TextStyle(color: _text),
          decoration: InputDecoration(
            labelText: '目标（${t.unit}）',
            labelStyle: TextStyle(color: _textSec),
            hintText: '如：100',
            hintStyle: TextStyle(color: _textHint),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: _primary)),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: _border)),
          ),
        ),
        actions: [
          if (current > 0)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'clear'),
              child: Text('清除目标', style: TextStyle(color: _textHint)),
            ),
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
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (result == 'clear') {
        _goals.remove(t.key);
      } else {
        _goals[t.key] = double.tryParse(result.toString()) ?? 0;
      }
    });
    await prefs.setString('checkin_goals', jsonEncode(_goals));
  }

  String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }

  void _showPrivacyToast(bool enabled) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final topInset = MediaQuery.of(ctx).padding.top;
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: EdgeInsets.only(top: topInset + kToolbarHeight + 10),
            child: Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: _primary,
                borderRadius: BorderRadius.circular(20),
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Text(
                    enabled ? '已开启，其他同修可查看你的功课' : '已关闭，其他同修不可查看你的功课',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (entry.mounted) entry.remove();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: const Text('打卡目标', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: _text),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: CheckInHistoryStats(entries: _historyStats),
          ),
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(16),
            ),
            child: SwitchListTile(
              value: _showCheckinOnHome,
              activeTrackColor: const Color(0xFF71867A),
              activeThumbColor: Colors.white,
              inactiveTrackColor: const Color(0xFFE8E2DA),
              inactiveThumbColor: const Color(0xFFBDB6AC),
              trackOutlineColor:
                  WidgetStateProperty.resolveWith((_) => Colors.transparent),
              onChanged: (v) async {
                setState(() => _showCheckinOnHome = v);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('privacy_show_checkin', v);
                await SyncService.instance.push();
                if (mounted) _showPrivacyToast(v);
              },
              title: const Text('允许他人查看我的功课',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600, color: _text)),
              subtitle: const Text(
                '开启后，其他同修在查看你的主页时可看到你的功课设置与目标',
                style: TextStyle(fontSize: 12, color: _textSec),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text('设定目标，并依据每天打卡累计进度', style: TextStyle(fontSize: 12, color: _textHint)),
          ),
          for (final t in _types) _buildTypeCard(t),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  /// 历史统计条目：各类型自使用以来累计的总量，并附每日功课的具体内容明细。
  List<CheckInStatEntry> get _historyStats => [
        for (final t in _types)
          if ((_totals[t.key] ?? 0) > 0)
            CheckInStatEntry(
                label: t.label,
                unit: t.unit,
                total: _totals[t.key] ?? 0,
                detail: _details[t.key] ?? const []),
      ];

  Widget _buildTypeCard(_GoalType t) {
    final goal = _goals[t.key] ?? 0;
    final total = _totals[t.key] ?? 0;
    final progress = goal > 0 ? (total / goal).clamp(0.0, 1.0) : 0.0;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
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
          Row(
            children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(color: _primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                child: Icon(t.icon, size: 17, color: const Color(0xFF71867A)),
              ),
              const SizedBox(width: 10),
              Text(t.label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _text)),
              const Spacer(),
              if (goal > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(color: _gold.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(12)),
                  child: Text('目标 ${_fmt(goal)}${t.unit}', style: TextStyle(fontSize: 12, color: _gold, fontWeight: FontWeight.w600)),
                )
              else
                Text('未设置目标', style: TextStyle(fontSize: 12, color: _textHint)),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: _border,
              valueColor: AlwaysStoppedAnimation<Color>(goal > 0 ? _primary : _textHint),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('已累计 ${_fmt(total)} ${t.unit}', style: TextStyle(fontSize: 12, color: _textSec)),
              const Spacer(),
              if (goal > 0)
                Text('${(progress * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _primary)),
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => _setGoal(t),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Text(goal > 0 ? '修改目标' : '设置目标', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _primary)),
            ),
          ),
        ],
      ),
    );
  }
}

class _GoalType {
  final String key;
  final String label;
  final String unit;
  final IconData icon;
  _GoalType({required this.key, required this.label, required this.unit, required this.icon});
}
