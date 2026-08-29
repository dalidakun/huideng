import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sync_service.dart';

import 'app_palette.dart';
Color get _primary => AppPalette.p.primary;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _border => AppPalette.p.border;
class CheckInSettingsPage extends StatefulWidget {
  const CheckInSettingsPage({super.key});

  @override
  State<CheckInSettingsPage> createState() => _CheckInSettingsPageState();
}

class _CheckInSettingsPageState extends State<CheckInSettingsPage> {
  List<_Item> _meditationItems = [];
  List<_NamedCountItem> _readingItems = [];
  List<_NamedCountItem> _nianfoItems = [];
  List<_NamedCountItem> _mantraItems = [];
  List<_NamedCountItem> _buddhaItems = [];
  List<_Item> _copyingItems = [];
  List<_CustomType> _customTypes = [];

  /// 是否允许完成当日全部功课后自动分享到菩提空间。
  bool _allowShareDailyCheckin = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _allowShareDailyCheckin = prefs.getBool('privacy_share_daily_checkin') ?? false;
      _meditationItems = _decodeItems(prefs.getString('setting_meditation_minutes'));
      if (_meditationItems.isEmpty) _meditationItems.add(_Item(ctrl: TextEditingController(text: '0')));
      _readingItems = _decodeReading(prefs.getString('setting_reading_titles'));
      if (_readingItems.isEmpty) _readingItems.add(_NamedCountItem(nameCtrl: TextEditingController(), countCtrl: TextEditingController()));
      _nianfoItems = _decodeNamedCount(prefs.getString('setting_nianfo_items'));
      if (_nianfoItems.isEmpty) _nianfoItems.add(_NamedCountItem(nameCtrl: TextEditingController(), countCtrl: TextEditingController(text: '108')));
      _mantraItems = _decodeNamedCount(prefs.getString('setting_mantra_items'));
      if (_mantraItems.isEmpty) _mantraItems.add(_NamedCountItem(nameCtrl: TextEditingController(), countCtrl: TextEditingController(text: '108')));
      _buddhaItems = _decodeNamedCount(prefs.getString('setting_buddha_items'));
      if (_buddhaItems.isEmpty) _buddhaItems.add(_NamedCountItem(nameCtrl: TextEditingController(), countCtrl: TextEditingController(text: '1000')));
      _copyingItems = _decodeItems(prefs.getString('setting_copying_titles'));
      if (_copyingItems.isEmpty) _copyingItems.add(_Item(ctrl: TextEditingController()));
      _customTypes = _decodeCustom(prefs.getString('custom_checkin_types'));
    });
  }

  List<_Item> _decodeItems(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => _Item(ctrl: TextEditingController(text: e.toString()))).toList();
  }

  List<_NamedCountItem> _decodeNamedCount(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => _NamedCountItem(
      nameCtrl: TextEditingController(text: e['name'] ?? ''),
      countCtrl: TextEditingController(text: (e['count'] ?? 108).toString()),
    )).toList();
  }

  List<_NamedCountItem> _decodeReading(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) {
      if (e is String) {
        return _NamedCountItem(nameCtrl: TextEditingController(text: e), countCtrl: TextEditingController());
      }
      return _NamedCountItem(
        nameCtrl: TextEditingController(text: e['name'] ?? ''),
        countCtrl: TextEditingController(text: (e['count'] ?? '').toString()),
      );
    }).toList();
  }

  List<_CustomType> _decodeCustom(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) {
        final itemList = e['items'] as List<dynamic>?;
        return _CustomType(
          key: e['key'].toString(),
          category: (e['category'] ?? e['label'] ?? '').toString(),
          unit: (e['unit'] ?? '遍').toString(),
          items: itemList == null
              ? null
              : [
                  for (final i in itemList)
                    {
                      'name': (i['name'] ?? '').toString(),
                      'count': (i['count'] ?? '').toString(),
                    }
                ],
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save() async {
    final lines = <String>[];
    for (final e in _meditationItems) {
      final v = e.text.trim();
      if (v.isNotEmpty) lines.add('静坐 $v分钟');
    }
    for (final e in _readingItems) {
      final n = e.name.trim();
      if (n.isNotEmpty) lines.add('诵经 $n ${e.count}遍');
    }
    for (final e in _nianfoItems) {
      final n = e.name.trim();
      if (n.isNotEmpty) lines.add('念佛 $n ${e.count}声');
    }
    for (final e in _mantraItems) {
      final n = e.name.trim();
      if (n.isNotEmpty) lines.add('持咒 $n ${e.count}遍');
    }
    for (final e in _buddhaItems) {
      final n = e.name.trim();
      if (n.isNotEmpty) lines.add('称名 $n ${e.count}声');
    }
    for (final e in _copyingItems) {
      final v = e.text.trim();
      if (v.isNotEmpty) lines.add('抄经 $v');
    }
    for (final e in _customTypes) {
      final cat = e.category.trim();
      if (cat.isEmpty) continue;
      for (final item in e.items) {
        final name = item.name.trim();
        if (name.isEmpty) continue;
        final cnt = item.count.trim();
        lines.add('$cat $name ${cnt.isEmpty ? '0' : cnt}${e.unit}');
      }
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('确认功课', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lines.map((l) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, size: 16, color: const Color(0xFF71867A)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(l, style: TextStyle(fontSize: 15, color: _text))),
                  ],
                ),
              )).toList(),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: TextStyle(color: _textSec))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('确认保存', style: TextStyle(color: _primary, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (confirmed != true) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('setting_meditation_minutes', jsonEncode(_meditationItems.map((e) => e.text).toList()));
    await prefs.setString('setting_reading_titles', jsonEncode(_readingItems.map((e) => {'name': e.name, 'count': e.count}).toList()));
    await prefs.setString('setting_nianfo_items', jsonEncode(_nianfoItems.map((e) => {'name': e.name, 'count': e.count}).toList()));
    await prefs.setString('setting_mantra_items', jsonEncode(_mantraItems.map((e) => {'name': e.name, 'count': e.count}).toList()));
    await prefs.setString('setting_buddha_items', jsonEncode(_buddhaItems.map((e) => {'name': e.name, 'count': e.count}).toList()));
    await prefs.setString('setting_copying_titles', jsonEncode(_copyingItems.map((e) => e.text).toList()));
    await prefs.setString('custom_checkin_types', jsonEncode(_customTypes.map((e) => {
      'key': e.key,
      'category': e.category,
      'label': e.category,
      'unit': e.unit,
      'count': '',
      'items': e.items
          .map((i) => {'name': i.name, 'count': i.count})
          .toList(),
    }).toList()));
    if (mounted) {
      _showSavedToast();
      // 确认保存后直接返回主页，不留在这个编辑设置页面。
      Navigator.popUntil(context, (route) => route.isFirst);
    }
  }

  void _showSavedToast() {
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle, size: 14, color: Colors.white),
                      const SizedBox(width: 5),
                      Text('功课已保存',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.none,
                          decorationColor: Colors.transparent,
                        )),
                    ],
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

  void _showShareToast(bool enabled) {
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
                    enabled ? '已开启，完成功课后将自动分享到菩提空间' : '已关闭，完成功课后不再自动分享',
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

  Future<void> _addCustomType() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => const _AddTypeDialog(),
    );
    if (result == null) return;
    final category = result['category']?.trim() ?? '';
    final name = result['name']?.trim() ?? '';
    final unit = result['unit'] ?? '遍';
    if (category.isEmpty || name.isEmpty) return;
    // 同类别复用同一分组，新增名称只需追加一个条目。
    final idx = _customTypes.indexWhere((t) => t.category == category);
    setState(() {
      if (idx >= 0) {
        _customTypes[idx].items.add(_CustomItem(name: name));
      } else {
        final key = 'custom_${DateTime.now().millisecondsSinceEpoch}';
        _customTypes.add(_CustomType(
            key: key,
            category: category,
            unit: unit,
            items: [
              {'name': name, 'count': ''}
            ]));
      }
    });
  }

  void _removeCustomType(int index) {
    final t = _customTypes[index];
    t.categoryCtrl.dispose();
    for (final item in t.items) {
      item.nameCtrl.dispose();
      item.countCtrl.dispose();
    }
    setState(() => _customTypes.removeAt(index));
  }

  @override
  void dispose() {
    for (final e in _meditationItems) e.ctrl.dispose();
    for (final e in _readingItems) { e.nameCtrl.dispose(); e.countCtrl.dispose(); }
    for (final e in _nianfoItems) { e.nameCtrl.dispose(); e.countCtrl.dispose(); }
    for (final e in _mantraItems) { e.nameCtrl.dispose(); e.countCtrl.dispose(); }
    for (final e in _buddhaItems) { e.nameCtrl.dispose(); e.countCtrl.dispose(); }
    for (final e in _copyingItems) e.ctrl.dispose();
    for (final e in _customTypes) {
      e.categoryCtrl.dispose();
      for (final item in e.items) {
        item.nameCtrl.dispose();
        item.countCtrl.dispose();
      }
    }
    super.dispose();
  }

  Widget _buildSection(IconData icon, String title, List<Widget> fields) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Row(
              children: [
                Icon(icon, size: 22, color: const Color(0xFF71867A)),
                const SizedBox(width: 10),
                Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: Column(children: fields),
          ),
        ],
      ),
    );
  }

  Widget _buildField(String label, TextEditingController ctrl, {String? suffix, TextInputType? keyboardType}) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text(label, style: TextStyle(fontSize: 14, color: _textSec))),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: _bg,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: ctrl,
                      keyboardType: keyboardType,
                      style: TextStyle(fontSize: 14, color: _text),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        isDense: true,
                      ),
                    ),
                  ),
                  if (suffix != null)
                    Text(suffix, style: TextStyle(fontSize: 13, color: _textHint)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemRow(int index, List<_Item> items, String hint, {String? suffix, TextInputType? keyboardType}) {
    final item = items[index];
    final isLast = index == items.length - 1;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: _bg,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                controller: item.ctrl,
                keyboardType: keyboardType,
                style: TextStyle(fontSize: 14, color: _text),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: TextStyle(color: _textHint, fontSize: 14),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  isDense: true,
                  suffixText: suffix,
                  suffixStyle: TextStyle(fontSize: 13, color: _textHint),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: isLast
                ? () => setState(() => items.add(_Item(ctrl: TextEditingController())))
                : () => setState(() => items.removeAt(index)),
            child: Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: isLast ? _primary.withValues(alpha: 0.1) : Colors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(isLast ? Icons.add : Icons.remove, size: 18,
                color: isLast ? const Color(0xFF71867A) : Colors.red.withValues(alpha: 0.7)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNamedCountRow(int index, List<_NamedCountItem> items,
      {String suffix = '遍'}) {
    final item = items[index];
    final isLast = index == items.length - 1;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Container(
              decoration: BoxDecoration(
                color: _bg,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                controller: item.nameCtrl,
                style: TextStyle(fontSize: 14, color: _text),
                decoration: InputDecoration(
                  hintText: '名称',
                  hintStyle: TextStyle(color: _textHint, fontSize: 14),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  isDense: true,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Container(
              decoration: BoxDecoration(
                color: _bg,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                controller: item.countCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(fontSize: 14, color: _text),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  isDense: true,
                  suffixText: suffix,
                  suffixStyle: TextStyle(fontSize: 13, color: _textHint),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: isLast
                ? () => setState(() => items.add(_NamedCountItem(nameCtrl: TextEditingController(), countCtrl: TextEditingController(text: '108'))))
                : () => setState(() => items.removeAt(index)),
            child: Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: isLast ? _primary.withValues(alpha: 0.1) : Colors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(isLast ? Icons.add : Icons.remove, size: 18,
                color: isLast ? const Color(0xFF71867A) : Colors.red.withValues(alpha: 0.7)),
            ),
          ),
        ],
      ),
    );
  }

  /// 自定义功课分组内的名称+数量行：支持追加/删除条目。
  Widget _buildCustomItemRow(_CustomType type, int index, String unit) {
    final item = type.items[index];
    final isLast = index == type.items.length - 1;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Container(
              decoration: BoxDecoration(
                color: _bg,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                controller: item.nameCtrl,
                style: TextStyle(fontSize: 14, color: _text),
                decoration: InputDecoration(
                  hintText: '名称',
                  hintStyle: TextStyle(color: _textHint, fontSize: 14),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  isDense: true,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Container(
              decoration: BoxDecoration(
                color: _bg,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                controller: item.countCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(fontSize: 14, color: _text),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  isDense: true,
                  suffixText: unit,
                  suffixStyle: TextStyle(fontSize: 13, color: _textHint),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: isLast
                ? () => setState(() => type.items.add(_CustomItem()))
                : () => setState(() => type.items.removeAt(index)),
            child: Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: isLast
                    ? _primary.withValues(alpha: 0.1)
                    : Colors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(isLast ? Icons.add : Icons.remove, size: 18,
                color: isLast
                    ? const Color(0xFF71867A)
                    : Colors.red.withValues(alpha: 0.7)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: Text('功课设置', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: _text),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 26),
            child: GestureDetector(
              onTap: _save,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
                decoration: BoxDecoration(
                  color: _primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text('保存', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _primary)),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: SizedBox(
          width: 42, height: 42,
          child: FloatingActionButton(
            onPressed: _addCustomType,
            heroTag: 'settings_fab',
            backgroundColor: _card,
            elevation: 8,
            highlightElevation: 12,
            shape: const CircleBorder(),
            child: Icon(Icons.add, size: 20, color: const Color(0xFF71867A)),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(16),
            ),
            child: SwitchListTile(
              value: _allowShareDailyCheckin,
              activeTrackColor: const Color(0xFF71867A),
              activeThumbColor: Colors.white,
              inactiveTrackColor: AppPalette.p.borderSoft,
              inactiveThumbColor: AppPalette.p.muted,
              trackOutlineColor:
                  WidgetStateProperty.resolveWith((_) => Colors.transparent),
              onChanged: (v) async {
                setState(() => _allowShareDailyCheckin = v);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('privacy_share_daily_checkin', v);
                await SyncService.instance.push();
                if (mounted) _showShareToast(v);
              },
              title: Text('分享每日功课到菩提空间',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600, color: _text)),
              subtitle: Text(
                '开启后，完成当日全部功课时自动以笔记形式分享到菩提空间',
                style: TextStyle(fontSize: 12, color: _textSec),
              ),
            ),
          ),
          _buildSection(Icons.chrome_reader_mode_outlined, '诵经', [
            ..._readingItems.asMap().entries.map((e) => _buildNamedCountRow(e.key, _readingItems)),
          ]),
          _buildSection(Icons.local_florist_outlined, '念佛', [
            ..._nianfoItems.asMap().entries.map((e) => _buildNamedCountRow(e.key, _nianfoItems, suffix: '声')),
          ]),
          _buildSection(Icons.spa_outlined, '称名', [
            ..._buddhaItems.asMap().entries.map((e) => _buildNamedCountRow(e.key, _buddhaItems)),
          ]),
          _buildSection(Icons.notifications_none_outlined, '持咒', [
            ..._mantraItems.asMap().entries.map((e) => _buildNamedCountRow(e.key, _mantraItems)),
          ]),
          _buildSection(Icons.edit_outlined, '抄经', [
            ..._copyingItems.asMap().entries.map((e) => _buildItemRow(e.key, _copyingItems, '经书名')),
          ]),
          _buildSection(Icons.self_improvement_outlined, '静坐', [
            ..._meditationItems.asMap().entries.map((e) => _buildItemRow(e.key, _meditationItems, '0', suffix: '分钟', keyboardType: TextInputType.number)),
          ]),
          if (_customTypes.isNotEmpty) ...[
            ..._customTypes.asMap().entries.map((e) {
              final idx = e.key;
              final t = e.value;
              return _buildSection(Icons.menu, '自定义', [
                // 类别行
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: _bg,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: TextField(
                            controller: t.categoryCtrl,
                            style: TextStyle(fontSize: 14, color: _text),
                            decoration: InputDecoration(
                              hintText: '类别（如：读经）',
                              hintStyle: TextStyle(color: _textHint, fontSize: 14),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(vertical: 10),
                              isDense: true,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => _removeCustomType(idx),
                        child: Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.delete_outline, size: 18, color: Colors.red.withValues(alpha: 0.7)),
                        ),
                      ),
                    ],
                  ),
                ),
                // 该类别的各名称行
                ...t.items.asMap().entries
                    .map((it) => _buildCustomItemRow(t, it.key, t.unit)),
              ]);
            }),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _Item {
  final TextEditingController ctrl;
  _Item({required this.ctrl});
  String get text => ctrl.text;
}

class _NamedCountItem {
  final TextEditingController nameCtrl;
  final TextEditingController countCtrl;
  _NamedCountItem({required this.nameCtrl, required this.countCtrl});
  String get name => nameCtrl.text;
  int get count => int.tryParse(countCtrl.text) ?? 0;
}

class _CustomType {
  final String key;
  final TextEditingController categoryCtrl;
  final String unit;
  final List<_CustomItem> items;
  _CustomType({
    required this.key,
    required String category,
    required this.unit,
    List<Map<String, String>>? items,
  })  : categoryCtrl = TextEditingController(text: category),
        items = (items == null || items.isEmpty)
            ? [_CustomItem()]
            : items
                .map((e) => _CustomItem(
                    name: e['name'] ?? '', count: e['count'] ?? ''))
                .toList();
  String get category => categoryCtrl.text;
}

class _CustomItem {
  final TextEditingController nameCtrl;
  final TextEditingController countCtrl;
  _CustomItem({String name = '', String count = ''})
      : nameCtrl = TextEditingController(text: name),
        countCtrl = TextEditingController(text: count);
  String get name => nameCtrl.text;
  String get count => countCtrl.text;
}

class _AddTypeDialog extends StatefulWidget {
  const _AddTypeDialog();
  @override
  State<_AddTypeDialog> createState() => _AddTypeDialogState();
}

class _AddTypeDialogState extends State<_AddTypeDialog> {
  final _categoryCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _unitCtrl = TextEditingController(text: '遍');

  @override
  void dispose() {
    _categoryCtrl.dispose();
    _nameCtrl.dispose();
    _unitCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('添加新功课', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _categoryCtrl,
            style: TextStyle(color: _text),
            decoration: InputDecoration(
              labelText: '类别',
              hintText: '如：读经',
              hintStyle: TextStyle(color: _textHint),
              labelStyle: TextStyle(color: _textSec),
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: _primary)),
              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: _border)),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            style: TextStyle(color: _text),
            decoration: InputDecoration(
              labelText: '名称',
              hintText: '如：金刚经',
              hintStyle: TextStyle(color: _textHint),
              labelStyle: TextStyle(color: _textSec),
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: _primary)),
              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: _border)),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _unitCtrl,
            style: TextStyle(color: _text),
            decoration: InputDecoration(
              labelText: '单位',
              hintText: '如：遍、声、分钟、次',
              hintStyle: TextStyle(color: _textHint),
              labelStyle: TextStyle(color: _textSec),
              focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: _primary)),
              enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: _border)),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('取消', style: TextStyle(color: _textSec))),
        TextButton(onPressed: () {
          if (_categoryCtrl.text.trim().isEmpty || _nameCtrl.text.trim().isEmpty) return;
          Navigator.pop(context, {
            'category': _categoryCtrl.text.trim(),
            'name': _nameCtrl.text.trim(),
            'unit': _unitCtrl.text.trim().isEmpty ? '遍' : _unitCtrl.text.trim(),
          });
        }, child: Text('添加', style: TextStyle(color: _primary, fontWeight: FontWeight.w600))),
      ],
    );
  }
}
