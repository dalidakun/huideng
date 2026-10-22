import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'app_palette.dart';
import 'collapsible_bottom_sheet.dart';
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

  /// 新增时默认关联的经文（如从阅读页打开时传入当前经名，含卷）。
  final String? initialSutra;

  /// 新增时默认填进「人天利益」的段落（如从阅读页打开时传入选中文字）。
  final List<String>? initialParagraphs;

  const ShanZhiShiEditSheet({
    super.key,
    this.index,
    this.entry,
    this.initialSutra,
    this.initialParagraphs,
  });

  /// 弹出编辑面板。返回保存后的位次（新增返回新位次、编辑返回原位次），
  /// 取消或删除返回 null。
  static Future<int?> show(
    BuildContext context, {
    int? index,
    ShanyishiEntry? entry,
    String? initialSutra,
    List<String>? initialParagraphs,
    bool collapsible = false,
    String? collapsedTitle,
  }) {
    final sheet = ShanZhiShiEditSheet(
      index: index,
      entry: entry,
      initialSutra: initialSutra,
      initialParagraphs: initialParagraphs,
    );
    if (collapsible) {
      return showCollapsibleBottomSheet<int>(
        context,
        collapsedTitle: collapsedTitle ??
            (index == null && entry == null ? '添加善知识' : '编辑善知识'),
        builder: (_) => sheet,
      );
    }
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
        child: sheet,
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

  /// 人天利益：一部经对应一个输入区（各存各的），点选经文切换显示哪一个。
  /// 一条经文都没有时才用 [_flatCtrl]（不绑经文的段落池）。
  late final Map<String, TextEditingController> _paraCtrls;

  /// 没有任何关联经文时的段落输入区；有经文时为 null。
  TextEditingController? _flatCtrl;

  /// 当前激活的经文：下面显示的就是它的人天利益；null = 无经文可选。
  String? _activeSutra;

  /// 人天利益输入区的字形：与 [ParaRulePainter] 的测量共用同一套字号行高。
  TextStyle get _paraStyle =>
      TextStyle(fontSize: 14, color: AppPalette.p.text, height: 1.8);

  /// 所有人天利益输入区共用的一枚信号：任何一处文本变化都要重画虚线。
  final ValueNotifier<int> _paraRev = ValueNotifier(0);

  /// 输入区（Stack）的锚点：虚线位置直接从真正渲染这段文字的 `RenderEditable`
  /// 上量出来，不自己按字号乘行高去估——估出来的行位迟早会飘到字里面去。
  final GlobalKey _paraStackKey = GlobalKey();

  /// 每处「段间分界」在输入区坐标里的 y，[CustomPaint] 照着画。
  final ValueNotifier<List<double>> _paraRules = ValueNotifier(const []);

  /// 新建一片人天利益输入区（顺带接上虚线重画信号）。
  TextEditingController _newParaCtrl([String text = '']) {
    final c = TextEditingController(text: text);
    c.addListener(() => _paraRev.value++);
    return c;
  }

  late final List<String> _sutras;

  List<NoteSutraLink> _suggestions = [];
  Timer? _debounce;
  bool _saving = false;

  /// 经名输入框的锚点：待选经文列表以浮层形式挂在它下方，不挤动下面的内容。
  final LayerLink _sutraLink = LayerLink();
  OverlayEntry? _suggestOverlay;

  bool get _isEdit => widget.index != null && widget.entry != null;

  /// 打开面板时的段落初值：每部经各一份（[ShanyishiEntry.quotes]）。
  /// 旧数据（段落还只存一份、不绑经文）先归到第一条经文，编辑时看得到、改得动；
  /// 再存一次就落进 quotes，从此按经文各归各的。
  void _initParagraphEditors() {
    final entry = widget.entry;
    final quotes = <String, List<String>>{
      for (final e in (entry?.quotes ?? const {}).entries)
        e.key: List.of(e.value),
    };
    var flat = List<String>.of(entry?.paragraphs ?? const []);
    // 更旧的一版：段落曾按经书存在 quotes 里且没拍平过，先拍平再归位。
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
      // 只把「还没挂到任何经文下」的旧段落归到第一条经文；
      // 已经在某部经名下、只是被镜像进平铺池的那些不重复搬。
      final tied = <String>{for (final l in quotes.values) ...l};
      final loose = [
        for (final t in flat)
          if (!tied.contains(t)) t
      ];
      if (loose.isNotEmpty) {
        final first = _sutras.first;
        quotes[first] = [...loose, ...?quotes[first]];
      }
      flat = const [];
    }
    final initialParagraphs = _isEdit ? null : widget.initialParagraphs;
    if (initialParagraphs != null &&
        initialParagraphs.isNotEmpty &&
        _sutras.isNotEmpty) {
      final target = _sutras.first;
      quotes[target] = [...initialParagraphs, ...?quotes[target]];
    }
    _paraCtrls = {
      for (final s in _sutras)
        s: _newParaCtrl((quotes[s] ?? const []).join('\n\n')),
    };
    _flatCtrl = _sutras.isEmpty ? _newParaCtrl(flat.join('\n\n')) : null;
    _activeSutra = _sutras.isEmpty ? null : _sutras.first;
  }

  @override
  void initState() {
    super.initState();
    _sutras = List.of(widget.entry?.sutras ?? const []);
    final initialSutra = widget.initialSutra?.trim();
    if (!_isEdit &&
        initialSutra != null &&
        initialSutra.isNotEmpty &&
        !_sutras.contains(initialSutra)) {
      _sutras.add(initialSutra);
    }
    _initParagraphEditors();
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
    for (final c in _paraCtrls.values) {
      c.dispose();
    }
    _flatCtrl?.dispose();
    _paraRev.dispose();
    _paraRules.dispose();
    super.dispose();
  }

  /// 量出当前输入区里每处「段间分界」的 y 并刷新虚线层（人天利益）。
  void _measureParaRules() {
    if (!mounted) return;
    final ctrl = _activeParaCtrl;
    final next = ctrl == null
        ? const <double>[]
        : measureParagraphRules(stackKey: _paraStackKey, ctrl: ctrl);
    if (!listEquals(_paraRules.value, next)) _paraRules.value = next;
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
    // 分卷经书只写合并名点不开对的那一卷（永远落到卷一）：提示改选带卷标的名字。
    if (ShanZhiShiStore.mergedSutraNames.contains(t)) {
      _sutraCtrl.clear();
      _setSuggestions(const []);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '《$t》分卷，请选「$t卷一」这样带卷标的名字',
            style: const TextStyle(fontSize: 13),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    setState(() {
      _sutras.add(t);
      // 新经文各有一片自己的输入区，加完顺手切到它。
      _paraCtrls[t] = _newParaCtrl();
      _activeSutra = t;
      _sutraCtrl.clear();
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
        // 最后一部经也去掉：把它这段文字留成不绑经文的段落，不要凭空丢掉。
        _flatCtrl = _newParaCtrl(removedText.trim());
      }
    });
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

  /// 当前正在编辑的那片人天利益输入区（没经文时就是那片不绑经文的）。
  TextEditingController? get _activeParaCtrl =>
      _activeSutra != null ? _paraCtrls[_activeSutra] : _flatCtrl;

  /// 已录入过有相同字符的名号时（≥2 个相同字符就算，通用尊称不计），
  /// 弹提示框：只有两个方向——点某一位 = 合并到这位旧名号（保留它的名字）；
  /// 「保存两者」= 各存各的。候选名号完整显示，不做省略。
  /// 返回 null 表示取消（留在面板上继续编辑）。
  Future<_SimilarPick?> _chooseSimilarTargets(
    List<(int, String)> candidates,
  ) {
    final p = AppPalette.p;
    return showDialog<_SimilarPick>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '或有重名善知识',
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
                  _similarTargetRow(i, candidates[i], p),
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
            key: const ValueKey('shanzhishi_add_new'),
            onPressed: () => Navigator.pop(ctx, const _SimilarPick(-1)),
            child: Text('保存两者', style: TextStyle(color: p.accentDeep)),
          ),
        ],
      ),
    );
  }

  /// 一条候选项：合并到这一位（保留它的名字）。名字完整换行显示。
  /// 第一条沿用旧的 key，便于既有测试与外部语义对齐。
  Widget _similarTargetRow(int i, (int, String) cand, PaletteData p) {
    final key = i == 0
        ? const ValueKey('shanzhishi_merge_existing')
        : ValueKey('shanzhishi_merge_existing_${cand.$1}');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        onTap: () => Navigator.of(context).pop(_SimilarPick(cand.$1)),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '合并到「${cand.$2}」（已有名号）',
                  softWrap: true,
                  style: TextStyle(fontSize: 14.5, color: p.text, height: 1.4),
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

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _saving) return;
    final store = ShanZhiShiStore.instance;
    // 人天利益按经文各收一份（一部经一片输入区，空行/换行分成多条）；
    // 没有经文时收的是那片不绑经文的段落池。
    final quotes = <String, List<String>>{};
    for (final sutra in _sutras) {
      final texts = _collectParagraphs(_paraCtrls[sutra]!);
      if (texts.isNotEmpty) quotes[sutra] = texts;
    }
    final flat = (_sutras.isEmpty && _flatCtrl != null)
        ? _collectParagraphs(_flatCtrl!)
        : <String>[];
    // 平铺的那一份（面板没有经文分组时的兜底显示）＝不绑经文的段落 + 各经文段落。
    final paragraphs = <String>[
      ...flat,
      for (final sutra in _sutras) ...?quotes[sutra],
    ];

    setState(() => _saving = true);

    // 编辑：保存前查重，与新增完全一致——摘掉通用尊称后仍有 ≥2 个相同字符
    // （如「地藏菩萨」与「地藏王菩萨」剩「地藏」+「王」）才提示，候选项可能不止一条。
    if (_isEdit) {
      final index = widget.index!;
      final similar = store.findSimilarEntries(name, skip: index);
      var pick = const _SimilarPick(-1);
      if (similar.isNotEmpty) {
        final chosen = await _chooseSimilarTargets(similar);
        if (!mounted) return;
        if (chosen == null) {
          setState(() => _saving = false);
          return;
        }
        pick = chosen;
      }
      int result;
      try {
        await store.update(
          index,
          name: name,
          sutras: _sutras,
          paragraphs: paragraphs,
          quotes: quotes,
        );
        result = pick.targetIndex >= 0
            ? await store.mergeAndRemove(index, pick.targetIndex)
            : index;
      } catch (_) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(result < 0 ? null : result);
      return;
    }

    // 新增：同样按「摘掉通用尊称后 ≥2 个相同字符」查重，列出全部候选名号，
    // 用户选合并到旧的，或「保存两者」另起一位。
    final similar = store.findSimilarEntries(name);
    var pick = const _SimilarPick(-1);
    if (similar.isNotEmpty) {
      final chosen = await _chooseSimilarTargets(similar);
      if (!mounted) return;
      if (chosen == null) {
        setState(() => _saving = false);
        return;
      }
      pick = chosen;
    }

    int result;
    try {
      if (pick.targetIndex >= 0) {
        result = await store.mergeInto(
          pick.targetIndex,
          sutras: _sutras,
          paragraphs: paragraphs,
          quotes: quotes,
        );
      } else {
        result = await store.add(
          name,
          _sutras,
          paragraphs: paragraphs,
          quotes: quotes,
          // 用户已明确选「保存两者」：同名也另起一位，不再默默合并。
          allowDuplicate: similar.isNotEmpty,
        );
      }
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
                if (_isEdit)
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
                      hintText: '地藏菩萨',
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
                  _sectionLabel(p, '人天利益'),
                  // 下面的输入区跟着「当前选中的经文」走：点上面某个经文胶囊，
                  // 这里就换成它自己的人天利益（各经文各存一份，互不串）。
                  if (_activeSutra != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '当前经文：$_activeSutra',
                      style: TextStyle(fontSize: 12, color: p.accentDeep),
                    ),
                  ],
                  const SizedBox(height: 8),
                  // 不加框：就是一片可以直接写的输入区，一段一条（空行分隔）。
                  // 三句提示直接作为占位（与上面输入框同号字），光标就落在提示
                  // 开头处，一输入提示即整块消失；段与段之间自动打一条虚线分隔。
                  ListenableBuilder(
                    listenable: Listenable.merge([_paraRev, _paraRules]),
                    builder: (context, _) {
                      final ctrl = _activeParaCtrl;
                      if (ctrl == null) return const SizedBox.shrink();
                      // 文字排完版才知道每行落在哪儿，所以量行位放到这一帧之后。
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => _measureParaRules());
                      return Stack(
                        key: _paraStackKey,
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              key:
                                  const ValueKey('shanzhishi_paragraphs_rules'),
                              painter: ParaRulePainter(
                                // 用 hint 灰而不是 border 米白：太浅的线等于没画，
                                // 这段虚线要能让用户一眼看出「这里已经分段了」。
                                rules: _paraRules.value,
                                color: p.textHint,
                              ),
                            ),
                          ),
                          TextField(
                            key: const ValueKey('shanzhishi_paragraphs_field'),
                            controller: ctrl,
                            minLines: 16,
                            maxLines: null,
                            keyboardType: TextInputType.multiline,
                            textAlignVertical: TextAlignVertical.top,
                            // 回车＝换一段：一个换行自动补成「空行＋新行」。
                            inputFormatters: const [
                              ParagraphBreakInputFormatter(),
                            ],
                            style: _paraStyle,
                            decoration: InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: '输入佛菩萨人天利益\n一段一条，空行分隔\n'
                                  '点选经文对应人天利益段落',
                              hintStyle: _paraStyle.copyWith(color: p.textHint),
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
                  onPressed:
                      _nameCtrl.text.trim().isEmpty || _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: p.primary,
                    foregroundColor: p.card,
                    disabledBackgroundColor: p.muted,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 10),
                    textStyle: const TextStyle(fontSize: 14),
                  ),
                  child: const Text('保存'),
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

  /// 一部关联经文：点一下即选中（高亮），下面的人天利益就换成它的那一份；
  /// 右侧小叉从名号里去掉这部经（连同它的人天利益一起）。
  Widget _sutraChip(String name) {
    final p = AppPalette.p;
    final active = name == _activeSutra;
    return GestureDetector(
      key: ValueKey('shanzhishi_sutra_chip_$name'),
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
              key: ValueKey('shanzhishi_sutra_remove_$name'),
              onTap: () => _removeSutra(name),
              child: Icon(Icons.close, size: 14, color: p.textSec),
            ),
          ],
        ),
      ),
    );
  }
}

/// 新增/编辑时遇到同名 / 高度相似名号，用户在提示框里选的处理方式：
/// [targetIndex] ≥ 0 = 并进该位（保留它的名字）；< 0 = 「保存两者」，
/// 各存各的（同名也各算一位）。
class _SimilarPick {
  const _SimilarPick(this.targetIndex);
  final int targetIndex;
}

/// 人天利益的分段口径（保存与画虚线共用）：空行分段；整段没有空行时一行一段。
/// 返回每段占用的行号区间 `[起, 止)`（按下标的字面行，空行只作为分隔）。
List<(int, int)> paragraphLineRanges(List<String> lines) {
  final hasBlank = lines.any((l) => l.trim().isEmpty);
  final ranges = <(int, int)>[];
  if (!hasBlank) {
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().isNotEmpty) ranges.add((i, i + 1));
    }
    return ranges;
  }
  var start = -1;
  for (var i = 0; i < lines.length; i++) {
    final blank = lines[i].trim().isEmpty;
    if (!blank && start < 0) start = i;
    if ((blank || i == lines.length - 1) && start >= 0) {
      ranges.add((start, blank ? i : i + 1));
      start = -1;
    }
  }
  return ranges;
}

/// 量出输入区里每处「段间分界」的 y：行位一律问在渲染这段文字的
/// [RenderEditable] 要，跟屏幕上的字共用一套坐标，折行/字体/行高都不必猜。
/// 分界两侧隔着空行时画在空档正中，紧挨着（一行一段的口径）就画在交界。
/// 末尾空行：光标若已落到空行下面一行（回车后的新位置），空档只算到光标
/// 行顶，虚线画在空行正中、光标在线下；光标还停在空行上时盖住光标那一行。
List<double> measureParagraphRules({
  required GlobalKey stackKey,
  required TextEditingController ctrl,
}) {
  final box = stackKey.currentContext?.findRenderObject() as RenderBox?;
  if (box == null) return const [];
  final editable = _findRenderEditable(box);
  if (editable == null) return const [];
  final raw = ctrl.text.replaceAll('\r\n', '\n');
  final lines = raw.split('\n');
  final starts = <int>[];
  var acc = 0;
  for (final l in lines) {
    starts.add(acc);
    acc += l.length + 1;
  }
  // RenderEditable 在输入区里的纵向原点（正常就是 0，取出来更保险）。
  final originY = editable.localToGlobal(Offset.zero, ancestor: box).dy;
  double lineTop(int line) =>
      originY +
      editable
          .getLocalRectForCaret(
              TextPosition(offset: starts[line].clamp(0, raw.length)))
          .top;

  final rules = <double>[];
  final ranges = paragraphLineRanges(lines);
  for (var k = 0; k < ranges.length; k++) {
    final b = ranges[k].$2;
    if (k + 1 < ranges.length) {
      final nextStart = ranges[k + 1].$1;
      final gapTop = lineTop(b);
      // 空行隔开的一段：画在空档正中；相邻两行就直接画在交界上。
      rules.add(nextStart > b
          ? (gapTop + lineTop(nextStart)) / 2
          : lineTop(nextStart));
    } else if (b < lines.length) {
      // 末尾还留着的空行。光标（量的就是文末位置）已经落到空行下面一行时，
      // 空档算到光标行顶为止；还停在同一行时按旧行为盖住光标那一行。
      final caretLine = lines.length - 1;
      if (caretLine > b) {
        rules.add((lineTop(b) + lineTop(caretLine)) / 2);
      } else {
        final caret =
            editable.getLocalRectForCaret(TextPosition(offset: raw.length));
        rules.add((lineTop(b) + originY + caret.bottom) / 2);
      }
    }
  }
  return rules;
}

/// 从输入区往下找出真正排字的那个 [RenderEditable]。
RenderEditable? _findRenderEditable(RenderObject root) {
  RenderEditable? found;
  void visit(RenderObject o) {
    if (found != null) return;
    if (o is RenderEditable) {
      found = o;
      return;
    }
    o.visitChildren(visit);
  }

  visit(root);
  return found;
}

/// 段落输入区的回车口径：按一下回车＝换一段。平台只送来一个换行，这里把
/// 它扩成「空行＋新行」并把光标放到空行下面——段间虚线随即画出，用户不必
/// 再按一次回车去追光标。光标两侧已贴着的空行会被收成一个（光标已经在空行
/// 下面时回车等于没按，不叠空行）；粘贴、删字、组字中的输入原样放行。
class ParagraphBreakInputFormatter extends TextInputFormatter {
  const ParagraphBreakInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final oldText = oldValue.text;
    final newText = newValue.text;
    // 只拦「恰好插进一个换行」的编辑。
    if (!newValue.selection.isCollapsed ||
        !newValue.composing.isCollapsed ||
        newText.length != oldText.length + 1) {
      return newValue;
    }
    final caret = newValue.selection.extentOffset;
    if (caret < 1 || newText[caret - 1] != '\n') return newValue;
    if (newText.substring(0, caret - 1) + newText.substring(caret) != oldText) {
      return newValue;
    }
    // 把插入点两侧贴着的换行收成一个空行，光标落在空行下面。
    var start = caret - 1;
    while (start > 0 && oldText[start - 1] == '\n') {
      start--;
    }
    var end = caret - 1;
    while (end < oldText.length && oldText[end] == '\n') {
      end++;
    }
    final head = oldText.substring(0, start);
    final tail = oldText.substring(end);
    return TextEditingValue(
      text: '$head\n\n$tail',
      selection: TextSelection.collapsed(offset: head.length + 2),
    );
  }
}

/// 段落输入区的段间虚线。位置不在这里算：由 [measureParagraphRules] 从
/// 真正的 `RenderEditable` 上量好每处「段间分界」的 y 交进来，这里只负责画，
/// 所以线跟字永远是同一套坐标，不会穿到上一段的字里去。
class ParaRulePainter extends CustomPainter {
  ParaRulePainter({required this.rules, required this.color});

  /// 每处「段间分界」在输入区坐标里的 y。
  final List<double> rules;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (rules.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2;
    for (final y in rules) {
      if (y < 0 || y > size.height) continue;
      _dashedLine(canvas, y, size.width, paint);
    }
  }

  void _dashedLine(Canvas canvas, double y, double width, Paint paint) {
    const dash = 4.0;
    const gap = 3.0;
    var x = 0.0;
    while (x < width) {
      final end = x + dash > width ? width : x + dash;
      canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(ParaRulePainter old) =>
      old.color != color || !listEquals(old.rules, rules);
}
