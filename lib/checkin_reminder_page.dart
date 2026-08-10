import 'package:flutter/material.dart';

import 'notification_service.dart';
import 'settings_widgets.dart';

/// 打卡提醒：每日定时（闹钟式）提醒诵经。
/// 基于系统通知调度，App 不在前台/被杀死也能按时提醒。
class CheckinReminderPage extends StatefulWidget {
  const CheckinReminderPage({super.key});

  @override
  State<CheckinReminderPage> createState() => _CheckinReminderPageState();
}

class _CheckinReminderPageState extends State<CheckinReminderPage> {
  bool _enabled = false;
  String _time = '21:00';
  bool _masterOn = false;
  bool _osEnabled = true;
  bool _hasPending = false;
  bool _systemAlarmOn = false;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _enabled = await NotificationService.instance.isReminderEnabled();
    _time = await NotificationService.instance.getReminderTime();
    _masterOn = await NotificationService.instance.isMasterEnabled();
    _osEnabled = await NotificationService.instance.areNotificationsEnabled();
    _hasPending = await NotificationService.instance.hasPendingCheckinReminder();
    _systemAlarmOn = await NotificationService.instance.isSystemAlarmEnabled();
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _toggleSystemAlarm(bool value) async {
    setState(() => _busy = true);
    try {
      if (value) {
        var res = await NotificationService.instance.armSystemAlarm(skipUI: true);
        if (res == null) {
          await NotificationService.instance.armSystemAlarm(skipUI: false);
        }
      } else {
        _showToast('已关闭自动设置闹钟；如需删除已设闹钟，请在手机「闹钟」里手动删除');
      }
      await NotificationService.instance.setSystemAlarmEnabled(value);
      if (mounted) setState(() => _systemAlarmOn = value);
    } catch (e) {
      if (mounted) _showToast('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickTime() async {
    final parts = _time.split(':');
    final initial =
        TimeOfDay(hour: int.tryParse(parts[0]) ?? 21, minute: int.tryParse(parts[1]) ?? 0);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    final hh = picked.hour.toString().padLeft(2, '0');
    final mm = picked.minute.toString().padLeft(2, '0');
    setState(() => _time = '$hh:$mm');
    await NotificationService.instance.setReminderTime('$hh:$mm');
    _hasPending = await NotificationService.instance.hasPendingCheckinReminder();
    if (mounted) setState(() {});
  }

  Future<void> _toggle(bool value) async {
    setState(() => _busy = true);
    try {
      if (value && !_masterOn) {
        final ok = await NotificationService.instance.setMasterEnabled(true);
        if (!ok) {
          if (mounted) {
            _showToast('未获得通知权限，请到系统设置中允许通知后重试');
          }
          return;
        }
        if (mounted) setState(() => _masterOn = true);
      }
      await NotificationService.instance.setReminderEnabled(value);
      if (mounted) setState(() => _enabled = value);
      _osEnabled = await NotificationService.instance.areNotificationsEnabled();
      _hasPending = await NotificationService.instance.hasPendingCheckinReminder();
      if (mounted && value && !_osEnabled) {
        _showToast('系统通知权限未开启，提醒无法弹出，请到系统设置中开启');
        setState(() {});
      }
    } catch (e) {
      if (mounted) _showToast('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showToast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const SettingsPageScaffold(
        title: '打卡提醒',
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return SettingsPageScaffold(
      title: '打卡提醒',
      child: ListView(
        padding: const EdgeInsets.only(top: 16, bottom: 40),
        children: [
          // 时间选择大卡（闹钟式）
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
                child: Column(
                  children: [
                    const Text('每日提醒时间',
                        style: TextStyle(fontSize: 14, color: sTextSec)),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: _busy ? null : _pickTime,
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                        decoration: BoxDecoration(
                          color: sGold.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: sGold.withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.schedule, size: 22, color: sGold),
                            const SizedBox(width: 8),
                            Text(
                              _time,
                              style: const TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.w700,
                                color: sText,
                                letterSpacing: 2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('点击时间可修改', style: const TextStyle(fontSize: 12, color: sTextHint)),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: sGold.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.notifications_active_outlined, size: 20, color: sGold),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('开启打卡提醒', style: TextStyle(fontSize: 16, color: sText, fontWeight: FontWeight.w500)),
                          SizedBox(height: 2),
                          Text('每天准时提醒诵经打卡', style: TextStyle(fontSize: 12, color: sTextHint)),
                        ],
                      ),
                    ),
                    SwitchTheme(
                      data: SwitchThemeData(
                        trackOutlineColor: WidgetStateProperty.resolveWith((_) => Colors.transparent),
                      ),
                      child: Switch(
                        value: _enabled,
                        activeThumbColor: sCard,
                        activeTrackColor: sGold,
                        onChanged: _busy ? null : _toggle,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: sGold.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.alarm_on, size: 20, color: sGold),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('手机闹钟提醒',
                              style: TextStyle(fontSize: 16, color: sText, fontWeight: FontWeight.w500)),
                          SizedBox(height: 2),
                          Text('直接调用手机自带闹钟，必定响铃（推荐）',
                              style: TextStyle(fontSize: 12, color: sTextHint)),
                        ],
                      ),
                    ),
                    SwitchTheme(
                      data: SwitchThemeData(
                        trackOutlineColor: WidgetStateProperty.resolveWith((_) => Colors.transparent),
                      ),
                      child: Switch(
                        value: _systemAlarmOn,
                        activeThumbColor: sCard,
                        activeTrackColor: sGold,
                        onChanged: _busy ? null : _toggleSystemAlarm,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _hasPending ? Icons.check_circle_outline : Icons.schedule,
                  size: 15,
                  color: _hasPending ? const Color(0xFF2E7D32) : sTextHint,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _hasPending
                        ? '已预约每日 $_time 的系统提醒（由系统闹钟准点触发）。'
                        : '当前系统内没有挂起的提醒，请重新打开开关或修改时间后重试。',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: _hasPending ? const Color(0xFF2E7D32) : sTextHint,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          if (_masterOn && !_osEnabled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFE4E4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFEE8888), width: 1),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, size: 16, color: Color(0xFFCC3333)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '系统通知权限未开启，提醒将无法弹出。请到 系统设置→应用→燃灯→通知 中开启「通知」开关。',
                        style: TextStyle(fontSize: 12.5, color: Color(0xFFAA3333), height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 15, color: sTextHint),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        '提醒由手机系统按时弹出，不需要打开 App 也能收到。',
                        style: TextStyle(fontSize: 12.5, color: sTextSec, height: 1.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (!_masterOn)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lightbulb_outline, size: 15, color: sGold),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          '提示：开启打卡提醒会自动打开「消息通知」；也可在设置页单独管理消息通知总开关。',
                          style: TextStyle(fontSize: 12.5, color: sTextSec, height: 1.5),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
