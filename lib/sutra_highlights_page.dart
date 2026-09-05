import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';

import 'app_palette.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';
import 'ai_translate_page.dart';

/// 画线分享帖正文里的元数据哨兵前缀：后面紧跟 base64 编码的
/// 「全部画线文字」JSON 数组。展示时只显示第一条，点击色块用完整数据打开画线页。
const String kSutraHighlightsMetaPrefix = '\u00a7\u00a7HS\u00a7\u00a7';

/// 「画线归集」页：把某本经里所有被画线的文字汇总展示。
/// 白底、只显示画线文字，每条带「复制」按钮；右上角三点可导出 txt / 分享到菩提空间。
class SutraHighlightsPage extends StatefulWidget {
  final String title;
  final List<String> highlights;

  const SutraHighlightsPage({
    super.key,
    required this.title,
    required this.highlights,
  });

  @override
  State<SutraHighlightsPage> createState() => _SutraHighlightsPageState();
}

class _SutraHighlightsPageState extends State<SutraHighlightsPage> {
  static const _bg = Color(0xFFFAF7F2);
  static const _card = Colors.white;
  static const _fg = Color(0xFF212121);

  bool _showMenu = false;

  List<String> get _highlights =>
      widget.highlights.where((h) => h.trim().isNotEmpty).toList();

  String get _sutraName => widget.title;

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _exportTxt() async {
    final list = _highlights;
    final body = list.join('\n\n');
    if (body.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可导出的画线内容'), duration: Duration(seconds: 2)),
        );
      }
      return;
    }
    final safeTitle = _sutraName
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '');
    final filename = '${safeTitle}_画线.txt';
    final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(body)];

    try {
      final savedPath = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          data: Uint8List.fromList(bytes),
          fileName: filename,
          mimeTypesFilter: const ['text/plain'],
        ),
      );
      if (savedPath != null && savedPath.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已保存：$savedPath'), duration: const Duration(seconds: 3)),
          );
        }
        return;
      }
    } catch (_) {}

    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '导出TXT',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['txt'],
      );
      if (savePath != null && savePath.isNotEmpty && !savePath.startsWith('content:')) {
        final file = File(savePath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已保存：$savePath'), duration: const Duration(seconds: 3)),
          );
        }
        return;
      }
    } catch (_) {}

    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$filename');
      await file.writeAsBytes(bytes, flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存到应用目录：${file.path}'), duration: const Duration(seconds: 4)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e'), duration: const Duration(seconds: 4)),
        );
      }
    }
  }

  /// 构建发布到菩提空间的分享帖正文：
  ///   $经名
  ///   （空行）第一条画线文字
  ///   （空行）哨兵 + base64(全部画线)
  ///   （若有留言）空行 + 留言（展示在色块下方）
  String _buildShareContent(String message) {
    final list = _highlights;
    final first = list.isNotEmpty ? list.first : '';
    final meta = base64Encode(utf8.encode(jsonEncode(list)));
    final lines = <String>[
      if (_sutraName.isNotEmpty) '\$$_sutraName',
      if (first.isNotEmpty) first,
      '$kSutraHighlightsMetaPrefix$meta',
      if (message.trim().isNotEmpty) message.trim(),
    ];
    return lines.join('\n\n');
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
    final first = _highlights.isNotEmpty ? _highlights.first : '';
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
                          color: _fg,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 预览色块：第一条画线。
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
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.6,
                            color: _fg,
                            decoration: TextDecoration.underline,
                            decorationColor: accent.withValues(alpha: 0.6),
                            decorationThickness: 1.2,
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
                        onTap: () =>
                            Navigator.of(ctx).pop(ctrl.text.trim()),
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
        content: _buildShareContent(message),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已分享到菩提空间'), duration: Duration(seconds: 2)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('分享失败：${e is CloudApiException ? e.message : e}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _highlights;
    final accent = AppPalette.p.accent;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _fg,
        elevation: 0,
        title: Text('画线：$_sutraName', style: const TextStyle(fontSize: 16, color: _fg)),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_horiz, size: 22, color: _fg),
            onPressed: () => setState(() => _showMenu = !_showMenu),
          ),
        ],
      ),
      body: Stack(
        children: [
          list.isEmpty
              ? Center(
                  child: Text(
                    '还没有为《$_sutraName》画线\n长按正文选中文字，点「画线」即可标记',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14, height: 1.6, color: Colors.black38),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final h = list[i];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.fromLTRB(14, 12, 12, 6),
                      decoration: BoxDecoration(
                        color: _card,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            h,
                            style: const TextStyle(fontSize: 14, height: 1.6, color: _fg),
                          ),
                          const SizedBox(height: 4),
                          // 底行操作：复制 | AI译，右对齐并排。
                          Align(
                            alignment: Alignment.centerRight,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // AI译
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => AiTranslatePage.open(
                                    context,
                                    paragraph: h,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 6),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.auto_awesome,
                                            size: 14, color: accent),
                                        const SizedBox(width: 4),
                                        Text(
                                          'AI译',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: accent,
                                              fontWeight: FontWeight.w500),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                // 复制
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _copy(h),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 6),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.copy_outlined,
                                            size: 14, color: accent),
                                        const SizedBox(width: 4),
                                        Text(
                                          '复制',
                                          style: TextStyle(
                                              fontSize: 12, color: accent),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
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
                        icon: const Icon(Icons.file_download_outlined, size: 18),
                        label: '导出txt',
                        onTap: () {
                          setState(() => _showMenu = false);
                          _exportTxt();
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
    );
  }

  Widget _buildMenuTile({
    required Icon icon,
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
