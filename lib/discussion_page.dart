import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_palette.dart';
import 'assistant_session.dart';

/// 全局 AI 助手（DeepSeek）展示面。
///
/// 三个入口（底部 Tab / 上滑面板 / 圆形展开面板）都渲染同一个
/// [DiscussionPage]，但共享同一个 [AssistantSession] 的 WebViewController，
/// 并且只有「当前活跃」的那个展示面才真正挂载 WebViewWidget。
/// 因此整个 App 最多只有一个 WebView 存活，会话跨入口延续。
class DiscussionPage extends StatefulWidget {
  /// 当前实例对应的展示面。
  final AssistantSurface surface;
  const DiscussionPage({super.key, required this.surface});

  @override
  State<DiscussionPage> createState() => _DiscussionPageState();
}

class _DiscussionPageState extends State<DiscussionPage> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AssistantSurface?>(
      valueListenable: AssistantSession.instance.activeSurface,
      builder: (context, active, _) {
        final isActive = active == widget.surface;
        final controller = AssistantSession.instance.controller;

        if (kIsWeb) {
          return const ColoredBox(
            color: Color(0xFFf0f3f8),
            child: Center(
              child: Text(
                'WebView 功能暂不支持 Web 平台\n请在移动设备上查看',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            ),
          );
        }

        // 非活跃展示面：不挂载 WebView，只留底色占位，避免面板滑出/展开时闪白。
        if (!isActive || controller == null) {
          return const ColoredBox(color: Color(0xFFf0f3f8));
        }

        return ColoredBox(
          color: const Color(0xFFf0f3f8),
          child: Stack(
            children: [
              WebViewWidget(controller: controller),
              ValueListenableBuilder<bool>(
                valueListenable: AssistantSession.instance.isLoading,
                builder: (context, loading, _) {
                  if (!loading) return const SizedBox.shrink();
                  return const Center(child: CircularProgressIndicator());
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: AssistantSession.instance.isOnChatPage,
                builder: (context, onChat, _) {
                  if (onChat) return const SizedBox.shrink();
                  return Positioned(
                    right: 16,
                    bottom: 111,
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: FloatingActionButton(
                        heroTag: 'assistant_back_to_chat',
                        onPressed: () => AssistantSession.instance.goBackToChat(),
                        backgroundColor: const Color(0xFFf7f7f7),
                        elevation: 8,
                        highlightElevation: 12,
                        shape: const CircleBorder(),
                        child: Icon(
                          Icons.arrow_back,
                          size: 18,
                          color: AppPalette.p.primary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
