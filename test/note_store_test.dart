import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/note_store.dart';

void main() {
  // 本地笔记的 updatedAt / deletedAt 存的是 DateTime.toIso8601String()，
  // 云端游标要的是 epoch 毫秒。这一层换算错了不会报错，只会静默地把所有
  // 时间戳压成 0，表现为时间线排序混乱、翻页重复或漏页，所以单独盯住。
  group('NoteStore 时间戳换算', () {
    test('ISO8601 字符串能正确转成毫秒，而不是 NaN→0', () {
      final dt = DateTime.utc(2026, 9, 28, 10, 0, 0);
      final iso = dt.toIso8601String();
      expect(NoteStore.toMillis(iso), dt.millisecondsSinceEpoch);
      expect(NoteStore.toMillis(iso), isNot(0));
    });

    test('本地时区字符串与 UTC 同一时刻得到相同毫秒', () {
      final local = DateTime(2026, 9, 28, 10, 0, 0);
      final utcSame = local.toUtc();
      expect(
        NoteStore.toMillis(local.toIso8601String()),
        utcSame.millisecondsSinceEpoch,
      );
    });

    test('毫秒转 ISO8601 再转回是恒等的（往返不丢精度）', () {
      final ms = 1791600000123;
      final iso = NoteStore.toIso(ms);
      expect(NoteStore.toMillis(iso), ms);
    });

    test('int 与 num 直接透传', () {
      expect(NoteStore.toMillis(1791600000123), 1791600000123);
      expect(NoteStore.toMillis(1791600000123.0), 1791600000123);
    });

    test('数值字符串按毫秒解析（兼容已存成数字的历史数据）', () {
      expect(NoteStore.toMillis('1791600000123'), 1791600000123);
    });

    test('空值与非法值兜底为 0，绝不抛异常', () {
      expect(NoteStore.toMillis(null), 0);
      expect(NoteStore.toMillis(''), 0);
      expect(NoteStore.toMillis('   '), 0);
      expect(NoteStore.toMillis('不是时间'), 0);
      expect(NoteStore.toMillis(<int>[1]), 0);
    });

    test('非正毫秒转成空串，避免 1970 假时间戳', () {
      expect(NoteStore.toIso(0), '');
      expect(NoteStore.toIso(-1), '');
    });
  });

  group('NoteStore 云端 payload', () {
    test('本地笔记没有 createdAt 时用 updatedAt 兜底，不丢时间线顺序', () {
      final iso = DateTime.utc(2026, 1, 2, 3, 4, 5).toIso8601String();
      final row = NoteStore.toCloud(
        {'id': 'n1', 'content': 'hello', 'updatedAt': iso},
        trashed: false,
      );
      expect(row['noteId'], 'n1');
      expect(row['createdAt'], NoteStore.toMillis(iso));
      expect(row['updatedAt'], NoteStore.toMillis(iso));
      expect(row['deletedAt'], 0);
    });

    test('已有 createdAt 时优先保留它（云端也只首次采纳）', () {
      final created = DateTime.utc(2025, 1, 1);
      final updated = DateTime.utc(2026, 1, 1);
      final row = NoteStore.toCloud(
        {
          'id': 'n1',
          'content': 'x',
          'createdAt': created.toIso8601String(),
          'updatedAt': updated.toIso8601String(),
        },
        trashed: false,
      );
      expect(row['createdAt'], created.millisecondsSinceEpoch);
      expect(row['updatedAt'], updated.millisecondsSinceEpoch);
    });

    test('updatedAt 完全缺失时兜当前时间，绝不写 0', () {
      final row = NoteStore.toCloud({'id': 'n1', 'content': 'x'}, trashed: false);
      expect(row['updatedAt'], greaterThan(0));
    });

    test('回收站笔记 deletedAt 为毫秒；正常笔记 deletedAt 为 0', () {
      final deleted = DateTime.utc(2026, 5, 6, 7, 8, 9);
      final trashed = NoteStore.toCloud(
        {
          'id': 'n1',
          'content': 'x',
          'updatedAt': deleted.toIso8601String(),
          'deletedAt': deleted.toIso8601String(),
        },
        trashed: true,
      );
      expect(trashed['deletedAt'], deleted.millisecondsSinceEpoch);
      expect(trashed['deletedAt'], greaterThan(0));

      final alive = NoteStore.toCloud(
        {'id': 'n2', 'content': 'x', 'updatedAt': deleted.toIso8601String()},
        trashed: false,
      );
      expect(alive['deletedAt'], 0);
    });

    test('shared / cloudId 正确透传，null 归一成空串', () {
      final row = NoteStore.toCloud(
        {'id': 'n1', 'content': 'x', 'shared': true, 'cloudId': 'c9'},
        trashed: false,
      );
      expect(row['shared'], isTrue);
      expect(row['cloudId'], 'c9');

      final none = NoteStore.toCloud(
        {'id': 'n2', 'content': 'x', 'cloudId': null},
        trashed: false,
      );
      expect(none['shared'], isFalse);
      expect(none['cloudId'], '');
    });

    test('从正文 \$经名 标签抽出 sutraKeys，供云端按经反查', () {
      final keys = NoteStore.extractSutraKeys(
        '读《\$金剛經》有感\n另一条\$法华经',
      );
      expect(keys, contains('金剛經'));
      expect(keys, contains('法华经'));
      expect(keys.length, 2);
    });

    test('正文无标签时 sutraKeys 为空，不报错', () {
      expect(NoteStore.extractSutraKeys('普通笔记，没有标签'), isEmpty);
    });
  });

  group('NoteStore 云端行反解', () {
    test('云端行转回本地笔记，形状与本地一致（ISO 字符串时间）', () {
      final updated = DateTime.utc(2026, 3, 4, 5, 6, 7);
      final created = DateTime.utc(2026, 3, 1);
      final local = NoteStore.fromCloud({
        'noteId': 'n1',
        'title': 't',
        'content': 'c',
        'createdAt': created.millisecondsSinceEpoch,
        'updatedAt': updated.millisecondsSinceEpoch,
        'shared': true,
        'cloudId': 'c1',
        'deletedAt': 0,
      });
      expect(local['id'], 'n1');
      expect(local['content'], 'c');
      expect(local['updatedAt'], isA<String>());
      expect(NoteStore.toMillis(local['updatedAt']),
          updated.millisecondsSinceEpoch);
      // 正常笔记不应带 deletedAt 键：UI 侧用 n['deletedAt'] == null 判断在不在回收站。
      expect(local.containsKey('deletedAt'), isFalse);
    });

    test('回收站行会带上 deletedAt，供 UI 判别', () {
      final deleted = DateTime.utc(2026, 4, 5);
      final local = NoteStore.fromCloud({
        'noteId': 'n1',
        'content': 'c',
        'createdAt': 0,
        'updatedAt': 0,
        'deletedAt': deleted.millisecondsSinceEpoch,
      });
      expect(local.containsKey('deletedAt'), isTrue);
      expect(NoteStore.toMillis(local['deletedAt']),
          deleted.millisecondsSinceEpoch);
    });

    test('云端 → 本地 → 云端 往返保持稳定（幂等重传不会漂移）', () {
      final updated = DateTime.utc(2026, 7, 8, 9, 10, 11);
      final original = {
        'noteId': 'n1',
        'content': 'round trip',
        'createdAt': updated.millisecondsSinceEpoch,
        'updatedAt': updated.millisecondsSinceEpoch,
        'deletedAt': 0,
      };
      final local = NoteStore.fromCloud(original);
      final again = NoteStore.toCloud(local, trashed: false);
      expect(again['createdAt'], original['createdAt']);
      expect(again['updatedAt'], original['updatedAt']);
      expect(again['deletedAt'], 0);
      expect(again['content'], 'round trip');
    });
  });
}
