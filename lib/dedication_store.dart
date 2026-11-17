import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'dedication_templates.dart';

/// 一条「当前回向」：回向正文 + 它的持续时间。
///
/// 与旧版「定时回向」（到某个日期改用某条）不同，现在只有一个当前回向：
/// 保存后立即生效，持续 N 天；期限未到时修改正文只是就地更新，不会进历史。
/// 只有到期（自动恢复默认）或手动终止后，这一条才会记入历史。
class DedicationEntry {
  /// 回向正文（含回向对象的具体表述）。
  final String text;

  /// 开始日期，格式 yyyy-MM-dd（第一次保存当天）。
  final String startDate;

  /// 结束日期，格式 yyyy-MM-dd（含当天）。
  ///
  /// 旧版本留下的回向没有期限，此时为空字符串，视为长期有效，
  /// 用户下次保存时会被写入新的期限。
  final String endDate;

  /// 结束方式：空字符串表示当前回向或未知，[reasonExpired] 为自然到期，
  /// [reasonTerminated] 为手动提前终止。仅历史记录会用到。
  final String endReason;

  const DedicationEntry({
    required this.text,
    required this.startDate,
    required this.endDate,
    this.endReason = '',
  });

  static const String reasonExpired = 'expired';
  static const String reasonTerminated = 'terminated';

  /// 是否设置过持续时间。
  bool get hasDuration => endDate.trim().isNotEmpty;

  /// 是否被手动提前终止。
  bool get isTerminated => endReason == reasonTerminated;

  /// 总天数（含开始当天）；没有期限时返回 0。
  int get days {
    final s = DedicationStore.parseDate(startDate);
    final e = DedicationStore.parseDate(endDate);
    if (s == null || e == null) return 0;
    return _calendarDaysBetween(s, e) + 1;
  }

  Map<String, dynamic> toJson() => {
        'text': text,
        'start': startDate,
        'end': endDate,
        if (endReason.isNotEmpty) 'reason': endReason,
      };

  factory DedicationEntry.fromJson(Map<String, dynamic> json) => DedicationEntry(
        text: (json['text'] ?? '').toString().trim(),
        startDate: (json['start'] ?? '').toString(),
        endDate: (json['end'] ?? '').toString(),
        endReason: (json['reason'] ?? '').toString(),
      );
}

/// 两个日期之间相差的自然日数（只按年月日算，不受夏令时影响）。
int _calendarDaysBetween(DateTime from, DateTime to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

/// 回向数据的读写、「当前生效回向」的解析与历史记录。
///
/// - 当前回向正文（`checkin_dedication`）与起止日期（`checkin_dedication_start`
///   / `checkin_dedication_end`）一起保存。
/// - 生效规则：今天在期限之内用当前回向；到期后自动恢复为默认回向。
/// - 历史只记录**已经结束**的回向：自然到期（[reconcile]）或手动终止
///   （[terminate]）。期限未到时修改正文只是就地更新，不会产生历史记录。
/// - 历史记录（`checkin_dedication_history`）最近结束的排在最前。
/// - 旧版「定时方案」键（`checkin_dedication_schedule`）只用于数据迁移，随后删除。
class DedicationStore {
  static const String textKey = 'checkin_dedication';
  static const String startKey = 'checkin_dedication_start';
  static const String endKey = 'checkin_dedication_end';
  static const String historyKey = 'checkin_dedication_history';

  /// 旧版本「定时自动更换」的存储键：现已废弃，读取时迁移并清理。
  static const String legacyScheduleKey = 'checkin_dedication_schedule';

  /// 历史记录最多保留的条数，避免无限增长。
  static const int historyLimit = 200;

  /// 默认回向：模板列表第一条「通用回向偈」。
  ///
  /// 当前回向到期后自动恢复为这一条。
  static String get defaultText => kDedicationTemplates.first.text;

  /// 已保存的当前回向；未设置过返回 null。
  static DedicationEntry? current(SharedPreferences p) {
    final text = (p.getString(textKey) ?? '').trim();
    if (text.isEmpty) return null;
    return DedicationEntry(
      text: text,
      startDate: p.getString(startKey) ?? '',
      endDate: p.getString(endKey) ?? '',
    );
  }

  /// 当前回向是否仍在生效。
  ///
  /// 旧数据没有结束日期（[DedicationEntry.hasDuration] 为 false）时视为长期有效。
  static bool isActive(DedicationEntry? entry, {String? today}) {
    if (entry == null || entry.text.trim().isEmpty) return false;
    if (!entry.hasDuration) return true;
    final t = today ?? dateKey(DateTime.now());
    return t.compareTo(entry.endDate.trim()) <= 0;
  }

  /// 是否已过期（设置过期限且今天已超过结束日期）。
  static bool isExpired(DedicationEntry? entry, {String? today}) {
    if (entry == null || entry.text.trim().isEmpty) return false;
    return entry.hasDuration && !isActive(entry, today: today);
  }

  /// 剩余天数（含今天）。已过期返回 0；没有期限返回 null。
  static int? remainingDays(DedicationEntry? entry, {String? today}) {
    if (entry == null || !entry.hasDuration) return null;
    final t = parseDate(today ?? dateKey(DateTime.now()));
    final e = parseDate(entry.endDate);
    if (t == null || e == null) return null;
    final left = _calendarDaysBetween(t, e) + 1;
    return left < 0 ? 0 : left;
  }

  /// 当前实际生效的回向：期限内用当前回向，否则用默认回向。
  static String effective(SharedPreferences p, {String? today}) {
    final entry = current(p);
    if (isActive(entry, today: today)) return entry!.text;
    return defaultText;
  }

  /// 对账：当前回向已过期则记入历史并清空，返回仍生效的回向。
  ///
  /// 首页与回向抽屉在读取前调用，保证到期后马上回到默认回向、
  /// 同时让到期的那条自动进入历史记录。
  static Future<DedicationEntry?> reconcile(
    SharedPreferences p, {
    String? today,
  }) async {
    final entry = current(p);
    if (entry == null) return null;
    if (isExpired(entry, today: today)) {
      await _archive(p, entry, reason: DedicationEntry.reasonExpired);
      await _clearCurrent(p);
      return null;
    }
    return entry;
  }

  /// 保存当前回向。期限未到时就地更新，期限结束后才开始新的一段。
  ///
  /// [days] 表示**从今天起还剩多少天**（含今天）：新设置时就是总天数，
  /// 已生效的回向在抽屉里预填的是剩余天数。
  ///
  /// - 当前回向仍在期限内：只更新正文和结束日期，开始日期保持不变，
  ///   不产生历史记录（改几个字不算结束）。
  /// - 当前回向为空或已过期：从今天起算新的一段；过期未对账的旧回向
  ///   先按「自然到期」记入历史。
  static Future<void> saveCurrent(
    SharedPreferences p, {
    required String text,
    required int days,
    DateTime? now,
  }) async {
    final normalized = text.trim();
    final start = now ?? DateTime.now();
    final today = dateKey(start);
    final safeDays = days < 1 ? 1 : days;
    final end = DateTime(
      start.year,
      start.month,
      start.day + safeDays - 1,
    );
    final newEnd = dateKey(end);
    final old = current(p);
    if (old != null && !isExpired(old, today: today)) {
      // 期限未到：同一段回向，就地更新，不写入历史。
      final oldStart = old.startDate.isNotEmpty ? old.startDate : today;
      await p.setString(textKey, normalized);
      await p.setString(startKey, oldStart);
      await p.setString(endKey, newEnd);
      return;
    }
    if (old != null) {
      await _archive(p, old, reason: DedicationEntry.reasonExpired);
    }
    await p.setString(textKey, normalized);
    await p.setString(startKey, today);
    await p.setString(endKey, newEnd);
  }

  /// 手动终止当前回向：提前结束并记入历史，随后恢复为默认回向。
  ///
  /// 返回被终止的那条；没有当前回向时返回 null。
  static Future<DedicationEntry?> terminate(SharedPreferences p) async {
    final old = current(p);
    if (old != null) {
      await _archive(p, old, reason: DedicationEntry.reasonTerminated);
      await _clearCurrent(p);
    }
    await p.remove(legacyScheduleKey);
    return old;
  }

  /// 恢复为默认回向：把当前回向按「提前终止」记入历史后清掉它。
  static Future<void> clear(SharedPreferences p) async {
    final old = current(p);
    if (old != null) {
      await _archive(p, old, reason: DedicationEntry.reasonTerminated);
    }
    await _clearCurrent(p);
    await p.remove(legacyScheduleKey);
  }

  /// 历史记录，最近结束的排在最前。
  static List<DedicationEntry> history(SharedPreferences p) {
    final raw = p.getString(historyKey);
    if (raw == null || raw.isEmpty) return const <DedicationEntry>[];
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const <DedicationEntry>[];
    }
    if (decoded is! List) return const <DedicationEntry>[];
    final out = <DedicationEntry>[];
    for (final e in decoded) {
      try {
        final entry =
            DedicationEntry.fromJson((e as Map).cast<String, dynamic>());
        if (entry.text.isNotEmpty) out.add(entry);
      } catch (_) {
        // 跳过单条损坏的记录，其余历史仍可正常显示。
      }
    }
    return out;
  }

  /// 清理旧版本误记入历史的回向。
  ///
  /// 上一版只要改了回向正文就把上一条写进历史，且没有记录结束方式。
  /// 这类记录如果结束日期还没到（今天或以后），按新规则根本还不算结束，
  /// 读取时直接丢掉；带结束方式的新记录（到期/终止）不受影响。
  static Future<void> cleanupLegacyHistory(
    SharedPreferences p, {
    String? today,
  }) async {
    final list = history(p);
    if (list.isEmpty) return;
    final t = today ?? dateKey(DateTime.now());
    final kept = list.where((e) {
      if (e.endReason.isNotEmpty) return true;
      if (!e.hasDuration) return true;
      return e.endDate.compareTo(t) < 0;
    }).toList();
    if (kept.length == list.length) return;
    await p.setString(
        historyKey, jsonEncode(kept.map((e) => e.toJson()).toList()));
  }

  /// 把一条结束了的回向写入历史（相同内容、起止日期与结束方式不重复记录）。
  static Future<void> _archive(
    SharedPreferences p,
    DedicationEntry entry, {
    String reason = DedicationEntry.reasonExpired,
  }) async {
    final text = entry.text.trim();
    if (text.isEmpty) return;
    final archived = DedicationEntry(
      text: text,
      startDate: entry.startDate,
      endDate: entry.endDate,
      endReason: reason,
    );
    final list = List<DedicationEntry>.of(history(p));
    final duplicated = list.any((e) =>
        e.text == archived.text &&
        e.startDate == archived.startDate &&
        e.endDate == archived.endDate &&
        e.endReason == archived.endReason);
    if (duplicated) return;
    list.insert(0, archived);
    if (list.length > historyLimit) {
      list.removeRange(historyLimit, list.length);
    }
    await p.setString(
        historyKey, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  /// 只清掉当前回向，不动历史记录。
  static Future<void> _clearCurrent(SharedPreferences p) async {
    await p.remove(textKey);
    await p.remove(startKey);
    await p.remove(endKey);
  }

  /// 迁移旧版「定时回向」数据：把升级前正在生效的那条正文保留为当前回向，
  /// 然后删除废弃的定时方案键。
  ///
  /// 旧方案只有生效日期、没有结束日期，迁移后的回向没有期限（长期有效），
  /// 用户下次保存时再设置持续时间即可。
  static Future<void> migrateLegacy(
    SharedPreferences p, {
    String? today,
  }) async {
    final raw = p.getString(legacyScheduleKey);
    if (raw == null) return;
    final t = today ?? dateKey(DateTime.now());
    String? activeText;
    var activeDate = '';
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final e in list) {
        final map = (e as Map).cast<String, dynamic>();
        final date = (map['date'] ?? '').toString();
        final text = (map['text'] ?? '').toString().trim();
        if (text.isEmpty || date.isEmpty || date.compareTo(t) > 0) continue;
        if (date.compareTo(activeDate) >= 0) {
          activeDate = date;
          activeText = text;
        }
      }
    } catch (_) {
      // 旧数据解析失败就只做清理，不阻塞使用。
    }
    if (activeText != null) {
      await p.setString(textKey, activeText);
      await p.remove(startKey);
      await p.remove(endKey);
    }
    await p.remove(legacyScheduleKey);
  }

  /// 把 DateTime 格式化为 yyyy-MM-dd。
  static String dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 解析 yyyy-MM-dd，失败返回 null。
  static DateTime? parseDate(String s) {
    final parts = s.trim().split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  /// 把 yyyy-MM-dd 显示成「11月21日」；解析失败时原样返回。
  static String displayDate(String date) {
    final d = parseDate(date);
    if (d == null) return date;
    return '${d.month}月${d.day}日';
  }

  /// 把 yyyy-MM-dd 显示成「2026年11月21日」；解析失败时原样返回。
  static String displayFullDate(String date) {
    final d = parseDate(date);
    if (d == null) return date;
    return '${d.year}年${d.month}月${d.day}日';
  }
}
