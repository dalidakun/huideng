import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
///  - checkin_reminder_system_alarm：是否用手机自带闹钟（最可靠）
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const int _checkinId = 1001;

  static const String masterKey = 'notification_master';
  static const String reminderEnabledKey = 'checkin_reminder_enabled';
  static const String reminderTimeKey = 'checkin_reminder_time';
  static const String systemAlarmKey = 'checkin_reminder_system_alarm';

  static const MethodChannel _alarmChannel = MethodChannel('app_channel');

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
    // 主动创建提醒通道：保证高重要性+默认提示音在系统里固定下来，
    // 避免依赖第一次定时触发时才创建通道。
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'checkin_reminder',
          '打卡提醒',
          description: '每日诵经打卡提醒',
          importance: Importance.high,
          playSound: true,
        ));
    _initialized = true;
    await syncCheckinReminder();
  }

  /// App 回到前台时调用：只重挂系统通知式的打卡提醒（不自动打开系统闹钟，
  /// 避免从闹钟页返回时被再次弹回闹钟页面；系统闹钟由用户手动设置）。
  Future<void> onAppResumed() async {
    try {
      await ensureInitialized();
      await syncCheckinReminder();
    } catch (e) {
      debugPrint('[reminder] 回到前台重新调度失败: $e');
    }
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

  /// 系统通知权限是否开启（Android 13+ 对应 POST_NOTIFICATIONS，旧版本默认开启）。
  Future<bool> areNotificationsEnabled() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    try {
      return await android.areNotificationsEnabled() ?? true;
    } catch (e) {
      debugPrint('areNotificationsEnabled failed: $e');
      return true;
    }
  }

  /// 设备当前是否已挂起打卡提醒（查系统 AlarmManager 的实际挂起任务）。
  Future<bool> hasPendingCheckinReminder() async {
    try {
      final pending = await _plugin.pendingNotificationRequests();
      return pending.any((r) => r.id == _checkinId);
    } catch (e) {
      debugPrint('pendingNotificationRequests failed: $e');
      return false;
    }
  }

  /// 「手机自带闹钟」开关状态（最可靠的方式：直接调用系统闹钟 App）。
  Future<bool> isSystemAlarmEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(systemAlarmKey) ?? false;
  }

  /// 开启/关闭「手机自带闹钟」。
  Future<void> setSystemAlarmEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(systemAlarmKey, enabled);
    if (enabled) {
      await armSystemAlarm();
    }
  }

  /// 调用系统闹钟 App 创建一个闹钟（下次到点的单次闹钟，响了之后需 App 再设）。
  /// [skipUI] 为 true 时静默创建；返回本次走通的路径（null 表示失败）。
  Future<String?> armSystemAlarm({bool skipUI = true}) async {
    final time = await getReminderTime();
    final parts = time.split(':');
    final hour = int.tryParse(parts[0]) ?? 21;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    try {
      final res = await _alarmChannel.invokeMethod<String>('setSystemAlarm', {
        'hour': hour,
        'minute': minute,
        'message': '诵经打卡',
        'skipUI': skipUI,
      });
      debugPrint('[systemAlarm] 调用系统闹钟 $hour:$minute skipUI=$skipUI -> $res');
      return res;
    } catch (e) {
      debugPrint('[systemAlarm] 调用系统闹钟失败: $e');
      return null;
    }
  }

  /// 重新挂起「手机自带闹钟」（单次闹钟，App 每次启动/回前台时补设下一次）。
  Future<void> resyncSystemAlarm() async {
    if (!await isSystemAlarmEnabled()) return;
    final res = await armSystemAlarm(skipUI: true);
    if (res == null) {
      // 部分系统（Android 12+ 未授予精确闹钟权限）静默创建会失败，
      // 回退到打开系统闹钟界面由用户确认。
      await armSystemAlarm(skipUI: false);
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

    // 设备支持「精确闹钟」权限时优先用闹钟式精确调度：MIUI 等国产 ROM 后台
    // 限制严格，普通非精确闹钟常被推迟或拦截；闹钟式（setAlarmClock）被视为
    // 高优先级任务，准点触发、后台/Doze 下最可靠。不支持时回退到非精确调度。
    var scheduleMode = AndroidScheduleMode.inexactAllowWhileIdle;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final canExact = await android?.canScheduleExactNotifications();
      if (canExact == true) {
        scheduleMode = AndroidScheduleMode.alarmClock;
      }
    } catch (e) {
      debugPrint('canScheduleExactNotifications failed: $e');
    }

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'checkin_reminder',
        '打卡提醒',
        channelDescription: '每日诵经打卡提醒',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
      ),
      iOS: DarwinNotificationDetails(),
    );

    try {
      await _plugin.zonedSchedule(
        id: _checkinId,
        title: '今日打卡提醒',
        body: '又到诵经打卡的时间了，坚持就是精进。',
        scheduledDate: next,
        notificationDetails: details,
        androidScheduleMode: scheduleMode,
        matchDateTimeComponents: DateTimeComponents.time,
      );
      debugPrint('[reminder] 已调度打卡提醒: $next, mode=$scheduleMode');
    } catch (e) {
      debugPrint('[reminder] 调度打卡提醒失败: $e');
      rethrow;
    }
  }
}
