import 'dart:math' as math;

/// 去掉经文末尾由 CBETA 资料库附带的说明块。
///
/// 每部经文原文文末都带一段与正文无关的说明：
///
/// ```
/// 经文名（含卷数）重复
/// 【经文资讯】…
/// 【版本记录】…
/// 【编辑说明】…
/// 【原始资料】…
/// 【版权宣告】…
/// 【制作说明】…
/// ```
///
/// 阅读页只需要正文，因此这里把「说明块」整段去掉，并顺手去掉紧贴在说明块前、
/// 重复经名（含卷数，可能带「(八千一百九字)」等卷末字数注）的那一行。
///
/// 已下载到本机的旧正文仍是带说明块的版本（下载器命中本地文件时不会重下），
/// 所以在读取正文时再兜底清理一次，保证老用户看到的也是干净正文。
class SutraTextCleaner {
  SutraTextCleaner._();

  /// 说明块必须按顺序出现的标签（第 5 项有「版权宣告 / 版权公告」两种写法）。
  static const List<String> metadataMarkers = [
    '【经文资讯】',
    '【版本记录】',
    '【编辑说明】',
    '【原始资料】',
    '【版权宣告】',
    '【制作说明】',
  ];

  static const String _primaryMarker = '【经文资讯】';
  static const String _copyrightAlt = '【版权公告】';

  static const String _sentenceEnd = '。！？；：!?';
  static const List<String> _titleTails = [
    '经',
    '论',
    '品',
    '传',
    '记',
    '疏',
    '钞',
    '释',
    '集',
    '录',
    '赞',
    '咒',
    '呪',
  ];

  /// 括号注释（卷末字数、诵次、异名等）在比对标题时先去掉。
  static final RegExp _parens =
      RegExp(r'（[^（）]*）|\([^()]*\)|\[[^\[\]]*\]|〔[^〔〕]*〕');
  static final RegExp _blanks = RegExp(r'[\s\u3000·・]');
  static final RegExp _hasChinese = RegExp(r'[\u4e00-\u9fff]');
  static final RegExp _stripPunct =
      RegExp(r'^[，。！？；：、,.;:!?\s]+|[，。！？；：、,.;:!?\s]+$');
  static final RegExp _volumeSuffix = RegExp(
    r'(?:卷(?:第?[一二三四五六七八九十百千零〇两0-9]+|[上中下])?'
    r'|第[一二三四五六七八九十百千零〇两0-9]+卷'
    r'|[一二三四五六七八九十]+卷'
    r'|[上中下]卷)$',
  );
  static final RegExp _noLine = RegExp(r'^No\.\s*\d');
  static final RegExp _indexEntry = RegExp(r'P\.|大正|[0-9０-９]\s*b\s*）');
  static final RegExp _dartSutraId = RegExp(r'T\d{2}n\d{4}[A-Za-z]?_\d{3}');
  static final RegExp _infoTitle =
      RegExp(r'【经文资讯】[^\n]*?No\.\s*\d+[A-Za-z]?\s+(\S.*)');
  static final RegExp _decoration = RegExp(r'[◎○●＊*\s\u3000]');

  /// 清理 [content]；[titleHints] 可传当前经名，帮助识别文末重复的经名。
  ///
  /// 找不到完整的说明块时原样返回（避免误伤管理员手工排版的正文）。
  static String strip(String content, {List<String> titleHints = const []}) {
    if (content.isEmpty || !content.contains(_primaryMarker)) return content;
    final markerIndex = content.lastIndexOf(_primaryMarker);
    final lineStart = content.lastIndexOf('\n', markerIndex) + 1;
    final prefix = content.substring(lineStart, markerIndex);
    // 只处理独立成行的说明块（个别正文在标签前带一个「◎」装饰）。
    if (prefix.replaceAll(_decoration, '').isNotEmpty) return content;

    final tail = content.substring(markerIndex);
    // 说明块只有几百字；超长说明定位到的不是文末说明，保守不动。
    if (tail.length > 4000) return content;
    var pos = -1;
    for (var i = 0; i < metadataMarkers.length; i++) {
      final marker = metadataMarkers[i];
      var p = tail.indexOf(marker);
      if (p < 0 && i == 4) p = tail.indexOf(_copyrightAlt);
      if (p < 0 || p < pos) return content;
      pos = p;
    }

    final eol = content.contains('\r\n') ? '\r\n' : '\n';
    var body = content.substring(0, lineStart).trimRight();
    if (body.isEmpty) return content;

    final lines = body.split('\n');
    final last = lines.last.trim();
    final candidates = _candidates(body, titleHints, tail);
    if (_isRepeatedTitle(last, candidates)) {
      lines.removeLast();
      body = lines.join('\n').trimRight();
      if (body.isEmpty) return content;
    }
    return '$body$eol';
  }

  /// 经名候选：调用方提示 + 正文前几行 +「经文资讯」里的规范经名。
  static List<String> _candidates(
      String body, List<String> hints, String tail) {
    final raw = <String>[
      for (final h in hints) h.replaceAll(_dartSutraId, ''),
    ];
    var count = 0;
    for (final line in body.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || _noLine.hasMatch(t)) continue;
      // 长行/带句读的行已经是正文（短经可能只有几行，别把文末跋记当成经名）。
      if (t.length > 40 || _containsSentencePunct(t)) break;
      if (!_hasChinese.hasMatch(t)) continue;
      raw.add(t);
      count++;
      if (count >= 4) break;
    }
    final info = _infoTitle.firstMatch(tail);
    if (info != null) raw.add(info.group(1) ?? '');

    final out = <String>[];
    for (final c in raw) {
      final n = _normalize(c);
      for (final v in [n, _stripVolume(n)]) {
        if (v.isNotEmpty && !out.contains(v)) out.add(v);
      }
    }
    return out;
  }

  /// 文末那行是否是前文经名（含卷数）的重复。
  static bool _isRepeatedTitle(String line, List<String> candidates) {
    if (line.isEmpty || line.length > 60) return false;
    // 目录/索引条目（「…卷上（大正五一 P. 833b）」）也以「卷上」收尾，
    // 但那是正文内容，不是卷末题名。
    if (_indexEntry.hasMatch(line)) return false;
    // 带句末标点的多半是正文/跋文，不是标题行。
    if (_containsSentencePunct(line)) return false;
    final n = _normalize(line);
    if (n.length < 2 || !_hasChinese.hasMatch(n)) return false;

    // 说明块前的经名重复一定带卷数：卷第一 / 卷上 / 第十二卷 / 一卷 / 上卷 …
    // （单卷经的经名不带卷数，属于正文里的标题段，保留。）
    if (_volumeSuffix.hasMatch(n) && n.length >= 3) return true;

    final nv = _stripVolume(n);
    for (final c in candidates) {
      if (c.isEmpty) continue;
      final cv = _stripVolume(c);
      if (n == c || n == cv || nv == cv) return true;
      final shorter = n.length <= c.length ? n : c;
      final longer = n.length <= c.length ? c : n;
      if (shorter.length >= 4 &&
          longer.contains(shorter) &&
          shorter.length / longer.length >= 0.6) {
        return true;
      }
      if (n.length >= 3 && _similar(n, c) >= 0.8) return true;
      // 「僧伽和尚经」对「僧伽和尚欲入涅槃说六度经」这类简写。
      if (n.length >= 4 &&
          _titleTails.any(n.endsWith) &&
          _commonPrefix(n, c) >= 4) {
        return true;
      }
    }
    return false;
  }

  static bool _containsSentencePunct(String s) {
    for (final ch in _sentenceEnd.split('')) {
      if (s.contains(ch)) return true;
    }
    return false;
  }

  static String _normalize(String s) {
    var x = s
        .replaceAll('[＊]', '')
        .replaceAll('＊', '')
        .replaceAll('◎', '')
        .replaceAll('《', '')
        .replaceAll('》', '')
        .replaceAll('「', '')
        .replaceAll('」', '');
    x = x.replaceAll(_parens, '');
    x = x.replaceAll(_blanks, '');
    return x.replaceAll(_stripPunct, '');
  }

  static String _stripVolume(String s) {
    var prev = '\u0000';
    var cur = s;
    while (prev != cur) {
      prev = cur;
      cur = cur.replaceAll(_volumeSuffix, '');
    }
    return cur;
  }

  static int _commonPrefix(String a, String b) {
    var k = 0;
    final n = math.min(a.length, b.length);
    while (k < n && a.codeUnitAt(k) == b.codeUnitAt(k)) {
      k++;
    }
    return k;
  }

  /// 归一化编辑距离相似度（1.0 完全相同），只用于短标题。
  static double _similar(String a, String b) {
    if (a == b) return 1;
    if ((a.length - b.length).abs() > 6) return 0;
    final la = a.length;
    final lb = b.length;
    var prev = List<int>.generate(lb + 1, (i) => i);
    for (var i = 1; i <= la; i++) {
      final cur = List<int>.filled(lb + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= lb; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = math.min(
          math.min(prev[j] + 1, cur[j - 1] + 1),
          prev[j - 1] + cost,
        );
      }
      prev = cur;
    }
    return 1 - prev[lb] / math.max(la, lb);
  }
}
