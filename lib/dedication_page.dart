import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'dedication_store.dart';
import 'dedication_templates.dart';

/// 打开「功课回向」抽屉：自底部上滑展开，固定占屏幕 90% 高。
///
/// 顶部为当前回向的正文与持续时间，下方为可点击填入的回向模板。
/// 当前回向保存后立即生效，持续天数结束后自动恢复为默认回向。
/// 返回保存后实际生效的回向文本；取消返回 null。
Future<String?> showDedicationSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppPalette.p.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const FractionallySizedBox(
      heightFactor: 0.9,
      child: _DedicationSheet(),
    ),
  );
}

/// 打开「回向历史」抽屉：列出所有已经结束的回向。
///
/// 每一条含回向正文、开始时间与持续天数；点「再次使用」返回该条，
/// 由调用方回填到编辑框。直接关闭返回 null。
Future<DedicationEntry?> showDedicationHistorySheet(BuildContext context) {
  return showModalBottomSheet<DedicationEntry>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppPalette.p.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const FractionallySizedBox(
      heightFactor: 0.8,
      child: _DedicationHistorySheet(),
    ),
  );
}

class _DedicationSheet extends StatefulWidget {
  const _DedicationSheet();

  @override
  State<_DedicationSheet> createState() => _DedicationSheetState();
}

class _DedicationSheetState extends State<_DedicationSheet> {
  final TextEditingController _ctrl = TextEditingController();
  final TextEditingController _daysCtrl = TextEditingController(text: '7');
  SharedPreferences? _prefs;
  DedicationEntry? _entry;
  bool _loading = true;

  /// 允许的最长持续时间，避免误输入一个荒唐的数字。
  static const int _maxDays = 3650;

  /// 天数选项与自定义天数输入共用的胶囊高度。
  static const double _chipHeight = 34;

  @override
  void initState() {
    super.initState();
    // 输入内容变化时刷新模板的「已添加」对号与默认回向状态；
    // 天数变化时刷新生效至日期的预览。
    _ctrl.addListener(_onChanged);
    _daysCtrl.addListener(_onChanged);
    _load();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DedicationStore.dateKey(DateTime.now());
    // 旧版本的「定时回向」数据先迁移成当前回向，再清理废弃键。
    await DedicationStore.migrateLegacy(prefs, today: today);
    await DedicationStore.cleanupLegacyHistory(prefs, today: today);
    // 已过期的回向先记入历史并清空，编辑框回到当前的默认回向。
    final entry = await DedicationStore.reconcile(prefs, today: today);
    if (!mounted) return;
    final remain = DedicationStore.remainingDays(entry, today: today) ?? 0;
    _ctrl.text = entry?.text ?? '';
    // 还在期限内时预填剩余天数：不改内容直接保存，结束日期保持不变。
    _daysCtrl.text = '${remain > 0 ? remain : 7}';
    setState(() {
      _prefs = prefs;
      _entry = entry;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _daysCtrl.removeListener(_onChanged);
    _ctrl.dispose();
    _daysCtrl.dispose();
    super.dispose();
  }

  String get _text => _ctrl.text.trim();

  /// 正文为空或就是默认回向时，使用默认回向（长期有效）。
  bool get _usesDefault =>
      _text.isEmpty || _text == DedicationStore.defaultText;

  int? get _days {
    final v = int.tryParse(_daysCtrl.text.trim());
    if (v == null || v < 1 || v > _maxDays) return null;
    return v;
  }

  bool get _canSave => _usesDefault || _days != null;

  /// 当前是否有一条仍在期限内的回向（决定是否显示「终止」）。
  bool get _hasActiveEntry =>
      DedicationStore.isActive(_entry, today: _todayKey());

  String _todayKey() => DedicationStore.dateKey(DateTime.now());

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

  /// 打开回向历史：选中某条后回填到编辑框，可修改持续时间再保存。
  Future<void> _openHistory() async {
    final picked = await showDedicationHistorySheet(context);
    if (picked == null || !mounted) return;
    setState(() {
      _ctrl.text = picked.text;
      _ctrl.selection = TextSelection.collapsed(offset: picked.text.length);
      final days = picked.days;
      _daysCtrl.text = '${days > 0 ? days : 7}';
    });
  }

  /// 手动终止当前回向：确认后提前结束、记入历史并恢复默认回向。
  Future<void> _confirmTerminate() async {
    final p = AppPalette.p;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        title: Text('终止当前回向？',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: p.text)),
        content: Text('终止后当前回向立即结束，恢复为默认回向，并记入历史记录。',
            style: TextStyle(fontSize: 13, color: p.textSec, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: p.textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('终止', style: TextStyle(color: p.accentDeep)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final prefs = _prefs;
    if (prefs == null) return;
    await DedicationStore.terminate(prefs);
    if (!mounted) return;
    Navigator.pop(context, DedicationStore.defaultText);
  }

  Future<void> _save() async {
    final prefs = _prefs;
    if (prefs == null) return;
    // 默认回向不限期限：清掉旧的当前回向，之后一直显示默认回向。
    if (_usesDefault) {
      await DedicationStore.clear(prefs);
      if (!mounted) return;
      Navigator.pop(context, DedicationStore.defaultText);
      return;
    }
    final days = _days;
    if (days == null) return;
    await DedicationStore.saveCurrent(prefs, text: _text, days: days);
    if (!mounted) return;
    Navigator.pop(context, _text);
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
          _sheetHeader(
            p,
            '功课回向',
            trailing: IconButton(
              onPressed: _openHistory,
              tooltip: '回向历史',
              icon: Icon(Icons.history, size: 20, color: p.textSec),
            ),
          ),
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
          _footer(
            p,
            onCancel: () => Navigator.pop(context),
            onSave: _save,
            enabled: _canSave,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(PaletteData p) {
    final currentHint = _currentHintText();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
      children: [
        Row(
          children: [
            Expanded(child: _sectionLabel(p, '当前回向')),
            _statusBadge(p),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _ctrl,
          minLines: 3,
          maxLines: 8,
          style: TextStyle(fontSize: 14, color: p.text, height: 1.6),
          decoration: InputDecoration(
            hintText: DedicationStore.defaultText,
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
        const SizedBox(height: 4),
        // 生效中时这一行放「终止当前回向」，其余状态显示对应说明。
        if (_hasActiveEntry)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _confirmTerminate,
              style: TextButton.styleFrom(
                foregroundColor: p.accentDeep,
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.stop_circle_outlined, size: 16),
              label: const Text('终止当前回向',
                  style: TextStyle(fontSize: 12.5)),
            ),
          )
        else if (currentHint != null)
          _hint(p, currentHint),
        const SizedBox(height: 20),
        _buildDurationSection(p),
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

  /// 当前保存的那条回向的状态：生效中 / 已到期 / 默认回向。
  Widget _statusBadge(PaletteData p) {
    final entry = _entry;
    final today = _todayKey();
    if (entry == null) return _badge(p, '默认回向', p.textHint);
    if (DedicationStore.isExpired(entry, today: today)) {
      return _badge(p, '已到期 · 默认回向', p.textHint);
    }
    if (!entry.hasDuration) return _badge(p, '长期有效', p.textHint);
    final remain = DedicationStore.remainingDays(entry, today: today) ?? 0;
    return _badge(p, '生效中 · 剩 $remain 天', p.accent);
  }

  /// 文本输入框下方的状态说明。
  ///
  /// 生效中时不显示（那一行换成「终止当前回向」按钮），返回 null。
  String? _currentHintText() {
    final entry = _entry;
    final today = _todayKey();
    if (entry == null) {
      return '当前使用默认回向。填写内容并设置持续时间，保存后立即生效。';
    }
    if (DedicationStore.isExpired(entry, today: today)) {
      return '上次回向已于 ${DedicationStore.displayDate(entry.endDate)}结束，'
          '现在显示的是默认回向；重新填写内容并保存即可再次生效。';
    }
    if (!entry.hasDuration) {
      return '这条回向还没有设置持续时间。设置后，到期会自动恢复为默认回向。';
    }
    return null;
  }

  Widget _buildDurationSection(PaletteData p) {
    final enabled = !_usesDefault;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(p, _hasActiveEntry ? '剩余天数' : '持续时间'),
        const SizedBox(height: 8),
        if (!enabled)
          _hint(p, '默认回向长期有效，不需要设置期限。填写自己的回向内容后，即可设置持续天数。')
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final d in const [7, 21, 49, 108])
                _dayChip(p, d, enabled: true),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _daysInputChip(p),
              const SizedBox(width: 10),
              Expanded(child: _hint(p, _durationHintText())),
            ],
          ),
          const SizedBox(height: 8),
          _hint(p, '到期后自动恢复为默认回向（通用回向偈）；也可以提前终止。'),
        ],
      ],
    );
  }

  /// 自定义天数输入：做成和上方天数选项一样的胶囊大小，避免比选项更抢眼。
  Widget _daysInputChip(PaletteData p) {
    final custom = _days != null && !const [7, 21, 49, 108].contains(_days);
    return Container(
      height: _chipHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: custom
            ? p.accent.withValues(alpha: 0.16)
            : (AppPalette.instance.isPlain
                ? const Color(0xFFF5F5F5)
                : p.tintBg),
        borderRadius: BorderRadius.circular(_chipHeight / 2),
        border: Border.all(color: custom ? p.accent : p.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 34,
            child: TextField(
              controller: _daysCtrl,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.right,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: '7',
                hintStyle: TextStyle(fontSize: 13, color: p.textHint),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text('天', style: TextStyle(fontSize: 13, color: p.textSec)),
        ],
      ),
    );
  }

  Widget _dayChip(PaletteData p, int days, {required bool enabled}) {
    final selected = enabled && _days == days;
    return InkWell(
      onTap: enabled
          ? () {
              _daysCtrl.text = '$days';
              _daysCtrl.selection =
                  TextSelection.collapsed(offset: '$days'.length);
            }
          : null,
      borderRadius: BorderRadius.circular(_chipHeight / 2),
      child: Container(
        height: _chipHeight,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: !enabled
              ? p.border.withValues(alpha: 0.35)
              : selected
                  ? p.accent.withValues(alpha: 0.16)
                  : (AppPalette.instance.isPlain
                      ? const Color(0xFFF5F5F5)
                      : p.tintBg),
          borderRadius: BorderRadius.circular(_chipHeight / 2),
          border: Border.all(
            color: selected ? p.accent : p.border,
          ),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(
            '$days 天',
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: !enabled
                  ? p.textHint
                  : selected
                      ? p.accentDeep
                      : p.textSec,
            ),
          ),
        ),
      ),
    );
  }

  String _durationHintText() {
    if (_usesDefault) return '当前为默认回向，长期有效，不需要设置期限。';
    final days = _days;
    if (days == null) return '请填写 1～$_maxDays 之间的天数。';
    final now = DateTime.now();
    final endDate = DateTime(
      now.year,
      now.month,
      now.day + days - 1,
    );
    final endLabel =
        DedicationStore.displayDate(DedicationStore.dateKey(endDate));
    if (_hasActiveEntry) return '剩余 $days 天，至 $endLabel 结束。';
    return '共 $days 天，生效至 $endLabel。';
  }
}

/// 回向历史抽屉：列出所有已结束的回向（新→旧），可选中回填到编辑框。
class _DedicationHistorySheet extends StatefulWidget {
  const _DedicationHistorySheet();

  @override
  State<_DedicationHistorySheet> createState() =>
      _DedicationHistorySheetState();
}

class _DedicationHistorySheetState extends State<_DedicationHistorySheet> {
  List<DedicationEntry> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DedicationStore.dateKey(DateTime.now());
    // 万一抽屉打开期间跨天到期，先对账，保证刚结束的回向也在列表里。
    await DedicationStore.reconcile(prefs, today: today);
    // 去掉上一版误记的「还没结束」的回向。
    await DedicationStore.cleanupLegacyHistory(prefs, today: today);
    if (!mounted) return;
    setState(() {
      _items = DedicationStore.history(prefs);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Column(
      children: [
        _dragHandle(p),
        _sheetHeader(
          p,
          '回向历史',
          icon: Icons.history,
          trailing: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: Icon(Icons.close, size: 20, color: p.textSec),
          ),
        ),
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
              : _items.isEmpty
                  ? _empty(p)
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
                      children: [
                        _hint(p, '「再次使用」会把这条回向填回编辑框，可重新设置持续时间后保存。'),
                        const SizedBox(height: 12),
                        for (final e in _items) _historyTile(p, e),
                      ],
                    ),
        ),
      ],
    );
  }

  Widget _historyTile(PaletteData p, DedicationEntry entry) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color:
            AppPalette.instance.isPlain ? const Color(0xFFF5F5F5) : p.tintBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_note_outlined, size: 16, color: p.textHint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _rangeLabel(entry),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.textSec,
                  ),
                ),
              ),
              if (entry.isTerminated) ...[
                const SizedBox(width: 6),
                _badge(p, '已终止', p.accentDeep),
              ],
              if (entry.hasDuration) ...[
                const SizedBox(width: 6),
                _badge(p, '共 ${entry.days} 天', p.textHint),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            entry.text,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: p.text, height: 1.6),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => Navigator.pop(context, entry),
              style: TextButton.styleFrom(
                foregroundColor: p.primary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(Icons.restore, size: 16, color: p.primary),
              label: const Text('再次使用', style: TextStyle(fontSize: 12.5)),
            ),
          ),
        ],
      ),
    );
  }

  String _rangeLabel(DedicationEntry entry) {
    if (!entry.hasDuration) {
      return entry.startDate.isEmpty
          ? '未记录期限'
          : '${DedicationStore.displayFullDate(entry.startDate)} 起 · 未记录期限';
    }
    final start = entry.startDate.isEmpty
        ? ''
        : '${DedicationStore.displayFullDate(entry.startDate)} — ';
    return '$start${DedicationStore.displayDate(entry.endDate)}';
  }

  Widget _empty(PaletteData p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_toggle_off, size: 40, color: p.textHint),
            const SizedBox(height: 14),
            Text(
              '还没有回向历史',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: p.textSec,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '当前回向到期或被终止后，会记录在这里。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: p.textHint,
                height: 1.6,
              ),
            ),
          ],
        ),
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

Widget _sheetHeader(
  PaletteData p,
  String title, {
  Widget? trailing,
  IconData icon = Icons.volunteer_activism_outlined,
}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 10, 4),
    child: Row(
      children: [
        Icon(icon, size: 20, color: p.accent),
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
        if (trailing != null) trailing,
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
