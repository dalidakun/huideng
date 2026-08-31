import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';

/// 「读经笔记」编辑页：全屏大输入框（仿「新建笔记」编辑页样式），无任何提示词。
/// 顶部自动显示 $经文名 + 段原文预览，底部可选「分享到菩提空间」开关。
/// 返回 Map{String, dynamic} 类型：null=取消，note='__delete__'=删除，
/// note=... 为保存的正文，shared 表示是否分享。
class ReadingNoteEditPage extends StatefulWidget {
  final String paragraph;
  final String initialText;
  final bool hasExistingNote;

  /// 经书名，用于顶部 $经文 标签和发布时的 $经文 引用。
  final String sutraTitle;

  /// 是否已分享到菩提空间（编辑已有笔记时传入）。
  final bool initialShared;

  /// 云端笔记 id（编辑已分享笔记时传入）。
  final String? initialCloudId;

  const ReadingNoteEditPage({
    super.key,
    required this.paragraph,
    required this.initialText,
    required this.hasExistingNote,
    required this.sutraTitle,
    this.initialShared = false,
    this.initialCloudId,
  });

  @override
  State<ReadingNoteEditPage> createState() => _ReadingNoteEditPageState();
}

class _ReadingNoteEditPageState extends State<ReadingNoteEditPage> {
  late final TextEditingController _controller;
  late bool _hasChanges;

  bool _previewExpanded = false;
  bool _previewMeasured = false;
  bool _previewOverflow = false;
  final GlobalKey _previewKey = GlobalKey();

  // 分享到菩提空间
  late bool _shared;
  String? _cloudId;
  bool _savingCloud = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _hasChanges = false;
    _shared = widget.initialShared;
    _cloudId = widget.initialCloudId;
    _controller.addListener(() {
      final changed = _controller.text != widget.initialText;
      if (changed != _hasChanges && mounted) {
        setState(() => _hasChanges = changed);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _measurePreview());
  }

  void _measurePreview() {
    if (!mounted || widget.paragraph.isEmpty) return;
    final ro = _previewKey.currentContext?.findRenderObject();
    if (ro is! RenderBox) return;
    const threeLines = 13.0 * 1.5 * 3 + 1.0;
    final overflow = ro.size.height > threeLines;
    setState(() {
      _previewOverflow = overflow;
      _previewMeasured = true;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建发布到菩提空间的完整内容：$经文名 + 段原文 + 笔记内容。
  /// 三段之间用空行（\n\n）分隔，便于帖子展示时解析出经文名 / 段原文 / 笔记。
  String _buildShareContent() {
    final noteText = _controller.text.trim();
    final parts = <String>[
      if (widget.sutraTitle.isNotEmpty) '\$${widget.sutraTitle}',
      if (widget.paragraph.isNotEmpty) widget.paragraph,
      if (noteText.isNotEmpty) noteText,
    ];
    return parts.join('\n\n');
  }

  void _close([Map<String, dynamic>? result]) {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(result);
  }

  Future<bool> _onWillPop() async {
    if (!_hasChanges) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('放弃修改？'),
        content: const Text('笔记有未保存的更改'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    return ok ?? false;
  }

  void _onShareChanged(bool value) {
    if (value && !AuthService.instance.isLoggedIn) {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }
    setState(() {
      _shared = value;
      if (!_hasChanges) _hasChanges = true;
    });
  }

  Future<void> _save() async {
    final noteText = _controller.text.trim();
    if (noteText.isEmpty && !_shared) {
      _close({'note': noteText, 'shared': false});
      return;
    }

    // 分享到菩提空间需要登录
    if (_shared && !AuthService.instance.isLoggedIn) {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }

    setState(() => _savingCloud = true);
    String? newCloudId = _cloudId;
    bool cloudOk = true;

    if (_shared) {
      try {
        final content = _buildShareContent();
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
      // 取消分享
      try {
        await CloudNotesService.instance.unpublishNote(_cloudId!);
        _cloudId = null;
      } catch (_) {}
    }

    if (mounted) {
      setState(() => _savingCloud = false);
      final sharedNow = _shared && (cloudOk || (_cloudId != null && _cloudId!.isNotEmpty));
      _close({'note': noteText, 'shared': sharedNow, 'cloudId': sharedNow ? _cloudId : null});
      if (sharedNow) {
        _showToast('已分享到菩提空间');
      }
    }
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
                color: AppPalette.p.primary,
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

  Widget _buildShareRow() {
    final p = AppPalette.p;
    final iconBg = _shared
        ? p.accent.withValues(alpha: 0.15)
        : p.textHint.withValues(alpha: 0.12);
    final iconColor = _shared ? p.accent : p.textHint;
    final titleColor = _shared ? p.text : p.textSec;
    return Container(
      color: p.card,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                  color: iconBg, borderRadius: BorderRadius.circular(8)),
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
                  Text(_shared ? '已分享，保存后同步到菩提空间' : '开启后同修可在菩提空间看到',
                      style: TextStyle(fontSize: 10, color: p.textSec)),
                ],
              ),
            ),
            if (_savingCloud)
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
              )
            else
              SwitchTheme(
                data: SwitchThemeData(
                  thumbColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                          ? AppPalette.p.card
                          : AppPalette.p.muted),
                  trackColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                          ? p.accent
                          : AppPalette.p.borderSoft),
                  trackOutlineColor: WidgetStateProperty.resolveWith(
                      (_) => Colors.transparent),
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

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (!shouldPop || !mounted) return;
        Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: p.bg,
        appBar: AppBar(
          backgroundColor: p.bg,
          elevation: 0,
          title: Text('读经想法',
              style:
                  TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.w600)),
          actions: [
            if (widget.hasExistingNote)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: GestureDetector(
                  onTap: () => _close({'note': '__delete__'}),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text('删除',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.redAccent)),
                  ),
                ),
              ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: GestureDetector(
                onTap: _save,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                  decoration: BoxDecoration(
                    color: p.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text('保存',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: p.accentDeep)),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: p.card,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // $经文名 标签（绿色，点击可进入讨论页）
                      if (widget.sutraTitle.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                          child: Text(
                            '\$${widget.sutraTitle}',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: p.accent,
                            ),
                          ),
                        ),
                      // 段原文预览（只读，淡显，默认折叠，点击可展开全文）
                      if (widget.paragraph.isNotEmpty)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _previewExpanded = !_previewExpanded),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                 Text(
                                   widget.paragraph,
                                   key: _previewKey,
                                  maxLines: (!_previewMeasured || _previewExpanded)
                                      ? null
                                      : 3,
                                  overflow:
                                      _previewExpanded ? TextOverflow.clip : TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.5,
                                    color: p.textHint,
                                  ),
                                ),
                                if (_previewOverflow)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        Text(
                                          _previewExpanded ? '点击收起' : '点击展开',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: p.accentDeep,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const SizedBox(width: 2),
                                        Icon(
                                          _previewExpanded
                                              ? Icons.keyboard_arrow_up
                                              : Icons.keyboard_arrow_down,
                                          size: 16,
                                          color: p.accentDeep,
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          maxLines: null,
                          expands: true,
                          textAlignVertical: TextAlignVertical.top,
                          autofocus: true,
                          style: TextStyle(
                              fontSize: 16, color: p.text, height: 1.7),
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.fromLTRB(16, 14, 16, 18),
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _buildShareRow(),
            ],
          ),
        ),
      ),
    );
  }
}
