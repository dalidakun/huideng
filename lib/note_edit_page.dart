import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';
import 'note_sutra_links.dart';

const Color _primary = Color(0xFF5C4033);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _gold = Color(0xFFD4A06A);

class NoteEditPage extends StatefulWidget {
  final Map<String, dynamic>? note;
  const NoteEditPage({super.key, this.note});

  @override
  State<NoteEditPage> createState() => _NoteEditPageState();
}

class _NoteEditPageState extends State<NoteEditPage> {
  late TextEditingController _contentController;
  bool _hasChanges = false;
  String? _savedId;
  late bool _shared;
  String? _cloudId;
  bool _savingCloud = false;

  // @经书 搜索状态
  List<NoteSutraLink> _sutraResults = [];
  bool _sutraPanelVisible = false;
  bool _justInsertedSutra = false;
  int _atIndex = -1;
  Timer? _sutraDebounce;

  @override
  void initState() {
    super.initState();
    _contentController = TextEditingController(text: widget.note?['content'] ?? '');
    _shared = widget.note?['shared'] == true;
    _cloudId = widget.note?['cloudId'] as String?;
    _contentController.addListener(_onContentChanged);
  }

  void _onContentChanged() {
    // 刚由程序插入 @经书 产生的一次变化，不触发搜索，避免选中后立刻又弹出面板。
    if (_justInsertedSutra) {
      _justInsertedSutra = false;
      if (!_hasChanges) setState(() => _hasChanges = true);
      return;
    }
    if (!_hasChanges) setState(() => _hasChanges = true);

    final text = _contentController.text;
    final sel = _contentController.selection;
    var panelVisible = false;
    var atIndex = -1;
    var query = '';
    if (sel.isValid && sel.isCollapsed) {
      final cursor = sel.start;
      final at = cursor > 0 ? text.lastIndexOf('@', cursor - 1) : -1;
      if (at >= 0) {
        // 已成形标记内部、或 @ 前是 '[' 时不触发搜索。
        final insideExisting = at > 0 && text[at - 1] == '[';
        final seg = text.substring(at, cursor);
        final valid = !insideExisting &&
            !seg.substring(1).contains(RegExp(r'[\s\[\]\(\)@]'));
        if (valid) {
          panelVisible = true;
          atIndex = at;
          query = seg.substring(1);
        }
      }
    }

    if (!panelVisible) {
      if (_sutraPanelVisible || _atIndex >= 0) {
        setState(() {
          _sutraResults = [];
          _sutraPanelVisible = false;
          _atIndex = -1;
        });
      }
      return;
    }

    if (!_sutraPanelVisible || _atIndex != atIndex) {
      setState(() {
        _sutraPanelVisible = true;
        _atIndex = atIndex;
        _sutraResults = [];
      });
    }
    _sutraDebounce?.cancel();
    if (query.isEmpty) return;
    _sutraDebounce = Timer(const Duration(milliseconds: 250), () async {
      final results = await NoteSutraCatalog.search(query);
      if (!mounted) return;
      final curText = _contentController.text;
      final curSel = _contentController.selection;
      final stillActive = _sutraPanelVisible &&
          _atIndex == atIndex &&
          curSel.isValid &&
          curSel.isCollapsed &&
          curText.lastIndexOf('@', curSel.start - 1) == atIndex;
      if (stillActive) setState(() => _sutraResults = results);
    });
  }

  void _insertSutra(NoteSutraLink link) {
    final text = _contentController.text;
    final sel = _contentController.selection;
    final cursor = sel.isValid ? sel.start : text.length;
    final at = _atIndex >= 0 ? _atIndex : text.lastIndexOf('@', cursor - 1);
    if (at < 0 || at >= cursor) return;
    final token = NoteSutraLinks.encode(link.title);
    _justInsertedSutra = true;
    _contentController.value = TextEditingValue(
      text: text.replaceRange(at, cursor, token),
      selection: TextSelection.collapsed(offset: at + token.length),
    );
    setState(() {
      _sutraResults = [];
      _sutraPanelVisible = false;
      _atIndex = -1;
    });
  }

  void _hideSutraPanel() {
    _sutraDebounce?.cancel();
    setState(() {
      _sutraResults = [];
      _sutraPanelVisible = false;
      _atIndex = -1;
    });
  }

  @override
  void dispose() {
    _sutraDebounce?.cancel();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final content = _contentController.text.trim();
    if (content.isEmpty) return;

    if (_shared && !AuthService.instance.isLoggedIn) {
      _showToast('分享到菩提空间需要先登录');
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }

    setState(() => _savingCloud = true);
    String? newCloudId = _cloudId;
    bool cloudOk = true;

    if (_shared) {
      try {
        if (_cloudId == null || _cloudId!.isEmpty) {
          newCloudId = await CloudNotesService.instance.publishNote(
            title: '',
            content: content,
          );
        } else {
          await CloudNotesService.instance.updateSharedNote(
            cloudId: _cloudId!,
            title: '',
            content: content,
            isPublic: true,
          );
        }
        _cloudId = newCloudId;
      } catch (e) {
        cloudOk = false;
        if (mounted) _showToast('分享失败：${e.toString()}');
      }
    } else if (_cloudId != null && _cloudId!.isNotEmpty) {
      try {
        await CloudNotesService.instance.unpublishNote(_cloudId!);
      } catch (_) {}
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('notes') ?? '[]';
    final List<dynamic> notes = jsonDecode(raw);
    final now = DateTime.now().toIso8601String();

    final sharedNow =
        _shared && (cloudOk || (_cloudId != null && _cloudId!.isNotEmpty));
    final targetId = _savedId ?? widget.note?['id'] ?? now;
    final newNote = <String, dynamic>{
      'id': targetId,
      'title': '',
      'content': content,
      'updatedAt': now,
      'shared': sharedNow,
      'cloudId': sharedNow ? (_cloudId ?? newCloudId) : null,
    };
    final index = notes.indexWhere((n) => n['id'] == targetId);
    if (index >= 0) {
      notes[index] = newNote;
    } else {
      notes.add(newNote);
    }

    await prefs.setString('notes', jsonEncode(notes));
    if (mounted) {
      setState(() {
        _savedId = targetId;
        _hasChanges = false;
        _savingCloud = false;
      });
      _showSavedToast(sharedNow ? '已保存并分享' : '已保存到草稿');
    }
  }

  void _onShareChanged(bool value) {
    if (value && !AuthService.instance.isLoggedIn) {
      _showToast('分享到菩提空间需要先登录');
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }
    setState(() {
      _shared = value;
      if (!_hasChanges) _hasChanges = true;
    });
  }

  Widget _buildSutraPanel() {
    final results = _sutraResults;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFEBE1D6)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 16,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
            child: Row(
              children: [
                const Icon(Icons.menu_book_outlined, size: 15, color: _textHint),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text('选择经书',
                      style: TextStyle(
                          fontSize: 13,
                          color: _textSec,
                          fontWeight: FontWeight.w600)),
                ),
                GestureDetector(
                  onTap: _hideSutraPanel,
                  child: const Icon(Icons.close, size: 16, color: _textHint),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFEBE1D6)),
          if (results.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text('输入经书名称开始搜索，例如：地藏',
                    style: TextStyle(fontSize: 13, color: _textHint)),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 6),
                itemCount: results.length,
                itemBuilder: (context, index) {
                  final s = results[index];
                  return InkWell(
                    onTap: () => _insertSutra(s),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 9),
                      child: Row(
                        children: [
                          Icon(Icons.menu_book_rounded, size: 17, color: _gold),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: _text)),
                                if (s.folder.isNotEmpty) ...[
                                  const SizedBox(height: 1),
                                  Text(s.folder,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 11, color: _textHint)),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildShareRow() {
    final iconBg =
        _shared ? _gold.withValues(alpha: 0.15) : _textHint.withValues(alpha: 0.12);
    final iconColor = _shared ? _gold : _textHint;
    final titleColor = _shared ? _text : _textSec;
    return Container(
      color: _card,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.people_outline, size: 16, color: iconColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('分享到菩提空间',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: titleColor)),
                  const SizedBox(height: 1),
                  Text(
                      _shared ? '已分享，保存后同步到菩提空间' : '开启后同修可在菩提空间看到',
                      style: const TextStyle(fontSize: 10, color: _textSec)),
                ],
              ),
            ),
            if (_savingCloud)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
              )
            else
              SwitchTheme(
                data: SwitchThemeData(
                  thumbColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                          ? const Color(0xFFFFFAF5)
                          : const Color(0xFFC9BFB2)),
                  trackColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                          ? _gold
                          : const Color(0xFFE8DED0)),
                  trackOutlineColor:
                      WidgetStateProperty.resolveWith((_) => Colors.transparent),
                ),
                child: Switch(
                  value: _shared,
                  onChanged: _savingCloud ? null : _onShareChanged,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showToast(String text) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final topInset = MediaQuery.of(ctx).padding.top;
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: EdgeInsets.only(top: topInset + kToolbarHeight + 10),
            child: Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: _primary,
                borderRadius: BorderRadius.circular(20),
                elevation: 0,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (entry.mounted) entry.remove();
    });
  }

  void _showSavedToast(String message) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final topInset = MediaQuery.of(ctx).padding.top;
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: EdgeInsets.only(top: topInset + kToolbarHeight + 10),
            child: Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: _primary,
                borderRadius: BorderRadius.circular(20),
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle, size: 14, color: Colors.white),
                      const SizedBox(width: 5),
                      Text(message,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.none,
                          decorationColor: Colors.transparent,
                        )),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (entry.mounted) entry.remove();
    });
  }

  Future<bool> _onWillPop() async {
    if (!_hasChanges) return true;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('放弃修改？', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: const Text('您有未保存的更改', style: TextStyle(color: _textSec)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: _textSec))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('放弃', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.note == null && _savedId == null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          elevation: 0,
          title: Text(isNew ? '新建笔记' : '编辑笔记',
              style: const TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: GestureDetector(
                onTap: _save,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                  decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Text('保存', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _primary)),
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _contentController,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(fontSize: 16, color: _text, height: 1.6),
                      decoration: InputDecoration(
                        hintText: '开始记录...\n输入 @ 可引用经书',
                        hintStyle: TextStyle(color: _textHint),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 18),
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  ),
                  if (_sutraPanelVisible)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildSutraPanel(),
                    ),
                ],
              ),
            ),
            _buildShareRow(),
          ],
        ),
      ),
    );
  }
}
