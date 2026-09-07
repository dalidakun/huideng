import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'note_sutra_links.dart';
import 'pdf_export.dart';
import 'reading_note_post.dart';
import 'settings_widgets.dart';

import 'app_palette.dart';
Color get _enPrimary => AppPalette.p.primary;
Color get _enPrimaryLight => AppPalette.p.textSec;
Color get _enText => AppPalette.p.text;
Color get _enTextSec => AppPalette.p.textSec;
Color get _enTextHint => AppPalette.p.textHint;
Color get _enBorder => AppPalette.p.border;
Color get _enCard => AppPalette.p.card;
Color get _enBg => AppPalette.p.bg;
/// 进入时拉取全部帖子并按年份分组，可单选某一整年导出为 PDF。
class ExportNotesPage extends StatefulWidget {
  const ExportNotesPage({super.key});

  @override
  State<ExportNotesPage> createState() => _ExportNotesPageState();
}

class _ExportNotesPageState extends State<ExportNotesPage> {
  bool _loading = true;
  String? _error;

  /// 按年份倒序的全部帖子（仅本人发布，去掉回复类）。
  final Map<int, List<PlazaNote>> _byYear = {};

  /// 已选中的导出年份（单选，默认最近的年份）。
  int? _selectedYear;

  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!AuthService.instance.isLoggedIn) {
        setState(() {
          _error = '请先登录后重试';
          _loading = false;
        });
        return;
      }
      final all = <PlazaNote>[];
      int page = 1;
      const int pageSize = 50;
      while (true) {
        final (list, hasMore) =
            await CloudNotesService.instance.getMyNotes(page: page, pageSize: pageSize);
        all.addAll(list);
        if (!hasMore || list.isEmpty) break;
        page++;
        if (page > 200) break; // 兜底保护
      }

      // 仅保留真正“发的帖子”：剔除 reply 类型（仍保留 forward/quote）。
      // 同时只保留当前真实账号的笔记（降级/匿名会话串号数据一律过滤）。
      final myUid = AuthService.instance.currentUser.value?.id ??
          AuthService.instance.cachedUserId;
      final mine = all
          .where((n) =>
              n.repostKind != 'reply' &&
              (myUid == null || myUid.isEmpty || n.ownerUserId == myUid))
          .toList();

      final map = <int, List<PlazaNote>>{};
      for (final n in mine) {
        if (n.createdAt <= 0) continue;
        final y = DateTime.fromMillisecondsSinceEpoch(n.createdAt).year;
        map.putIfAbsent(y, () => []).add(n);
      }
      // 按时间正序排列，更早的在前。
      map.forEach((_, v) {
        v.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      });

      if (mounted) {
        setState(() {
          _byYear
            ..clear()
            ..addAll(map);
          // 默认选中最近的年份（单选）。
          if (map.isNotEmpty) {
            _selectedYear ??= map.keys.reduce((a, b) => a > b ? a : b);
          }
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '加载失败：${e.toString()}';
          _loading = false;
        });
      }
    }
  }

  List<int> get _yearsDesc =>
      _byYear.keys.toList()..sort((a, b) => b.compareTo(a));

  int get _selectedCount {
    final y = _selectedYear;
    if (y == null) return 0;
    return _byYear[y]?.length ?? 0;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: '导出笔记',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _byYear.isEmpty
                  ? _buildEmpty()
                  : _buildBody(),
    );
  }

  Widget _buildError() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.error_outline, size: 48, color: _enPrimaryLight),
        const SizedBox(height: 12),
        Text(_error ?? '',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _enTextSec)),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _load,
          style: ElevatedButton.styleFrom(
            backgroundColor: _enPrimary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('重试'),
        ),
      ],
    );
  }

  Widget _buildEmpty() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        SizedBox(height: 40),
        Icon(Icons.menu_book_outlined, size: 56, color: _enTextHint),
        SizedBox(height: 16),
        Text('还没有发过帖子',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: _enTextSec)),
        SizedBox(height: 8),
        Text('在菩提空间或学习大厅发布帖子后，可在此导出存档。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: _enTextHint)),
      ],
    );
  }

  Widget _buildBody() {
    final years = _yearsDesc;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                child: Text(
                  '你的笔记都已经保存在云端，账号不丢失，数据就会保存；但如果你想保存到本地，可以选择导出 pdf 文件，本地保存。',
                  style: TextStyle(fontSize: 12, color: _enTextHint),
                ),
              ),
              SettingsCard(
                children: [
                  for (final y in years) _yearRow(y),
                  const SizedBox(height: 6),
                ],
              ),
            ],
          ),
        ),
        _buildExportBar(),
      ],
    );
  }

  Widget _yearRow(int year) {
    final count = _byYear[year]?.length ?? 0;
    final selected = _selectedYear == year;
    return InkWell(
      onTap: () {
        setState(() => _selectedYear = year);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            _radioBox(selected),
            const SizedBox(width: 12),
            Expanded(
              child: Text('$year 年',
                  style: TextStyle(
                      fontSize: 16,
                      color: _enText,
                      fontWeight: FontWeight.w500)),
            ),
            Text('$count 篇',
                style:
                    TextStyle(fontSize: 13, color: _enTextSec)),
          ],
        ),
      ),
    );
  }

  Widget _radioBox(bool checked) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: checked ? _enPrimary : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: checked ? _enPrimary : _enBorder,
          width: 1.5,
        ),
      ),
      child: checked
          ? const Icon(Icons.check, size: 16, color: Colors.white)
          : null,
    );
  }

  Widget _buildExportBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        decoration: BoxDecoration(
          color: _enCard,
          border: Border(top: BorderSide(color: _enBorder, width: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _selectedCount == 0
                    ? '请选择要导出的年份'
                    : '$_selectedYear 年，共 $_selectedCount 篇',
                style: TextStyle(fontSize: 13, color: _enTextSec),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed:
                  (_exporting || _selectedCount == 0) ? null : _onExport,
              icon: _exporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.picture_as_pdf_outlined, size: 18),
              label: Text(_exporting ? '生成中…' : '导出为 PDF'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _enPrimary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _enPrimaryLight.withValues(alpha: 0.5),
                disabledForegroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onExport() async {
    if (_exporting) return;
    final year = _selectedYear;
    if (year == null || _selectedCount == 0) {
      _toast('请先选择要导出的年份');
      return;
    }
    if (!AuthService.instance.isLoggedIn) {
      _toast('请先登录');
      return;
    }
    setState(() => _exporting = true);
    try {
      final List<PlazaNote> notes = [
        ...(_byYear[year] ?? const <PlazaNote>[]),
      ];
      final me = AuthService.instance.currentUser.value;
      final filenameBase = '$year年笔记';
      // 用纯 Dart 直接排版 PDF（内置中文字体），不依赖系统 WebView，
      // 避免 convertHtml 在部分安卓设备上永不回调导致按钮一直转圈。
      final pdf = await PdfExporter.buildNotesPdf(
        author: me?.nickname ?? '我',
        years: _buildYears(notes),
      );
      if (pdf.isEmpty) {
        _toast('生成失败：内容为空');
        return;
      }
      final savedPath =
          await _saveUint8List(pdf, '$filenameBase.pdf', 'application/pdf');
      if (savedPath != null) {
        _showSavedToastWithView(savedPath, pdf);
      }
    } catch (e) {
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 返回最终保存路径；失败时返回 null（错误已通过 toast 提示）。
  Future<String?> _saveUint8List(
      Uint8List bytes, String filename, String mime) async {
    // 优先：用原生保存对话框，由插件写入用户选择的位置（兼容 Android 的 content://）。
    try {
      final savedPath = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          data: bytes,
          fileName: filename,
          mimeTypesFilter: [mime],
        ),
      );
      if (savedPath != null && savedPath.isNotEmpty) {
        return savedPath;
      }
    } catch (_) {
      // ignore，走兜底
    }

    // 兜底1：file_picker
    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '保存文件',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: [filename.split('.').last],
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
      // ignore
    }

    // 兜底2：保存到应用目录
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$filename');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (e) {
      _toast('保存失败：$e');
      return null;
    }
  }

  /// 保存成功后的底部提示：「已保存：xxx，点击查看」。
  /// 显示最长 10 秒，点击整体进入内置 PDF 预览页，点 X 仅关闭。
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
            color: _enPrimary,
            borderRadius: BorderRadius.circular(12),
            elevation: 4,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                dismiss();
                Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => _PdfViewerPage(
                    bytes: pdfBytes,
                    title: '已导出的笔记',
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
                        child: Icon(Icons.close,
                            size: 16, color: Colors.white70),
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

  /// 把选中的帖子按年份分组，交给纯 Dart PDF 排版。
  /// 时间倒序：最近的年份在前、同年内最新发的写在前（最上面）。
  List<PdfNotesYear> _buildYears(List<PlazaNote> notes) {
    final sorted = [...notes]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final byYear = <int, List<PlazaNote>>{};
    for (final n in sorted) {
      if (n.createdAt <= 0) continue;
      final y = DateTime.fromMillisecondsSinceEpoch(n.createdAt).year;
      byYear.putIfAbsent(y, () => []).add(n);
    }
    final years = byYear.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final y in years)
        PdfNotesYear(
          year: y,
          posts: [
            for (final n in byYear[y]!)
              () {
                final parts = _pdfBodyParts(n);
                return PdfNotesPost(
                  date: _formatFull(n.createdAt),
                  body: parts.body,
                  verse: parts.verse,
                  thought: parts.thought,
                  footer: '点赞 ${n.likeCount} · 评论 ${n.commentCount} · '
                      '转发 ${n.repostCount} · 阅读 ${n.viewCount}',
                );
              }(),
          ],
        ),
    ];
  }

  /// 把帖子正文拆成「常规文字 + 经文色块 + 感想色块」三部分，交给 PDF 排版。
  ///
  /// 阅读界面的「画线 / 感想」分享帖正文末尾带一段 base64 元数据（哨兵
  /// `§§HS§§` / `§§TS§§` 编码的成对数组），直接导出会显示乱码。这里解析后：
  ///   - 感想汇总页分享帖：$经名 + 留言在上，经文色块 + 感想色块（只取第一条）
  ///   - 画线归集页分享帖：$经名 + 留言在上，第一条画线当作经文色块
  ///   - 选择文字直接分享：感想/留言在上，段原文当作经文色块
  ///   - 普通帖走 @经书 纯文本化
  static ({String body, String? verse, String? thought}) _pdfBodyParts(
      PlazaNote n) {
    // 感想汇总页分享帖（§§TS§§）。
    final thoughts = SutraThoughtsPost.parse(n.content);
    if (thoughts != null) {
      final lines = <String>[
        if (thoughts.sutraTitle.isNotEmpty) '\$${thoughts.sutraTitle}',
      ];
      final msg = thoughts.message.trim();
      if (msg.isNotEmpty) lines.add(msg);
      // 只导出第一条「经文,感想」。
      final verse = thoughts.pairs.isNotEmpty
          ? thoughts.pairs.first.$1.trim()
          : thoughts.firstParagraph.trim();
      final thought = thoughts.pairs.isNotEmpty
          ? thoughts.pairs.first.$2.trim()
          : '';
      return (
        body: lines.join('\n\n'),
        verse: verse.isEmpty ? null : verse,
        thought: thought.isEmpty ? null : thought,
      );
    }
    // 画线归集页分享帖（§§HS§§）。
    final highlights = SutraHighlightsPost.parse(n.content);
    if (highlights != null) {
      final lines = <String>[
        if (highlights.sutraTitle.isNotEmpty) '\$${highlights.sutraTitle}',
      ];
      final msg = highlights.message.trim();
      if (msg.isNotEmpty) lines.add(msg);
      // 只导出第一条画线，当作经文色块。
      final verse = highlights.highlights.isNotEmpty
          ? highlights.highlights.first.trim()
          : highlights.firstHighlight.trim();
      return (
        body: lines.join('\n\n'),
        verse: verse.isEmpty ? null : verse,
        thought: null,
      );
    }
    // 选择文字直接分享的感想（ReadingNotePost）。
    final rn = ReadingNotePost.parse(n.content);
    if (rn != null) {
      final lines = <String>[
        if (rn.sutraTitle.isNotEmpty) '\$${rn.sutraTitle}',
      ];
      if (rn.noteText.trim().isNotEmpty) lines.add(rn.noteText.trim());
      return (
        body: lines.join('\n\n'),
        verse: rn.paragraph.trim().isEmpty ? null : rn.paragraph.trim(),
        thought: null,
      );
    }
    // 普通帖子：整段纯文本。
    return (
      body: NoteSutraLinks.plainText(n.content),
      verse: null,
      thought: null,
    );
  }

  static String _formatFull(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

/// 内置 PDF 预览页：用 [Printing.raster] 把 PDF 字节光栅化为图片逐页展示。
/// 仅用于「刚导出后查看」的轻量预览，不提供书签/搜索等高级功能。
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
      await for (final page in Printing.raster(widget.bytes,
          dpi: PdfPageFormat.inch * 2)) {
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
      backgroundColor: _enBg,
      appBar: AppBar(
        backgroundColor: _enCard,
        foregroundColor: _enText,
        elevation: 0.3,
        title: Text(widget.title,
            style:
                const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        centerTitle: false,
      ),
      body: _loading && _pages.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _pages.isEmpty
                  ? Center(
                      child: Text('该 PDF 无可显示内容',
                          style: TextStyle(color: _enTextSec)),
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

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined,
                size: 48, color: _enTextSec),
            const SizedBox(height: 12),
            Text(_error ?? '',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 14, color: _enTextSec)),
          ],
        ),
      ),
    );
  }
}