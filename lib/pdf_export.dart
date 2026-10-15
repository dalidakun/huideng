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

  /// 需要归一化的标点：Droid Sans Fallback 只含中文字形，通用标点（弯引号
  /// `“”‘’`、破折号、省略号等）既不在该字体里，也超出内置拉丁字体
  /// （仅支持 0x00–0xFF）的范围，排版时会被替换成空白占位符。这里把这类
  /// 标点统一成字体里已有的写法，保证用户原文能正常显示。
  static const Map<int, String> _punctMap = {
    // 单引号 / 撇号。
    0x2018: "'", 0x2019: "'", 0x201A: "'", 0x201B: "'", 0x2032: "'",
    // 双引号。
    0x201C: '"', 0x201D: '"', 0x201E: '"', 0x201F: '"', 0x2033: '"',
    // 各种连字符 / 短横 / 减号。
    0x2010: '-', 0x2011: '-', 0x2012: '-', 0x2013: '-', 0x2014: '-',
    0x2015: '-', 0x2212: '-',
    // 省略号 / 间隔号。
    0x2026: '...', 0x2027: '\u30fb',
    // 单书名号 fallback。
    0x3008: '<', 0x3009: '>',
  };

  /// 直接丢弃的不可见字符（零宽空格 / 连接符、BOM）。
  static const Set<int> _punctDrop = {0x200B, 0x200C, 0x200D, 0xFEFF};

  /// 归一化文本里的通用标点，避免 PDF 里丢字。见 [_punctMap]。
  static String _sanitize(String input) {
    if (input.isEmpty) return input;
    final buf = StringBuffer();
    for (final r in input.runes) {
      if (_punctDrop.contains(r)) continue;
      final rep = _punctMap[r];
      if (rep != null) {
        buf.write(rep);
      } else {
        buf.writeCharCode(r);
      }
    }
    return buf.toString();
  }

  /// 供测试使用的公开入口（内部同样走 [_sanitize]）。
  static String sanitizePunctuation(String input) => _sanitize(input);

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

  /// 时间线记录导出（画线 / 备注 / 笔记）：按年份分组。
  ///
  /// 画线、备注对应的经文以棕色块显著展示，用户自己写的内容用绿色块区分，
  /// 两者从底色到文字颜色都不同，一眼可分。
  static Future<Uint8List> buildTimelinePdf({
    required String author,
    required List<PdfRecordYear> years,
    DateTime? now,
  }) async {
    final madeOn = _madeOn(now ?? DateTime.now());
    final total = years.fold<int>(0, (s, y) => s + y.records.length);
    return _build(
      title: '我的笔记',
      subtitle: author,
      madeOn: madeOn,
      countText: '共 $total 条记录 · 涉及 ${years.length} 个年份',
      body: _buildTimelineBody(years),
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
    // 标题 / 副标题 / 时间 / 统计等直接 pw.Text 的文本也统一归一化标点。
    title = _sanitize(title);
    subtitle = _sanitize(subtitle);
    madeOn = _sanitize(madeOn);
    countText = _sanitize(countText);
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
      pw.Text(_sanitize(post.date),
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
        pw.Text(_sanitize(post.footer!),
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

  // ---------- 时间线记录正文 ----------

  static List<pw.Widget> _buildTimelineBody(List<PdfRecordYear> years) {
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
            pw.Divider(color: _border, height: 1, thickness: 0.8),
            pw.SizedBox(height: 14),
          ],
        ),
      );
      for (final r in y.records) {
        children.add(_timelineRecord(r));
      }
    }
    return children;
  }

  static pw.Widget _timelineRecord(PdfRecord r) {
    final children = <pw.Widget>[
      // 顶部一行：类型角标 + 经名 + 时间。
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _recordBadge(r.kind),
          pw.SizedBox(width: 6),
          pw.Expanded(
            child: pw.Text(
              _sanitize(r.sutraName.isEmpty ? '未标注经名' : r.sutraName),
              style: pw.TextStyle(
                  fontSize: 12, color: _ink, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(width: 8),
          pw.Text(_sanitize(r.date),
              style: pw.TextStyle(fontSize: 10.5, color: _grey)),
        ],
      ),
      pw.SizedBox(height: 6),
    ];

    // 经文：棕色块，与用户内容明确区分。
    final sutra = r.sutraText?.trim() ?? '';
    if (sutra.isNotEmpty) {
      children.addAll(_labeledBlock(
        label: '经文',
        text: sutra,
        labelColor: _brown,
        bg: _sutraBg,
        textColor: _sutraText,
      ));
    }

    // 用户内容（备注 / 笔记正文）：绿色块。
    final user = r.userText?.trim() ?? '';
    if (user.isNotEmpty) {
      if (sutra.isNotEmpty) children.add(pw.SizedBox(height: 6));
      children.addAll(_labeledBlock(
        label: r.userLabel ?? '内容',
        text: user,
        labelColor: _ideaText,
        bg: _ideaBg,
        textColor: _ideaText,
      ));
    }

    if ((r.footnote ?? '').isNotEmpty) {
      children.addAll([
        pw.SizedBox(height: 6),
        pw.Text(_sanitize(r.footnote!),
            style: pw.TextStyle(fontSize: 10, color: _darkGrey)),
      ]);
    }
    children.add(pw.SizedBox(height: 16));

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: children,
    );
  }

  /// 记录类型角标：画线绿、备注红、笔记黑，一律白字。
  static pw.Widget _recordBadge(PdfRecordKind kind) {
    final PdfColor bg;
    final String label;
    switch (kind) {
      case PdfRecordKind.highlight:
        label = '画线';
        bg = _markHighlight;
      case PdfRecordKind.thought:
        label = '备注';
        bg = _markThought;
      case PdfRecordKind.note:
        label = '笔记';
        bg = _markNote;
    }
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: pw.BoxDecoration(
        color: bg,
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Text(label,
          style: pw.TextStyle(
              fontSize: 10,
              color: PdfColors.white,
              fontWeight: pw.FontWeight.bold)),
    );
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
    label = _sanitize(label);
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
    text = _sanitize(text);
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
  static const PdfColor _markHighlight = PdfColor.fromInt(0xFF5D7C5A);
  static const PdfColor _markThought = PdfColor.fromInt(0xFFC0392B);
  static const PdfColor _markNote = PdfColor.fromInt(0xFF1C1C1C);
}

/// 记录类型（与时间线的画线 / 备注 / 笔记对应）。
enum PdfRecordKind { highlight, thought, note }

/// 一年内的时间线记录列表。
class PdfRecordYear {
  const PdfRecordYear({required this.year, required this.records});

  final int year;
  final List<PdfRecord> records;
}

/// 单条时间线记录（用于导出）。
class PdfRecord {
  const PdfRecord({
    required this.kind,
    required this.date,
    required this.sutraName,
    this.sutraText,
    this.userText,
    this.userLabel,
    this.footnote,
  });

  final PdfRecordKind kind;
  final String date;
  final String sutraName;

  /// 经文内容：以棕色块展示（画线的画线文字 / 备注对应的段落经文）。
  final String? sutraText;

  /// 用户自己写的内容：以绿色块展示（备注 / 笔记正文）。
  final String? userText;

  /// 用户内容色块的角标文案（备注 / 笔记）。
  final String? userLabel;

  final String? footnote;
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