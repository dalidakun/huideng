import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// 纯 Dart 生成中文 PDF，替代 printing 插件的 `convertHtml` 方案。
///
/// `convertHtml` 依赖系统 WebView 把 HTML 打印成 PDF，在部分安卓设备上
/// WebView 的打印适配器会一直不回调，导致导出按钮永远转圈。这里改为直接
/// 排版 PDF（内置 Droid Sans Fallback 中文字体，Apache 2.0），不依赖
/// WebView，任何设备都能稳定导出。
class PdfExporter {
  PdfExporter._();

  /// 缓存已加载的中文字体，避免重复读取与解析 4MB 字体文件。
  static pw.Font? _baseFont;

  /// 菩提空间笔记导出。
  static Future<Uint8List> buildNotesPdf({
    required String author,
    required List<PdfNotesYear> years,
    DateTime? now,
  }) async {
    final madeOn = _madeOn(now ?? DateTime.now());
    final total = years.fold<int>(0, (s, y) => s + y.posts.length);
    return _build(
      title: '我的笔记',
      subtitle: author,
      madeOn: madeOn,
      countText: '共 $total 篇帖子 · 涉及 ${years.length} 个年份',
      body: _buildNotesBody(years),
    );
  }

  /// 读经感想导出：经文 + 感想成组。
  static Future<Uint8List> buildReadingNotesPdf({
    required String sutraName,
    required List<(String, String)> pairs,
    DateTime? now,
  }) async {
    final madeOn = _madeOn(now ?? DateTime.now());
    return _build(
      title: '读经感想',
      subtitle: sutraName,
      madeOn: madeOn,
      countText: '共 ${pairs.length} 组（每组：经文 + 感想）',
      body: _buildReadingBody(pairs),
    );
  }

  static Future<Uint8List> _build({
    required String title,
    required String subtitle,
    required String madeOn,
    required String countText,
    required List<pw.Widget> body,
  }) async {
    final font = _baseFont ??= await _loadFont();
    // Droid Sans Fallback 只含中文字形（无西文/数字），所以补上内置拉丁字体
    // 作为兜底；粗体也统一用该字体，避免 Type1 粗体不认中文。
    final latin = <pw.Font>[
      pw.Font.helvetica(),
      pw.Font.helveticaBold(),
      pw.Font.helveticaOblique(),
      pw.Font.helveticaBoldOblique(),
    ];
    final theme = pw.ThemeData.withFont(
      base: font,
      bold: font,
      italic: font,
      boldItalic: font,
      fontFallback: latin,
    );
    final doc = pw.Document(theme: theme);

    // 封面页。
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 44, vertical: 40),
        build: (ctx) => _cover(
          title: title,
          subtitle: subtitle,
          madeOn: madeOn,
          countText: countText,
        ),
      ),
    );

    // 正文：自动分页。
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(44, 58, 44, 44),
        header: (ctx) => pw.Text(
          '$subtitle · $title',
          style: pw.TextStyle(fontSize: 9, color: _grey, lineSpacing: 1),
          textAlign: pw.TextAlign.left,
        ),
        footer: (ctx) => pw.Text(
          '${ctx.pageNumber} / ${ctx.pagesCount}',
          style: pw.TextStyle(fontSize: 9, color: _grey, lineSpacing: 1),
          textAlign: pw.TextAlign.right,
        ),
        maxPages: 500,
        build: (ctx) => body,
      ),
    );

    return doc.save();
  }

  static Future<pw.Font> _loadFont() async {
    final data =
        await rootBundle.load('assets/fonts/DroidSansFallbackFull.ttf');
    return pw.Font.ttf(data);
  }

  // ---------- 笔记正文 ----------

  static List<pw.Widget> _buildNotesBody(List<PdfNotesYear> years) {
    final children = <pw.Widget>[];
    for (var i = 0; i < years.length; i++) {
      final y = years[i];
      if (i > 0) {
        // 每个年份从新的一页开始。
        children.add(pw.NewPage());
      }
      children.add(
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(height: 4),
            pw.Text('${y.year} 年',
                style: pw.TextStyle(
                    fontSize: 20, color: _brown, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 8),
            pw.Divider(
                color: _border, height: 1, thickness: 0.8),
            pw.SizedBox(height: 14),
          ],
        ),
      );
      for (final post in y.posts) {
        children.add(_notesPost(post));
      }
    }
    return children;
  }

  static pw.Widget _notesPost(PdfNotesPost post) {
    final children = <pw.Widget>[
      pw.Text(post.date,
          style: pw.TextStyle(fontSize: 10.5, color: _grey)),
      pw.SizedBox(height: 5),
    ];
    // 正文（$经名、用户留言等放在经文色块上方的文字）。
    for (final chunk in _chunks(post.body)) {
      children.add(pw.Text(chunk,
          style: pw.TextStyle(fontSize: 13, color: _ink, lineSpacing: 3)));
    }
    // 经文：背景色包裹块。
    final verse = post.verse?.trim() ?? '';
    if (verse.isNotEmpty) {
      children.addAll([
        pw.SizedBox(height: 8),
        ..._labeledBlock(
          label: post.verseLabel ?? '经文',
          text: verse,
          labelColor: _brown,
          bg: _sutraBg,
          textColor: _sutraText,
        ),
      ]);
    }
    // 感想：背景色包裹块（放在经文色块下方）。
    final thought = post.thought?.trim() ?? '';
    if (thought.isNotEmpty) {
      children.addAll([
        pw.SizedBox(height: 8),
        ..._labeledBlock(
          label: post.thoughtLabel ?? '感想',
          text: thought,
          labelColor: _ideaText,
          bg: _ideaBg,
          textColor: _ideaText,
        ),
      ]);
    }
    if (post.footer != null && post.footer!.isNotEmpty) {
      children.addAll([
        pw.SizedBox(height: 6),
        pw.Text(post.footer!,
            style: pw.TextStyle(fontSize: 10, color: _darkGrey)),
      ]);
    }
    children.add(pw.SizedBox(height: 16));

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: children,
    );
  }

  // ---------- 读经感想正文 ----------

  static List<pw.Widget> _buildReadingBody(
      List<(String, String)> pairs) {
    final children = <pw.Widget>[];
    for (final (para, note) in pairs) {
      children.add(pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          ..._labeledBlock(
            label: '经文',
            text: para,
            labelColor: _brown,
            bg: _sutraBg,
            textColor: _sutraText,
          ),
          ..._labeledBlock(
            label: '感想',
            text: note,
            labelColor: _ideaText,
            bg: _ideaBg,
            textColor: _ideaText,
          ),
          pw.SizedBox(height: 16),
        ],
      ));
    }
    return children;
  }

  /// 经文/感想色块：角标与整段文字都落在同一个背景色块内。
  /// 超长内容按行切块后各块仍铺满同一背景色，上下贴紧形成连续色块，
  /// 避免单块高出一页导致分页失败。
  static List<pw.Widget> _labeledBlock({
    required String label,
    required String text,
    required PdfColor labelColor,
    required PdfColor bg,
    required PdfColor textColor,
  }) {
    final chunks = _chunks(text);
    return [
      // 顶部角标行：同为背景色。
      pw.Container(
        width: double.infinity,
        color: bg,
        padding: const pw.EdgeInsets.fromLTRB(10, 5, 10, 3),
        child: pw.Text(label,
            style: pw.TextStyle(
                fontSize: 11,
                color: labelColor,
                fontWeight: pw.FontWeight.bold)),
      ),
      // 正文：每块都铺满背景色，块与块之间零间距，视觉上是一整块。
      for (var i = 0; i < chunks.length; i++)
        pw.Container(
          width: double.infinity,
          color: bg,
          padding: pw.EdgeInsets.only(
            left: 10,
            right: 10,
            top: i == 0 ? 1 : 0,
            bottom: i == chunks.length - 1 ? 6 : 0,
          ),
          child: pw.Text(chunks[i],
              style:
                  pw.TextStyle(fontSize: 13, color: textColor, lineSpacing: 3)),
        ),
    ];
  }

  // ---------- 通用 ----------

  /// 把长文本按行切块，避免单个 widget 高出一页导致分页失败。
  static List<String> _chunks(String text, {int maxLen = 900}) {
    final result = <String>[];
    final buf = StringBuffer();
    for (final line in text.split('\n')) {
      if (buf.length + line.length + 1 > maxLen && buf.isNotEmpty) {
        result.add(buf.toString());
        buf.clear();
      }
      if (line.length > maxLen) {
        // 用于极其罕见、没有换行的超长段：再按长度硬切。
        for (var i = 0; i < line.length; i += maxLen) {
          result.add(line.substring(
              i, i + maxLen > line.length ? line.length : i + maxLen));
        }
      } else {
        if (buf.isNotEmpty) buf.write('\n');
        buf.write(line);
      }
    }
    if (buf.isNotEmpty) result.add(buf.toString());
    return result;
  }

  static pw.Widget _cover({
    required String title,
    required String subtitle,
    required String madeOn,
    required String countText,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.SizedBox(height: 110),
        pw.Text(title,
            style:
                pw.TextStyle(fontSize: 26, color: _ink, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 12),
        pw.Text(subtitle, style: pw.TextStyle(fontSize: 15, color: _soft)),
        pw.SizedBox(height: 26),
        pw.Text('导出于 $madeOn', style: pw.TextStyle(fontSize: 11, color: _grey)),
        pw.SizedBox(height: 22),
        pw.Text(countText, style: pw.TextStyle(fontSize: 11, color: _darkGrey)),
      ],
    );
  }

  static String _madeOn(DateTime now) {
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    return '${now.year}年${now.month}月${now.day}日 $h:$m';
  }

  static const PdfColor _ink = PdfColor.fromInt(0xFF2C1F18);
  static const PdfColor _brown = PdfColor.fromInt(0xFF5C4033);
  static const PdfColor _soft = PdfColor.fromInt(0xFF8B6B5A);
  static const PdfColor _grey = PdfColor.fromInt(0xFFB59B86);
  static const PdfColor _darkGrey = PdfColor.fromInt(0xFF6F5142);
  static const PdfColor _border = PdfColor.fromInt(0xFFEADFD2);
  static const PdfColor _sutraBg = PdfColor.fromInt(0xFFF3E9DF);
  static const PdfColor _ideaBg = PdfColor.fromInt(0xFFEAF0E7);
  static const PdfColor _sutraText = PdfColor.fromInt(0xFF5C4033);
  static const PdfColor _ideaText = PdfColor.fromInt(0xFF3D5C3A);
}

/// 一年内的笔记帖子列表。
class PdfNotesYear {
  const PdfNotesYear({required this.year, required this.posts});

  final int year;
  final List<PdfNotesPost> posts;
}

/// 单篇笔记（用于导出）。
class PdfNotesPost {
  const PdfNotesPost({
    required this.date,
    required this.body,
    this.footer,
    this.verse,
    this.verseLabel,
    this.thought,
    this.thoughtLabel,
  });

  final String date;

  /// 常规正文（$经名、用户留言等），显示在经文色块上方。
  final String body;
  final String? footer;

  /// 经文内容：以背景色块包裹显示（放在正文/留言下方）。
  final String? verse;

  /// 经文色块角标文案（默认「经文」）。
  final String? verseLabel;

  /// 感想内容：以背景色块包裹显示（放在经文色块下方）。
  final String? thought;

  /// 感想色块角标文案（默认「感想」）。
  final String? thoughtLabel;
}