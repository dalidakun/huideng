import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/post_rich_content.dart';

Map<String, dynamic> _meta(List<Map<String, String>> items) =>
    {'v': 1, 'items': items};

String _notesMeta() => base64Encode(utf8.encode(jsonEncode([
      {'c': '第一条笔记'},
    ])));

String _highlightsMeta() => base64Encode(utf8.encode(jsonEncode([
      {'text': '凡所有相，皆是虚妄。'},
    ])));

String _thoughtsMeta() => base64Encode(utf8.encode(jsonEncode(
      _meta([
        {'text': '应无所住而生其心。'},
      ]),
    )));

void main() {
  group('classifySutraNote 三标签互斥', () {
    test('画线分享帖（§§HS§§）归入「画线」', () {
      final content =
          '\$金刚般若波罗蜜经\n\n凡所有相，皆是虚妄。\n\n§§HS§§${_highlightsMeta()}';
      expect(classifySutraNote(content), SutraNoteKind.highlight);
    });

    test('按段感想（§§TS§§）归入「备注」', () {
      final content =
          '\$金刚般若波罗蜜经\n\n应无所住而生其心。\n\n§§TS§§${_thoughtsMeta()}';
      expect(classifySutraNote(content), SutraNoteKind.remark);
    });

    test('读经笔记汇总（§§SN§§）归入「笔记」', () {
      final content =
          '\$金刚般若波罗蜜经\n\n第一条笔记\n\n§§SN§§${_notesMeta()}';
      expect(classifySutraNote(content), SutraNoteKind.note);
    });

    test('单条读经备注（无哨兵）归入「备注」', () {
      const content = '\$金刚般若波罗蜜经\n\n应无所住而生其心。\n\n这是一条读经备注';
      expect(classifySutraNote(content), SutraNoteKind.remark);
    });

    test('普通 \$经名 引用帖归入「笔记」', () {
      const content = '\$金刚般若波罗蜜经\n今天重读了这一部。';
      expect(classifySutraNote(content), SutraNoteKind.note);
    });

    test('画线帖不会被误判进「备注」', () {
      final content =
          '\$金刚般若波罗蜜经\n\n凡所有相，皆是虚妄。\n\n§§HS§§${_highlightsMeta()}';
      expect(classifySutraNote(content), isNot(SutraNoteKind.remark));
    });

    test('读经笔记汇总不会被误判进「备注」', () {
      final content =
          '\$金刚般若波罗蜜经\n\n第一条笔记\n\n§§SN§§${_notesMeta()}';
      expect(classifySutraNote(content), isNot(SutraNoteKind.remark));
    });
  });
}
