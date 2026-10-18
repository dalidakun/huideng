import 'dart:async';

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'note_sutra_links.dart';
import 'shanzhishi_store.dart';

/// 善知识编辑面板：新增 / 编辑一位名号，并维护它出现过的经文。
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
      backgroundColor: AppPalette.p.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ShanZhiShiEditSheet(index: index, entry: entry),
    );
  }

  @override
  State<ShanZhiShiEditSheet> createState() => _ShanZhiShiEditSheetState();
}

class _ShanZhiShiEditSheetState extends State<ShanZhiShiEditSheet> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.entry?.name ?? '');
  final TextEditingController _sutraCtrl = TextEditingController();

  late final List<String> _sutras;
  List<NoteSutraLink> _suggestions = [];
  Timer? _debounce;
  bool _saving = false;

  bool get _isEdit => widget.index != null && widget.entry != null;

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
    _nameCtrl.dispose();
    _sutraCtrl.dispose();
    super.dispose();
  }

  void _onSutraInputChanged(String q) {
    _debounce?.cancel();
    final query = q.trim();
    if (query.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 160), () async {
      final result = await NoteSutraCatalog.search(query);
      if (!mounted || _sutraCtrl.text.trim() != query) return;
      setState(() => _suggestions = result);
    });
  }

  void _addSutra(String name) {
    final t = name.trim();
    if (t.isEmpty || _sutras.contains(t)) {
      _sutraCtrl.clear();
      setState(() => _suggestions = []);
      return;
    }
    setState(() {
      _sutras.add(t);
      _sutraCtrl.clear();
      _suggestions = [];
    });
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);
    final store = ShanZhiShiStore.instance;
    int result;
    try {
      if (_isEdit) {
        await store.update(widget.index!, name: name, sutras: _sutras);
        result = widget.index!;
      } else {
        result = await store.add(name, _sutras);
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(result < 0 ? null : result);
  }

  Future<void> _delete() async {
    final p = AppPalette.p;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除名号',
            style:
                TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: p.text)),
        content: Text('删除后「${widget.entry?.name ?? ''}」将从球面移除，确定删除吗？',
            style: TextStyle(fontSize: 14, color: p.textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: p.textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFB56A5A))),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ShanZhiShiStore.instance.removeAt(widget.index!);
    if (!mounted) return;
    Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
            const SizedBox(height: 16),
            Text('名号',
                style: TextStyle(fontSize: 12, color: p.textSec, letterSpacing: 0.5)),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              autofocus: !_isEdit,
              maxLength: 20,
              style: TextStyle(fontSize: 16, color: p.text, letterSpacing: 1),
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
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            const SizedBox(height: 16),
            Text('出现过的经文',
                style: TextStyle(fontSize: 12, color: p.textSec, letterSpacing: 0.5)),
            const SizedBox(height: 8),
            if (_sutras.isNotEmpty) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _sutras.length; i++)
                    _sutraChip(_sutras[i], i),
                ],
              ),
              const SizedBox(height: 10),
            ],
            TextField(
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
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
            if (_suggestions.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 6),
                constraints: const BoxConstraints(maxHeight: 190),
                decoration: BoxDecoration(
                  color: p.bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: p.borderSoft),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _suggestions.length,
                  itemBuilder: (ctx, i) {
                    final s = _suggestions[i];
                    return InkWell(
                      onTap: () => _addSutra(s.title),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 9),
                        child: Text(s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5, color: p.text)),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 22),
            Row(
              children: [
                if (_isEdit)
                  TextButton.icon(
                    onPressed: _delete,
                    icon: const Icon(Icons.delete_outline,
                        size: 17, color: Color(0xFFB56A5A)),
                    label: const Text('删除',
                        style:
                            TextStyle(fontSize: 13.5, color: Color(0xFFB56A5A))),
                  ),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                    textStyle: const TextStyle(fontSize: 14),
                  ),
                  child: Text(_isEdit ? '保存' : '添加'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sutraChip(String name, int index) {
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
            onTap: () => setState(() => _sutras.removeAt(index)),
            child: Icon(Icons.close, size: 14, color: p.textSec),
          ),
        ],
      ),
    );
  }
}
