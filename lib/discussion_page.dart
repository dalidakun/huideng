import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

class DiscussionPage extends StatefulWidget {
  const DiscussionPage({super.key});

  @override
  State<DiscussionPage> createState() => _DiscussionPageState();
}

class _DiscussionPageState extends State<DiscussionPage> {
  static const String _kChatUrl = 'https://chat.deepseek.com/';

  late final WebViewController _controller;
  bool _isLoading = true;
  bool _dblClickReloadInjected = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return;

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            setState(() {
              _isLoading = true;
              _dblClickReloadInjected = false;
            });
          },
          onPageFinished: (String url) {
            setState(() {
              _isLoading = false;
            });
            _injectDoubleClickReloadIfNeeded();
          },
          onWebResourceError: (WebResourceError error) {
            setState(() {
              _isLoading = false;
            });
          },
        ),
      );

    // Android file chooser support for <input type="file"> (Gemini uploads).
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setOnShowFileSelector(_androidFilePickerHandler);
    }

    _controller.loadRequest(Uri.parse(_kChatUrl));
  }

  Future<List<String>> _androidFilePickerHandler(FileSelectorParams params) async {
    FilePickerResult? result;
    final accept = params.acceptTypes.map((e) => e.toLowerCase()).toList();

    if (accept.contains('image/*') || accept.contains('image/png') || accept.contains('image/jpeg')) {
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
      await _controller.runJavaScript('''
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

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFf0f3f8),
      child: Stack(
        children: [
          kIsWeb
              ? const Center(
                  child: Text(
                    'WebView 功能暂不支持 Web 平台\n请在移动设备上查看',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                )
              : GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onDoubleTap: () {
                    _controller.reload();
                  },
                  child: WebViewWidget(controller: _controller),
                ),
          if (_isLoading && !kIsWeb) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
