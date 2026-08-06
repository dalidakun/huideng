import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';

/// 读经时长统计：仅记录「经书阅读页处于前台打开」的时间。
/// 浏览 App 其他页面、应用退到后台均不计时。
/// 今日读经（跨天自动清零）与累积读经均为即时累加。
/// 登录后把累积时长增量上报云端（userAccounts.readingSeconds），
/// 供他人主页展示该用户点亮的修学徽章。
class ReadingTimeService {
  ReadingTimeService._();
  static final ReadingTimeService instance = ReadingTimeService._();

  static const _kTotal = 'reading_time_total_seconds';
  static const _kTodayDate = 'reading_time_today_date';
  static const _kTodaySec = 'reading_time_today_seconds';
  static const _kSessionStart = 'reading_time_session_start_ms';

  /// 已成功上报到云端的累计秒数（本地增量上报游标）。
  static const _kSentTotal = 'reading_time_sent_total';

  /// 单次会话最大计入时长（秒），防止异常数据刷爆统计。
  static const int _maxSessionSeconds = 6 * 60 * 60;

  /// 单次云端上报最大增量（秒）：一天 24 小时，防止异常/恶意数据刷爆服务端。
  static const int _maxReportDelta = 24 * 60 * 60;

  final ValueNotifier<int> todaySeconds = ValueNotifier<int>(0);
  final ValueNotifier<int> totalSeconds = ValueNotifier<int>(0);

  SharedPreferences? _prefs;
  Timer? _timer;
  bool _running = false;
  bool _loaded = false;
  int _sessionStartMs = 0;
  int _todaySec = 0;
  int _totalSec = 0;
  String _todayKey = '';

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    if (_loaded) return;
    _prefs ??= await SharedPreferences.getInstance();
    _totalSec = _prefs!.getInt(_kTotal) ?? 0;
    final now = DateTime.now();
    _todayKey = _dateKey(now);
    _todaySec = _prefs!.getString(_kTodayDate) == _todayKey
        ? (_prefs!.getInt(_kTodaySec) ?? 0)
        : 0;
    _loaded = true;
    _emit();
  }

  /// 读取当前统计值（仅初始化，不开启会话）。
  Future<void> ensureLoaded() => _load();

  /// 打开经书阅读页（且处于前台、为当前路由）时调用：开始累计。
  Future<void> start() async {
    await _load();
    if (_running) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // 上次会话异常未结束（进程被杀/闪退）：补记后清空。
    final lastStart = _prefs!.getInt(_kSessionStart) ?? 0;
    if (lastStart > 0) {
      final elapsedSec = ((now - lastStart) / 1000).round();
      if (elapsedSec > 0 && elapsedSec <= _maxSessionSeconds) {
        _add(elapsedSec);
      }
      await _prefs!.remove(_kSessionStart);
    }
    _running = true;
    _sessionStartMs = now;
    await _prefs!.setInt(_kSessionStart, now);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// 离开阅读页或应用退到后台时调用：结束累计。
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsedSec = ((now - _sessionStartMs) / 1000).round();
    if (elapsedSec > 0 && elapsedSec <= _maxSessionSeconds) {
      _add(elapsedSec);
    }
    _sessionStartMs = 0;
    await _prefs?.remove(_kSessionStart);
    // 阅读会话结束即上报云端，保证他人主页徽章及时点亮。
    unawaited(reportToCloud());
  }

  void _tick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsedSec = ((now - _sessionStartMs) / 1000).round();
    if (elapsedSec <= 0) return;
    _add(elapsedSec);
    _sessionStartMs = now;
  }

  void _add(int seconds) {
    _todaySec += seconds;
    _totalSec += seconds;
    final key = _dateKey(DateTime.now());
    if (key != _todayKey) {
      _todayKey = key;
      _todaySec = seconds;
    }
    _emit();
    _prefs?.setInt(_kTotal, _totalSec);
    _prefs?.setString(_kTodayDate, _todayKey);
    _prefs?.setInt(_kTodaySec, _todaySec);
  }

  void _emit() {
    todaySeconds.value = _todaySec;
    totalSeconds.value = _totalSec;
  }

  /// 把本地新增的累计时长增量上报云端（幂等：游标记录已上报部分）。
  /// 登录后才上报；失败静默，游标不前进，下次上报会重试。
  Future<void> reportToCloud() async {
    if (!AuthService.instance.isLoggedIn) return;
    await ensureLoaded();
    if (_totalSec <= 0) return;
    final prefs = _prefs!;
    final sent = prefs.getInt(_kSentTotal) ?? 0;
    final delta = _totalSec - sent;
    if (delta <= 0) return;
    final sendDelta = delta > _maxReportDelta ? _maxReportDelta : delta;
    try {
      final res =
          await CloudNotesService.instance.reportReadingTime(sendDelta);
      final accepted = (res['accepted'] as num?)?.toInt() ?? sendDelta;
      await prefs.setInt(_kSentTotal, sent + accepted);
    } catch (_) {
      // 网络失败静默，等待下次上报。
    }
  }
}
