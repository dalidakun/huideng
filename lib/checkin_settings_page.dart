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
  List<_Item> _readingItems = [];
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
      _readingItems = _decodeItems(prefs.getString('setting_reading_titles'));
      if (_readingItems.isEmpty) _readingItems.add(_Item(ctrl: TextEditingController()));
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

  List<_CustomType> _decodeCustom(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => _CustomType(key: e['key'], label: e['label'], icon: e['icon'])).toList();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('setting_meditation_minutes', jsonEncode(_meditationItems.map((e) => e.text).toList()));
    await prefs.setString('setting_reading_titles', jsonEncode(_readingItems.map((e) => e.text).toList()));
    await prefs.setString('setting_mantra_items', jsonEncode(_mantraItems.map((e) => {'name': e.name, 'count': e.count}).toList()));
    await prefs.setString('setting_buddha_items', jsonEncode(_buddhaItems.map((e) => {'name': e.name, 'count': e.count}).toList()));
    await prefs.setString('setting_copying_titles', jsonEncode(_copyingItems.map((e) => e.text).toList()));
    await prefs.setString('custom_checkin_types', jsonEncode(_customTypes.map((e) => {'key': e.key, 'label': e.label, 'icon': e.icon}).toList()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('设置已保存', style: TextStyle(color: _card)),
          backgroundColor: _primary, behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _addCustomType() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => const _AddTypeDialog(),
    );
    if (result != null) {
      final key = 'custom_${DateTime.now().millisecondsSinceEpoch}';
      setState(() {
        _customTypes.add(_CustomType(key: key, label: result['label']!, icon: result['icon']!));
      });
    }
  }

  void _removeCustomType(int index) {
    _customTypes[index].ctrl.dispose();
    setState(() => _customTypes.removeAt(index));
  }

  @override
  void dispose() {
    for (final e in _meditationItems) e.ctrl.dispose();
    for (final e in _readingItems) e.ctrl.dispose();
    for (final e in _mantraItems) { e.nameCtrl.dispose(); e.countCtrl.dispose(); }
    for (final e in _buddhaItems) { e.nameCtrl.dispose(); e.countCtrl.dispose(); }
    for (final e in _copyingItems) e.ctrl.dispose();
    for (final e in _customTypes) e.ctrl.dispose();
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
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 80),
        child: SizedBox(
          width: 36, height: 36,
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
            ..._readingItems.asMap().entries.map((e) => _buildItemRow(e.key, _readingItems, '经书名')),
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
            Container(
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
                        Icon(Icons.playlist_add, size: 22, color: _primary),
                        const SizedBox(width: 10),
                        Text('自定义', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                    child: Column(
                      children: _customTypes.asMap().entries.map((e) {
                        final idx = e.key;
                        final t = e.value;
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              children: [
                                Text(t.icon, style: TextStyle(fontSize: 18)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: _bg,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    padding: const EdgeInsets.symmetric(horizontal: 14),
                                    child: TextField(
                                      controller: t.ctrl,
                                      style: TextStyle(fontSize: 14, color: _text),
                                      decoration: InputDecoration(
                                        border: InputBorder.none,
                                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                                        isDense: true,
                                      ),
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
                                  child: Icon(Icons.remove, size: 18, color: Colors.red.withValues(alpha: 0.7)),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ],
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: _card,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: const Text('保存', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
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
  final TextEditingController ctrl;
  final String icon;
  _CustomType({required this.key, required String label, required this.icon}) : ctrl = TextEditingController(text: label);
  String get label => ctrl.text;
}

class _AddTypeDialog extends StatefulWidget {
  const _AddTypeDialog();
  @override
  State<_AddTypeDialog> createState() => _AddTypeDialogState();
}

class _AddTypeDialogState extends State<_AddTypeDialog> {
  final _nameCtrl = TextEditingController();
  final _icons = ['🙏', '📿', '🪷', '☸️', '🕉️', '🔥', '💧', '🌿', '🪐', '⭐', '🌙', '☀️', '⚡', '🎵', '🕯️'];
  String _selected = '🙏';

  @override
  void dispose() {
    _nameCtrl.dispose();
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _icons.map((ic) {
              final sel = ic == _selected;
              return GestureDetector(
                onTap: () => setState(() => _selected = ic),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: sel ? _primary.withValues(alpha: 0.1) : _bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: sel ? _primary : _border, width: sel ? 2 : 1),
                  ),
                  child: Text(ic, style: TextStyle(fontSize: 22)),
                ),
              );
            }).toList(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('取消', style: TextStyle(color: _textSec))),
        TextButton(onPressed: () {
          if (_nameCtrl.text.trim().isEmpty) return;
          Navigator.pop(context, {'label': _nameCtrl.text.trim(), 'icon': _selected});
        }, child: Text('添加', style: TextStyle(color: _primary, fontWeight: FontWeight.w600))),
      ],
    );
  }
}
