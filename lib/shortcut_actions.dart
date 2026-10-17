import 'dart:io';

import 'package:flutter/services.dart';

/// 桌面长按图标的静态快捷方式动作。
///
/// Android 侧在 `shortcuts.xml` 中声明两条快捷方式（一键打卡 / 继续阅读），
/// 点击后会把对应 action 带到 [MainActivity] 的启动 Intent 或 onNewIntent。
/// 原生侧用 `pendingShortcut` 保存动作，Dart 侧通过 [consumeLaunchAction] 原子
/// 拉取并清空，保证同一动作只被处理一次。
class ShortcutActions {
  ShortcutActions._();

  static const MethodChannel _channel = MethodChannel('app_channel');

  /// 一键打卡：一次性完成主页今日全部功课。
  static const String quickCheckIn = 'quick_checkin';

  /// 继续阅读：直接进入最近阅读的经书阅读页。
  static const String continueReading = 'continue_reading';

  /// 拉取并消费待处理的快捷方式动作；无动作时返回 null。
  static Future<String?> consumeLaunchAction() async {
    if (!Platform.isAndroid) return null;
    try {
      final action = await _channel.invokeMethod<String>('getShortcutAction');
      return (action == null || action.isEmpty) ? null : action;
    } catch (_) {
      return null;
    }
  }

  /// 监听原生侧热启动（App 已在后台，点击快捷方式触发 onNewIntent）发来的信号。
  ///
  /// [onAction] 只接收非空动作；原生信号不携带动作内容，收到信号后再统一
  /// 走 [consumeLaunchAction] 拉取，确保与冷启动路径共用同一消费入口。
  static void listen(void Function(String action) onAction) {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShortcutAction') {
        final action = await consumeLaunchAction();
        if (action != null) onAction(action);
      }
      return null;
    });
  }

  /// 取消监听（页面销毁时调用）。
  static void dispose() {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler(null);
  }
}
