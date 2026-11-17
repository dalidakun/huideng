import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_flutter_app/dedication_store.dart';
import 'package:my_flutter_app/dedication_templates.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('默认回向是模板第一条「通用回向偈」', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(DedicationStore.defaultText, kDedicationTemplates.first.text);
    expect(DedicationStore.defaultText, contains('愿以此功德，庄严佛净土'));
    expect(DedicationStore.effective(prefs), DedicationStore.defaultText);
  });

  test('当前回向在期限内生效，到期当天仍生效，次日起恢复默认', () async {
    final prefs = await SharedPreferences.getInstance();
    await DedicationStore.saveCurrent(
      prefs,
      text: '愿以此功德，回向给我的父母。',
      days: 7,
      now: DateTime(2026, 11, 15, 10, 30),
    );

    expect(prefs.getString(DedicationStore.startKey), '2026-11-15');
    expect(prefs.getString(DedicationStore.endKey), '2026-11-21');

    const text = '愿以此功德，回向给我的父母。';
    expect(DedicationStore.effective(prefs, today: '2026-11-15'), text);
    expect(DedicationStore.effective(prefs, today: '2026-11-21'), text);
    expect(DedicationStore.effective(prefs, today: '2026-11-22'),
        DedicationStore.defaultText);

    final entry = DedicationStore.current(prefs);
    expect(entry, isNotNull);
    expect(entry!.days, 7);
    expect(DedicationStore.remainingDays(entry, today: '2026-11-18'), 4);
    expect(DedicationStore.remainingDays(entry, today: '2026-11-22'), 0);
    expect(DedicationStore.isExpired(entry, today: '2026-11-21'), isFalse);
    expect(DedicationStore.isExpired(entry, today: '2026-11-22'), isTrue);
    expect(DedicationStore.isActive(entry, today: '2026-11-22'), isFalse);
  });

  test('持续时间跨月、跨年都按自然日计算', () async {
    final prefs = await SharedPreferences.getInstance();

    await DedicationStore.saveCurrent(
      prefs,
      text: '跨月回向',
      days: 21,
      now: DateTime(2026, 1, 20),
    );
    expect(prefs.getString(DedicationStore.endKey), '2026-02-09');

    await DedicationStore.saveCurrent(
      prefs,
      text: '跨年回向',
      days: 30,
      now: DateTime(2026, 12, 20),
    );
    expect(prefs.getString(DedicationStore.endKey), '2027-01-18');
    expect(DedicationStore.current(prefs)!.days, 30);
  });

  test('恢复默认回向会清掉当前回向与期限，并把这条记入历史', () async {
    final prefs = await SharedPreferences.getInstance();
    await DedicationStore.saveCurrent(
      prefs,
      text: '临时回向',
      days: 7,
      now: DateTime(2026, 11, 15),
    );
    await DedicationStore.clear(prefs);

    expect(DedicationStore.current(prefs), isNull);
    expect(prefs.getString(DedicationStore.textKey), isNull);
    expect(prefs.getString(DedicationStore.endKey), isNull);
    expect(DedicationStore.effective(prefs), DedicationStore.defaultText);

    final history = DedicationStore.history(prefs);
    expect(history, hasLength(1));
    expect(history.first.text, '临时回向');
    expect(history.first.startDate, '2026-11-15');
    expect(history.first.endDate, '2026-11-21');
    expect(history.first.days, 7);
    expect(history.first.endReason, DedicationEntry.reasonTerminated);
  });

  test('到期对账：过期回向移入历史、当前回向清空并恢复默认', () async {
    final prefs = await SharedPreferences.getInstance();
    await DedicationStore.saveCurrent(
      prefs,
      text: '愿以此功德，回向给我的母亲。',
      days: 7,
      now: DateTime(2026, 11, 1),
    );

    // 到期当天仍算生效。
    final stillActive =
        await DedicationStore.reconcile(prefs, today: '2026-11-07');
    expect(stillActive, isNotNull);
    expect(DedicationStore.history(prefs), isEmpty);

    // 次日起对账：进入历史，回到默认回向。
    final reconciled =
        await DedicationStore.reconcile(prefs, today: '2026-11-08');
    expect(reconciled, isNull);
    expect(DedicationStore.current(prefs), isNull);
    expect(DedicationStore.effective(prefs, today: '2026-11-08'),
        DedicationStore.defaultText);

    final history = DedicationStore.history(prefs);
    expect(history, hasLength(1));
    expect(history.first.text, '愿以此功德，回向给我的母亲。');
    expect(history.first.startDate, '2026-11-01');
    expect(history.first.endDate, '2026-11-07');
    expect(history.first.endReason, DedicationEntry.reasonExpired);
  });

  test('期限未到时修改回向内容：不进历史，开始日期保持不变', () async {
    final prefs = await SharedPreferences.getInstance();

    await DedicationStore.saveCurrent(
      prefs,
      text: '愿以此功德，回向给我的母亲。',
      days: 7,
      now: DateTime(2026, 11, 1),
    );
    // 第 5 天只改几个字，剩余 3 天（结束日期仍是 11-07）。
    await DedicationStore.saveCurrent(
      prefs,
      text: '愿以此功德，回向给我的母亲，愿她安康。',
      days: 3,
      now: DateTime(2026, 11, 5),
    );

    expect(DedicationStore.history(prefs), isEmpty,
        reason: '持续时间还没结束，不能出现在历史里');
    final current = DedicationStore.current(prefs)!;
    expect(current.text, '愿以此功德，回向给我的母亲，愿她安康。');
    expect(current.startDate, '2026-11-01', reason: '还是同一次回向，开始日期不变');
    expect(current.endDate, '2026-11-07');

    // 到期后才进入历史，记录的是修改后的正文。
    await DedicationStore.reconcile(prefs, today: '2026-11-08');
    final history = DedicationStore.history(prefs);
    expect(history, hasLength(1));
    expect(history.first.text, '愿以此功德，回向给我的母亲，愿她安康。');
    expect(history.first.startDate, '2026-11-01');
    expect(history.first.endDate, '2026-11-07');
    expect(history.first.endReason, DedicationEntry.reasonExpired);
  });

  test('手动终止：提前结束并记入历史，恢复默认回向', () async {
    final prefs = await SharedPreferences.getInstance();
    await DedicationStore.saveCurrent(
      prefs,
      text: '提前终止的回向',
      days: 30,
      now: DateTime(2026, 11, 1),
    );

    final terminated = await DedicationStore.terminate(prefs);
    expect(terminated, isNotNull);
    expect(terminated!.text, '提前终止的回向');

    expect(DedicationStore.current(prefs), isNull);
    expect(DedicationStore.effective(prefs), DedicationStore.defaultText);
    final history = DedicationStore.history(prefs);
    expect(history, hasLength(1));
    expect(history.first.text, '提前终止的回向');
    expect(history.first.endReason, DedicationEntry.reasonTerminated);
    expect(history.first.startDate, '2026-11-01');
    expect(history.first.endDate, '2026-11-30');
    expect(history.first.days, 30);
  });

  test('过期未对账就保存新回向：旧回向按自然到期归档', () async {
    final prefs = await SharedPreferences.getInstance();

    await DedicationStore.saveCurrent(
      prefs,
      text: '旧回向',
      days: 7,
      now: DateTime(2026, 11, 1),
    );
    await DedicationStore.saveCurrent(
      prefs,
      text: '新回向',
      days: 7,
      now: DateTime(2026, 11, 10),
    );

    final history = DedicationStore.history(prefs);
    expect(history, hasLength(1));
    expect(history.first.text, '旧回向');
    expect(history.first.endReason, DedicationEntry.reasonExpired);
    expect(DedicationStore.current(prefs)!.text, '新回向');
    expect(DedicationStore.current(prefs)!.startDate, '2026-11-10');
  });

  test('历史记录最近结束的排在最前，损坏数据不影响读取', () async {
    SharedPreferences.setMockInitialValues({
      DedicationStore.historyKey: jsonEncode([
        {
          'text': '最近结束',
          'start': '2026-11-10',
          'end': '2026-11-16',
          'reason': 'terminated',
        },
        {'text': '更早结束', 'start': '2026-10-01', 'end': '2026-10-07'},
        {'text': '', 'start': '2026-09-01', 'end': '2026-09-07'},
        'not-a-map',
      ]),
    });
    final prefs = await SharedPreferences.getInstance();

    final history = DedicationStore.history(prefs);
    expect(history.map((e) => e.text).toList(), ['最近结束', '更早结束']);
    expect(history.first.days, 7);
    expect(history.first.isTerminated, isTrue);
    expect(history.last.isTerminated, isFalse);
  });

  test('清理旧版误记：结束日期还没到的无标记历史会被剔除', () async {
    SharedPreferences.setMockInitialValues({
      DedicationStore.historyKey: jsonEncode([
        {
          'text': '误记（还没结束）',
          'start': '2026-11-10',
          'end': '2026-11-20',
        },
        {'text': '已正常结束', 'start': '2026-10-01', 'end': '2026-10-07'},
        {
          'text': '已终止',
          'start': '2026-11-10',
          'end': '2026-11-20',
          'reason': 'terminated',
        },
        {'text': '旧数据无期限', 'start': '', 'end': ''},
      ]),
    });
    final prefs = await SharedPreferences.getInstance();

    await DedicationStore.cleanupLegacyHistory(prefs, today: '2026-11-15');

    final history = DedicationStore.history(prefs);
    expect(history.map((e) => e.text).toList(),
        ['已正常结束', '已终止', '旧数据无期限'],
        reason: '结束日期未到的误记条目应被剔除，带结束方式的记录保留');
  });

  test('旧数据没有结束日期时视为长期有效', () async {
    SharedPreferences.setMockInitialValues({
      'checkin_dedication': '旧版填写的回向',
    });
    final prefs = await SharedPreferences.getInstance();
    final entry = DedicationStore.current(prefs);

    expect(entry, isNotNull);
    expect(entry!.hasDuration, isFalse);
    expect(entry.days, 0);
    expect(DedicationStore.remainingDays(entry), isNull);
    expect(DedicationStore.isActive(entry), isTrue);
    expect(DedicationStore.effective(prefs), '旧版填写的回向');
  });

  test('迁移旧版定时回向：保留升级前生效的那条，并删除废弃键', () async {
    SharedPreferences.setMockInitialValues({
      'checkin_dedication': '基础回向',
      'checkin_dedication_schedule': jsonEncode([
        {'date': '2026-11-01', 'text': '旧日程一'},
        {'date': '2026-11-10', 'text': '旧日程二'},
        {'date': '2026-12-01', 'text': '尚未生效的日程'},
      ]),
    });
    final prefs = await SharedPreferences.getInstance();

    await DedicationStore.migrateLegacy(prefs, today: '2026-11-15');

    expect(prefs.getString(DedicationStore.legacyScheduleKey), isNull);
    expect(prefs.getString(DedicationStore.textKey), '旧日程二');
    expect(prefs.getString(DedicationStore.endKey), isNull,
        reason: '旧日程没有持续期限，迁移后同样没有期限');
    expect(DedicationStore.effective(prefs, today: '2026-11-15'), '旧日程二');
  });

  test('迁移时没有任何已生效的旧日程，则保留原回向', () async {
    SharedPreferences.setMockInitialValues({
      'checkin_dedication': '基础回向',
      'checkin_dedication_schedule': jsonEncode([
        {'date': '2026-12-01', 'text': '尚未生效的日程'},
      ]),
    });
    final prefs = await SharedPreferences.getInstance();

    await DedicationStore.migrateLegacy(prefs, today: '2026-11-15');

    expect(prefs.getString(DedicationStore.legacyScheduleKey), isNull);
    expect(prefs.getString(DedicationStore.textKey), '基础回向');
    expect(DedicationStore.effective(prefs), '基础回向');
  });
}
