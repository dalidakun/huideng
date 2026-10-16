import 'package:flutter/foundation.dart';

/// 全局「AI 助手」面板显隐信号。
/// 阅读页点「AI」时置 true；再次点 AI / 系统返回 / 离开阅读页时置 false。
/// 面板 WebView 常驻根节点（不随阅读页销毁），聊天会话得以延续。
final ValueNotifier<bool> assistantVisible = ValueNotifier<bool>(false);

/// 经藏页右上角「助手」圆形展开面板显隐信号。
/// 点击入口从右上角圆点展开为全屏 DeepSeek 页面；再点关闭/系统返回时缩回。
final ValueNotifier<bool> assistantReveal = ValueNotifier<bool>(false);

/// Home page pull-down reveal: the home content slides down while the
/// DeepSeek chat slides in from the top.
final ValueNotifier<bool> homeReveal = ValueNotifier<bool>(false);

/// DeepSeek 下拉露出的实时进度（0→1）。
///
/// 手指在顶边下拉时由 PullRevealTracker 跟手写入，DeepSeek 页面随之逐渐露出；
/// 反向上拖进度回落即收回；松手后若未达展开阈值也会归零（收合动画走完后
/// 才释放 WebView，避免露出过程中内容闪没）。
final ValueNotifier<double> homeRevealScrub = ValueNotifier<double>(0);

/// 全局夜间模式信号：跟随阅读页「夜间模式」开关。
/// 消息中心等非阅读页面据此切换浅色/深色配色。
final ValueNotifier<bool> appDarkMode = ValueNotifier<bool>(false);
