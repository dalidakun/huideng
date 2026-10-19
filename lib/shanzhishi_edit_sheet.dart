import 'dart:async';

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'note_sutra_links.dart';
import 'shanzhishi_store.dart';

/// 善知识编辑面板：新增 / 编辑一位名号，维护它的关联经文，
/// 以及一片直接手写「引用段落」的输入区（一段一条，空行分隔）。
///
/// 经文优先从经藏目录里检索（选中后可跳阅读），目录外的手输名称也能保存，
/// 展示为纯文本卡片。
class ShanZhiShiEditSheet extends StatefulWidget {
  /// 新增时为 null；编辑时传位次与当前条目。
  final int? index;
  final ShanyishiEntry? entry;

  const ShanZhiShiEditSheet({super.key, this.index, this.entry});

  /// 弹出编辑面板。返回保存后的位次（新增返回新位次、编辑返回原位次），
  /// 取消或删除返回 null。
  static Future<int?> show(
    BuildContext context, {
    int? index,
    ShanyishiEntry? entry,
  }) {
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppPalette.p.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // 固定占屏幕 90% 高：引用段落往往较多，给足编辑空间。
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.9,
        child: ShanZhiShiEditSheet(index: index, entry: entry),
      ),
    );
  }

  @override
  State<ShanZhiShiEditSheet> createState() => _ShanZhiShiEditSheetState();
}

class _ShanZhiShiEditSheetState extends State<ShanZhiShiEditSheet> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.entry?.name ?? '');
  final TextEditingController _sutraCtrl = TextEditingController();

  /// 引用段落输入区：整片文本，一段一条（空行或换行分隔）。
  late final TextEditingController _paraCtrl =
      TextEditingController(text: _initialParagraphs().join('\n\n'));

  late final List<String> _sutras;

  List<NoteSutraLink> _suggestions = [];
  Timer? _debounce;
  bool _saving = false;

  /// 经名输入框的锚点：待选经文列表以浮层形式挂在它下方，不挤动下面的内容。
  final LayerLink _sutraLink = LayerLink();
  OverlayEntry? _suggestOverlay;

  bool get _isEdit => widget.index != null && widget.entry != null;

  /// 编辑时的初始段落：优先用统一段落池，旧数据（按经书存的）拍平后回填。
  List<String> _initialParagraphs() {
    final entry = widget.entry;
    if (entry == null) return const [];
    final list = <String>[...entry.paragraphs];
    if (list.isEmpty) {
      for (final sutra in entry.sutras) {
        for (final t in entry.quotes[sutra] ?? const <String>[]) {
          if (!list.contains(t)) list.add(t);
        }
      }
      for (final texts in entry.quotes.values) {
        for (final t in texts) {
          if (!list.contains(t)) list.add(t);
        }
      }
    }
    return list;
  }

  @override
  void initState() {
    super.initState();
    _sutras = List.of(widget.entry?.sutras ?? const []);
    // 名号输入变化时刷新「保存」按钮的可用态。
    _nameCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _suggestOverlay?.remove();
    _suggestOverlay = null;
    _nameCtrl.dispose();
    _sutraCtrl.dispose();
    _paraCtrl.dispose();
    super.dispose();
  }

  // ─────────── 待选经文浮层 ───────────

  /// 更新待选经文并同步浮层（有结果就浮在经名输入框下方，没有就移除）。
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

  /// 待选经文浮层：锚在经名输入框下边缘，盖在页面上方（不挤占下面区域）。
  Widget _buildSuggestionOverlay(BuildContext ctx) {
    final p = AppPalette.p;
    return Stack(
      children: [
        // 透明遮罩：点一下浮层外就收起。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _setSuggestions(const []),
          ),
        ),
        CompositedTransformFollower(
          link: _sutraLink,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          showWhenUnlinked: false,
          offset: const Offset(0, 6),
          child: SizedBox(
            key: const ValueKey('shanzhishi_sutra_suggest'),
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
                      onTap: () => _addSutra(s.title),
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

  void _onSutraInputChanged(String q) {
    _debounce?.cancel();
    final query = q.trim();
    if (query.isEmpty) {
      _setSuggestions(const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 160), () async {
      final result = await NoteSutraCatalog.search(query);
      if (!mounted || _sutraCtrl.text.trim() != query) return;
      _setSuggestions(result);
    });
  }

  void _addSutra(String name) {
    final t = name.trim();
    if (t.isEmpty || _sutras.contains(t)) {
      _sutraCtrl.clear();
      _setSuggestions(const []);
      return;
    }
    setState(() {
      _sutras.add(t);
      _sutraCtrl.clear();
    });
    _setSuggestions(const []);
  }

  void _removeSutra(String sutra) {
    setState(() {
      _sutras.remove(sutra);
    });
  }

  /// 收集引用段落：空行分段；整段没有空行时退回「一行一段」。
  List<String> _collectParagraphs() {
    final raw = _paraCtrl.text.replaceAll('\r\n', '\n').trim();
    if (raw.isEmpty) return const [];
    var chunks = raw.split(RegExp(r'\n[ \t]*\n'));
    if (chunks.length == 1) chunks = raw.split('\n');
    final out = <String>[];
    for (final c in chunks) {
      final t = c.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  /// 已录入过同名 / 高度相似（≥80% 字符重合）的名号时，让用户选择怎么处理：
  /// 新增时是「添加新的 / 合并到已有的」，编辑时是「保留名号 / 合并并删掉这一位」。
  /// 返回 null 表示取消（留在面板上继续编辑）。
  Future<_SimilarChoice?> _chooseForSimilar(
    String existing, {
    required bool editing,
  }) {
    final p = AppPalette.p;
    return showDialog<_SimilarChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '已有相似的善知识',
          style: TextStyle(
              fontSize: 17, fontWeight: FontWeight.w600, color: p.text),
        ),
        content: Text(
          editing
              ? '已存在「$existing」。\n\n'
                  '合并：把这一位的经文与引用段落并进「$existing」，并删掉当前这一位。\n'
                  '保留名号：仍然用这个名号，会留下两条相近的记录。'
              : '已存在「$existing」。\n\n'
                  '合并：把这次填写的经文与引用段落并到「$existing」下面，'
                  '名号沿用已有的那一位。\n'
                  '添加新的：另起一位名号。',
          style: TextStyle(fontSize: 13.5, color: p.textSec, height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: p.textSec)),
          ),
          TextButton(
            key: const ValueKey('shanzhishi_add_new'),
            onPressed: () => Navigator.pop(ctx, _SimilarChoice.keep),
            child: Text(editing ? '保留名号' : '添加新的',
                style: TextStyle(color: p.accentDeep)),
          ),
          FilledButton(
            key: const ValueKey('shanzhishi_merge_existing'),
            onPressed: () => Navigator.pop(ctx, _SimilarChoice.merge),
            style: FilledButton.styleFrom(
              backgroundColor: p.primary,
              foregroundColor: p.card,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              textStyle: const TextStyle(fontSize: 13.5),
            ),
            child: const Text('合并'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _saving) return;
    final store = ShanZhiShiStore.instance;
    // 引用段落就是这片输入区里的文本，空行（或换行）分成多条。
    final paragraphs = _collectParagraphs();
    // 旧版按经书存的段落已拍平进段落池，保存时清掉，避免两处重复展示。
    const noLegacyQuotes = <String, List<String>>{};

    setState(() => _saving = true);

    // 编辑：保存前查重（跳过自己）。
    // 改了名号：按 80% 近似判定；没改名号：只查是否还有完全同名的另一位
    // （例如之前选「保留名号」留下的重复），这样不会因为种子里的近似名号被反复打扰。
    if (_isEdit) {
      final index = widget.index!;
      var mergeTarget = -1;
      final renamed = name != (widget.entry?.name ?? '');
      final similar = store.findSimilarIndex(
        name,
        skip: index,
        threshold: renamed ? 0.8 : 1.0,
      );
      if (similar >= 0) {
        final choice = await _chooseForSimilar(
          store[similar]?.name ?? '',
          editing: true,
        );
        if (!mounted) return;
        if (choice == null) {
          setState(() => _saving = false);
          return;
        }
        if (choice == _SimilarChoice.merge) mergeTarget = similar;
      }
      int result;
      try {
        await store.update(
          index,
          name: name,
          sutras: _sutras,
          paragraphs: paragraphs,
          quotes: noLegacyQuotes,
        );
        result = mergeTarget >= 0
            ? await store.mergeAndRemove(index, mergeTarget)
            : index;
      } catch (_) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(result < 0 ? null : result);
      return;
    }

    // 新增：先查有没有同名 / 高度相似（≥80% 字符重合）的名号，
    // 让用户自己决定「添加新的」还是把经文与段落合并到已有的名号下面。
    final similar = store.findSimilarIndex(name);
    var mergeTarget = -1;
    if (similar >= 0) {
      final choice =
          await _chooseForSimilar(store[similar]?.name ?? '', editing: false);
      if (!mounted) return;
      if (choice == null) {
        setState(() => _saving = false);
        return;
      }
      if (choice == _SimilarChoice.merge) mergeTarget = similar;
    }

    int result;
    try {
      result = mergeTarget >= 0
          ? await store.mergeInto(
              mergeTarget,
              sutras: _sutras,
              paragraphs: paragraphs,
            )
          : await store.add(
              name,
              _sutras,
              paragraphs: paragraphs,
              // 用户已明确选「添加新的」：同名也另起一位，不再默默合并。
              allowDuplicate: similar >= 0,
            );
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(result < 0 ? null : result);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    // 面板固定占屏幕 90% 高（见 show() 里的 FractionallySizedBox）：
    // 标题与底部按钮钉住，中间整块滚动；引用段落是一片无边框的大输入区。
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
                    _isEdit ? '编辑善知识' : '添加善知识',
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
                  _sectionLabel(p, '名号'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameCtrl,
                    autofocus: !_isEdit,
                    maxLength: 20,
                    style: TextStyle(
                        fontSize: 16, color: p.text, letterSpacing: 1),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: '如：地藏王菩萨',
                      hintStyle: TextStyle(fontSize: 14, color: p.textHint),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: p.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: p.accent),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _sectionLabel(p, '关联经文'),
                  const SizedBox(height: 8),
                  if (_sutras.isNotEmpty) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final sutra in _sutras) _sutraChip(sutra),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  // 锚点：待选经文以浮层形式挂在这个输入框下方（不占版面）。
                  CompositedTransformTarget(
                    link: _sutraLink,
                    child: TextField(
                      controller: _sutraCtrl,
                      style: TextStyle(fontSize: 14, color: p.text),
                      onChanged: _onSutraInputChanged,
                      onSubmitted: _addSutra,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        hintText: '搜索经藏，或直接输入经名后回车',
                        hintStyle: TextStyle(fontSize: 13, color: p.textHint),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: p.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: p.accent),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(height: 0.8, color: p.borderSoft),
                  const SizedBox(height: 14),
                  _sectionLabel(p, '引用段落'),
                  const SizedBox(height: 3),
                  Text(
                    '输入和佛菩萨关联的经文段落',
                    style: TextStyle(fontSize: 11, color: p.textHint),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '一段一条，空行分隔',
                    style: TextStyle(fontSize: 11, color: p.textHint),
                  ),
                  const SizedBox(height: 8),
                  // 不加框：就是一片可以直接写的输入区，一段一条（空行分隔）。
                  TextField(
                    key: const ValueKey('shanzhishi_paragraphs_field'),
                    controller: _paraCtrl,
                    minLines: 16,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    style: TextStyle(fontSize: 14, color: p.text, height: 1.8),
                    decoration: const InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 分隔线 + 底部按钮：固定，不随内容滚动。
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
                  onPressed: _nameCtrl.text.trim().isEmpty || _saving
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
                  child: Text(_isEdit ? '保存' : '添加'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(PaletteData p, String text) {
    return Text(
      text,
      style: TextStyle(fontSize: 12, color: p.textSec, letterSpacing: 0.5),
    );
  }

  Widget _sutraChip(String name) {
    final p = AppPalette.p;
    return Container(
      padding: const EdgeInsets.only(left: 12, top: 6, bottom: 6, right: 4),
      decoration: BoxDecoration(
        color: p.tintBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.borderSoft),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name, style: TextStyle(fontSize: 13, color: p.text)),
          const SizedBox(width: 2),
          GestureDetector(
            key: ValueKey('shanzhishi_sutra_remove_$name'),
            onTap: () => _removeSutra(name),
            child: Icon(Icons.close, size: 14, color: p.textSec),
          ),
        ],
      ),
    );
  }
}

/// 新增/编辑时遇到同名 / 高度相似名号，用户的选择：
/// 保留当前名号（新增即另起一位），或者合并到已有的那一位。
enum _SimilarChoice { keep, merge }
