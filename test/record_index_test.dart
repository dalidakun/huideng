import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/record_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('syncParagraph：新增感想与画线，擦除后按差集移除', () async {
    final idx = RecordIndex.instance;
    await idx.load(force: true);

    const para = '如是我闻，一时佛在舍卫国祇树给孤独园，与大比丘众千二百五十人俱。';
    await idx.syncParagraph(
      sutraKey: '佛说阿弥陀经',
      para: 0,
      paraText: para,
      thought: '一切有为法，如梦幻泡影',
      underlines: [
        (start: 5, end: 9),
        (start: 12, end: 16),
      ],
    );
    expect(idx.items.length, 3);
    expect(idx.items.where((i) => i.type == RecordType.thought).length, 1);
    expect(idx.items.where((i) => i.type == RecordType.highlight).length, 2);
    // 画线文字按区间从段落原文切出（期望值直接由 para 推导，避免手数下标）。
    final cut = idx.items
        .where((i) => i.type == RecordType.highlight)
        .map((i) => i.text)
        .toList();
    expect(cut,
        containsAllInOrder([para.substring(5, 9), para.substring(12, 16)]));

    // 同一段再次保存：只保留第二条画线、感想清空。
    await idx.syncParagraph(
      sutraKey: '佛说阿弥陀经',
      para: 0,
      paraText: para,
      thought: '',
      underlines: [(start: 12, end: 16)],
    );
    expect(idx.items.where((i) => i.type == RecordType.thought), isEmpty);
    final lines = idx.items.where((i) => i.type == RecordType.highlight);
    expect(lines.length, 1);
    expect(lines.first.text, para.substring(12, 16));
  });

  test('syncParagraph：画线全部擦除后不留残条', () async {
    final idx = RecordIndex.instance;
    await idx.load(force: true);
    await idx.syncParagraph(
      sutraKey: '心经',
      para: 3,
      paraText: '观自在菩萨，行深般若波罗蜜多时。',
      thought: '',
      underlines: [(start: 0, end: 5)],
    );
    expect(idx.items.length, 1);
    expect(idx.items.first.text, '观自在菩萨');
    await idx.syncParagraph(
      sutraKey: '心经',
      para: 3,
      paraText: '观自在菩萨，行深般若波罗蜜多时。',
      thought: '',
      underlines: const [],
    );
    expect(idx.items, isEmpty);
  });

  test('resyncSutra：重排版后按新段号重建，不留旧段号幽灵条目', () async {
    final idx = RecordIndex.instance;
    await idx.load(force: true);
    await idx.syncParagraph(
      sutraKey: '心经',
      para: 3,
      paraText: '观自在菩萨',
      thought: '照见五蕴皆空',
      underlines: [(start: 0, end: 2)],
    );
    expect(idx.items.length, 2);

    // 经文删掉第 1 段后，原本第 3 段变成第 2 段。
    await idx.resyncSutra(
      sutraKey: '心经',
      paragraphs: ['色即是空', '观自在菩萨'],
      notes: {1: '照见五蕴皆空'},
      underlines: {
        1: [
          {'start': 0, 'end': 2}
        ]
      },
    );
    final thought = idx.items.firstWhere((i) => i.type == RecordType.thought);
    final line = idx.items.firstWhere((i) => i.type == RecordType.highlight);
    expect(thought.para, 1);
    expect(thought.text, '照见五蕴皆空');
    expect(line.para, 1);
    expect(line.text, '观自');
    expect(idx.items.length, 2);
    // 旧段号 3 的条目不应残留。
    expect(idx.items.where((i) => i.para == 3), isEmpty);
  });

  test('syncNotesFromPrefs：与本地 notes 全量对账（新增 / 删除 / 引用经名）', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'notes',
      jsonEncode([
        {
          'id': 'n1',
          'content': r'$佛说阿弥陀经' '\n\n' '第一则',
          'updatedAt': '2026-01-02T03:04:05.000',
          'shared': true,
        },
        {
          'id': 'n2',
          'content': r'$心经' '\n' '第二则',
          'updatedAt': '2026-01-03T03:04:05.000',
          'shared': false,
        },
      ]),
    );
    final idx = RecordIndex.instance;
    await idx.load(force: true);
    await idx.syncNotesFromPrefs();

    var notes = idx.items.where((i) => i.type == RecordType.note).toList();
    expect(notes.length, 2);
    final n1 = notes.firstWhere((i) => i.id == 'n|n1');
    expect(n1.sutraKey, '佛说阿弥陀经');
    expect(n1.text, '第一则');
    expect(n1.shared, isTrue);
    expect(n1.paraText, isEmpty);

    // 删掉 n1（回收站彻底删除）后再对账，索引应同步移除。
    await prefs.setString(
      'notes',
      jsonEncode([
        {
          'id': 'n2',
          'content': r'$心经' '\n' '第二则',
          'updatedAt': '2026-01-03T03:04:05.000',
          'shared': false,
        },
      ]),
    );
    await idx.syncNotesFromPrefs();
    notes = idx.items.where((i) => i.type == RecordType.note).toList();
    expect(notes.length, 1);
    expect(notes.first.id, 'n|n2');
  });

  test('经名引用解析与剥离', () {
    expect(
      RecordIndex.extractSutraTitles(r'$佛说阿弥陀经' '\n' r'又见 $心经卷一' '\n正文'),
      ['佛说阿弥陀经', '心经卷一'],
    );
    // 引用后紧跟标点/空格时只取经名本身。
    expect(RecordIndex.extractSutraTitles(r'$地藏经，昨天读了一卷'), ['地藏经']);
    expect(
      RecordIndex.stripSutraTags(r'$佛说阿弥陀经' '\n\n' '正文一' '\n\n' '正文二'),
      '正文一\n\n正文二',
    );
  });

  test('RecordItem JSON 往返', () {
    const item = RecordItem(
      id: 'h|经|1|2|5',
      type: RecordType.highlight,
      sutraKeys: ['经', '经卷一'],
      para: 1,
      text: '片段',
      paraText: '',
      createdAt: 100,
      updatedAt: 200,
      shared: true,
      backfilled: true,
    );
    final back = RecordItem.fromJson(item.toJson())!;
    expect(back.id, item.id);
    expect(back.type, RecordType.highlight);
    expect(back.sutraKeys, ['经', '经卷一']);
    expect(back.createdAt, 100);
    expect(back.shared, isTrue);
    expect(back.backfilled, isTrue);
  });
}
