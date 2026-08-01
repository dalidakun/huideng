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

class CheckInSettingsPage extends StatefulWidget {
  const CheckInSettingsPage({super.key});

  @override
  State<CheckInSettingsPage> createState() => _CheckInSettingsPageState();
}

class _CheckInSettingsPageState extends State<CheckInSettingsPage> {
  List<_Item> _meditationItems = [];
  List<_NamedCountItem> _readingItems = [];
  List<_NamedCountItem> _mantraItems = [];
  List<_NamedCountItem> _buddhaItems = [];
  List<_Item> _copyingItems = [];
  List<_CustomType> _customTypes = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _meditationItems = _decodeItems(prefs.getString('setting_meditation_minutes'));
      if (_meditationItems.isEmpty) _meditationItems.add(_Item(ctrl: TextEditingController(text: '30')));
      _readingItems = _decodeReading(prefs.getString('setting_reading_titles'));
      if (_readingItems.isEmpty) _readingItems.add(_NamedCountItem(nameCtrl: TextEditingController(), countCtrl: TextEditingController()));
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
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => _CustomType(
      key: e['key'],
      label: e['label'] ?? '',
      unit: e['unit'] ?? '遍',
      count: (e['count'] ?? '').toString(),
    )).toList();
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
    for (final e in _mantraItems) {
      final n = e.name.trim();
      if (n.isNotEmpty) lines.add('持咒 $n ${e.count}遍');
    }
    for (final e in _buddhaItems) {
      final n = e.name.trim();
      if (n.isNotEmpty) lines.add('称名 $n ${e.count}遍');
    }
    for (final e in _copyingItems) {
      final v = e.text.trim();
      if (v.isNotEmpty) lines.add('抄经 $v');
    }
    for (final e in _customTypes) {
      final n = e.label.trim();
      if (n.isNotEmpty) lines.add('$n ${e.count.trim().isEmpty ? '0' : e.count.trim()}${e.unit}');
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
                    Icon(Icons.check_circle_outline, size: 16, color: _primaryLight),
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
    await prefs.setString('setting_mantra_items', jsonEncode(_mantraItems.map((e) => {'name': e.name, 'count': e.count}).toList()));
    await prefs.setString('setting_buddha_items', jsonEncode(_buddhaItems.map((e) => {'name': e.name, 'count': e.count}).toList()));
    await prefs.setString('setting_copying_titles', jsonEncode(_copyingItems.map((e) => e.text).toList()));
    await prefs.setString('custom_checkin_types', jsonEncode(_customTypes.map((e) => {'key': e.key, 'label': e.label, 'unit': e.unit, 'count': e.count}).toList()));
    if (mounted) _showSavedToast();
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

  Future<void> _addCustomType() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => const _AddTypeDialog(),
    );
    if (result != null) {
      final key = 'custom_${DateTime.now().millisecondsSinceEpoch}';
      setState(() {
        _customTypes.add(_CustomType(key: key, label: result['label']!, unit: result['unit']!));
      });
    }
  }

  void _removeCustomType(int index) {
    _customTypes[index].labelCtrl.dispose();
    _customTypes[index].countCtrl.dispose();
    setState(() => _customTypes.removeAt(index));
  }

  @override
  void dispose() {
    for (final e in _meditationItems) e.ctrl.dispose();
    for (final e in _readingItems) { e.nameCtrl.dispose(); e.countCtrl.dispose(); }
    for (final e in _mantraItems) { e.nameCtrl.dispose(); e.countCtrl.dispose(); }
    for (final e in _buddhaItems) { e.nameCtrl.dispose(); e.countCtrl.dispose(); }
    for (final e in _copyingItems) e.ctrl.dispose();
    for (final e in _customTypes) { e.labelCtrl.dispose(); e.countCtrl.dispose(); }
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
                Icon(icon, size: 22, color: _primary),
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
                color: isLast ? _primary : Colors.red.withValues(alpha: 0.7)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNamedCountRow(int index, List<_NamedCountItem> items) {
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
                  suffixText: '遍',
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
                color: isLast ? _primary : Colors.red.withValues(alpha: 0.7)),
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
        title: const Text('功课设置', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
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
            child: Icon(Icons.add, size: 20, color: _primary),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          _buildSection(Icons.self_improvement_outlined, '静坐', [
            ..._meditationItems.asMap().entries.map((e) => _buildItemRow(e.key, _meditationItems, '30', suffix: '分钟', keyboardType: TextInputType.number)),
          ]),
          _buildSection(Icons.chrome_reader_mode_outlined, '诵经', [
            ..._readingItems.asMap().entries.map((e) => _buildNamedCountRow(e.key, _readingItems)),
          ]),
          _buildSection(Icons.notifications_none_outlined, '持咒', [
            ..._mantraItems.asMap().entries.map((e) => _buildNamedCountRow(e.key, _mantraItems)),
          ]),
          _buildSection(Icons.spa_outlined, '称名', [
            ..._buddhaItems.asMap().entries.map((e) => _buildNamedCountRow(e.key, _buddhaItems)),
          ]),
          _buildSection(Icons.edit_outlined, '抄经', [
            ..._copyingItems.asMap().entries.map((e) => _buildItemRow(e.key, _copyingItems, '经书名')),
          ]),
          if (_customTypes.isNotEmpty) ...[
            ..._customTypes.asMap().entries.map((e) {
              final t = e.value;
              return _buildSection(Icons.playlist_add, t.label, [
                Padding(
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
                            controller: t.labelCtrl,
                            style: TextStyle(fontSize: 14, color: _text),
                            decoration: InputDecoration(
                              hintText: '名称',
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
                      Expanded(
                        flex: 2,
                        child: Container(
                          decoration: BoxDecoration(
                            color: _bg,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: TextField(
                            controller: t.countCtrl,
                            keyboardType: TextInputType.number,
                            style: TextStyle(fontSize: 14, color: _text),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(vertical: 10),
                              isDense: true,
                              suffixText: t.unit,
                              suffixStyle: TextStyle(fontSize: 13, color: _textHint),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => _removeCustomType(e.key),
                        child: Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.remove, size: 18, color: Colors.red.withValues(alpha: 0.7)),
                        ),
                      ),
                    ],
                  ),
                ),
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
  final TextEditingController labelCtrl;
  final TextEditingController countCtrl;
  final String unit;
  _CustomType({required this.key, required String label, required this.unit, String count = ''})
      : labelCtrl = TextEditingController(text: label),
        countCtrl = TextEditingController(text: count);
  String get label => labelCtrl.text;
  String get count => countCtrl.text;
}

class _AddTypeDialog extends StatefulWidget {
  const _AddTypeDialog();
  @override
  State<_AddTypeDialog> createState() => _AddTypeDialogState();
}

class _AddTypeDialogState extends State<_AddTypeDialog> {
  final _nameCtrl = TextEditingController();
  final _unitCtrl = TextEditingController(text: '遍');

  @override
  void dispose() {
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
            controller: _nameCtrl,
            style: TextStyle(color: _text),
            decoration: InputDecoration(
              labelText: '名称',
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
          if (_nameCtrl.text.trim().isEmpty) return;
          Navigator.pop(context, {
            'label': _nameCtrl.text.trim(),
            'unit': _unitCtrl.text.trim().isEmpty ? '遍' : _unitCtrl.text.trim(),
          });
        }, child: Text('添加', style: TextStyle(color: _primary, fontWeight: FontWeight.w600))),
      ],
    );
  }
}
