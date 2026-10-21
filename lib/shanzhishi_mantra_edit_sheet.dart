import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'collapsible_bottom_sheet.dart';
import 'note_sutra_links.dart';
import 'shanzhishi_edit_sheet.dart';
import 'shanzhishi_mantra_store.dart';

/// 保存时遇到重复 / 相似密咒，用户在合并提示里选的处理方式：
/// [targetName] 非空 = 与这条并成一条（保留它的名字）；
/// 为空 = 「保存两者」，各存各的（同名也各算一条）。
class _MantraPick {
  const _MantraPick(this.targetName);
  final String targetName;
}

/// 注音 / 备注对话框的结果：两个字段各自返回，未编辑的那项原样带回。
class MantraAnnotationResult {
  const MantraAnnotationResult({
    required this.ruby,
    required this.note,
  });

  final String ruby;
  final String note;
}

/// 注音 / 备注输入框。自己持有输入控制器，随对话框一起释放。
class MantraAnnotationDialog extends StatefulWidget {
  const MantraAnnotationDialog({
    super.key,
    required this.quoted,
    required this.initialRuby,
    required this.initialNote,
    required this.focusRuby,
    required this.canDelete,
  });

  final String quoted;
  final String initialRuby;
  final String initialNote;
  final bool focusRuby;
  final bool canDelete;

  @override
  State<MantraAnnotationDialog> createState() =>
      _MantraAnnotationDialogState();
}

class _MantraAnnotationDialogState extends State<MantraAnnotationDialog> {
  late final TextEditingController _rubyCtrl =
      TextEditingController(text: widget.initialRuby);
  late final TextEditingController _noteCtrl =
      TextEditingController(text: widget.initialNote);

  @override
  void dispose() {
    _rubyCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return AlertDialog(
      backgroundColor: p.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        widget.focusRuby ? '注音' : '备注',
        style:
            TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: p.text),
      ),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: p.tintBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '「${widget.quoted}」',
                  style: TextStyle(fontSize: 14, color: p.text, height: 1.5),
                ),
              ),
              const SizedBox(height: 14),
              // 注音与备注分开录入：点哪个工具就只改哪一项，另一项原样保留。
              if (widget.focusRuby)
                _annotationField(
                  key: const ValueKey('shanzhishi_mantra_ruby_input'),
                  controller: _rubyCtrl,
                  p: p,
                  label: '注音',
                  hint: '如：ōng ma ṇi pad me hūṃ',
                  autofocus: true,
                  maxLines: 1,
                )
              else
                _annotationField(
                  key: const ValueKey('shanzhishi_mantra_note_input'),
                  controller: _noteCtrl,
                  p: p,
                  label: '备注',
                  hint: '写下这段文字的备注（可多行）',
                  autofocus: true,
                  maxLines: 5,
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.canDelete)
          TextButton(
            key: const ValueKey('shanzhishi_mantra_annotation_delete'),
            onPressed: () => Navigator.pop(
              context,
              MantraAnnotationResult(
                ruby: widget.focusRuby ? '' : _rubyCtrl.text.trim(),
                note: widget.focusRuby ? _noteCtrl.text.trim() : '',
              ),
            ),
            child: Text('删除', style: TextStyle(color: p.accentDeep)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消', style: TextStyle(color: p.textSec)),
        ),
        TextButton(
          key: const ValueKey('shanzhishi_mantra_annotation_save'),
          onPressed: () => Navigator.pop(
            context,
            MantraAnnotationResult(
              ruby: _rubyCtrl.text.trim(),
              note: _noteCtrl.text.trim(),
            ),
          ),
          child: Text('保存', style: TextStyle(color: p.accentDeep)),
        ),
      ],
    );
  }

  static Widget _annotationField({
    required Key key,
    required TextEditingController controller,
    required PaletteData p,
    required String label,
    required String hint,
    required bool autofocus,
    required int maxLines,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style:
              TextStyle(fontSize: 12, color: p.textSec, letterSpacing: 0.5),
        ),
        const SizedBox(height: 6),
        TextField(
          key: key,
          controller: controller,
          autofocus: autofocus,
          maxLines: maxLines,
          minLines: maxLines > 1 ? 2 : 1,
          maxLength: maxLines > 1 ? 500 : 60,
          style: TextStyle(fontSize: 14, color: p.text, height: 1.5),
          decoration: InputDecoration(
            counterText: '',
            hintText: hint,
            hintStyle: TextStyle(fontSize: 13, color: p.textHint),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: p.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: p.accent),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          ),
        ),
      ],
    );
  }
}

/// 添加/编辑密咒面板：神咒名称、经文出处、神咒原文、人天利益四项
/// + 取消/添加（保存）。
/// 与【添加善知识】同款底部上拉面板：固定占屏幕九成高，标题与底部按钮钉住，
/// 中间整块可滚动；键盘弹出时整体让位，不会盖住输入区。
class ShanZhiShiMantraEditSheet extends StatefulWidget {
  /// 要编辑的密咒名；null = 添加新密咒。
  final String? editing;

  /// 要编辑的密咒内部键：同名密咒各改各的，不传时按名字找第一条。
  final String? editingKey;

  /// 新增时默认填入的经文出处（如从阅读页打开时传入当前经名，含卷）。
  final String? initialSource;

  /// 新增时默认填入的神咒原文（如从阅读页打开时传入选中文字）。
  final String? initialText;

  const ShanZhiShiMantraEditSheet({
    super.key,
    this.editing,
    this.editingKey,
    this.initialSource,
    this.initialText,
  });

  /// 弹出面板；保存成功返回（保存后的）密咒名，取消返回 null。
  /// 编辑时名称被删空保存 = 删除这条，返回空串。
  static Future<String?> show(
    BuildContext context, {
    String? editing,
    String? editingKey,
    String? initialSource,
    String? initialText,
    bool collapsible = false,
    String? collapsedTitle,
  }) {
    final sheet = ShanZhiShiMantraEditSheet(
      editing: editing,
      editingKey: editingKey,
      initialSource: initialSource,
      initialText: initialText,
    );
    if (collapsible) {
      return showCollapsibleBottomSheet<String>(
        context,
        collapsedTitle: collapsedTitle ?? (editing == null ? '添加神咒' : '编辑神咒'),
        builder: (_) => sheet,
      );
    }
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
        child: sheet,
      ),
    );
  }

  @override
  State<ShanZhiShiMantraEditSheet> createState() =>
      _ShanZhiShiMantraEditSheetState();
}

class _ShanZhiShiMantraEditSheetState extends State<ShanZhiShiMantraEditSheet> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _sourceCtrl = TextEditingController();
  final TextEditingController _textCtrl = TextEditingController();

  /// 人天利益：一部经对应一个输入区（各存各的），点选经文切换显示哪一个。
  /// 一条经文都没有时才用 [_flatCtrl]。
  late final Map<String, TextEditingController> _paraCtrls;

  /// 没有任何关联经文时的段落输入区；有经文时为 null。
  TextEditingController? _flatCtrl;

  /// 当前激活的经文。
  String? _activeSutra;

  bool _saving = false;

  /// 神咒原文上的注音 / 备注批注（保存时随原文一起写入）。
  List<MantraAnnotation> _annotations = [];

  /// 上一次的原文：输入变化时用它算出编辑区间，把批注位置跟着平移。
  String _lastText = '';

  /// 人天利益输入区：段间虚线的 Stack 锚点与量好的分界 y（与善知识页同款）。
  final GlobalKey _benefitStackKey = GlobalKey();
  final ValueNotifier<List<double>> _benefitRules = ValueNotifier(const []);

  /// 任一「人天利益」输入区文字变化都会自增，触发重新量虚线。
  final ValueNotifier<int> _benefitRev = ValueNotifier(0);

  /// 编辑中的那条密咒名（原名）；null = 添加。
  String? get _editing => widget.editing;

  /// 编辑中的那条密咒内部键（同名条目时用它精确定位）。
  String? get _editingKey => widget.editingKey;

  late final List<String> _sutras;

  /// 经文出处输入框的锚点：候选取经浮层挂在它下方，不挤动下面的内容。
  final LayerLink _sourceLink = LayerLink();
  OverlayEntry? _suggestOverlay;
  List<NoteSutraLink> _suggestions = const [];
  Timer? _debounce;

  TextEditingController _newParaCtrl([String text = '']) {
    final c = TextEditingController(text: text);
    // 任何一处文字变化都触发重新量虚线（与善知识页同款）。
    c.addListener(() => _benefitRev.value++);
    return c;
  }

  void _initParagraphEditors() {
    final editing = _editing;
    final store = ShanZhiShiMantraStore.instance;
    final key = _editingKey;
    final quotes = <String, List<String>>{};
    if (editing != null) {
      final bySutra = key == null
          ? store.benefitBySutraOf(editing)
          : store.benefitBySutraOfKey(key);
      for (final e in bySutra.entries) {
        quotes[e.key] = List.of(e.value);
      }
      var flat = List<String>.of(key == null
          ? store.benefitOf(editing)
          : store.benefitOfKey(key));
      if (flat.isEmpty && quotes.isNotEmpty) {
        for (final sutra in _sutras) {
          for (final t in quotes[sutra] ?? const <String>[]) {
            if (!flat.contains(t)) flat.add(t);
          }
        }
        for (final list in quotes.values) {
          for (final t in list) {
            if (!flat.contains(t)) flat.add(t);
          }
        }
        quotes.clear();
      }
      if (_sutras.isNotEmpty && flat.isNotEmpty) {
        final tied = <String>{for (final l in quotes.values) ...l};
        final loose = [for (final t in flat) if (!tied.contains(t)) t];
        if (loose.isNotEmpty) {
          final first = _sutras.first;
          quotes[first] = [...loose, ...?quotes[first]];
        }
        flat = const [];
      }
      _paraCtrls = {
        for (final s in _sutras)
          s: _newParaCtrl((quotes[s] ?? const []).join('\n\n')),
      };
      _flatCtrl = _sutras.isEmpty ? _newParaCtrl(flat.join('\n\n')) : null;
      _activeSutra = _sutras.isEmpty ? null : _sutras.first;
      return;
    }
    _paraCtrls = {for (final s in _sutras) s: _newParaCtrl()};
    _flatCtrl = _sutras.isEmpty ? _newParaCtrl() : null;
    _activeSutra = _sutras.isEmpty ? null : _sutras.first;
  }

  @override
  void initState() {
    super.initState();
    final editing = _editing;
    if (editing != null) {
      final store = ShanZhiShiMantraStore.instance;
      final key = _editingKey;
      _nameCtrl.text = editing;
      // 没带内部键时按名字找（同名条目仍由 key 精确定位）。
      final sources = key == null
          ? store.sourcesOf(editing)
          : store.sourcesOfKey(key);
      _sutras = List.of(sources);
      _textCtrl.text =
          key == null ? store.textOf(editing) : store.textOfKey(key);
      _annotations = key == null
          ? List.of(store.annotationsOf(editing))
          : List.of(store.annotationsOfKey(key));
    } else {
      // 从阅读页打开时带进来的经名只预填到出处输入框里（还没确认成经文），
      // 保存时会自动算作一条关联经文。
      final initialSource = widget.initialSource?.trim();
      _sutras = [];
      if (initialSource != null && initialSource.isNotEmpty) {
        _sourceCtrl.text = initialSource;
      }
      final initialText = widget.initialText?.trim();
      if (initialText != null && initialText.isNotEmpty) {
        _textCtrl.text = initialText;
      }
    }
    _initParagraphEditors();
    _lastText = _textCtrl.text;
    _textCtrl.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _suggestOverlay?.remove();
    _suggestOverlay = null;
    _textCtrl.removeListener(_onTextChanged);
    _nameCtrl.dispose();
    _sourceCtrl.dispose();
    _textCtrl.dispose();
    for (final c in _paraCtrls.values) {
      c.dispose();
    }
    _flatCtrl?.dispose();
    _benefitRules.dispose();
    _benefitRev.dispose();
    super.dispose();
  }

  /// 量出人天利益输入区里每处「段间分界」的 y 并刷新虚线层。
  void _measureBenefitRules() {
    if (!mounted) return;
    final ctrl = _activeParaCtrl;
    final next = ctrl == null
        ? const <double>[]
        : measureParagraphRules(stackKey: _benefitStackKey, ctrl: ctrl);
    if (!listEquals(_benefitRules.value, next)) _benefitRules.value = next;
  }

  // ─────────── 神咒原文批注（注音 / 备注） ───────────

  /// 原文或选区变化：选区变了只刷新工具栏可用态；文字变了把批注位置平移到新原文。
  void _onTextChanged() {
    final next = _textCtrl.text;
    if (next != _lastText) {
      _annotations = _remapAnnotations(_annotations, _lastText, next);
      _lastText = next;
    }
    if (mounted) setState(() {});
  }

  /// 文字被编辑后，把批注区间按「公共前缀 / 后缀」算出的改动区间平移、
  /// 收缩到新原文上；整段被删掉的批注直接丢弃。
  static List<MantraAnnotation> _remapAnnotations(
    List<MantraAnnotation> list,
    String oldText,
    String newText,
  ) {
    if (list.isEmpty || oldText == newText) return list;
    var prefix = 0;
    final maxPrefix = math.min(oldText.length, newText.length);
    while (prefix < maxPrefix &&
        oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    final maxSuffix =
        math.min(oldText.length - prefix, newText.length - prefix);
    while (suffix < maxSuffix &&
        oldText.codeUnitAt(oldText.length - 1 - suffix) ==
            newText.codeUnitAt(newText.length - 1 - suffix)) {
      suffix++;
    }
    final oldChangeEnd = oldText.length - suffix;
    final newChangeEnd = newText.length - suffix;
    final delta = newText.length - oldText.length;
    final out = <MantraAnnotation>[];
    for (final ann in list) {
      var s = ann.start;
      var e = ann.end;
      if (e <= prefix) {
        // 改动完全在批注之后：位置不动。
      } else if (s >= oldChangeEnd) {
        // 改动完全在批注之前：整条后移 / 前移。
        s += delta;
        e += delta;
      } else {
        // 与改动区间重叠：起点收到改动处，终点按删掉 / 新插入的内容伸缩。
        if (s > prefix) s = prefix;
        if (e > oldChangeEnd) {
          e += delta;
        } else {
          e = newChangeEnd;
        }
      }
      s = s.clamp(0, newText.length);
      e = e.clamp(0, newText.length);
      if (e <= s) continue;
      out.add(ann.copyWith(start: s, end: e));
    }
    return out;
  }

  /// 当前选区（正常化后的起止）；没有选中文字时为 null。
  (int, int)? get _selectedRange {
    final sel = _textCtrl.selection;
    if (!sel.isValid || sel.isCollapsed) return null;
    final s = math.min(sel.start, sel.end);
    final e = math.max(sel.start, sel.end);
    if (e <= s || e > _textCtrl.text.length) return null;
    return (s, e);
  }

  /// 神咒原文顶部的编辑工具栏：给选中的文字加注音 / 备注。
  Widget _annotationToolbar(PaletteData p) {
    final hasSelection = _selectedRange != null;
    return Row(
      children: [
        _label(p, '神咒原文'),
        const Spacer(),
        _annotationTool(
          p,
          key: const ValueKey('shanzhishi_mantra_ruby_tool'),
          icon: Icons.text_fields,
          label: '注音',
          enabled: hasSelection,
          onTap: () => _openAnnotationDialog(ruby: true),
        ),
        const SizedBox(width: 8),
        _annotationTool(
          p,
          key: const ValueKey('shanzhishi_mantra_note_tool'),
          icon: Icons.edit_note,
          label: '备注',
          enabled: hasSelection,
          onTap: () => _openAnnotationDialog(ruby: false),
        ),
      ],
    );
  }

  Widget _annotationTool(
    PaletteData p, {
    required Key key,
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final color = enabled ? p.accentDeep : p.textHint;
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: enabled ? p.tintBg : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: enabled ? p.tintBg : p.borderSoft),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 为选中文字（或已有的某条批注）写注音 / 备注；已有批注可在这里删除。
  Future<void> _openAnnotationDialog({
    required bool ruby,
    int? editIndex,
  }) async {
    var index = editIndex;
    MantraAnnotation? existing;
    int start;
    int end;
    if (index != null && index >= 0 && index < _annotations.length) {
      existing = _annotations[index];
      start = existing.start;
      end = existing.end;
    } else {
      final range = _selectedRange;
      if (range == null) return;
      start = range.$1;
      end = range.$2;
      index = _annotations.indexWhere(
          (a) => a.start == start && a.end == end);
      if (index >= 0) {
        existing = _annotations[index];
      } else {
        index = null;
      }
    }
    final quoted = _textCtrl.text.substring(start, end);
    final result = await showDialog<MantraAnnotationResult>(
      context: context,
      builder: (_) => MantraAnnotationDialog(
        quoted: quoted,
        initialRuby: existing?.ruby ?? '',
        initialNote: existing?.note ?? '',
        focusRuby: ruby,
        canDelete: existing != null,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      final i = index ??
          _annotations.indexWhere(
              (a) => a.start == start && a.end == end);
      // 只清空当前工具对应的那一项；另一项还在就保留这条批注。
      if (result.ruby.isEmpty && result.note.isEmpty) {
        if (i >= 0) _annotations.removeAt(i);
        return;
      }
      final ann = MantraAnnotation(
        start: start,
        end: end,
        ruby: result.ruby,
        note: result.note,
      );
      if (i >= 0) {
        _annotations[i] = ann;
      } else {
        _annotations.add(ann);
      }
      _annotations.sort((a, b) => a.start != b.start
          ? a.start - b.start
          : a.end - b.end);
    });
  }

  /// 已加批注的清单：点行可再次编辑，右侧可直接删除。
  Widget _annotationList(PaletteData p) {
    if (_annotations.isEmpty) return const SizedBox.shrink();
    final text = _textCtrl.text;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        key: const ValueKey('shanzhishi_mantra_annotation_list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < _annotations.length; i++)
            _annotationRow(p, i, text),
        ],
      ),
    );
  }

  Widget _annotationRow(PaletteData p, int i, String text) {
    final ann = _annotations[i];
    final s = ann.start.clamp(0, text.length);
    final e = ann.end.clamp(0, text.length);
    final quoted = e > s ? text.substring(s, e) : '';
    final parts = <String>[
      if (quoted.isNotEmpty) '「$quoted」',
      if (ann.hasRuby) '注音：${ann.ruby}',
      if (ann.hasNote) '备注：${ann.note}',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        key: ValueKey('shanzhishi_mantra_annotation_$i'),
        padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
        decoration: BoxDecoration(
          color: p.tintBg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                parts.join('  '),
                style: TextStyle(fontSize: 12.5, color: p.text, height: 1.4),
              ),
            ),
            _annotationMiniAction(
              p,
              key: ValueKey('shanzhishi_mantra_annotation_edit_ruby_$i'),
              label: '注音',
              onTap: () => _openAnnotationDialog(ruby: true, editIndex: i),
            ),
            _annotationMiniAction(
              p,
              key: ValueKey('shanzhishi_mantra_annotation_edit_note_$i'),
              label: '备注',
              onTap: () => _openAnnotationDialog(ruby: false, editIndex: i),
            ),
            GestureDetector(
              key: ValueKey('shanzhishi_mantra_annotation_delete_$i'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _annotations.removeAt(i)),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close, size: 15, color: p.textHint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _annotationMiniAction(
    PaletteData p, {
    required Key key,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: p.accentDeep,
          ),
        ),
      ),
    );
  }

  // ─────────── 经文出处候选 ───────────

  void _setSuggestions(List<NoteSutraLink> list) {
    if (!mounted) return;
    setState(() => _suggestions = list);
    _syncSuggestOverlay();
  }

  void _syncSuggestOverlay() {
    if (!mounted) return;
    if (_suggestions.isEmpty) {
      _suggestOverlay?.remove();
      _suggestOverlay = null;
      return;
    }
    if (_suggestOverlay == null) {
      _suggestOverlay = OverlayEntry(builder: _buildSuggestionOverlay);
      Overlay.of(context, rootOverlay: true).insert(_suggestOverlay!);
    } else {
      _suggestOverlay!.markNeedsBuild();
    }
  }

  Widget _buildSuggestionOverlay(BuildContext ctx) {
    final p = AppPalette.p;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _setSuggestions(const []),
          ),
        ),
        CompositedTransformFollower(
          link: _sourceLink,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          showWhenUnlinked: false,
          offset: const Offset(0, 6),
          child: SizedBox(
            key: const ValueKey('shanzhishi_mantra_source_suggest'),
            width: MediaQuery.of(ctx).size.width - 40,
            child: Material(
              color: p.card,
              elevation: 6,
              shadowColor: Colors.black.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _suggestions.length,
                  itemBuilder: (_, i) {
                    final s = _suggestions[i];
                    return InkWell(
                      onTap: () {
                        _addSutra(s.title);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 11),
                        child: Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13.5, color: p.text),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _onSourceChanged(String q) {
    _debounce?.cancel();
    final query = q.trim();
    if (query.isEmpty) {
      _setSuggestions(const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 160), () async {
      final result = await NoteSutraCatalog.search(query);
      if (!mounted || _sourceCtrl.text.trim() != query) return;
      _setSuggestions(result);
    });
  }

  void _addSutra(String name) {
    final t = name.trim();
    if (t.isEmpty || _sutras.contains(t)) {
      _sourceCtrl.clear();
      _setSuggestions(const []);
      return;
    }
    setState(() {
      _sutras.add(t);
      _paraCtrls[t] = _newParaCtrl();
      _activeSutra = t;
      _sourceCtrl.clear();
    });
    _setSuggestions(const []);
  }

  void _removeSutra(String sutra) {
    final wasActive = _activeSutra == sutra;
    final removedText = _paraCtrls[sutra]?.text ?? '';
    setState(() {
      _sutras.remove(sutra);
      _paraCtrls.remove(sutra)?.dispose();
      if (wasActive) {
        _activeSutra = _sutras.isEmpty ? null : _sutras.first;
      }
      if (_sutras.isEmpty && _flatCtrl == null) {
        _flatCtrl = _newParaCtrl(removedText.trim());
      }
    });
  }

  TextEditingController? get _activeParaCtrl =>
      _activeSutra != null ? _paraCtrls[_activeSutra] : _flatCtrl;

  /// 已有重复 / 相似的密咒时的提示框：只有两个方向——点某一条 = 合并到
  /// 这条旧密咒（保留它的名字）；「保存两者」= 各存各的（同名也各算一条）。
  /// 候选名号完整显示，不做省略，用户才看得出到底是不是同一个。
  /// 返回 null 表示取消。
  Future<_MantraPick?> _chooseMergeTargets(List<String> candidates) {
    final p = AppPalette.p;
    return showDialog<_MantraPick>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '或有重名神咒',
          style: TextStyle(
              fontSize: 17, fontWeight: FontWeight.w600, color: p.text),
        ),
        content: SizedBox(
          width: 300,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < candidates.length; i++)
                  _mergeTargetRow(i, candidates[i], p),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: p.textSec)),
          ),
          TextButton(
            key: const ValueKey('shanzhishi_mantra_keep_both'),
            onPressed: () => Navigator.pop(ctx, const _MantraPick('')),
            child: Text('保存两者', style: TextStyle(color: p.accentDeep)),
          ),
        ],
      ),
    );
  }

  /// 一条候选密咒：合并到这一位（保留它的名字）。名字完整换行显示。
  Widget _mergeTargetRow(int i, String name, PaletteData p) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: i == 0
            ? const ValueKey('shanzhishi_mantra_merge_existing')
            : ValueKey('shanzhishi_mantra_merge_existing_$i'),
        onTap: () => Navigator.of(context).pop(_MantraPick(name)),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '合并到「$name」（已有名号）',
                  softWrap: true,
                  style: TextStyle(
                      fontSize: 14.5,
                      color: p.text,
                      letterSpacing: 1,
                      height: 1.4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.chevron_right, size: 18, color: p.textHint),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 收集一片输入区里的段落：空行分段；整段没有空行时退回「一行一段」。
  List<String> _collectParagraphs(TextEditingController ctrl) {
    final lines = ctrl.text.replaceAll('\r\n', '\n').split('\n');
    final out = <String>[];
    for (final (a, b) in paragraphLineRanges(lines)) {
      final t = lines.sublist(a, b).join('\n').trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }



  Future<void> _save() async {
    final typed = _nameCtrl.text.trim();
    final editing = _editing;
    if (_saving) return;
    // 编辑时把名称也删空：没有名字就无从展示，保存 = 删除这条密咒。
    if (editing != null && typed.isEmpty) {
      setState(() => _saving = true);
      final ok = await ShanZhiShiMantraStore.instance
          .remove(editing, entryKey: _editingKey);
      if (!mounted) return;
      if (!ok) {
        setState(() => _saving = false);
        return;
      }
      Navigator.of(context).pop('');
      return;
    }
    if (typed.isEmpty) return;
    setState(() => _saving = true);
    final store = ShanZhiShiMantraStore.instance;
    final text = _textCtrl.text;
    final annotations = _annotations;
    // 出处输入框里还没回车确认的经名，保存时也算数：把它当作已添加的经文，
    // 没有经文时原本写在「无经文」输入区的人天利益顺手挂到这部经名下。
    final pendingSource = _sourceCtrl.text.trim();
    if (pendingSource.isNotEmpty && !_sutras.contains(pendingSource)) {
      final carried = _sutras.isEmpty ? (_flatCtrl?.text ?? '') : '';
      _sutras.add(pendingSource);
      _paraCtrls[pendingSource] = _newParaCtrl(carried);
      _activeSutra = pendingSource;
      _flatCtrl?.dispose();
      _flatCtrl = null;
    }
    final quotes = <String, List<String>>{};
    for (final sutra in _sutras) {
      final texts = _collectParagraphs(_paraCtrls[sutra]!);
      if (texts.isNotEmpty) quotes[sutra] = texts;
    }
    final flat = (_sutras.isEmpty && _flatCtrl != null)
        ? _collectParagraphs(_flatCtrl!)
        : <String>[];
    final paragraphs = <String>[
      ...flat,
      for (final sutra in _sutras) ...?quotes[sutra],
    ];

    // 保存前查重（口径同佛号：完全同名，或摘掉通用尊称后 ≥2 个相同字符）。
    // 撞名时只有两个方向：合并到旧的那条，或「保存两者」各存各的。
    final candidates = store.findSimilarEntries(
      typed,
      skip: editing,
      skipKey: _editingKey,
    );
    var mergeIntoName = '';
    var saveBoth = false;
    if (candidates.isNotEmpty) {
      final pick = await _chooseMergeTargets(candidates);
      if (!mounted) return;
      if (pick == null) {
        setState(() => _saving = false);
        return;
      }
      mergeIntoName = pick.targetName;
      saveBoth = mergeIntoName.isEmpty;
    }

    try {
      if (mergeIntoName.isNotEmpty) {
        // 并进选中的那一条（保留它的名字），当前这条删掉。
        final ok = await store.mergeInto(
          mergeIntoName,
          sources: _sutras,
          text: text,
          benefit: paragraphs,
          benefitBySutra: quotes,
          annotations: annotations,
        );
        if (ok && editing != null && editing != mergeIntoName) {
          await store.remove(editing, entryKey: _editingKey);
        }
        if (!ok || !mounted) {
          if (mounted) setState(() => _saving = false);
          return;
        }
        Navigator.of(context).pop(mergeIntoName);
        return;
      }
      // 没有相似项，或用户选「保存两者」：照常保存（同名允许另起一条）。
      final ok = editing == null
          ? await store.add(typed,
              sources: _sutras,
              text: text,
              benefit: paragraphs,
              benefitBySutra: quotes,
              annotations: annotations,
              allowDuplicate: saveBoth)
          : await store.update(
              editing,
              newName: typed,
              entryKey: _editingKey,
              sources: _sutras,
              text: text,
              benefit: paragraphs,
              benefitBySutra: quotes,
              annotations: annotations,
              allowDuplicate: saveBoth,
            );
      if (!mounted) return;
      if (!ok) {
        setState(() => _saving = false);
        return;
      }
      Navigator.of(context).pop(typed);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    // 重名（与内置或已存密咒同名）时贴在输入框下方的错误提示；
    // 编辑时名字没改（仍等于原名）不算撞名。
    final name = _nameCtrl.text.trim();
    final store = ShanZhiShiMantraStore.instance;
    final duplicated = name.isNotEmpty &&
        (name != _editing || _editing == null) &&
        store.mantras.any((m) => m.trim() == name);
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _editing == null ? '添加神咒' : '编辑神咒',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                if (_editing != null)
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Icon(Icons.close, size: 20, color: p.textSec),
                  ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label(p, '神咒名称'),
                  const SizedBox(height: 8),
                  _field(
                    key: const ValueKey('shanzhishi_mantra_name_field'),
                    controller: _nameCtrl,
                    hint: '如：药师灌顶真言',
                    // 编辑时不自动弹键盘（一进来就遮住下面的原文）；添加才自动聚焦。
                    autofocus: _editing == null,
                    maxLength: 30,
                    onChanged: (_) => setState(() {}),
                  ),
                  if (duplicated)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '已有相似的密咒：保存时可选择合并方式，或换个名字',
                        style: TextStyle(fontSize: 12, color: p.accentDeep),
                      ),
                    ),
                  // 编辑时名称删空：不是「不改名」，而是这条要从名单里去掉。
                  if (_editing != null && name.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '名称已清空：保存后这条密咒将从名单中删除',
                        style: TextStyle(fontSize: 12, color: p.accentDeep),
                      ),
                    ),
                  const SizedBox(height: 18),
                   _label(p, '经文出处'),
                   const SizedBox(height: 8),
                   if (_sutras.isNotEmpty) ...[
                     Wrap(
                       spacing: 8,
                       runSpacing: 8,
                       children: [
                         for (final sutra in _sutras) _sutraChip(sutra, p),
                       ],
                     ),
                     const SizedBox(height: 10),
                   ],
                   CompositedTransformTarget(
                     link: _sourceLink,
                     child: _field(
                       key: const ValueKey('shanzhishi_mantra_source_field'),
                       controller: _sourceCtrl,
                       hint: '搜索经藏，或直接输入经名后回车',
                       maxLength: 100,
                       onChanged: _onSourceChanged,
                       onSubmitted: _addSutra,
                     ),
                   ),
                  const SizedBox(height: 18),
                  _annotationToolbar(p),
                  const SizedBox(height: 8),
                  // 不加框：一片可直接写的空白。神咒原文不画段间虚线，
                  // 回车就是普通换行。
                  TextField(
                    key: const ValueKey('shanzhishi_mantra_text_field'),
                    controller: _textCtrl,
                    minLines: 8,
                    maxLines: null,
                    maxLength: 2000,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    // 选中文字后不弹系统的剪切 / 复制 / 粘贴，
                    // 改由上方工具栏「注音 / 备注」处理。
                    contextMenuBuilder: (context, editableTextState) =>
                        const SizedBox.shrink(),
                    style: TextStyle(
                        fontSize: 14,
                        color: p.text,
                        height: 1.8,
                        letterSpacing: 1),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      counterText: '',
                      hintText: '输入咒语的具体内容',
                      hintStyle: TextStyle(
                          fontSize: 14, color: p.textHint, height: 1.8),
                    ),
                  ),
                  _annotationList(p),
                  const SizedBox(height: 20),
                  Container(height: 0.8, color: p.borderSoft),
                  const SizedBox(height: 14),
                  _label(p, '人天利益'),
                  if (_activeSutra != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '当前经文：$_activeSutra',
                      style: TextStyle(fontSize: 12, color: p.accentDeep),
                    ),
                  ],
                  const SizedBox(height: 8),
                  // 与善知识同款：一片无边框的大输入区，空行分段，
                  // 段与段之间自动画一条虚线；回车自动补空行并把光标接到
                  // 空行下面。
                  ListenableBuilder(
                    listenable: Listenable.merge([_benefitRev, _benefitRules]),
                    builder: (context, _) {
                      final ctrl = _activeParaCtrl;
                      if (ctrl == null) return const SizedBox.shrink();
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => _measureBenefitRules());
                      return Stack(
                        key: _benefitStackKey,
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              key: const ValueKey(
                                  'shanzhishi_mantra_benefit_rules'),
                              painter: ParaRulePainter(
                                rules: _benefitRules.value,
                                color: p.textHint,
                              ),
                            ),
                          ),
                          TextField(
                            key: const ValueKey(
                                'shanzhishi_mantra_benefit_field'),
                            controller: ctrl,
                            minLines: 12,
                            maxLines: null,
                            maxLength: 4000,
                            keyboardType: TextInputType.multiline,
                            textAlignVertical: TextAlignVertical.top,
                            // 回车＝换一段：一个换行自动补成「空行＋新行」。
                            inputFormatters: const [
                              ParagraphBreakInputFormatter(),
                            ],
                            style: TextStyle(
                                fontSize: 14,
                                color: p.text,
                                height: 1.8,
                                letterSpacing: 1),
                            decoration: InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              counterText: '',
                              hintText: '输入神咒的人天利益\n一段一条，空行分隔\n'
                                  '点选经文对应人天利益段落',
                              hintStyle: TextStyle(
                                  fontSize: 14, color: p.textHint, height: 1.8),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          Container(height: 0.8, color: p.borderSoft),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('取消',
                      style: TextStyle(fontSize: 14, color: p.textSec)),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  // 编辑时名称删空 = 删除这条；添加仍要求填了名字。
                  onPressed: _saving || (name.isEmpty && _editing == null)
                      ? null
                      : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: p.primary,
                    foregroundColor: p.card,
                    disabledBackgroundColor: p.muted,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 10),
                    textStyle: const TextStyle(fontSize: 14),
                  ),
                  child: Text(_editing != null && name.isEmpty ? '删除' : '保存'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(PaletteData p, String text) {
    return Text(
      text,
      style: TextStyle(fontSize: 12, color: p.textSec, letterSpacing: 0.5),
    );
  }

  Widget _sutraChip(String name, PaletteData p) {
    final active = name == _activeSutra;
    return GestureDetector(
      key: ValueKey('shanzhishi_mantra_source_chip_$name'),
      onTap: () => setState(() => _activeSutra = name),
      child: Container(
        padding: const EdgeInsets.only(left: 12, top: 6, bottom: 6, right: 4),
        decoration: BoxDecoration(
          color: active ? p.accent.withValues(alpha: 0.16) : p.tintBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? p.accent : p.borderSoft),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              style: TextStyle(
                fontSize: 13,
                color: active ? p.accentDeep : p.text,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(width: 2),
            GestureDetector(
              key: ValueKey('shanzhishi_mantra_source_remove_$name'),
              onTap: () => _removeSutra(name),
              child: Icon(Icons.close, size: 14, color: p.textSec),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required Key key,
    required TextEditingController controller,
    required String hint,
    bool autofocus = false,
    bool enabled = true,
    int? maxLength,
    int? minLines = 1,
    int? maxLines = 1,
    TextInputType? keyboardType,
    TextAlignVertical? textAlignVertical,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
  }) {
    final p = AppPalette.p;
    return TextField(
      key: key,
      controller: controller,
      autofocus: autofocus,
      enabled: enabled,
      maxLength: maxLength,
      minLines: minLines,
      maxLines: maxLines,
      keyboardType: keyboardType,
      textAlignVertical: textAlignVertical,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: onSubmitted != null ? TextInputAction.done : null,
      style: TextStyle(fontSize: 16, color: p.text, letterSpacing: 1),
      decoration: InputDecoration(
        counterText: '',
        hintText: hint,
        hintStyle: TextStyle(fontSize: 14, color: p.textHint),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.accent),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.border),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}
