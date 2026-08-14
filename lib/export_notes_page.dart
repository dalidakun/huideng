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
import 'settings_widgets.dart';

const Color _enPrimary = Color(0xFF5C4033);
const Color _enPrimaryLight = Color(0xFF8B6B5A);
const Color _enText = Color(0xFF3E2723);
const Color _enTextSec = Color(0xFF8B6B5A);
const Color _enTextHint = Color(0xFFC4B5A8);
const Color _enBorder = Color(0xFFEBE1D6);
const Color _enCard = Color(0xFFFFFAF5);
const Color _enBg = Color(0xFFF5EDE3);

/// 导出笔记：把当前用户自己发布的帖子按年份汇总导出为 PDF。
/// 进入时拉取全部帖子并按年份分组，可勾选年份，亦可“全部导出”。
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

  /// 已勾选的年份集合（为空且 _selectAll=true 表示全部）。
  final Set<int> _selected = {};
  bool _selectAll = true;

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

  int get _totalCount => _byYear.values.fold(0, (s, l) => s + l.length);

  int get _selectedCount {
    if (_selectAll) return _totalCount;
    int c = 0;
    for (final y in _selected) {
      c += _byYear[y]?.length ?? 0;
    }
    return c;
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
        const Icon(Icons.error_outline, size: 48, color: _enPrimaryLight),
        const SizedBox(height: 12),
        Text(_error ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: _enTextSec)),
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
      children: const [
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
                  '你的笔记都已经保存在云端，账号不丢失，数据就会保存；但如果你想保存到本地，可以选择导出pdf文件，永久保存。',
                  style: const TextStyle(fontSize: 12, color: _enTextHint),
                ),
              ),
              SettingsCard(
                children: [
                  InkWell(
                    onTap: () {
                      setState(() {
                        _selectAll = true;
                        _selected.clear();
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 14),
                      child: Row(
                        children: [
                          _radioBox(_selectAll),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('全部导出',
                                    style: TextStyle(
                                        fontSize: 16,
                                        color: _enText,
                                        fontWeight: FontWeight.w600)),
                                SizedBox(height: 2),
                                Text('共全部年份的帖子',
                                    style: TextStyle(
                                        fontSize: 12, color: _enTextHint)),
                              ],
                            ),
                          ),
                          Text('$_totalCount 篇',
                              style: const TextStyle(
                                  fontSize: 13, color: _enTextSec)),
                        ],
                      ),
                    ),
                  ),
                  const SettingsDivider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                    child: Text(
                      '按年份选择',
                      style: const TextStyle(
                          fontSize: 12,
                          color: _enTextSec,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
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
    final selected = !_selectAll && _selected.contains(year);
    return InkWell(
      onTap: () {
        setState(() {
          if (_selectAll) {
            _selectAll = false;
          }
          if (_selected.contains(year)) {
            _selected.remove(year);
          } else {
            _selected.add(year);
          }
          if (_selected.isEmpty) {
            _selectAll = true;
          }
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            _radioBox(selected),
            const SizedBox(width: 12),
            Expanded(
              child: Text('$year 年',
                  style: const TextStyle(
                      fontSize: 16,
                      color: _enText,
                      fontWeight: FontWeight.w500)),
            ),
            Text('$count 篇',
                style:
                    const TextStyle(fontSize: 13, color: _enTextSec)),
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
        decoration: const BoxDecoration(
          color: _enCard,
          border: Border(top: BorderSide(color: _enBorder, width: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _selectAll
                    ? '将导出全部 $_totalCount 篇帖子'
                    : '已选 ${_selected.length} 年，共 $_selectedCount 篇',
                style: const TextStyle(fontSize: 13, color: _enTextSec),
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
    if (_selectedCount == 0) {
      _toast('请至少选择一个年份');
      return;
    }
    if (!AuthService.instance.isLoggedIn) {
      _toast('请先登录');
      return;
    }
    setState(() => _exporting = true);
    try {
      final notes = <PlazaNote>[];
      if (_selectAll) {
        for (final y in _yearsDesc) {
          notes.addAll(_byYear[y]!);
        }
      } else {
        final ys = _selected.toList()..sort((a, b) => b.compareTo(a));
        for (final y in ys) {
          notes.addAll(_byYear[y] ?? []);
        }
      }
      notes.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final html = _buildHtml(notes);
      final filenameBase = _selectAll
          ? '我的全部笔记'
          : (_selected.length == 1 ? '${_selected.first}年笔记' : '我的笔记');
      // 用系统 WebView 把 HTML 渲染为 PDF（自带 CJK 字体，无需额外打包字体）。
      // ignore: deprecated_member_use
      final pdf = await Printing.convertHtml(
        html: html,
        format: PdfPageFormat.a4,
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

  /// 把帖子按年份分组渲染为 HTML（使用系统 WebView 自带 CJK 字体）。
  String _buildHtml(List<PlazaNote> notes) {
    final me = AuthService.instance.currentUser.value;
    final author = me?.nickname ?? '我';
    final now = DateTime.now();
    final madeOn =
        '${now.year}年${now.month}月${now.day}日 ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final byYear = <int, List<PlazaNote>>{};
    for (final n in notes) {
      if (n.createdAt <= 0) continue;
      final y = DateTime.fromMillisecondsSinceEpoch(n.createdAt).year;
      byYear.putIfAbsent(y, () => []).add(n);
    }
    final years = byYear.keys.toList()..sort();

    final sb = StringBuffer()
      ..writeln('<!DOCTYPE html><html><head><meta charset="utf-8"/>')
      ..writeln('<meta name="viewport" content="width=device-width, initial-scale=1"/>')
      ..writeln('<title>$author 的笔记</title>')
      ..writeln('<style>')
      ..writeln('@page { size: A4; margin: 18mm 16mm; }')
      ..writeln('html, body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }')
      ..writeln('body { font-family: -apple-system, "Noto Sans CJK SC", "PingFang SC", "Microsoft YaHei", sans-serif; color: #2C1F18; line-height: 1.7; font-size: 14px; }')
      ..writeln('.cover { text-align: center; padding: 40mm 0 18mm; page-break-after: always; }')
      ..writeln('.cover h1 { font-size: 26px; letter-spacing: 2px; margin: 0 0 8px; }')
      ..writeln('.cover .author { font-size: 15px; color: #8B6B5A; margin-bottom: 24px; }')
      ..writeln('.cover .meta { font-size: 13px; color: #B59B86; }')
      ..writeln('.cover .count { margin-top: 22px; font-size: 13px; color: #6F5142; }')
      ..writeln('.year-block { page-break-before: always; }')
      ..writeln('.year-block:first-of-type { page-break-before: auto; }')
      ..writeln('.year-title { font-size: 22px; color: #5C4033; font-weight: 700; margin: 0 0 14px; border-bottom: 1px solid #EADFD2; padding-bottom: 8px; }')
      ..writeln('.post { margin: 0 0 18px; padding: 14px 16px; border: 1px solid #EADFD2; border-radius: 8px; page-break-inside: avoid; }')
      ..writeln('.post .date { font-size: 12px; color: #B59B86; margin-bottom: 8px; }')
      ..writeln('.post .content { font-size: 14px; color: #2C1F18; white-space: pre-wrap; word-break: break-word; }')
      ..writeln('.post .footer { margin-top: 10px; font-size: 11px; color: #9C7F6E; }')
      ..writeln('</style></head><body>');

    sb
      ..writeln('<section class="cover">')
      ..writeln('<h1>我的笔记</h1>')
      ..writeln('<div class="author">$author</div>')
      ..writeln('<div class="meta">导出于 $madeOn</div>')
      ..writeln('<div class="count">共 ${notes.length} 篇帖子 · 涉及 ${years.length} 个年份</div>')
      ..writeln('</section>');

    if (notes.isEmpty) {
      sb.writeln('<p style="color:#888;text-align:center;padding:24px 0">所选范围无内容</p>');
    } else {
      for (final y in years) {
        sb
          ..writeln('<section class="year-block">')
          ..writeln('<div class="year-title">$y 年</div>');
        for (final n in byYear[y]!) {
          sb
            ..writeln('<article class="post">')
            ..writeln('<div class="date">${_formatFull(n.createdAt)}</div>');
          final body = NoteSutraLinks.plainText(n.content);
          if (body.trim().isNotEmpty) {
            sb.writeln(
                '<div class="content">${_multilineToHtml(body)}</div>');
          }
          sb.writeln('<div class="footer">'
              '点赞 ${n.likeCount} · 评论 ${n.commentCount} · '
              '转发 ${n.repostCount} · 阅读 ${n.viewCount}'
              '</div>');
          sb.writeln('</article>');
        }
        sb.writeln('</section>');
      }
    }
    sb.writeln('</body></html>');
    return sb.toString();
  }

  static String _formatFull(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  static String _multilineToHtml(String text) {
    // 不破坏 _h 的转义，仅在转义后把换行替换为 <br/>。
    return _h(text).replaceAll('\n', '<br/>');
  }

  static String _h(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
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
                  ? const Center(
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
            const Icon(Icons.broken_image_outlined,
                size: 48, color: _enTextSec),
            const SizedBox(height: 12),
            Text(_error ?? '',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 14, color: _enTextSec)),
          ],
        ),
      ),
    );
  }
}