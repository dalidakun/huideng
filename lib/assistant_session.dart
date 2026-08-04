import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// AI 助手展示面：底部 Tab、上滑面板、圆形展开面板。
enum AssistantSurface { tab, panel, reveal }

/// 全局唯一的 DeepSeek WebView 会话。
///
/// 整个 App 只维护一个 [WebViewController]，由 [DiscussionPage] 挂载到
/// 当前「活跃」的展示面上。切换展示面时 WebViewWidget 会从一个表面卸载、
/// 在另一个表面重新挂载，但底层原生 WebView（会话/登录态）一直存活。
/// WebView 按需创建：第一次打开任意入口时才加载 DeepSeek，启动不加载。
class AssistantSession {
  AssistantSession._();

  static final AssistantSession instance = AssistantSession._();

  static const String _kChatUrl = 'https://chat.deepseek.com/';

  WebViewController? _controller;
  bool _dblClickReloadInjected = false;

  /// 加载中状态（供各展示面显示转圈）。
  final ValueNotifier<bool> isLoading = ValueNotifier<bool>(false);

  /// 当前挂载 WebView 的展示面；null 表示没有任何入口在使用 WebView。
  final ValueNotifier<AssistantSurface?> activeSurface =
      ValueNotifier<AssistantSurface?>(null);

  bool _tabActive = false;

  /// 底部「助手」Tab 是否处于当前选中页（由 MainPage 同步）。
  void setTabActive(bool v) {
    if (_tabActive == v) return;
    _tabActive = v;
    _resolve();
  }

  /// 上滑面板/圆形面板展开时调用：把 WebView 挂到该展示面。
  void claim(AssistantSurface surface) {
    ensureCreated();
    if (activeSurface.value != surface) {
      activeSurface.value = surface;
    }
  }

  /// 面板完全收起后调用：把 WebView 让给仍在使用的入口，否则卸载。
  void release(AssistantSurface surface) {
    if (activeSurface.value != surface) return;
    activeSurface.value = _fallback();
  }

  AssistantSurface? _fallback() {
    if (assistantReveal.value) return AssistantSurface.reveal;
    if (assistantVisible.value) return AssistantSurface.panel;
    if (_tabActive) return AssistantSurface.tab;
    return null;
  }

  void _resolve() {
    final next = _fallback();
    if (next != null) ensureCreated();
    if (activeSurface.value != next) {
      activeSurface.value = next;
    }
  }

  /// 创建共享 WebView（幂等）。仅在第一个入口真正被打开时才触发加载。
  void ensureCreated() {
    if (_controller != null) return;
    if (kIsWeb) return;

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            _dblClickReloadInjected = false;
            isLoading.value = true;
          },
          onPageFinished: (String url) {
            isLoading.value = false;
            _injectDoubleClickReloadIfNeeded();
          },
          onWebResourceError: (WebResourceError error) {
            isLoading.value = false;
          },
        ),
      );

    // Android file chooser support for <input type="file"> (Gemini uploads).
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setOnShowFileSelector(_androidFilePickerHandler);
    }

    controller.loadRequest(Uri.parse(_kChatUrl));
    _controller = controller;
  }

  /// 只读访问共享控制器，绝不在此触发创建（build 期间调用会破坏按需加载）。
  WebViewController? get controller => _controller;

  void reload() {
    _controller?.reload();
  }

  Future<List<String>> _androidFilePickerHandler(
    FileSelectorParams params,
  ) async {
    FilePickerResult? result;
    final accept = params.acceptTypes.map((e) => e.toLowerCase()).toList();

    if (accept.contains('image/*') ||
        accept.contains('image/png') ||
        accept.contains('image/jpeg')) {
      result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: params.mode == FileSelectorMode.openMultiple,
      );
    } else {
      result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: params.mode == FileSelectorMode.openMultiple,
      );
    }

    if (result == null) return [];

    // IMPORTANT: return `file://` URIs (not raw file paths). Some sites (Gemini) will
    // show the local path but fail to attach if we return plain paths.
    return result.paths
        .whereType<String>()
        .map((p) => File(p).uri.toString())
        .toList();
  }

  Future<void> _injectDoubleClickReloadIfNeeded() async {
    if (_dblClickReloadInjected) return;
    _dblClickReloadInjected = true;
    // Some platform views may swallow Flutter gestures; inject dblclick inside the page too.
    try {
      await _controller?.runJavaScript('''
        (function () {
          if (window.__flutter_dblclick_reload_installed) return;
          window.__flutter_dblclick_reload_installed = true;
          document.addEventListener('dblclick', function () {
            try { window.location.reload(); } catch (e) {}
          }, true);
        })();
      ''');
    } catch (_) {
      // ignore
    }
  }
}
