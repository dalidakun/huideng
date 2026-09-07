import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/pdf_export.dart';
import 'package:my_flutter_app/reading_notes_page.dart';
import 'package:my_flutter_app/sutra_highlights_page.dart';
import 'package:my_flutter_app/reading_note_post.dart';

/// 与 `ReadingNotesPage._buildShareContent` 相同的感想分享帖正文。
String _thoughtsContent() {
  const metaPrefix = kSutraThoughtsMetaPrefix;
  const sutra = '金刚般若波罗蜜经';
  const first = '佛告须菩提：诸菩萨摩诃萨应如是降伏其心。';
  const pairs = [
    {'p': '佛告须菩提：诸菩萨摩诃萨应如是降伏其心。', 't': '降伏其心，即是安住于正念。'},
    {'p': '凡所有相，皆是虚妄。', 't': '不执着于相，方见真如。'},
  ];
  final meta = base64Encode(utf8.encode(jsonEncode(pairs)));
  return ['\$$sutra', first, '$metaPrefix$meta', '今天读到这里很有收获。']
      .join('\n\n');
}

/// 与 `SutraHighlightsPage._buildShareContent` 相同的画线分享帖正文。
String _highlightsContent() {
  const metaPrefix = kSutraHighlightsMetaPrefix;
  const sutra = '地藏菩萨本愿经';
  const first = '地狱不空，誓不成佛；众生度尽，方证菩提。';
  final meta = base64Encode(utf8.encode(jsonEncode([
    '地狱不空，誓不成佛',
    '众生度尽，方证菩提',
    '众生无边誓愿度',
  ])));
  return ['\$$sutra', first, '$metaPrefix$meta', '愿力深重！']
      .join('\n\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sutraPostPlainText 去除分享帖 base64 乱码', () {
    test('感想分享帖：只导出第一条经文/感想，留言单列', () {
      final clean = sutraPostPlainText(_thoughtsContent());
      expect(clean, isNotNull);
      // 不允许残留哨兵 / base64 乱码。
      expect(clean, isNot(contains('TS')));
      expect(clean, isNot(contains('\u00a7')));
      expect(clean, isNot(contains('eyJ')));
      expect(clean, contains('\$金刚般若波罗蜜经'));
      // 只导出第一条经文与感想（不是全部）。
      expect(clean, contains('佛告须菩提：诸菩萨摩诃萨应如是降伏其心。'));
      expect(clean, contains('降伏其心，即是安住于正念。'));
      expect(clean, isNot(contains('凡所有相，皆是虚妄。')));
      expect(clean, isNot(contains('不执着于相，方见真如。')));
      // 留言与经文列表区分开，单独成节。
      expect(clean, contains('【留言】'));
      expect(clean, contains('今天读到这里很有收获。'));
    });

    test('画线分享帖：只导出第一条画线，留言单列', () {
      final clean = sutraPostPlainText(_highlightsContent());
      expect(clean, isNotNull);
      expect(clean, isNot(contains('HS')));
      expect(clean, isNot(contains('\u00a7')));
      expect(clean, contains('\$地藏菩萨本愿经'));
      // 只导出第一条画线（不是全部）。
      expect(clean, contains('地狱不空，誓不成佛'));
      expect(clean, isNot(contains('众生度尽，方证菩提')));
      expect(clean, isNot(contains('众生无边誓愿度')));
      expect(clean, contains('【留言】'));
      expect(clean, contains('愿力深重！'));
    });

    test('普通文本：返回 null（走原 plainText 逻辑）', () {
      expect(sutraPostPlainText('今天读了一遍《金刚经》，深感法喜。'), isNull);
    });
  });

  const poster = PdfNotesYear(year: 2026, posts: [
    PdfNotesPost(
      date: '2026-01-02 10:30',
      body: '第一段笔记：\n\n一切有为法，如梦幻泡影，如露亦如电，应作如是观。',
      footer: '点赞 3 · 评论 1 · 转发 0 · 阅读 12',
    ),
    PdfNotesPost(
      date: '2026-03-05 08:00',
      body: '第二段笔记：\n诸恶莫作，众善奉行，自净其意，是诸佛教。',
    ),
  ]);

  test('buildNotesPdf 生成可解析的非空 PDF', () async {
    final bytes = await PdfExporter.buildNotesPdf(
      author: '测试用户',
      years: [poster],
    );
    expect(bytes, isNotEmpty);
    // PDF 文件头。
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    // 尾部 %%EOF 标记。
    expect(String.fromCharCodes(bytes.skip(bytes.length - 5)).trimRight(),
        endsWith('%EOF'));
  });

  test('buildReadingNotesPdf 生成可解析的非空 PDF', () async {
    final bytes = await PdfExporter.buildReadingNotesPdf(
      sutraName: '金刚般若波罗蜜经',
      pairs: [
        (
          '佛告须菩提：诸菩萨摩诃萨应如是降伏其心。',
          '降伏其心，即是安住于正念。',
        ),
      ],
    );
    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(String.fromCharCodes(bytes.skip(bytes.length - 5)).trimRight(),
        endsWith('%EOF'));
  });
}