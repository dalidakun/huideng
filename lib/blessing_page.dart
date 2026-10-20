import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_palette.dart';
import 'blessing_service.dart';
import 'blessing_templates.dart';

// ─────────────────────────── 通用小组件 ───────────────────────────

Widget _dragHandle(PaletteData p) {
  return Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: p.border,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );
}

Widget _sectionLabel(PaletteData p, String text) {
  return Text(
    text,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: p.textSec,
      letterSpacing: 0.5,
    ),
  );
}

Widget _hint(PaletteData p, String text) {
  return Text(
    text,
    style: TextStyle(fontSize: 12, color: p.textHint, height: 1.5),
  );
}

InputDecoration _fieldDecoration(PaletteData p, String hint) {
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide.none,
  );
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(fontSize: 13, color: p.textHint),
    filled: true,
    fillColor: AppPalette.instance.isPlain ? const Color(0xFFF5F5F5) : p.tintBg,
    border: border,
    enabledBorder: border,
    focusedBorder: border,
    disabledBorder: border,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  );
}

Widget _tag(PaletteData p, String text, {Color? color}) {
  final c = color ?? p.accent;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c),
    ),
  );
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
}

String _fmtYmd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime? _parseYmd(String s) {
  final parts = s.split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

// ─────────────────────────── 新建 / 编辑抽屉 ───────────────────────────

/// 打开祈福编辑抽屉。保存成功返回 true；取消返回 null。
Future<bool?> showBlessingEditor(BuildContext context, {BlessingProject? initial}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppPalette.p.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92,
      child: _BlessingEditor(initial: initial),
    ),
  );
}

class _BlessingEditor extends StatefulWidget {
  final BlessingProject? initial;

  const _BlessingEditor({this.initial});

  @override
  State<_BlessingEditor> createState() => _BlessingEditorState();
}

class _MethodRow {
  final BlessingMethodOption? option;
  final String name;
  final String unit;
  bool on;
  final TextEditingController count;

  _MethodRow(this.option,
      {this.on = false, String? name, String? unit, String? count})
      : name = name ?? option?.category ?? '',
        unit = unit ?? option?.unit ?? '',
        count = TextEditingController(text: count ?? option?.defaultCount ?? '1');

  bool get isCustom => option == null;
}

class _CustomMethodResult {
  final String name;
  final String unit;
  final String count;

  const _CustomMethodResult(this.name, this.unit, this.count);
}

class _CustomMethodDialog extends StatefulWidget {
  const _CustomMethodDialog();

  @override
  State<_CustomMethodDialog> createState() => _CustomMethodDialogState();
}

class _CustomMethodDialogState extends State<_CustomMethodDialog> {
  final _nameCtrl = TextEditingController();
  final _unitCtrl = TextEditingController(text: '遍');
  final _countCtrl = TextEditingController(text: '1');

  @override
  void dispose() {
    _nameCtrl.dispose();
    _unitCtrl.dispose();
    _countCtrl.dispose();
    super.dispose();
  }

  void _done() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast(context, '请填写方式名称');
      return;
    }
    Navigator.pop(
      context,
      _CustomMethodResult(
        name,
        _unitCtrl.text.trim(),
        _countCtrl.text.trim().isEmpty ? '1' : _countCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return AlertDialog(
      backgroundColor: p.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('自定义祈福方式',
          style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w700, color: p.text)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              style: TextStyle(fontSize: 14, color: p.text),
              decoration: _fieldDecoration(p, '名称，如：拜忏'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _unitCtrl,
                    style: TextStyle(fontSize: 14, color: p.text),
                    decoration: _fieldDecoration(p, '单位，如：遍'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _countCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: TextStyle(fontSize: 14, color: p.text),
                    decoration: _fieldDecoration(p, '数量'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消', style: TextStyle(color: p.textSec)),
        ),
        FilledButton(
          onPressed: _done,
          style: FilledButton.styleFrom(backgroundColor: p.primary),
          child: const Text('添加'),
        ),
      ],
    );
  }
}

class _BlessingEditorState extends State<_BlessingEditor> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _targetCtrl;
  late final TextEditingController _dedicationCtrl;
  late final TextEditingController _daysCtrl;
  late final List<_MethodRow> _methods;
  final List<_MethodRow> _dropped = [];
  late String _startDate;
  late int _groupIndex;
  String _templateKey = '';
  bool _saving = false;
  bool _secTemplate = true;
  bool _secDays = false;
  bool _secMethods = false;
  bool _secDedication = false;

  @override
  void initState() {
    super.initState();
    final it = widget.initial;
    _titleCtrl = TextEditingController(text: it?.title ?? '');
    _targetCtrl = TextEditingController(text: it?.target ?? '');
    _dedicationCtrl = TextEditingController(text: it?.dedication ?? '');
    _daysCtrl = TextEditingController(text: '${it?.totalDays ?? 7}');
    _startDate = (it != null && it.startDate.isNotEmpty)
        ? it.startDate
        : BlessingService.today();
    _templateKey = it?.templateKey ?? '';
    _groupIndex = 0;
    _methods = [];
    final existing = it?.methods ?? const <BlessingMethod>[];
    for (final o in kBlessingMethodOptions) {
      BlessingMethod? hit;
      for (final m in existing) {
        final nm = m.name.isNotEmpty ? m.name : m.category;
        if (m.category == o.category || nm == o.category) {
          hit = m;
          break;
        }
      }
      _methods.add(_MethodRow(o,
          on: hit != null, count: hit?.count ?? o.defaultCount));
    }
    for (final m in existing) {
      final nm = m.name.isNotEmpty ? m.name : m.category;
      final isDefault = kBlessingMethodOptions
          .any((o) => o.category == m.category || o.category == nm);
      if (isDefault || nm.isEmpty) continue;
      _methods.add(_MethodRow(null,
          on: true, name: nm, unit: m.unit, count: m.count));
    }
    // 手动改事由时，同步刷新模板 chip 的选中态与折叠区的摘要。
    _titleCtrl.addListener(_onTitleChanged);
    _targetCtrl.addListener(_onTitleChanged);
    _dedicationCtrl.addListener(_onTitleChanged);
  }

  void _onTitleChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _titleCtrl.removeListener(_onTitleChanged);
    _targetCtrl.removeListener(_onTitleChanged);
    _dedicationCtrl.removeListener(_onTitleChanged);
    _titleCtrl.dispose();
    _targetCtrl.dispose();
    _dedicationCtrl.dispose();
    _daysCtrl.dispose();
    for (final m in _methods) {
      m.count.dispose();
    }
    for (final m in _dropped) {
      m.count.dispose();
    }
    super.dispose();
  }

  void _applyTemplate(BlessingTemplate t) {
    setState(() {
      _titleCtrl.text = t.title;
      _targetCtrl.text = t.target;
      _dedicationCtrl.text = t.dedication;
      _templateKey = t.title;
    });
  }

  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final first = DateTime(now.year - 1, 1, 1);
    final last = DateTime(now.year + 2, 12, 31);
    var initial = _parseYmd(_startDate) ?? now;
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: '选择起始日期',
      cancelText: '取消',
      confirmText: '确定',
      fieldLabelText: '起始日期',
    );
    if (picked == null || !mounted) return;
    setState(() => _startDate = _fmtYmd(picked));
  }

  List<BlessingMethod> _collectMethods() {
    final out = <BlessingMethod>[];
    for (final m in _methods) {
      if (!m.on || m.name.trim().isEmpty) continue;
      out.add(BlessingMethod(
        category: m.isCustom ? '' : m.name.trim(),
        name: m.isCustom ? m.name.trim() : '',
        count: m.count.text.trim(),
        unit: m.unit,
      ));
    }
    return out;
  }

  Future<void> _addCustomMethod() async {
    final r = await showDialog<_CustomMethodResult>(
      context: context,
      builder: (_) => const _CustomMethodDialog(),
    );
    if (r == null || !mounted) return;
    setState(() {
      _methods.add(_MethodRow(null,
          on: true, name: r.name, unit: r.unit, count: r.count));
      _secMethods = true;
    });
  }

  void _removeMethod(_MethodRow m) {
    setState(() {
      _methods.remove(m);
      _dropped.add(m);
    });
  }

  Future<void> _submit() async {
    if (_saving) return;
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _toast(context, '请填写祈福事由');
      return;
    }
    final days = (int.tryParse(_daysCtrl.text.trim()) ?? 7).clamp(1, 365);
    setState(() => _saving = true);
    try {
      final methods = _collectMethods();
      final it = widget.initial;
      if (it == null) {
        await BlessingService.instance.create(
          title: title,
          target: _targetCtrl.text.trim(),
          templateKey: _templateKey,
          dedication: _dedicationCtrl.text.trim(),
          totalDays: days,
          startDate: _startDate,
          methods: methods,
          isPrivate: false,
        );
      } else {
        await BlessingService.instance.update(
          it.id,
          title: title,
          target: _targetCtrl.text.trim(),
          templateKey: _templateKey,
          dedication: _dedicationCtrl.text.trim(),
          totalDays: days,
          startDate: _startDate,
          methods: methods,
          isPrivate: false,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Column(
        children: [
          _dragHandle(p),
          _editorHeader(p),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                  20, 14, 20, 24 + MediaQuery.of(context).padding.bottom),
              children: [
                _fold(
                  p,
                  title: '模板选择',
                  summary: _templateKey.isEmpty ? '选择分组与模板' : _templateKey,
                  open: _secTemplate,
                  onToggle: () => setState(() => _secTemplate = !_secTemplate),
                  child: _templateContent(p),
                ),
                _fold(
                  p,
                  title: '祈福天数',
                  summary: '${_daysCtrl.text.trim()} 天 · 起于 $_startDate',
                  open: _secDays,
                  onToggle: () => setState(() => _secDays = !_secDays),
                  child: _daysContent(p),
                ),
                _fold(
                  p,
                  title: '祈福方式',
                  summary: _methodsSummary(),
                  open: _secMethods,
                  onToggle: () => setState(() => _secMethods = !_secMethods),
                  child: _methodsContent(p),
                ),
                _fold(
                  p,
                  title: '回向文',
                  summary:
                      _dedicationCtrl.text.trim().isEmpty ? '未填写' : '已填写',
                  open: _secDedication,
                  onToggle: () =>
                      setState(() => _secDedication = !_secDedication),
                  child: TextField(
                    controller: _dedicationCtrl,
                    minLines: 3,
                    maxLines: 8,
                    style: TextStyle(fontSize: 14, color: p.text, height: 1.6),
                    decoration: _fieldDecoration(p, '愿以此功课功德，回向……'),
                  ),
                ),
                const SizedBox(height: 18),
                _sectionLabel(p, '祈福事由'),
                const SizedBox(height: 8),
                TextField(
                  controller: _titleCtrl,
                  minLines: 6,
                  maxLines: 14,
                  maxLength: 5000,
                  buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  cursorColor: p.primary,
                  style: TextStyle(fontSize: 14, color: p.text, height: 1.6),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText: '写下这次祈福的事由，可详细描述所缘的人或事……',
                    hintStyle: TextStyle(fontSize: 13, color: p.textHint),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _editorHeader(PaletteData p) {
    final editing = widget.initial != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 12, 2),
      child: Row(
        children: [
          Icon(Icons.volunteer_activism_outlined, size: 20, color: p.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              editing ? '编辑祈福' : '发起祈福',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: p.text,
                letterSpacing: 0.5,
              ),
            ),
          ),
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: p.textSec,
            ),
            child: const Text('取消', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: p.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: p.border,
              elevation: 0,
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Text('保存', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _fold(
    PaletteData p, {
    required String title,
    required String summary,
    required bool open,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: p.text)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 12, color: p.textHint),
                  ),
                ),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(Icons.expand_more, size: 20, color: p.textSec),
                ),
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: child,
          ),
      ],
    );
  }

  String _methodsSummary() {
    final n = _methods.where((m) => m.on && m.name.trim().isNotEmpty).length;
    return n == 0 ? '未选择' : '已选 $n 项';
  }

  Widget _daysContent(PaletteData p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final d in const [7, 21, 49, 100])
              _pill(p, '$d天', _daysCtrl.text.trim() == '$d',
                  () => setState(() => _daysCtrl.text = '$d')),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _daysCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => setState(() {}),
                style: TextStyle(fontSize: 14, color: p.text),
                decoration: _fieldDecoration(p, '自定义天数').copyWith(
                  suffixText: '天',
                  suffixStyle: TextStyle(fontSize: 13, color: p.textSec),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                onTap: _pickStartDate,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
                  decoration: BoxDecoration(
                    color: AppPalette.instance.isPlain
                        ? const Color(0xFFF5F5F5)
                        : p.tintBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.event_outlined, size: 16, color: p.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_startDate,
                            style: TextStyle(fontSize: 13, color: p.text)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _methodsContent(PaletteData p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hint(p, '勾选每日要做的功课，也可自定义添加。'),
        const SizedBox(height: 6),
        _buildMethodRows(p),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: _addCustomMethod,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppPalette.instance.isPlain
                  ? const Color(0xFFF3F3F3)
                  : p.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 16, color: p.primary),
                const SizedBox(width: 4),
                Text('自定义方式',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: p.primary)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _pill(
      PaletteData p, String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? p.primary.withValues(alpha: 0.12)
              : (AppPalette.instance.isPlain
                  ? const Color(0xFFF3F3F3)
                  : p.tintBg),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? p.primary : p.text,
          ),
        ),
      ),
    );
  }

  Widget _templateContent(PaletteData p) {
    final group = kBlessingGroups[_groupIndex];
    final currentTitle = _titleCtrl.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分组用「文字 + 下划线」样式，行距加大，避免下划线被挤在中间。
        Wrap(
          spacing: 18,
          runSpacing: 12,
          children: [
            for (int i = 0; i < kBlessingGroups.length; i++)
              _groupTab(p, kBlessingGroups[i].name, _groupIndex == i,
                  () => setState(() => _groupIndex = i)),
          ],
        ),
        const SizedBox(height: 18),
        // 模板用「无边框的浅色块」。
        Wrap(
          spacing: 8,
          runSpacing: 10,
          children: [
            for (final t in group.templates)
              _templateChip(p, t, currentTitle == t.title.trim()),
          ],
        ),
        const SizedBox(height: 16),
        Text('回向对象',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.textHint)),
        const SizedBox(height: 6),
        TextField(
          controller: _targetCtrl,
          style: TextStyle(fontSize: 14, color: p.text),
          decoration: _fieldDecoration(p, '如：我的父母 / 灾区同胞 / 法界众生'),
        ),
      ],
    );
  }

  Widget _groupTab(PaletteData p, String name, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              name,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? p.primary : p.textSec,
              ),
            ),
            const SizedBox(height: 6),
            // 选中时横杠铺满分组文字宽度，更醒目。
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 2,
              decoration: BoxDecoration(
                color: selected ? p.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _templateChip(PaletteData p, BlessingTemplate t, bool selected) {
    final bg = selected
        ? p.primary.withValues(alpha: 0.12)
        : (AppPalette.instance.isPlain ? const Color(0xFFF3F3F3) : p.tintBg);
    return GestureDetector(
      onTap: () => _applyTemplate(t),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Icons.check, size: 14, color: p.primary),
              const SizedBox(width: 4),
            ],
            Text(
              t.title,
              style: TextStyle(
                fontSize: 13,
                color: selected ? p.primary : p.text,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMethodRows(PaletteData p) {
    return Column(
      children: [
        for (final m in _methods)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Transform.scale(
                    scale: 0.82,
                    child: Checkbox(
                      value: m.on,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      side: const BorderSide(width: 1.4),
                      onChanged: (v) => setState(() => m.on = v ?? false),
                    ),
                  ),
                ),
                Expanded(
                  child: Text('${m.name}（${m.unit}）',
                      style: TextStyle(fontSize: 14, color: p.text)),
                ),
                if (m.isCustom)
                  GestureDetector(
                    onTap: () => _removeMethod(m),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.close, size: 15, color: p.textHint),
                    ),
                  ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 88,
                  child: TextField(
                    controller: m.count,
                    enabled: m.on,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: p.text),
                    decoration: _fieldDecoration(p, '数量').copyWith(
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────── 列表页 ───────────────────────────

class BlessingPage extends StatefulWidget {
  const BlessingPage({super.key});

  @override
  State<BlessingPage> createState() => _BlessingPageState();
}

class _BlessingPageState extends State<BlessingPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  bool _loadingMine = true;
  bool _loadingComm = true;
  String? _mineErr;
  String? _commErr;
  List<BlessingItem> _mine = [];
  List<BlessingItem> _comm = [];
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _loadMine();
    _loadComm();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _loadMine() async {
    setState(() {
      _loadingMine = true;
      _mineErr = null;
    });
    try {
      final list = await BlessingService.instance.listMine();
      if (!mounted) return;
      setState(() {
        _mine = list;
        _loadingMine = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mineErr = e.toString();
        _loadingMine = false;
      });
    }
  }

  Future<void> _loadComm() async {
    setState(() {
      _loadingComm = true;
      _commErr = null;
    });
    try {
      final list = await BlessingService.instance.listCommunity();
      if (!mounted) return;
      setState(() {
        _comm = list;
        _loadingComm = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _commErr = e.toString();
        _loadingComm = false;
      });
    }
  }

  Future<void> _create() async {
    final saved = await showBlessingEditor(context);
    if (saved == true) {
      _loadMine();
      _loadComm();
    }
  }

  Future<void> _openDetail(String id) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => BlessingDetailPage(id: id)));
    if (mounted) {
      _loadMine();
      _loadComm();
    }
  }

  Future<void> _bless(String id) async {
    if (_busy.contains(id)) return;
    _busy.add(id);
    try {
      final res = await BlessingService.instance.blessToday(id);
      if (!mounted) return;
      _toast(context, res.isDone ? '祈福圆满，随喜功德' : '今日祈福，功德已记');
      _loadMine();
      _loadComm();
    } catch (e) {
      if (mounted) _toast(context, e.toString());
    } finally {
      _busy.remove(id);
    }
  }

  Future<void> _toggleJoin(BlessingItem item) async {
    final id = item.project.id;
    if (_busy.contains(id)) return;
    _busy.add(id);
    final joined = item.progress?.joined == true;
    try {
      if (joined) {
        await BlessingService.instance.leave(id);
      } else {
        await BlessingService.instance.join(id);
      }
      if (!mounted) return;
      _loadMine();
      _loadComm();
    } catch (e) {
      if (mounted) _toast(context, e.toString());
    } finally {
      _busy.remove(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        title: Text('祈福共修',
            style: TextStyle(
                color: p.text, fontSize: 18, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: p.text),
          onPressed: () => Navigator.pop(context),
        ),
        bottom: TabBar(
          controller: _tab,
          indicatorColor: p.primary,
          labelColor: p.primary,
          unselectedLabelColor: p.textSec,
          labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          unselectedLabelStyle:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          tabs: const [Tab(text: '我的祈福'), Tab(text: '社区共修')],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildList(
            loading: _loadingMine,
            error: _mineErr,
            items: _mine,
            emptyTitle: '还没有祈福',
            emptyDesc: '发起一个祈福，把每日功课回向于此',
            onRetry: _loadMine,
            builder: (it) => _mineCard(p, it),
          ),
          _buildList(
            loading: _loadingComm,
            error: _commErr,
            items: _comm,
            emptyTitle: '暂无共修祈福',
            emptyDesc: '发起一个公开祈福，与大家一同祈愿',
            onRetry: _loadComm,
            builder: (it) => _commCard(p, it),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _create,
        backgroundColor: p.primary,
        foregroundColor: Colors.white,
        heroTag: 'blessing_fab',
        shape: const CircleBorder(),
        child: const Icon(Icons.add, size: 24),
      ),
    );
  }

  Widget _buildList({
    required bool loading,
    required String? error,
    required List<BlessingItem> items,
    required String emptyTitle,
    required String emptyDesc,
    required Future<void> Function() onRetry,
    required Widget Function(BlessingItem) builder,
  }) {
    final p = AppPalette.p;
    if (loading) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: p.accent),
        ),
      );
    }
    if (error != null) {
      return _centerNote(p, error, '重试', onRetry);
    }
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRetry,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.22),
            _emptyBlock(p, emptyTitle, emptyDesc),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRetry,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) => builder(items[i]),
      ),
    );
  }

  Widget _centerNote(PaletteData p, String msg, String action, Future<void> Function() onTap) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(msg, style: TextStyle(fontSize: 13, color: p.textSec)),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: () => onTap(), child: Text(action)),
        ],
      ),
    );
  }

  Widget _emptyBlock(PaletteData p, String title, String desc) {
    return Column(
      children: [
        Icon(Icons.volunteer_activism_outlined, size: 42, color: p.border),
        const SizedBox(height: 12),
        Text(title, style: TextStyle(fontSize: 15, color: p.textSec)),
        const SizedBox(height: 6),
        Text(desc, style: TextStyle(fontSize: 13, color: p.textHint)),
      ],
    );
  }

  Widget _cardShell(PaletteData p, {required Widget child, VoidCallback? onTap}) {
    return Material(
      color: p.card,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }

  Widget _progressBar(PaletteData p, int done, int total) {
    final value = total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 5,
              backgroundColor: p.border,
              valueColor: AlwaysStoppedAnimation<Color>(p.primary),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text('$done/$total',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: p.primary)),
      ],
    );
  }

  Widget _mineCard(PaletteData p, BlessingItem it) {
    final proj = it.project;
    final prog = it.progress ?? const BlessingProgress();
    final done = prog.isDone;
    final blessedToday = prog.doneToday();
    return _cardShell(
      p,
      onTap: () => _openDetail(proj.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(proj.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: p.text)),
              ),
              if (done) ...[
                const SizedBox(width: 6),
                _tag(p, '已圆满'),
              ],
            ],
          ),
          if (proj.target.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('回向：${proj.target}',
                style: TextStyle(fontSize: 12.5, color: p.textSec)),
          ],
          const SizedBox(height: 12),
          _progressBar(p, prog.doneCount, proj.totalDays),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('第 ${prog.doneCount}/${proj.totalDays} 天',
                  style: TextStyle(fontSize: 12.5, color: p.textSec)),
              const Spacer(),
              if (!done)
                _actionButton(
                  p,
                  blessedToday ? '今日已祈福' : '今日祈福',
                  enabled: !blessedToday && !_busy.contains(proj.id),
                  onTap: () => _bless(proj.id),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _commCard(PaletteData p, BlessingItem it) {
    final proj = it.project;
    final joined = it.progress?.joined == true;
    final done = it.progress?.isDone == true;
    return _cardShell(
      p,
      onTap: () => _openDetail(proj.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(proj.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: p.text)),
              ),
              if (done) _tag(p, '已圆满'),
            ],
          ),
          if (proj.target.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('回向：${proj.target}',
                style: TextStyle(fontSize: 12.5, color: p.textSec)),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.groups_outlined, size: 15, color: p.textSec),
              const SizedBox(width: 5),
              Text('已有 ${proj.joinerCount} 人共修',
                  style: TextStyle(fontSize: 12.5, color: p.textSec)),
              const Spacer(),
              _actionButton(
                p,
                joined ? '已参与' : '参与共修',
                outline: !joined,
                enabled: !_busy.contains(proj.id),
                onTap: () => _toggleJoin(it),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionButton(
    PaletteData p,
    String label, {
    bool enabled = true,
    bool outline = false,
    required VoidCallback onTap,
  }) {
    final bg = outline ? Colors.transparent : p.primary;
    final fg = outline ? p.primary : Colors.white;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: p.primary),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
        ),
      ),
    );
  }
}

// ─────────────────────────── 详情页 ───────────────────────────

class BlessingDetailPage extends StatefulWidget {
  final String id;

  const BlessingDetailPage({super.key, required this.id});

  @override
  State<BlessingDetailPage> createState() => _BlessingDetailPageState();
}

class _BlessingDetailPageState extends State<BlessingDetailPage> {
  bool _loading = true;
  String? _error;
  BlessingDetail? _detail;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await BlessingService.instance.getById(widget.id);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _bless() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await BlessingService.instance.blessToday(widget.id);
      if (!mounted) return;
      _toast(context, res.isDone ? '祈福圆满，随喜功德' : '今日祈福，功德已记');
      await _load();
    } catch (e) {
      if (mounted) _toast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await BlessingService.instance.join(widget.id);
      await _load();
    } catch (e) {
      if (mounted) _toast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await BlessingService.instance.leave(widget.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _toast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    final d = _detail;
    if (d == null) return;
    final saved = await showBlessingEditor(context, initial: d.project);
    if (saved == true) _load();
  }

  Future<void> _delete() async {
    final p = AppPalette.p;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        title: Text('删除该祈福？',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: p.text)),
        content: Text('删除后，此祈福及其参与记录将一并移除。',
            style: TextStyle(fontSize: 13, color: p.textSec, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: p.textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: p.primary)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await BlessingService.instance.delete(widget.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _toast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final d = _detail;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        title: Text('祈福详情',
            style: TextStyle(
                color: p.text, fontSize: 18, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: p.text),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (d?.project.isOwner == true)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_horiz, color: p.text),
              onSelected: (v) {
                if (v == 'edit') _edit();
                if (v == 'delete') _delete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
        ],
      ),
      body: _loading
          ? Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: p.accent),
              ),
            )
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: TextStyle(fontSize: 13, color: p.textSec)),
                      const SizedBox(height: 10),
                      OutlinedButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _body(p, d!),
    );
  }

  Widget _body(PaletteData p, BlessingDetail d) {
    final proj = d.project;
    final prog = d.progress;
    final joined = prog?.joined == true;
    final done = prog?.isDone == true;
    final blessedToday = prog?.doneToday() ?? false;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(proj.title,
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700, color: p.text)),
              const SizedBox(height: 10),
              if (proj.target.isNotEmpty)
                _kv(p, Icons.person_outline, '回向', proj.target),
              _kv(p, Icons.groups_outlined, '共修', '已有 ${d.joinerCount} 人共修'),
              _kv(p, Icons.event_outlined, '天数',
                  '${proj.totalDays} 天 · 起于 ${proj.startDate}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _sectionLabel(p, '我的祈福'),
                  const Spacer(),
                  if (done) _tag(p, '已圆满'),
                ],
              ),
              const SizedBox(height: 12),
              if (!joined)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _hint(p, '参与后即可每日祈福打卡，与大家一同回向。'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _busy ? null : _join,
                      style: FilledButton.styleFrom(
                        backgroundColor: p.primary,
                        minimumSize: const Size(0, 46),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('参与共修'),
                    ),
                  ],
                )
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: proj.totalDays <= 0
                              ? 0
                              : ((prog?.doneCount ?? 0) / proj.totalDays)
                                  .clamp(0.0, 1.0),
                          minHeight: 6,
                          backgroundColor: p.border,
                          valueColor: AlwaysStoppedAnimation<Color>(p.primary),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('${prog?.doneCount ?? 0}/${proj.totalDays}',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: p.primary)),
                  ],
                ),
                const SizedBox(height: 14),
                if (!done)
                  FilledButton.icon(
                    onPressed: (blessedToday || _busy) ? null : _bless,
                    style: FilledButton.styleFrom(
                      backgroundColor: p.primary,
                      disabledBackgroundColor: p.border,
                      disabledForegroundColor: p.textHint,
                      minimumSize: const Size(0, 46),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.spa_outlined, size: 18),
                    label: Text(blessedToday ? '今日已祈福' : '今日祈福'),
                  ),
                if (proj.methods.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _sectionLabel(p, '祈福方式'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final m in proj.methods)
                        if (m.label.isNotEmpty) _tag(p, m.label),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _busy ? null : _leave,
                    style: TextButton.styleFrom(
                      foregroundColor: p.textSec,
                      minimumSize: const Size(0, 34),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('退出共修'),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (proj.dedication.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel(p, '回向文'),
                const SizedBox(height: 10),
                Text(proj.dedication,
                    style: TextStyle(fontSize: 14, color: p.text, height: 1.7)),
              ],
            ),
          ),
        ],
        if (joined) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel(p, '完成记录'),
                const SizedBox(height: 10),
                if ((prog?.doneDates.isEmpty ?? true))
                  _hint(p, '尚无打卡记录')
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final date in prog!.doneDates) _tag(p, date.substring(5)),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _kv(PaletteData p, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: p.textSec),
          const SizedBox(width: 8),
          Text('$label：',
              style: TextStyle(fontSize: 13, color: p.textSec)),
          Expanded(
            child: Text(value,
                style: TextStyle(fontSize: 13, color: p.text)),
          ),
        ],
      ),
    );
  }
}
