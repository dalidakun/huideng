import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/cloud_notes_service.dart';
import 'package:my_flutter_app/paragraph_alignment.dart';

ParaNote note(String text, [String quoted = '']) =>
    ParaNote(id: ParaNote.newId(), text: text, quoted: quoted);

void main() {
  group('matchParagraphIndex', () {
    test('完全相同的段优先于互相包含的段', () {
      // 「乙」既被第 0 段包含，也在第 5 段独立存在：应命中完全相同的第 5 段。
      final paras = ['甲乙丙', '丁', '戊', '己', '庚', '乙'];
      expect(matchParagraphIndex(paras, '乙', 4), 5);
    });

    test('原文被拆分时取离旧下标最近的半段', () {
      // 旧第 0 段「甲乙」被拆成第 0 段「甲」+ 第 1 段「乙」：备注留在原位置的那半。
      expect(matchParagraphIndex(['甲', '乙', '丙'], '甲乙', 0), 0);
      // 旧第 1 段「甲乙」拆分后下标没变：仍取离旧下标最近的一半。
      expect(matchParagraphIndex(['新', '甲', '乙'], '甲乙', 1), 1);
    });

    test('空白不参与匹配，空原文返回 -1', () {
      final paras = ['甲  乙'];
      expect(matchParagraphIndex(paras, '甲乙', 0), 0);
      expect(matchParagraphIndex(paras, '   ', 0), -1);
      expect(matchParagraphIndex(paras, '丁', 0), -1);
    });
  });

  group('alignParagraphAnnotations', () {
    test('前面插入段落后，备注跟随原段平移到新下标', () {
      final old = ['甲', '乙', '丙'];
      final now = ['新一', '甲', '乙', '丙'];
      final a = alignParagraphAnnotations(
        oldParagraphs: old,
        paragraphs: now,
        notes: {1: [note('乙的备注')]},
        underlines: const {},
        done: const {},
      );
      expect(a.notes.keys, [2]);
      expect(a.notes[2]!.single.text, '乙的备注');
      expect(a.unmigratedOld, isEmpty);
    });

    test('删除中间段落后，后面段落的备注前移', () {
      final a = alignParagraphAnnotations(
        oldParagraphs: ['甲', '乙', '丙'],
        paragraphs: ['甲', '丙'],
        notes: {2: [note('丙的备注')]},
        underlines: const {},
        done: const {},
      );
      expect(a.notes.keys, [1]);
      expect(a.unmigratedOld, isEmpty);
    });

    test('段落合并时多个旧备注合并到同一新段，不互相覆盖', () {
      final a = alignParagraphAnnotations(
        oldParagraphs: ['甲', '乙', '丙'],
        paragraphs: ['甲乙', '丙'],
        notes: {0: [note('甲的备注')], 1: [note('乙的备注')]},
        underlines: const {},
        done: const {},
      );
      expect(a.notes.length, 1);
      expect(a.notes[0]!.map((e) => e.text), ['甲的备注', '乙的备注']);
      expect(a.unmigratedOld, isEmpty);
    });

    test('找不到原文字时保留下标并标记未对齐', () {
      final a = alignParagraphAnnotations(
        oldParagraphs: ['甲', '乙'],
        paragraphs: ['甲', '丁'],
        notes: {1: [note('乙的备注')]},
        underlines: const {},
        done: const {},
      );
      expect(a.notes.keys, [1]);
      expect(a.unmigratedOld, {1});
    });

    test('只有画线 / 完成态的段也一并迁移', () {
      final a = alignParagraphAnnotations(
        oldParagraphs: ['甲', '乙'],
        paragraphs: ['新一', '甲', '乙'],
        notes: const {},
        underlines: {1: [
          {'start': 0, 'end': 2}
        ]},
        done: {1: true},
      );
      expect(a.underlines.keys, [2]);
      expect(a.done, {2: true});
      expect(a.notes, isEmpty);
    });

    test('两段合并到同一新段时完成态取「或」', () {
      final a = alignParagraphAnnotations(
        oldParagraphs: ['甲', '乙'],
        paragraphs: ['甲乙'],
        notes: const {},
        underlines: const {},
        done: {0: false, 1: true},
      );
      expect(a.done, {0: true});
    });

    test('原段被拆成多段时，每条备注按选中文字精确定位到对应新段', () {
      // 旧第 0 段「甲乙丙丁」被拆成三段；三条备注分别针对「甲」「乙丙」「丁」。
      // 它们必须分别落到第 0 / 1 / 2 段，而不是都挤在离旧下标最近的第 0 段。
      final a = alignParagraphAnnotations(
        oldParagraphs: ['甲乙丙丁'],
        paragraphs: ['甲', '乙丙', '丁'],
        notes: {
          0: [
            note('丁注', '丁'),
            note('甲注', '甲'),
            note('乙丙注', '乙丙'),
          ],
        },
        underlines: const {},
        done: const {},
      );
      expect(a.notes.keys.toList()..sort(), [0, 1, 2]);
      expect(a.notes[0]!.single.text, '甲注');
      expect(a.notes[1]!.single.text, '乙丙注');
      expect(a.notes[2]!.single.text, '丁注');
      expect(a.unmigratedOld, isEmpty);
    });

    test('选中文字跨拆分边界时回退到整段对齐', () {
      // 旧段「ABCD」拆成「AB」「CD」，备注针对的「BC」跨了边界，任何新段都装不下，
      // 回退到整段匹配的结果（离旧下标最近的「AB」）。
      final a = alignParagraphAnnotations(
        oldParagraphs: ['ABCD'],
        paragraphs: ['AB', 'CD'],
        notes: {0: [note('跨段注', 'BC')]},
        underlines: const {},
        done: const {},
      );
      expect(a.notes[0]!.single.text, '跨段注');
    });

    test('无选中文字的备注仍按整段原文对齐', () {
      final a = alignParagraphAnnotations(
        oldParagraphs: ['甲', '乙'],
        paragraphs: ['新一', '甲', '乙'],
        notes: {1: [note('整段备注')]},
        underlines: const {},
        done: const {},
      );
      expect(a.notes.keys, [2]);
      expect(a.notes[2]!.single.text, '整段备注');
    });

    test('两个或多个原段合并为一段时，各段备注合并到同一新段', () {
      // 旧「甲乙」「丙丁」合并为新「甲乙丙丁」；四条带选中文字的备注必须全部汇入第 0 段。
      final a = alignParagraphAnnotations(
        oldParagraphs: ['甲乙', '丙丁'],
        paragraphs: ['甲乙丙丁'],
        notes: {
          0: [note('甲注', '甲'), note('乙注', '乙')],
          1: [note('丙注', '丙'), note('丁注', '丁')],
        },
        underlines: const {},
        done: const {},
      );
      expect(a.notes.length, 1);
      expect(a.notes[0]!.map((e) => e.text), ['甲注', '乙注', '丙注', '丁注']);
      expect(a.unmigratedOld, isEmpty);
    });
  });
}
