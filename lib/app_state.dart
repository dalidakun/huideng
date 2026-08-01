import 'package:flutter/foundation.dart';

/// 全局「AI 助手」面板显隐信号。
/// 阅读页点「AI」时置 true；再次点 AI / 系统返回 / 离开阅读页时置 false。
/// 面板 WebView 常驻根节点（不随阅读页销毁），聊天会话得以延续。
final ValueNotifier<bool> assistantVisible = ValueNotifier<bool>(false);
