import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'dedication_store.dart';
import 'dedication_templates.dart';

/// 打开「功德回向」抽屉：自底部上滑展开，固定占屏幕 90% 高。
///
/// 顶部为回向输入框，下方为可点击填入的回向模板，以及「定时自动更换」设置。
/// 返回保存后当前生效的回向文本；取消返回 null。
Future<String?> showDedicationSheet(
  BuildContext context, {
  required String defaultText,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppPalette.p.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.9,
      child: _DedicationSheet(defaultText: defaultText),
    ),
  );
}

/// 弹出「定时回向」编辑抽屉：返回填写结果；取消返回 null。
Future<DedicationPlan?> _openPlanEditor(
  BuildContext context, {
  DedicationPlan? initial,
}) {
  return showModalBottomSheet<DedicationPlan>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppPalette.p.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.88,
      child: _PlanEditor(initial: initial),
    ),
  );
}

class _DedicationSheet extends StatefulWidget {
  final String defaultText;

  const _DedicationSheet({required this.defaultText});

  @override
  State<_DedicationSheet> createState() => _DedicationSheetState();
}

class _DedicationSheetState extends State<_DedicationSheet> {
  final TextEditingController _ctrl = TextEditingController();
  List<DedicationPlan> _plans = [];
  SharedPreferences? _prefs;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // 输入内容变化时刷新模板的「已添加」对号状态。
    _ctrl.addListener(_onTextChanged);
    _load();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _prefs = prefs;
    _ctrl.text = DedicationStore.base(prefs);
    setState(() {
      _plans = DedicationStore.schedule(prefs);
      _loading = false;
    });
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTextChanged);
    _ctrl.dispose();
    super.dispose();
  }

  /// 右上角加号 / 对号切换：已添加则清空，未添加则填入该模板。
  void _toggleTemplate(DedicationTemplate t) {
    final selected = _ctrl.text.trim() == t.text.trim();
    setState(() {
      if (selected) {
        _ctrl.clear();
      } else {
        _ctrl.text = t.text;
        _ctrl.selection = TextSelection.collapsed(offset: t.text.length);
      }
    });
  }

  Future<void> _addPlan() async {
    final plan = await _openPlanEditor(context);
    if (plan == null || !mounted) return;
    setState(() {
      _plans = [..._plans, plan]..sort((a, b) => a.date.compareTo(b.date));
    });
  }

  Future<void> _editPlan(int index) async {
    final plan = await _openPlanEditor(context, initial: _plans[index]);
    if (plan == null || !mounted) return;
    setState(() {
      final list = [..._plans];
      list[index] = plan;
      _plans = list..sort((a, b) => a.date.compareTo(b.date));
    });
  }

  Future<void> _deletePlan(int index) async {
    final p = AppPalette.p;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        title: Text('删除该定时回向？',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: p.text)),
        content: Text('删除后不再按该日期自动更换回向。',
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
    setState(() {
      _plans = [..._plans]..removeAt(index);
    });
  }

  Future<void> _save() async {
    final prefs = _prefs;
    if (prefs == null) return;
    var base = _ctrl.text.trim();
    if (base.isEmpty && _plans.isEmpty) base = widget.defaultText;
    await DedicationStore.save(prefs, base, _plans);
    final effective = DedicationStore.effective(prefs);
    if (!mounted) return;
    Navigator.pop(context, effective.isEmpty ? widget.defaultText : effective);
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
          _header(p, '功课回向', () => Navigator.pop(context)),
          Expanded(
            child: _loading
                ? Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: p.accent),
                    ),
                  )
                : _buildBody(p),
          ),
          _footer(p, onCancel: () => Navigator.pop(context), onSave: _save),
        ],
      ),
    );
  }

  Widget _buildBody(PaletteData p) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
      children: [
        _sectionLabel(p, '当前回向'),
        const SizedBox(height: 8),
        TextField(
          controller: _ctrl,
          minLines: 3,
          maxLines: 8,
          style: TextStyle(fontSize: 14, color: p.text, height: 1.6),
          decoration: InputDecoration(
            hintText: widget.defaultText,
            hintStyle: TextStyle(fontSize: 13, color: p.textHint),
            filled: true,
            fillColor: AppPalette.instance.isPlain
                ? const Color(0xFFF5F5F5)
                : p.tintBg,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: p.border)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: p.border)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: p.accent, width: 1.4)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
        const SizedBox(height: 6),
        _hint(p, '未设置定时更换时使用此回向；点击下方模板可自动填入。'),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: _sectionLabel(p, '定时自动更换')),
            TextButton.icon(
              onPressed: _addPlan,
              style: TextButton.styleFrom(
                foregroundColor: p.primary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (_plans.isEmpty)
          _emptyPlans(p)
        else
          ..._buildPlanTiles(p),
        const SizedBox(height: 20),
        Divider(color: p.divider, height: 1),
        const SizedBox(height: 16),
        _sectionLabel(p, '回向模板'),
        const SizedBox(height: 4),
        _hint(p, '点击任意模板，自动填入上方输入框；点击分组标题可展开或收起。'),
        const SizedBox(height: 12),
        _GroupedTemplates(
          currentText: _ctrl.text,
          onToggle: _toggleTemplate,
        ),
      ],
    );
  }

  List<Widget> _buildPlanTiles(PaletteData p) {
    final active = DedicationStore.activePlan(_plans);
    final next = DedicationStore.nextPlan(_plans);
    return [
      for (var i = 0; i < _plans.length; i++)
        _planTile(
          p,
          _plans[i],
          isActive: active != null &&
              active.date == _plans[i].date &&
              active.text == _plans[i].text,
          isNext: next != null &&
              next.date == _plans[i].date &&
              next.text == _plans[i].text,
          onEdit: () => _editPlan(i),
          onDelete: () => _deletePlan(i),
        ),
    ];
  }

  Widget _planTile(
    PaletteData p,
    DedicationPlan plan, {
    required bool isActive,
    required bool isNext,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: AppPalette.instance.isPlain ? const Color(0xFFF5F5F5) : p.tintBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isActive ? p.accent : p.border,
            width: isActive ? 1.2 : 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.event_available_outlined,
              size: 18, color: isActive ? p.accent : p.textHint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(plan.date,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: p.text)),
                    const SizedBox(width: 8),
                    if (isActive) _badge(p, '生效中', p.accent)
                    else if (isNext) _badge(p, '待生效', p.textHint),
                  ],
                ),
                const SizedBox(height: 4),
                Text(plan.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 12, color: p.textSec, height: 1.5)),
              ],
            ),
          ),
          IconButton(
            onPressed: onEdit,
            icon: Icon(Icons.edit_outlined, size: 18, color: p.textSec),
            splashRadius: 20,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline, size: 18, color: p.textSec),
            splashRadius: 20,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _emptyPlans(PaletteData p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: AppPalette.instance.isPlain ? const Color(0xFFF5F5F5) : p.tintBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.schedule, size: 18, color: p.textHint),
          const SizedBox(width: 10),
          Expanded(
            child: _hint(p, '设置一个生效日期与回向内容，到达该日期后自动改用对应回向。'),
          ),
        ],
      ),
    );
  }
}

class _PlanEditor extends StatefulWidget {
  final DedicationPlan? initial;

  const _PlanEditor({this.initial});

  @override
  State<_PlanEditor> createState() => _PlanEditorState();
}

class _PlanEditorState extends State<_PlanEditor> {
  late String _date;
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _date = widget.initial?.date ?? DedicationStore.dateKey(DateTime.now());
    _ctrl = TextEditingController(text: widget.initial?.text ?? '');
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final first = DateTime(now.year - 2, 1, 1);
    final last = DateTime(now.year + 10, 12, 31);
    var initial = DedicationStore.parseDate(_date) ?? now;
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: '选择生效日期',
      cancelText: '取消',
      confirmText: '确定',
      fieldLabelText: '生效日期',
    );
    if (picked == null || !mounted) return;
    setState(() => _date = DedicationStore.dateKey(picked));
  }

  void _submit() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    Navigator.pop(context, DedicationPlan(date: _date, text: text));
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final canSave = _ctrl.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Column(
        children: [
          _dragHandle(p),
          _header(
            p,
            widget.initial == null ? '添加定时回向' : '编辑定时回向',
            () => Navigator.pop(context),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
              children: [
                _sectionLabel(p, '生效日期'),
                const SizedBox(height: 8),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: AppPalette.instance.isPlain
                          ? const Color(0xFFF5F5F5)
                          : p.tintBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: p.border),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.calendar_today_outlined,
                            size: 18, color: p.accent),
                        const SizedBox(width: 10),
                        Text(_date,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: p.text)),
                        const Spacer(),
                        Icon(Icons.chevron_right, size: 18, color: p.textHint),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                _hint(p, '到达该日期后，自动改用下面的回向内容。'),
                const SizedBox(height: 20),
                _sectionLabel(p, '回向内容'),
                const SizedBox(height: 8),
                TextField(
                  controller: _ctrl,
                  minLines: 4,
                  maxLines: 10,
                  style: TextStyle(fontSize: 14, color: p.text, height: 1.6),
                  decoration: InputDecoration(
                    hintText: '填写到达该日期后使用的回向',
                    hintStyle: TextStyle(fontSize: 13, color: p.textHint),
                    filled: true,
                    fillColor: AppPalette.instance.isPlain
                        ? const Color(0xFFF5F5F5)
                        : p.tintBg,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: p.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: p.border)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: p.accent, width: 1.4)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                  ),
                ),
                const SizedBox(height: 20),
                Divider(color: p.divider, height: 1),
                const SizedBox(height: 16),
                _sectionLabel(p, '从模板选择'),
                const SizedBox(height: 12),
                _GroupedTemplates(
                  currentText: _ctrl.text,
                  onToggle: (t) {
                    final selected = _ctrl.text.trim() == t.text.trim();
                    setState(() {
                      if (selected) {
                        _ctrl.clear();
                      } else {
                        _ctrl.text = t.text;
                        _ctrl.selection =
                            TextSelection.collapsed(offset: t.text.length);
                      }
                    });
                  },
                ),
              ],
            ),
          ),
          _footer(
            p,
            onCancel: () => Navigator.pop(context),
            onSave: _submit,
            enabled: canSave,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── 公共小组件 ───────────────────────────

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

Widget _header(PaletteData p, String title, VoidCallback onClose) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 10, 4),
    child: Row(
      children: [
        Icon(Icons.volunteer_activism_outlined, size: 20, color: p.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: p.text,
              letterSpacing: 0.5,
            ),
          ),
        ),
        IconButton(
          onPressed: onClose,
          icon: Icon(Icons.close, size: 20, color: p.textSec),
        ),
      ],
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

Widget _badge(PaletteData p, String text, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

Widget _footer(
  PaletteData p, {
  required VoidCallback onCancel,
  required VoidCallback onSave,
  bool enabled = true,
}) {
  return Container(
    decoration: BoxDecoration(
      color: p.card,
      border: Border(top: BorderSide(color: p.divider)),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: onCancel,
                style: OutlinedButton.styleFrom(
                  foregroundColor: p.textSec,
                  side: BorderSide(color: p.border),
                  minimumSize: const Size(0, 46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: enabled ? onSave : null,
                style: FilledButton.styleFrom(
                  backgroundColor: p.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: p.border,
                  disabledForegroundColor: p.textHint,
                  elevation: 0,
                  minimumSize: const Size(0, 46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _GroupedTemplates extends StatelessWidget {
  final String currentText;
  final ValueChanged<DedicationTemplate> onToggle;

  const _GroupedTemplates({
    required this.currentText,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < kDedicationGroups.length; i++)
          _TemplateGroup(
            group: kDedicationGroups[i],
            initiallyExpanded: i == 0,
            currentText: currentText,
            onToggle: onToggle,
          ),
      ],
    );
  }
}

class _TemplateGroup extends StatefulWidget {
  final DedicationGroup group;
  final bool initiallyExpanded;
  final String currentText;
  final ValueChanged<DedicationTemplate> onToggle;

  const _TemplateGroup({
    required this.group,
    required this.initiallyExpanded,
    required this.currentText,
    required this.onToggle,
  });

  @override
  State<_TemplateGroup> createState() => _TemplateGroupState();
}

class _TemplateGroupState extends State<_TemplateGroup> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.group.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                  ),
                  _badge(p, '${widget.group.count} 条', p.textHint),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.expand_more, size: 20, color: p.textSec),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Column(
              children: [
                Divider(color: p.divider, height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
                  child: Column(
                    children: [
                      for (final t in widget.group.templates)
                        _TemplateTile(
                          template: t,
                          selected: widget.currentText.trim() == t.text.trim(),
                          onTap: () => widget.onToggle(t),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            crossFadeState:
                _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
            sizeCurve: Curves.easeInOut,
          ),
        ],
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  final DedicationTemplate template;
  final bool selected;
  final VoidCallback onTap;

  const _TemplateTile({
    required this.template,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final baseFill =
        AppPalette.instance.isPlain ? const Color(0xFFF5F5F5) : p.tintBg;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: selected ? p.accent.withValues(alpha: 0.12) : baseFill,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    template.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                ),
                Icon(
                  selected ? Icons.check_circle : Icons.add_circle_outline,
                  size: 18,
                  color: p.accent,
                ),
              ],
            ),
            if (template.applicable.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '适用：${template.applicable}',
                style: TextStyle(fontSize: 11, color: p.textHint, height: 1.5),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              template.text,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: p.textSec, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}
