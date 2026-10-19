import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 定时回向方案：从「生效日期」起，回向自动改用此内容。
class DedicationPlan {
  /// 生效日期，格式 yyyy-MM-dd。
  final String date;

  /// 生效后的回向正文。
  final String text;

  const DedicationPlan({required this.date, required this.text});

  Map<String, dynamic> toJson() => {'date': date, 'text': text};

  factory DedicationPlan.fromJson(Map<String, dynamic> json) => DedicationPlan(
        date: (json['date'] ?? '').toString(),
        text: (json['text'] ?? '').toString(),
      );
}

/// 回向数据的读写与「当前生效回向」的解析。
///
/// - 基础回向（`checkin_dedication`）：未命中任何定时方案时使用。
/// - 定时方案（`checkin_dedication_schedule`）：到生效日期后自动切换。
class DedicationStore {
  static const String baseKey = 'checkin_dedication';
  static const String scheduleKey = 'checkin_dedication_schedule';

  /// 基础回向文本。
  static String base(SharedPreferences p) => p.getString(baseKey) ?? '';

  /// 定时方案列表（按生效日期升序）。
  static List<DedicationPlan> schedule(SharedPreferences p) {
    final raw = p.getString(scheduleKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final plans = <DedicationPlan>[];
      for (final e in list) {
        final plan =
            DedicationPlan.fromJson((e as Map).cast<String, dynamic>());
        if (plan.text.trim().isNotEmpty) plans.add(plan);
      }
      plans.sort((a, b) => a.date.compareTo(b.date));
      return plans;
    } catch (_) {
      return [];
    }
  }

  /// 保存基础回向与定时方案。
  static Future<void> save(
      SharedPreferences p, String base, List<DedicationPlan> plans) async {
    await p.setString(baseKey, base);
    final sorted = [...plans]..sort((a, b) => a.date.compareTo(b.date));
    await p.setString(
        scheduleKey, jsonEncode(sorted.map((e) => e.toJson()).toList()));
  }

  /// 命中的定时方案：生效日期 <= 今天 中最新的一条；没有则返回 null。
  static DedicationPlan? activePlan(List<DedicationPlan> plans,
      {String? today}) {
    final t = today ?? dateKey(DateTime.now());
    DedicationPlan? active;
    for (final plan in plans) {
      if (plan.date.isEmpty || plan.date.compareTo(t) > 0) continue;
      if (active == null || plan.date.compareTo(active.date) > 0) active = plan;
    }
    return active;
  }

  /// 下一条将要生效的方案（生效日期 > 今天 中最早的一条）；没有则返回 null。
  static DedicationPlan? nextPlan(List<DedicationPlan> plans, {String? today}) {
    final t = today ?? dateKey(DateTime.now());
    DedicationPlan? next;
    for (final plan in plans) {
      if (plan.date.isEmpty || plan.date.compareTo(t) <= 0) continue;
      if (next == null || plan.date.compareTo(next.date) < 0) next = plan;
    }
    return next;
  }

  /// 当前生效的回向：命中定时方案则用之，否则退回基础回向。
  static String effective(SharedPreferences p, {String? today}) {
    final active = activePlan(schedule(p), today: today);
    if (active != null) return active.text;
    return base(p);
  }

  /// 把 DateTime 格式化为 yyyy-MM-dd。
  static String dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 解析 yyyy-MM-dd，失败返回 null。
  static DateTime? parseDate(String s) {
    final parts = s.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }
}
