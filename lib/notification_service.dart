import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// 通知服务：负责每日打卡提醒的定时调度与消息通知总开关。
///
/// 持久化键（与 UI 共用）：
///  - notification_master：消息通知总开关
///  - checkin_reminder_enabled：打卡提醒是否开启
///  - checkin_reminder_time：每日提醒时间 "HH:mm"
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const int _checkinId = 1001;

  static const String masterKey = 'notification_master';
  static const String reminderEnabledKey = 'checkin_reminder_enabled';
  static const String reminderTimeKey = 'checkin_reminder_time';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  Future<void>? _initFuture;

  /// 应用启动时调用：初始化插件与时区。
  Future<void> init() {
    if (_initialized) return Future.value();
    return _initFuture ??= _doInit().then(
      (_) => _initFuture = null,
      onError: (Object e, StackTrace st) {
        _initFuture = null;
        debugPrint('NotificationService.init failed: $e');
      },
    );
  }

  Future<void> _doInit() async {
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
    }
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(settings: settings);
    _initialized = true;
    await syncCheckinReminder();
  }

  /// 确保初始化完成（应用启动时是后台异步初始化，操作前应等待它）。
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    await init();
  }

  /// 消息通知总开关是否开启。
  Future<bool> isMasterEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(masterKey) ?? false;
  }

  /// 打卡提醒开关是否开启。
  Future<bool> isReminderEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(reminderEnabledKey) ?? false;
  }

  /// 当前设置的提醒时间 "HH:mm"。
  Future<String> getReminderTime() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(reminderTimeKey) ?? '21:00';
  }

  /// 打开消息通知总开关（Android 13+ 会请求通知权限）。
  Future<bool> setMasterEnabled(bool enabled) async {
    await ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    if (enabled) {
      final granted = await _requestPermission();
      if (!granted) return false;
    }
    await prefs.setBool(masterKey, enabled);
    await syncCheckinReminder();
    return true;
  }

  Future<bool> _requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    try {
      final granted = await android.requestNotificationsPermission();
      return granted ?? true;
    } catch (e) {
      debugPrint('requestNotificationsPermission failed: $e');
      return true;
    }
  }

  /// 开启/关闭打卡提醒。开启时立即按设置时间重新调度。
  Future<void> setReminderEnabled(bool enabled) async {
    await ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(reminderEnabledKey, enabled);
    await syncCheckinReminder();
  }

  /// 设置提醒时间（"HH:mm"），保持当前开关状态。
  Future<void> setReminderTime(String time) async {
    await ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(reminderTimeKey, time);
    await syncCheckinReminder();
  }

  /// 按当前配置同步打卡提醒（总开关/提醒开关/时间任一变更后调用）。
  Future<void> syncCheckinReminder() async {
    if (!_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(reminderEnabledKey) ?? false;
    final master = prefs.getBool(masterKey) ?? false;
    if (!enabled || !master) {
      await _plugin.cancel(id: _checkinId);
      return;
    }
    final timeStr = prefs.getString(reminderTimeKey) ?? '21:00';
    final parts = timeStr.split(':');
    final hour = int.tryParse(parts[0]) ?? 21;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;

    final now = tz.TZDateTime.now(tz.local);
    var next = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!next.isAfter(now)) {
      next = next.add(const Duration(days: 1));
    }

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'checkin_reminder',
        '打卡提醒',
        channelDescription: '每日诵经打卡提醒',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );

    await _plugin.zonedSchedule(
      id: _checkinId,
      title: '今日打卡提醒',
      body: '又到诵经打卡的时间了，坚持就是精进。',
      scheduledDate: next,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }
}
