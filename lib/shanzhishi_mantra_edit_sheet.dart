import 'dart:async';

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'note_sutra_links.dart';
import 'shanzhishi_mantra_store.dart';

/// 保存时遇到重复 / 相似密咒，用户在合并提示里选的处理方式：
/// [targetName] 非空 = 与这条并成一条（保留它的名字）；
/// [targetName] 为空且 [keepNewName] = 反向合并——保留刚输入的名字，
/// 把相似条目并进来后删掉；两者皆空 = 「两个都留着」，各存各的。
class _MantraPick {
  const _MantraPick(this.targetName, {this.keepNewName = false});
  final String targetName;
  final bool keepNewName;
}

/// 添加/编辑密咒面板：神咒名称、经文出处、神咒原文三项 + 取消/添加（保存）。
/// 与【添加善知识】同款底部上拉面板：固定占屏幕九成高，标题与底部按钮钉住，
/// 中间整块可滚动；键盘弹出时整体让位，不会盖住输入区。
class ShanZhiShiMantraEditSheet extends StatefulWidget {
  /// 要编辑的密咒名；null = 添加新密咒。
  final String? editing;

  /// 新增时默认填入的经文出处（如从阅读页打开时传入当前经名，含卷）。
  final String? initialSource;

  /// 新增时默认填入的神咒原文（如从阅读页打开时传入选中文字）。
  final String? initialText;

  const ShanZhiShiMantraEditSheet({
    super.key,
    this.editing,
    this.initialSource,
    this.initialText,
  });

  /// 弹出面板；保存成功返回（保存后的）密咒名，取消返回 null。
  /// 编辑时名称被删空保存 = 删除这条，返回空串。
  static Future<String?> show(
    BuildContext context, {
    String? editing,
    String? initialSource,
    String? initialText,
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
        child: ShanZhiShiMantraEditSheet(
          editing: editing,
          initialSource: initialSource,
          initialText: initialText,
        ),
      ),
    );
  }

  @override
  State<ShanZhiShiMantraEditSheet> createState() =>
      _ShanZhiShiMantraEditSheetState();
}

class _ShanZhiShiMantraEditSheetState
    extends State<ShanZhiShiMantraEditSheet> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _sourceCtrl = TextEditingController();
  final TextEditingController _textCtrl = TextEditingController();
  bool _saving = false;

  /// 编辑中的那条密咒名（原名）；null = 添加。
  String? get _editing => widget.editing;

  /// 经文出处输入框的锚点：候选取经浮层挂在它下方，不挤动下面的内容。
  final LayerLink _sourceLink = LayerLink();
  OverlayEntry? _suggestOverlay;
  List<NoteSutraLink> _suggestions = const [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final editing = _editing;
    if (editing != null) {
      final store = ShanZhiShiMantraStore.instance;
      _nameCtrl.text = editing;
      _sourceCtrl.text = store.sourceOf(editing);
      _textCtrl.text = store.textOf(editing);
    } else {
      final initialSource = widget.initialSource?.trim();
      if (initialSource != null && initialSource.isNotEmpty) {
        _sourceCtrl.text = initialSource;
      }
      final initialText = widget.initialText?.trim();
      if (initialText != null && initialText.isNotEmpty) {
        _textCtrl.text = initialText;
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _suggestOverlay?.remove();
    _suggestOverlay = null;
    _nameCtrl.dispose();
    _sourceCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
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
                        _sourceCtrl.text = s.title;
                        _sourceCtrl.selection = TextSelection.collapsed(
                            offset: s.title.length);
                        _setSuggestions(const []);
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

  /// 已有重复 / 相似的密咒时的合并选择框（与佛号添加页同款口径）：
  /// 点某一条 = 与它并成一条、保留它的名字；「合并到当前名号」= 反过来，
  /// 保留刚输入的名字、把相似条目并进来后删掉。底部仍可「两个都留着」；
  /// 名字完全同名时不再提供「两个都留着」。返回 null 表示取消。
  Future<_MantraPick?> _chooseMergeTargets(
      List<String> candidates, String query) {
    final p = AppPalette.p;
    // 完全同名：两条名字一模一样，直接要求合并。
    final exact = candidates.contains(query);
    return showDialog<_MantraPick>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '或有重名密咒',
          style: TextStyle(
              fontSize: 17, fontWeight: FontWeight.w600, color: p.text),
        ),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < candidates.length; i++)
                _mergeTargetRow(i, candidates[i], p),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  key: const ValueKey('shanzhishi_mantra_keep_new_name'),
                  onTap: () => Navigator.of(context)
                      .pop(const _MantraPick('', keepNewName: true)),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 9),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '合并到当前「$query」（当前名号）',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14.5,
                                color: p.text,
                                height: 1.4),
                          ),
                        ),
                        Icon(Icons.chevron_right,
                            size: 18, color: p.textHint),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: p.textSec)),
          ),
          if (!exact)
            TextButton(
              key: const ValueKey('shanzhishi_mantra_keep_both'),
              onPressed: () => Navigator.pop(ctx, const _MantraPick('')),
              child: Text('两个都留着', style: TextStyle(color: p.accentDeep)),
            ),
        ],
      ),
    );
  }

  /// 一条候选密咒：合并到这一位（保留它的名字）。
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
            children: [
              Expanded(
                child: Text(
                  '合并到「$name」（已有名号）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14.5,
                      color: p.text,
                      letterSpacing: 1,
                      height: 1.4),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: p.textHint),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final typed = _nameCtrl.text.trim();
    final editing = _editing;
    if (_saving) return;
    // 编辑时把名称也删空：没有名字就无从展示，保存 = 删除这条密咒。
    if (editing != null && typed.isEmpty) {
      setState(() => _saving = true);
      final ok = await ShanZhiShiMantraStore.instance.remove(editing);
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
    final source = _sourceCtrl.text;
    final text = _textCtrl.text;

    // 保存前查重（口径同佛号：完全同名，或摘掉通用尊称后 ≥2 个相同字符）。
    // 与旧逻辑不同：不再静默拒绝保存，而是让用户选合并方向，或两个都留着。
    final candidates = store.findSimilarEntries(typed, skip: editing);
    var mergeIntoName = '';
    var keepNewName = false;
    if (candidates.isNotEmpty) {
      final pick = await _chooseMergeTargets(candidates, typed);
      if (!mounted) return;
      if (pick == null) {
        setState(() => _saving = false);
        return;
      }
      mergeIntoName = pick.targetName;
      keepNewName = pick.keepNewName;
    }

    try {
      if (keepNewName) {
        // 反向合并：保留刚输入的名字，先把这条存下来，
        // 再把每条相似密咒的内容并进来后删掉（内容一处不丢）。
        final ok = editing == null
            ? await store.add(typed, source: source, text: text)
            : await store.update(
                editing,
                newName: typed,
                source: source,
                text: text,
              );
        if (!ok) {
          if (mounted) setState(() => _saving = false);
          return;
        }
        for (final c in candidates) {
          await store.mergeAndRemove(typed, c);
        }
        if (!mounted) return;
        Navigator.of(context).pop(typed);
        return;
      }
      if (mergeIntoName.isNotEmpty) {
        // 并进选中的那一条（保留它的名字），当前这条删掉。
        final ok = await store.mergeInto(
          mergeIntoName,
          source: source,
          text: text,
        );
        if (ok && editing != null && editing != mergeIntoName) {
          await store.remove(editing);
        }
        if (!ok || !mounted) {
          if (mounted) setState(() => _saving = false);
          return;
        }
        Navigator.of(context).pop(mergeIntoName);
        return;
      }
      // 没有相似项，或用户选「两个都留着」：照常保存。
      final ok = editing == null
          ? await store.add(typed, source: source, text: text)
          : await store.update(
              editing,
              newName: typed,
              source: source,
              text: text,
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
                      _editing == null ? '添加密咒' : '编辑密咒',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
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
                  CompositedTransformTarget(
                    link: _sourceLink,
                    child: _field(
                      key: const ValueKey('shanzhishi_mantra_source_field'),
                      controller: _sourceCtrl,
                      hint: '搜索经藏，或直接输入经名',
                      maxLength: 100,
                      onChanged: _onSourceChanged,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _label(p, '神咒原文'),
                  const SizedBox(height: 8),
                  // 不加框：与佛号添加页的引用段落输入区同款，一片可直接写的空白。
                  TextField(
                    key: const ValueKey('shanzhishi_mantra_text_field'),
                    controller: _textCtrl,
                    minLines: 8,
                    maxLines: null,
                    maxLength: 2000,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
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
                  child:
                      Text('取消', style: TextStyle(fontSize: 14, color: p.textSec)),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  // 编辑时名称删空 = 删除这条；添加仍要求填了名字。
                  onPressed:
                      _saving || (name.isEmpty && _editing == null) ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: p.primary,
                    foregroundColor: p.card,
                    disabledBackgroundColor: p.muted,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 10),
                    textStyle: const TextStyle(fontSize: 14),
                  ),
                  child: Text(_editing == null
                      ? '添加'
                      : name.isEmpty
                          ? '删除'
                          : '保存'),
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
