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

  // ── 大数据量下的稳定性 ────────────────────────────────

  /// 造 n 条笔记，updatedAt 递增（越靠后越新）。
  Future<void> seedNotes(int n) async {
    final prefs = await SharedPreferences.getInstance();
    final base = DateTime(2026, 1, 1);
    await prefs.setString(
      'notes',
      jsonEncode([
        for (var i = 0; i < n; i++)
          {
            'id': 'n$i',
            'content': '第 $i 则',
            'updatedAt': base.add(Duration(minutes: i)).toIso8601String(),
            'shared': false,
          }
      ]),
    );
  }

  test('syncNotesFromPrefs：笔记超过配额时只留最新一批，且反复对账不再抖动',
      () async {
    final idx = RecordIndex.instance;
    // 把配额调小，才能在测试里真的走到截断分支。
    idx.noteQuota = 4;
    addTearDown(() => idx.noteQuota = RecordIndex.maxNoteItems);

    await idx.load(force: true);
    await seedNotes(12);
    await idx.syncNotesFromPrefs();

    // 只留更新时间最新的 4 条（n8..n11）。
    final kept = idx.items.where((i) => i.type == RecordType.note).map((i) => i.id).toList();
    expect(kept.length, 4);
    expect(kept, containsAll(<String>['n|n8', 'n|n9', 'n|n10', 'n|n11']));

    // 再连对 3 次：条目集合与时间戳必须一字不差。
    // 旧实现（写盘按最旧裁剪 + 下次全量加回）在这里必然出现增删抖动。
    final snapshot = <String, int>{
      for (final it in idx.items.where((i) => i.type == RecordType.note))
        it.id: it.updatedAt,
    };
    for (var i = 0; i < 3; i++) {
      await idx.syncNotesFromPrefs();
      final now = <String, int>{
        for (final it in idx.items.where((it) => it.type == RecordType.note))
          it.id: it.updatedAt,
      };
      expect(now, snapshot, reason: '第 $i 次重复对账结果发生了变化（抖动）');
    }

    // 新增一条最新的笔记：最旧的 n8 出局，其余不动。
    final prefs = await SharedPreferences.getInstance();
    final base = DateTime(2026, 1, 1);
    final all = [
      for (var i = 0; i < 12; i++)
        {
          'id': 'n$i',
          'content': '第 $i 则',
          'updatedAt': base.add(Duration(minutes: i)).toIso8601String(),
          'shared': false,
        },
      {
        'id': 'new',
        'content': '最新一则',
        'updatedAt': base.add(const Duration(days: 1)).toIso8601String(),
        'shared': false,
      }
    ];
    await prefs.setString('notes', jsonEncode(all));
    await idx.syncNotesFromPrefs();
    final after = idx.items.where((i) => i.type == RecordType.note).map((i) => i.id).toList();
    expect(after.length, 4);
    expect(after, contains('n|new'));
    expect(after, isNot(contains('n|n8'))); // 最旧的被顶掉
    // 顶掉之后仍然稳定。
    await idx.syncNotesFromPrefs();
    final again = idx.items.where((i) => i.type == RecordType.note).map((i) => i.id).toList();
    expect(again.toSet(), after.toSet());
  });

  test('syncNotesFromPrefs：画线/感想占位后，笔记配额相应让出，非笔记条目一条不少',
      () async {
    final idx = RecordIndex.instance;
    idx.noteQuota = 10;
    addTearDown(() => idx.noteQuota = RecordIndex.maxNoteItems);

    await idx.load(force: true);
    // 先塞 3 条非笔记条目。
    await idx.syncParagraph(
      sutraKey: '心经',
      para: 0,
      paraText: '观自在菩萨',
      thought: '照见五蕴皆空',
      underlines: [(start: 0, end: 2), (start: 2, end: 4)],
    );
    expect(idx.items.where((i) => i.type != RecordType.note).length, 3);

    await seedNotes(4);
    await idx.syncNotesFromPrefs();

    // 非笔记条目一条都不能因为笔记对账而丢掉。
    expect(idx.items.where((i) => i.type != RecordType.note).length, 3);
    expect(idx.items.where((i) => i.type == RecordType.note).length, 4);
    // 下标表与列表一致：每条的 id 唯一，且 _pos 指向的确实是它自己。
    final ids = idx.items.map((i) => i.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('_removeAll：批量删除后位置表仍与列表一致', () async {
    final idx = RecordIndex.instance;
    await idx.load(force: true);
    // 造 5 段各带一条感想。
    for (var p = 0; p < 5; p++) {
      await idx.syncParagraph(
        sutraKey: '心经',
        para: p,
        paraText: '段 $p 的原文',
        thought: '感想 $p',
        underlines: [(start: 0, end: 2)],
      );
    }
    expect(idx.items.length, 10);

    // 重排版把段号整体前移一位：应重建 5 段，且不残留旧段号。
    await idx.resyncSutra(
      sutraKey: '心经',
      paragraphs: ['新段 0', '新段 1', '新段 2', '新段 3', '新段 4'],
      notes: {0: '感想 0', 1: '感想 1', 2: '感想 2', 3: '感想 3', 4: '感想 4'},
      underlines: {
        0: [
          {'start': 0, 'end': 2}
        ],
        1: [
          {'start': 0, 'end': 2}
        ],
        2: [
          {'start': 0, 'end': 2}
        ],
        3: [
          {'start': 0, 'end': 2}
        ],
        4: [
          {'start': 0, 'end': 2}
        ],
      },
    );
    expect(idx.items.length, 10);
    // 没有旧段号 5+ 的幽灵条目。
    expect(idx.items.where((i) => i.para >= 5), isEmpty);
    // 位置表一致性：连续两次 syncParagraph 改不同段，结果必须都落在正确条目上。
    await idx.syncParagraph(
      sutraKey: '心经',
      para: 2,
      paraText: '新段 2',
      thought: '改过的感想',
      underlines: [(start: 0, end: 3)],
    );
    final t2 = idx.items.firstWhere((i) => i.type == RecordType.thought && i.para == 2);
    expect(t2.text, '改过的感想');
    // 其它段的感想没被串位。
    for (var p = 0; p < 5; p++) {
      if (p == 2) continue;
      final t = idx.items.firstWhere((i) => i.type == RecordType.thought && i.para == p);
      expect(t.text, '感想 $p');
    }
  });

  test('decodeIndexJson：重复的段落原文折叠成同一个字符串实例', () {
    const para = '观自在菩萨行深般若波罗蜜多时照见五蕴皆空度一切苦厄';
    final raw = jsonEncode([
      for (var i = 0; i < 4; i++)
        {
          'i': 'h|心经|$i|0|2',
          't': 0,
          'k': ['心经'],
          'p': i,
          'x': '观自',
          'q': para,
          'c': i,
          'u': i,
        }
    ]);
    final items = decodeIndexJson(raw);
    expect(items.length, 4);
    // 同一段原文只留一份内存。
    expect(identical(items[0].paraText, items[1].paraText), isTrue);
    expect(identical(items[2].paraText, items[3].paraText), isTrue);
    // 值仍然正确。
    expect(items[3].paraText, para);
  });

  test('decodeIndexJson：脏数据跳过而不是整体崩掉', () {
    final raw = jsonEncode([
      {'i': '', 't': 0}, // 空 id
      {'i': 'x', 't': 99}, // 越界类型
      {'i': 'ok', 't': 1, 'x': '正文', 'c': 5, 'u': 5},
      'not-a-map',
    ]);
    final items = decodeIndexJson(raw);
    expect(items.length, 1);
    expect(items.single.id, 'ok');
  });
}
