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

import 'app_palette.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'pdf_export.dart';
import 'login_page.dart';
import 'ai_translate_page.dart';

/// 感想分享帖正文里的元数据哨兵前缀：后面紧跟 base64 编码的
/// 「(经文,感想) 成对数组」JSON。展示时只显示第一条经文，点击色块用完整数据打开感想页。
const String kSutraThoughtsMetaPrefix = '\u00a7\u00a7TS\u00a7\u00a7';

/// 「读经感想」汇总页：列出本经所有带感想（备注）的段落，经文与感想成组展示。
/// 样式与「画线归集」页一致（米白底 + 白色卡片）；只读展示：
///   - 经文较长时可点击折叠 / 展开
///   - 右上角三点可导出 PDF / 分享到菩提空间
/// 该页同时被菩提空间的感想分享帖复用（点击色块进入）。
class ReadingNotesPage extends StatefulWidget {
  /// 经名。
  final String title;

  /// 各段经文（与 [notes] 一一对应）。
  final List<String> paragraphs;

  /// 各段感想（与 [paragraphs] 一一对应）。
  final List<String> notes;

  /// 是否显示删除按钮：仅当从读经页（用户自己的数据）进入时才为 true。
  final bool canDelete;

  /// 经书 filePath（sutra key），删除感想时云端同步用。
  final String sutraKey;

  /// 每条「经文+感想」对应的段落下标（与 [paragraphs] 一一对应，仅删除时需要）。
  final List<int> itemParagraphIndexes;

  /// 删除某段感想后，由读经页负责真正落地（更新本地状态 + 云端同步）。
  /// 返回 true 表示删除生效，页面可立即移除该条。
  final Future<bool> Function(int paragraphIndex)? onDeleteNote;

  /// 空态自定义提示（菩提空间分享帖：作者已删除全部感想时显示）；为空用默认引导文案。
  final String? emptyHint;

  /// 非空时在页面顶部显示同步失败提示条（实时数据加载失败、回退到分享快照）。
  final String? syncNotice;

  const ReadingNotesPage({
    super.key,
    required this.title,
    required this.paragraphs,
    required this.notes,
    this.canDelete = false,
    this.sutraKey = '',
    this.itemParagraphIndexes = const <int>[],
    this.onDeleteNote,
    this.emptyHint,
    this.syncNotice,
  });

  @override
  State<ReadingNotesPage> createState() => _ReadingNotesPageState();
}

class _ReadingNotesPageState extends State<ReadingNotesPage> {
  static const _bg = Color(0xFFFAF7F2);
  static const _card = Colors.white;
  static const _fg = Color(0xFF212121);

  /// 淡红色（删除按钮用），与整体米白 + accent 绿色系协调。
  static const _red = Color(0xFFDD6B6B);

  bool _showMenu = false;
  bool _exporting = false;
  // 已展开的卡片下标。
  final Set<int> _expanded = {};

  /// 当前展示的「经文+感想」项（删除时原地移除；每项自带段落下标）。
  late List<({String paragraph, String note, int para})> _items;

  @override
  void initState() {
    super.initState();
    _items = _buildItems();
  }

  /// 展示用「经文+感想」成对列表（与 [_items] 一一对应）。
  List<(String, String)> get _pairs =>
      [for (final it in _items) (it.paragraph, it.note)];

  /// 有感想的「经文+感想」项（过滤空感想，并记录段落下标）。
  List<({String paragraph, String note, int para})> _buildItems() {
    final items = <({String paragraph, String note, int para})>[];
    final n = widget.paragraphs.length < widget.notes.length
        ? widget.paragraphs.length
        : widget.notes.length;
    for (var i = 0; i < n; i++) {
      final t = widget.notes[i].trim();
      if (t.isEmpty) continue;
      items.add((
        paragraph: widget.paragraphs[i],
        note: t,
        para: i < widget.itemParagraphIndexes.length
            ? widget.itemParagraphIndexes[i]
            : -1,
      ));
    }
    return items;
  }

  String get _sutraName => widget.title;

  /// 文本较长时默认折叠，点击切换展开 / 收起。
  static const int _foldThreshold = 60;

  void _toggleExpand(int i) {
    setState(() {
      if (_expanded.contains(i)) {
        _expanded.remove(i);
      } else {
        _expanded.add(i);
      }
    });
  }

  /// 删除第 [index] 条「经文+感想」：二次确认后交由读经页落地（更新阅读页 + 云端）。
  Future<void> _confirmDelete(int index) async {
    if (!widget.canDelete || index >= _items.length) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除这段感想？', style: TextStyle(fontSize: 16)),
        content: Text(
          '删除后阅读页的这段感想也会一并移除',
          style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(color: Color(0xFF666666))),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除', style: TextStyle(color: _red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final callback = widget.onDeleteNote;
    if (callback == null) return;
    final para = _items[index].para;
    var ok = false;
    try {
      ok = await callback(para);
    } catch (_) {}
    if (!mounted) return;
    if (ok) {
      setState(() => _items.removeAt(index));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已删除'), duration: Duration(seconds: 1)),
      );
    }
  }

  /// 导出 PDF：经文与感想成组，每组先「经文」后「感想」，视觉上明显区分。
  /// 为避免生成过重卡死，只导出第一条「经文,感想」。
  Future<void> _exportPdf() async {
    if (_exporting) return;
    final pairs = _pairs;
    if (pairs.isEmpty) {
      _toast('没有可导出的感想');
      return;
    }
    setState(() => _exporting = true);
    try {
      // 用纯 Dart 直接排版 PDF（内置中文字体），不依赖系统 WebView，
      // 避免 convertHtml 在部分安卓设备上永不回调导致按钮一直转圈。
      final pdf = await PdfExporter.buildReadingNotesPdf(
        sutraName: _sutraName,
        pairs: [pairs.first],
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
    final filename = '${safeTitle}_感想.pdf';
    // 优先：用原生保存对话框，由插件写入用户选择的位置。
    try {
      final savedPath = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          data: bytes,
          fileName: filename,
          mimeTypesFilter: const ['application/pdf'],
        ),
      );
      if (savedPath != null && savedPath.isNotEmpty) return savedPath;
    } catch (_) {
      // ignore，走兜底
    }
    // 兜底1：file_picker
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
    } catch (_) {
      // ignore，走兜底
    }
    // 兜底2：保存到应用文档目录
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

  /// 构建发布到菩提空间的分享帖正文（与画线分享同构）：
  ///   $经文名
  ///   <空行>
  ///   第一条经文
  ///   <空行>
  ///   §§TS§§ + base64((经文,感想) 成对数组 JSON)
  ///   <空行> 留言（可空）
  /// 展示时只显示第一条经文（色块），点击色块用完整数据打开感想页。
  String _buildShareContent(List<(String, String)> pairs, String message) {
    final first = pairs.isNotEmpty ? pairs.first.$1 : '';
    final meta = _encodePairs(pairs);
    final lines = <String>[
      if (_sutraName.isNotEmpty) '\$$_sutraName',
      if (first.trim().isNotEmpty) first.trim(),
      '$kSutraThoughtsMetaPrefix$meta',
      if (message.trim().isNotEmpty) message.trim(),
    ];
    return lines.join('\n\n');
  }

  /// 把「经文,感想」成对数组编码为 base64 JSON。
  static String _encodePairs(List<(String, String)> pairs) {
    final arr = [
      for (final (p, t) in pairs) {'p': p, 't': t},
    ];
    return base64Encode(utf8.encode(jsonEncode(arr)));
  }

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
    final pairs = _pairs;
    final first = pairs.isNotEmpty ? pairs.first.$1 : '';
    final accent = AppPalette.p.accent;
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
                        '分享到菩提空间',
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _fg),
                      ),
                      const SizedBox(height: 12),
                      // 预览色块：第一条经文。
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
                          style: TextStyle(
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
                        decoration: InputDecoration(
                          hintText: '说点什么……',
                          hintStyle: const TextStyle(
                              fontSize: 14, color: Color(0xFFB9B9B9)),
                          filled: true,
                          fillColor: const Color(0xFFF5F5F5),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (_) => setSheet(() {}),
                      ),
                      const SizedBox(height: 4),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(ctx).pop(ctrl.text.trim()),
                        child: Container(
                          height: 46,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(23),
                          ),
                          child: const Text(
                            '分享',
                            style: TextStyle(
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
    try {
      await CloudNotesService.instance.publishNote(
        title: '',
        content: _buildShareContent(pairs, message),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('已分享到菩提空间'), duration: Duration(seconds: 2)),
      );
    } catch (e) {
      if (!mounted) return;
      _toast('分享失败：${e is CloudApiException ? e.message : e}');
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
                    title: '读经感想 PDF',
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
    final pairs = _pairs;
    final accent = AppPalette.p.accent;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _fg,
        elevation: 0,
        title: Text('感想：$_sutraName',
            style: const TextStyle(fontSize: 16, color: _fg)),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_horiz, size: 22, color: _fg),
            onPressed: () => setState(() => _showMenu = !_showMenu),
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.syncNotice != null && widget.syncNotice!.trim().isNotEmpty)
            _SyncNoticeBar(text: widget.syncNotice!),
          Expanded(
            child: Stack(
              children: [
                pairs.isEmpty
                    ? Center(
                        child: Text(
                          widget.emptyHint ??
                              '还没有为《$_sutraName》添加感想\n点击每段右侧的「感想」按钮即可记录',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 14, height: 1.6, color: Colors.black38),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: pairs.length,
                        itemBuilder: (context, i) {
                          final (p, note) = pairs[i];
                          final long = p.length > _foldThreshold;
                          final expanded = _expanded.contains(i);
                          final isDark = AppPalette.instance.isPlain &&
                              Theme.of(context).brightness == Brightness.dark;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              color: _card,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(14, 12, 12, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 经文（长文可折叠展开）
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(
                                            top: 2, right: 8),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color:
                                                accent.withValues(alpha: 0.12),
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: const Text(
                                            '经文',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF5C4033),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              p,
                                              maxLines:
                                                  long && !expanded ? 3 : null,
                                              overflow: long && !expanded
                                                  ? TextOverflow.ellipsis
                                                  : TextOverflow.visible,
                                              style: TextStyle(
                                                fontSize: 13.5,
                                                height: 1.6,
                                                color: isDark
                                                    ? Colors.white70
                                                    : _fg,
                                              ),
                                            ),
                                            // 展开/收起（左下方）
                                            if (long)
                                              GestureDetector(
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onTap: () => _toggleExpand(i),
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          top: 2),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Text(
                                                        expanded ? '收起' : '展开',
                                                        style: TextStyle(
                                                          fontSize: 12,
                                                          color: accent,
                                                          fontWeight:
                                                              FontWeight.w500,
                                                        ),
                                                      ),
                                                      Icon(
                                                        expanded
                                                            ? Icons.expand_less
                                                            : Icons.expand_more,
                                                        size: 16,
                                                        color: accent,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            // AI译按钮：紧贴经文短文右下角，靠右对齐
                                            Align(
                                              alignment: Alignment.centerRight,
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  GestureDetector(
                                                    behavior:
                                                        HitTestBehavior.opaque,
                                                    onTap: () =>
                                                        AiTranslatePage.open(
                                                      context,
                                                      paragraph: p,
                                                    ),
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                              top: 2),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Icon(
                                                              Icons
                                                                  .auto_awesome,
                                                              size: 13,
                                                              color: accent),
                                                          const SizedBox(
                                                              width: 3),
                                                          Text(
                                                            'AI译',
                                                            style: TextStyle(
                                                              fontSize: 12,
                                                              color: accent,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w500,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                  if (widget.canDelete) ...[
                                                    const SizedBox(width: 16),
                                                    // 删除（淡红，位于 AI译 之后）
                                                    GestureDetector(
                                                      behavior: HitTestBehavior
                                                          .opaque,
                                                      onTap: () =>
                                                          _confirmDelete(i),
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .only(top: 2),
                                                        child: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            Icon(
                                                                Icons
                                                                    .delete_outline,
                                                                size: 13,
                                                                color: _red),
                                                            const SizedBox(
                                                                width: 3),
                                                            Text(
                                                              '删除',
                                                              style: TextStyle(
                                                                fontSize: 12,
                                                                color: _red,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w500,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  // 感想
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF3F0EA),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      note,
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        height: 1.6,
                                        color: isDark
                                            ? Colors.white
                                            : const Color(0xFF3D5C3A),
                                      ),
                                    ),
                                  ),
                                ],
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildMenuTile(
                              icon: _exporting
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
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
                              icon: const Icon(Icons.share_outlined, size: 18),
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

/// 实时同步失败提示条：数据仍展示分享时的内容，仅作提示。
class _SyncNoticeBar extends StatelessWidget {
  const _SyncNoticeBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16, color: Color(0xFFB26A00)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                  fontSize: 12.5, height: 1.4, color: Color(0xFF8A5400)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 内置 PDF 预览页：用 [Printing.raster] 把 PDF 字节光栅化为图片逐页展示。
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
