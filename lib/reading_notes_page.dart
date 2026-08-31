import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 「读经笔记」页：列出某本经所有带备注/完成态的段落。
/// 点击某条返回该段索引，由阅读页跳回对应段落。
class ReadingNotesPage extends StatefulWidget {
  final String sutraKey;
  final String title;
  final List<String> paragraphs;
  final Map<int, String> notes;
  final Map<int, bool> done;
  final Future<void> Function(int index) onDelete;
  final Future<void> Function(int index, String note) onSave;
  final Future<void> Function(int index) onToggleDone;

  const ReadingNotesPage({
    super.key,
    required this.sutraKey,
    required this.title,
    required this.paragraphs,
    required this.notes,
    required this.done,
    required this.onDelete,
    required this.onSave,
    required this.onToggleDone,
  });

  @override
  State<ReadingNotesPage> createState() => _ReadingNotesPageState();
}

class _ReadingNotesPageState extends State<ReadingNotesPage> {
  bool _dark = false;

  @override
  Widget build(BuildContext context) {
    _dark = Theme.of(context).brightness == Brightness.dark;
    // 汇总所有有备注或有完成态的段落，按索引升序。
    final entries = <int>[
      for (var i = 0; i < widget.paragraphs.length; i++)
        if (widget.done[i] == true || (widget.notes[i] ?? '').isNotEmpty) i,
    ]..sort();

    final bg = _dark ? const Color(0xFF1A1A1A) : const Color(0xFFFAF7F2);
    final fg = _dark ? Colors.white : const Color(0xFF212121);
    final sub = _dark ? Colors.white.withOpacity(0.6) : const Color(0xFF8A8A8A);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        foregroundColor: fg,
        elevation: 0,
        title: Text('读经想法：${widget.title}',
            style: TextStyle(fontSize: 16, color: fg)),
      ),
      body: entries.isEmpty
          ? Center(
              child: Text(
                '还没有为《${widget.title}》添加段落想法\n点击每段右侧的「想法」按钮即可记录',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14, height: 1.6, color: _dark ? Colors.white38 : Colors.black38),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: entries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final index = entries[i];
                final note = widget.notes[index] ?? '';
                final done = widget.done[index] == true;
                final p = widget.paragraphs[index];
                return InkWell(
                  onTap: () => Navigator.of(context).pop(index),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 完成态方框
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () async {
                                await widget.onToggleDone(index);
                                if (!mounted) return;
                                setState(() {});
                              },
                              child: Container(
                                width: 18,
                                height: 18,
                                margin: const EdgeInsets.only(top: 2, right: 10),
                                decoration: BoxDecoration(
                                  color: done ? AppPalette.p.accent : Colors.transparent,
                                  border: Border.all(
                                    color: done ? AppPalette.p.accent : sub,
                                    width: 1.2,
                                  ),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: done
                                    ? Icon(Icons.check,
                                        size: 13,
                                        color: _dark ? const Color(0xFF1A1A1A) : Colors.white)
                                    : null,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                p,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: done ? sub : fg,
                                ),
                              ),
                            ),
                            Icon(Icons.chevron_right, color: sub, size: 18),
                          ],
                        ),
                        if (note.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: done
                                  ? (AppPalette.p.accent.withOpacity(0.08))
                                  : (AppPalette.p.accent.withOpacity(0.08)),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              note,
                              style: TextStyle(fontSize: 13, height: 1.6, color: fg),
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton.icon(
                              onPressed: () => _editNote(index, note),
                              icon: const Icon(Icons.edit_outlined, size: 15),
                              label: const Text('编辑'),
                              style: TextButton.styleFrom(
                                foregroundColor: AppPalette.p.accent,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                            if (note.isNotEmpty)
                              TextButton.icon(
                                onPressed: () async {
                                  await widget.onDelete(index);
                                  if (!mounted) return;
                                  setState(() {});
                                },
                                icon: const Icon(Icons.delete_outline, size: 15),
                                label: const Text('删除'),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.redAccent,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _editNote(int index, String current) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _NotesEditDialog(initialText: current),
    );
    if (result == null) return;
    await widget.onSave(index, result);
    if (!mounted) return;
    setState(() {});
  }
}

/// 编辑笔记对话框。自持并释放 TextEditingController，且在 pop 前先收起键盘，
/// 避免「保存/取消」时路由拆除 + 键盘收起动画叠加触发
/// framework `_dependents.isEmpty` 停用竞态断言。
class _NotesEditDialog extends StatefulWidget {
  const _NotesEditDialog({required this.initialText});

  final String initialText;

  @override
  State<_NotesEditDialog> createState() => _NotesEditDialogState();
}

class _NotesEditDialogState extends State<_NotesEditDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _close([String? result]) {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑想法'),
      content: TextField(
        controller: _controller,
        maxLines: 5,
        minLines: 2,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _close(_controller.text),
        decoration: const InputDecoration(
          hintText: '为这段经文写下你的想法…',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => _close(), child: const Text('取消')),
        TextButton(onPressed: () => _close(_controller.text), child: const Text('保存')),
      ],
    );
  }
}
