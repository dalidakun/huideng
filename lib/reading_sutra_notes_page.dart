import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'note_edit_page.dart';
import 'pdf_export.dart';
import 'login_page.dart';
import 'sutra_list_page.dart' show routeObserver;

/// 读经笔记分享帖的元数据哨兵前缀：用于标识这是读经笔记汇总帖。
/// 菩提空间展示时只显示第一篇笔记，点击色块用完整数据打开笔记汇总页。
const String kSutraNotesMetaPrefix = '\u00a7\u00a7SN\u00a7\u00a7';

/// 「读经笔记」汇总页：列出本经所有从右下角笔记按钮编写的笔记，
/// 笔记内容来自 SharedPreferences 本地存储，按经文名筛选。
/// 样式：浅色阴影卡片包裹每条笔记，带时间戳和分享状态标记。
/// 他人查看时从云端加载笔记，点击进入帖子详情页（不可编辑/删除）。
class ReadingSutraNotesPage extends StatefulWidget {
  /// 经名。
  final String title;

  /// 帖子作者 userId（非空时为他人查看模式）。
  final String ownerUserId;

  /// 他人查看模式下传入的笔记列表（从云端分享帖解析）。
  final List<Map<String, dynamic>>? initialNotes;

  /// 菩提空间帖子 noteId（他人查看时点击笔记进入帖子详情页）。
  final String noteId;

  const ReadingSutraNotesPage({
    super.key,
    required this.title,
    this.ownerUserId = '',
    this.initialNotes,
    this.noteId = '',
  });

  @override
  State<ReadingSutraNotesPage> createState() => _ReadingSutraNotesPageState();
}

/// 笔记数据项。
class _NoteItem {
  final String id;
  final String content;
  final DateTime updatedAt;
  final bool shared;
  final String? cloudId;

  const _NoteItem({
    required this.id,
    required this.content,
    required this.updatedAt,
    required this.shared,
    this.cloudId,
  });
}

class _ReadingSutraNotesPageState extends State<ReadingSutraNotesPage>
    with RouteAware {
  static const _bg = Color(0xFFFAF7F2);
  static const _card = Colors.white;
  static const _fg = Color(0xFF212121);
  static const _red = Color(0xFFDD6B6B);
  static const _green = Color(0xFF71867A);

  bool _showMenu = false;
  bool _exporting = false;
  bool _sharing = false;
  List<_NoteItem> _notes = [];
  bool _loading = true;

  /// 已展开的笔记下标集合。
  final Set<int> _expandedNotes = {};

  /// 笔记折叠阈值：超过此字符数默认折叠。
  static const _foldThreshold = 120;

  /// 已分享到菩提空间的帖子 cloudId。
  String? _shareCloudId;

  /// 是否为作者本人（ownerUserId 为空时视为作者本人，即从阅读页直接进入）。
  bool get _isOwner {
    final meId = AuthService.instance.cachedUserId;
    return widget.ownerUserId.isEmpty ||
        (meId != null && meId.isNotEmpty && widget.ownerUserId == meId);
  }

  bool _routeSubscribed = false;

  @override
  void initState() {
    super.initState();
    _loadNotes();
    if (_isOwner) _loadShareCloudId();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null && !_routeSubscribed) {
      _routeSubscribed = true;
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() {
    // 从菩提空间返回时刷新笔记列表
    if (_isOwner) _loadNotes();
  }

  @override
  void dispose() {
    if (_routeSubscribed) routeObserver.unsubscribe(this);
    super.dispose();
  }

  String get _sutraName => widget.title;

  /// 加载笔记：作者本人从本地 SharedPreferences 加载，他人从 initialNotes 加载。
  Future<void> _loadNotes() async {
    if (!_isOwner && widget.initialNotes != null) {
      // 他人查看模式：从传入的云端笔记加载
      final filtered = <_NoteItem>[];
      final sutraTag = '\$$_sutraName';
      for (final note in widget.initialNotes!) {
        final content = (note['content'] ?? '').toString();
        if (content.contains(sutraTag)) {
          DateTime updatedAt;
          try {
            updatedAt = DateTime.parse((note['updatedAt'] ?? '').toString());
          } catch (_) {
            updatedAt = DateTime.now();
          }
          filtered.add(_NoteItem(
            id: (note['id'] ?? '').toString(),
            content: content,
            updatedAt: updatedAt,
            shared: note['shared'] == true,
            cloudId: note['cloudId'] as String?,
          ));
        }
      }
      filtered.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (mounted) {
        setState(() {
          _notes = filtered;
          _loading = false;
        });
      }
      return;
    }

    // 作者本人：从 SharedPreferences 加载
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('notes') ?? '[]';
      final List<dynamic> notesList = jsonDecode(raw);

      // 筛选与当前经文相关的笔记（内容包含 $经文名）
      final sutraTag = '\$$_sutraName';
      final filtered = <_NoteItem>[];
      for (final note in notesList) {
        if (note is! Map<String, dynamic>) continue;
        final content = (note['content'] ?? '').toString();
        if (content.contains(sutraTag)) {
          final updatedAtStr = (note['updatedAt'] ?? '').toString();
          DateTime updatedAt;
          try {
            updatedAt = DateTime.parse(updatedAtStr);
          } catch (_) {
            updatedAt = DateTime.now();
          }
          filtered.add(_NoteItem(
            id: (note['id'] ?? '').toString(),
            content: content,
            updatedAt: updatedAt,
            shared: note['shared'] == true,
            cloudId: note['cloudId'] as String?,
          ));
        }
      }

      // 按更新时间倒序排列
      filtered.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      if (mounted) {
        setState(() {
          _notes = filtered;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  /// 从 SharedPreferences 加载已分享的帖子 cloudId。
  Future<void> _loadShareCloudId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'sutra_notes_share_${widget.title}';
      final saved = prefs.getString(key);
      if (saved != null && saved.isNotEmpty && mounted) {
        setState(() => _shareCloudId = saved);
      }
    } catch (_) {}
  }

  /// 保存已分享的帖子 cloudId 到 SharedPreferences。
  Future<void> _saveShareCloudId(String cloudId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'sutra_notes_share_${widget.title}';
      await prefs.setString(key, cloudId);
      if (mounted) setState(() => _shareCloudId = cloudId);
    } catch (_) {}
  }

  /// 格式化时间戳。
  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}月${dt.day}日';
  }

  /// 打开笔记：作者本人进入编辑页，他人进入帖子详情页（带评论/点赞/转发）。
  void _openNoteEditor(int index) async {
    if (!_isOwner) {
      // 他人查看：进入帖子详情页
      if (widget.noteId.isNotEmpty && mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => NoteDetailPage(noteId: widget.noteId),
          ),
        );
      }
      return;
    }
    // 作者本人：进入编辑页
    final note = _notes[index];
    final noteMap = <String, dynamic>{
      'id': note.id,
      'content': note.content,
      'updatedAt': note.updatedAt.toIso8601String(),
      'shared': note.shared,
      'cloudId': note.cloudId,
    };
    await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => NoteEditPage(note: noteMap),
      ),
    );
    // 返回后刷新列表
    if (mounted) {
      _loadNotes();
    }
  }

  /// 删除笔记。
  Future<void> _confirmDelete(int index) async {
    if (index >= _notes.length) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除笔记？', style: TextStyle(fontSize: 16)),
        content: const Text(
          '删除后将移入回收站',
          style: TextStyle(fontSize: 13, color: Color(0xFF666666)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
                const Text('取消', style: TextStyle(color: Color(0xFF666666))),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除', style: TextStyle(color: _red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final note = _notes[index];
    // 如果已分享到云端，先隐藏云端笔记
    if (note.shared && note.cloudId != null && note.cloudId!.isNotEmpty) {
      try {
        await CloudNotesService.instance.hideCloudNote(note.cloudId!);
      } catch (_) {}
    }

    // 移入回收站
    final prefs = await SharedPreferences.getInstance();
    final trashRaw = prefs.getString('trash_notes') ?? '[]';
    final trash =
        (jsonDecode(trashRaw) as List<dynamic>).cast<Map<String, dynamic>>();
    trash.add({
      'id': note.id,
      'content': note.content,
      'updatedAt': note.updatedAt.toIso8601String(),
      'shared': note.shared,
      'cloudId': note.cloudId,
      'deletedAt': DateTime.now().toIso8601String(),
    });
    await prefs.setString('trash_notes', jsonEncode(trash));

    // 从本地笔记列表中移除
    final notesRaw = prefs.getString('notes') ?? '[]';
    final notesList =
        (jsonDecode(notesRaw) as List<dynamic>).cast<Map<String, dynamic>>();
    notesList.removeWhere((n) => n['id'] == note.id);
    await prefs.setString('notes', jsonEncode(notesList));

    setState(() => _notes.removeAt(index));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已移入回收站'), duration: Duration(seconds: 1)),
    );
  }

  /// 导出 PDF。
  Future<void> _exportPdf() async {
    if (_exporting) return;
    if (_notes.isEmpty) {
      _toast('没有可导出的笔记');
      return;
    }
    setState(() => _exporting = true);
    try {
      final pairs = _notes.map((n) {
        // 去掉 $经文名 前缀
        final content = n.content.replaceFirst('\$$_sutraName', '').trim();
        return ('', content);
      }).toList();
      final pdf = await PdfExporter.buildReadingNotesPdf(
        sutraName: _sutraName,
        pairs: pairs,
      );
      if (pdf.isEmpty) {
        _toast('生成失败：内容为空');
        return;
      }
      final savedPath = await _savePdf(pdf);
      if (savedPath != null) {
        _showSavedToastWithView(savedPath, pdf);
      }
    } catch (e) {
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<String?> _savePdf(Uint8List bytes) async {
    final safeTitle = _sutraName
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '');
    final filename = '${safeTitle}_笔记.pdf';
    try {
      final savedPath = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          data: bytes,
          fileName: filename,
          mimeTypesFilter: const ['application/pdf'],
        ),
      );
      if (savedPath != null && savedPath.isNotEmpty) return savedPath;
    } catch (_) {}
    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '导出PDF',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      if (savePath != null &&
          savePath.isNotEmpty &&
          !savePath.startsWith('content:')) {
        final file = File(savePath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        return savePath;
      }
    } catch (_) {}
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$filename');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  /// 构建发布到菩提空间的分享帖正文。
  /// 格式：$经文名 + 第一篇笔记内容 + §§SN§§ 元数据 + 留言。
  /// 菩提空间展示时只显示第一篇笔记（色块），点击色块打开笔记汇总页。
  String _buildShareContent(String message) {
    if (_notes.isEmpty) return '';
    // 只分享已标注「已分享」的笔记
    final sharedNotes = _notes.where((n) => n.shared).toList();
    if (sharedNotes.isEmpty) return '';

    // 用第一条笔记的内容作为预览（去掉 $经文名 前缀）
    final firstContent = sharedNotes.first.content
        .replaceFirst('\$$_sutraName', '')
        .trim();

    // 编码所有已分享笔记的元数据
    final meta = _encodeNotes(sharedNotes);

    // 格式：$经文名\n\n第一篇笔记\n\n§§SN§§ + base64...\n\n留言
    final lines = <String>[
      if (_sutraName.isNotEmpty) '\$$_sutraName',
      if (firstContent.isNotEmpty) firstContent,
      '$kSutraNotesMetaPrefix$meta',
      if (message.trim().isNotEmpty) message.trim(),
    ];
    return lines.join('\n\n');
  }

  static String _encodeNotes(List<_NoteItem> notes) {
    final arr = [
      for (final n in notes) {'c': n.content},
    ];
    return base64Encode(utf8.encode(jsonEncode(arr)));
  }

  /// 分享到菩提空间。
  Future<void> _share() async {
    if (!AuthService.instance.isLoggedIn) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('分享到菩提空间需要先登录')),
      );
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
      return;
    }
    final sharedNotes = _notes.where((n) => n.shared).toList();
    if (sharedNotes.isEmpty) {
      _toast('请先将笔记标注为「已分享」再进行分享');
      return;
    }
    final first = sharedNotes.first.content;
    final accent = AppPalette.p.accent;
    final isUpdate =
        _shareCloudId != null && _shareCloudId!.isNotEmpty;
    final message = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final ctrl = TextEditingController();
        return Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SafeArea(
            child: StatefulBuilder(
              builder: (ctx, setSheet) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        isUpdate ? '更新菩提空间笔记' : '分享到菩提空间',
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _fg),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          first,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.6,
                            color: _fg,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: ctrl,
                        maxLines: 4,
                        maxLength: 500,
                        style: const TextStyle(fontSize: 15, color: _fg),
                        decoration: const InputDecoration(
                          hintText: '说点什么……',
                          hintStyle:
                              TextStyle(fontSize: 14, color: Color(0xFFB9B9B9)),
                          filled: true,
                          fillColor: Color(0xFFF5F5F5),
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.all(Radius.circular(10)),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (_) => setSheet(() {}),
                      ),
                      const SizedBox(height: 4),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () =>
                            Navigator.of(ctx).pop(ctrl.text.trim()),
                        child: Container(
                          height: 46,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(23),
                          ),
                          child: Text(
                            isUpdate ? '更新' : '分享',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
    if (message == null || !mounted) return;
    setState(() => _sharing = true);
    try {
      final content = _buildShareContent(message);
      if (content.isEmpty) {
        _toast('没有可分享的笔记');
        return;
      }
      if (isUpdate) {
        await CloudNotesService.instance.updateSharedNote(
          cloudId: _shareCloudId!,
          content: content,
        );
      } else {
        final newCloudId = await CloudNotesService.instance.publishNote(
          title: '',
          content: content,
        );
        if (newCloudId.isNotEmpty) {
          await _saveShareCloudId(newCloudId);
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(isUpdate ? '已更新菩提空间笔记' : '已分享到菩提空间'),
            duration: const Duration(seconds: 2)),
      );
    } catch (e) {
      if (!mounted) return;
      _toast('分享失败：${e is CloudApiException ? e.message : e}');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _showSavedToastWithView(String savedPath, Uint8List pdfBytes) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    Timer? timer;
    void dismiss() {
      timer?.cancel();
      if (entry.mounted) entry.remove();
    }

    entry = OverlayEntry(
      builder: (ctx) {
        final bottomInset = MediaQuery.of(ctx).padding.bottom;
        return Positioned(
          left: 16,
          right: 16,
          bottom: bottomInset + 24,
          child: Material(
            color: AppPalette.p.primary,
            borderRadius: BorderRadius.circular(12),
            elevation: 4,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                dismiss();
                Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => _PdfViewerPage(
                    bytes: pdfBytes,
                    title: '读经笔记 PDF',
                  ),
                ));
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          text: '已保存：$savedPath，',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                          children: const [
                            TextSpan(
                              text: '点击查看',
                              style: TextStyle(
                                color: Color(0xFFE0C9A8),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: dismiss,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child:
                            Icon(Icons.close, size: 16, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    timer = Timer(const Duration(seconds: 10), dismiss);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _fg,
        elevation: 0,
        title: Text('笔记：$_sutraName',
            style: const TextStyle(fontSize: 16, color: _fg)),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_horiz, size: 22, color: _fg),
            onPressed: () => setState(() => _showMenu = !_showMenu),
          ),
        ],
      ),
      body: Stack(
        children: [
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _notes.isEmpty
                  ? Center(
                      child: Text(
                        '还没有为《$_sutraName》编写笔记\n点击右下角的笔记按钮即可开始记录',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 14, height: 1.6, color: Colors.black38),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      itemCount: _notes.length,
                      itemBuilder: (context, i) {
                        final note = _notes[i];
                        final isDark = AppPalette.instance.isPlain &&
                            Theme.of(context).brightness == Brightness.dark;

                        // 去掉 $经文名 前缀，只显示用户写的内容
                        var displayContent = note.content
                            .replaceFirst('\$$_sutraName', '')
                            .trim();

                        final isExpanded = _expandedNotes.contains(i);
                        final isLong = displayContent.length > _foldThreshold;
                        final showContent = isExpanded || !isLong
                            ? displayContent
                            : '${displayContent.substring(0, _foldThreshold)}…';

                        return GestureDetector(
                          onTap: () => _openNoteEditor(i),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              color: _card,
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.06),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 笔记内容
                                  Text(
                                    showContent,
                                    style: TextStyle(
                                      fontSize: 14,
                                      height: 1.7,
                                      color: isDark
                                          ? Colors.white.withOpacity(0.9)
                                          : _fg,
                                    ),
                                  ),
                                  // 展开/折叠按钮
                                  if (isLong)
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        setState(() {
                                          if (isExpanded) {
                                            _expandedNotes.remove(i);
                                          } else {
                                            _expandedNotes.add(i);
                                          }
                                        });
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          isExpanded ? '折叠' : '展开',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: AppPalette.p.accent,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  const SizedBox(height: 10),
                                  // 底部：时间戳 + 分享状态 + 删除
                                  Row(
                                    children: [
                                      // 时间戳
                                      Icon(Icons.access_time,
                                          size: 13,
                                          color: isDark
                                              ? Colors.white38
                                              : const Color(0xFF999999)),
                                      const SizedBox(width: 4),
                                      Text(
                                        _formatTime(note.updatedAt),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isDark
                                              ? Colors.white38
                                              : const Color(0xFF999999),
                                        ),
                                      ),
                                      const Spacer(),
                                      // 分享状态标记（右侧，紧挨删除按钮）
                                      if (note.shared) ...[
                                        Icon(Icons.cloud_done,
                                            size: 13, color: _green),
                                        const SizedBox(width: 4),
                                        Text(
                                          '已分享',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: _green,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ] else ...[
                                        Icon(Icons.cloud_off,
                                            size: 13,
                                            color: isDark
                                                ? Colors.white24
                                                : const Color(0xFFCCCCCC)),
                                        const SizedBox(width: 4),
                                        Text(
                                        '未分享',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isDark
                                              ? Colors.white24
                                              : const Color(0xFFCCCCCC),
                                        ),
                                      ),
                                      ],
                                      // 删除按钮（仅作者本人）
                                      if (_isOwner) ...[
                                        const SizedBox(width: 12),
                                        GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => _confirmDelete(i),
                                          child: Padding(
                                            padding: const EdgeInsets.all(4),
                                            child: Icon(Icons.delete_outline,
                                                size: 16, color: _red),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          if (_showMenu)
            Positioned(
              top: 4,
              right: 16,
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(12),
                color: Colors.white,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildMenuTile(
                        icon: _exporting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.picture_as_pdf_outlined,
                                size: 18),
                        label: '导出PDF',
                        onTap: () {
                          setState(() => _showMenu = false);
                          _exportPdf();
                        },
                      ),
                      _buildMenuTile(
                        icon: _sharing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.share_outlined, size: 18),
                        label: '分享',
                        onTap: () {
                          setState(() => _showMenu = false);
                          _share();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMenuTile({
    required Widget icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconTheme(data: const IconThemeData(color: _fg), child: icon),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(color: _fg, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

/// 内置 PDF 预览页。
class _PdfViewerPage extends StatefulWidget {
  final Uint8List bytes;
  final String title;

  const _PdfViewerPage({required this.bytes, required this.title});

  @override
  State<_PdfViewerPage> createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<_PdfViewerPage> {
  final List<PdfRaster> _pages = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _render();
  }

  Future<void> _render() async {
    try {
      await for (final page
          in Printing.raster(widget.bytes, dpi: PdfPageFormat.inch * 2)) {
        if (!mounted) return;
        setState(() {
          _pages.add(page);
          _loading = false;
        });
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'PDF 打开失败：$e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAF7F2),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF212121),
        elevation: 0.3,
        title: Text(widget.title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        centerTitle: false,
      ),
      body: _loading && _pages.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.broken_image_outlined,
                            size: 48, color: Color(0xFF8A8A8A)),
                        const SizedBox(height: 12),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 14, color: Color(0xFF8A8A8A))),
                      ],
                    ),
                  ),
                )
              : _pages.isEmpty
                  ? Center(
                      child: Text('该 PDF 无可显示内容',
                          style: const TextStyle(color: Color(0xFF8A8A8A))),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 12),
                      itemCount: _pages.length,
                      itemBuilder: (ctx, i) {
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 6,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image(
                              image: PdfRasterImage(_pages[i]),
                              fit: BoxFit.contain,
                              width: double.infinity,
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
