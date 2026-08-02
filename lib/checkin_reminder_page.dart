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
    if (mounted) setState(() => _loaded = true);
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

          const SizedBox(height: 20),

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
