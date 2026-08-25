import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'app_palette.dart';

class ToolPage extends StatefulWidget {
  const ToolPage({super.key});

  @override
  State<ToolPage> createState() => _ToolPageState();
}

class _ToolPageState extends State<ToolPage> {
  late final WebViewController _controller;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return;

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FlutterTool',
        onMessageReceived: (JavaScriptMessage message) async {
          await _handleJsMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            setState(() {
              _isLoading = true;
            });
          },
          onPageFinished: (String url) {
            setState(() {
              _isLoading = false;
            });
          },
          onWebResourceError: (WebResourceError error) {
            setState(() {
              _isLoading = false;
            });
          },
        ),
      );

    _loadHtmlContent();
  }

  Future<void> _handleJsMessage(String raw) async {
    Map<String, dynamic>? msg;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        msg = decoded;
      }
    } catch (_) {
      // ignore
    }
    if (msg == null) return;

    final action = msg['action']?.toString();
    if (action != 'downloadTxt') return;

    final text = (msg['text'] ?? '').toString().trim();
    if (text.isEmpty) return;

    await _saveTxt(text);
  }

  String _suggestFilenameFromText(String text) {
    final prefixRaw = text.length <= 10 ? text : text.substring(0, 10);
    final prefix = prefixRaw.replaceAll(RegExp(r'[^a-zA-Z0-9\u4e00-\u9fa5]'), '_');
    final safePrefix = prefix.isEmpty ? 'clipboard' : prefix;
    return '$safePrefix.txt';
  }

  Future<String?> _getTextFromWebView() async {
    try {
      final result = await _controller.runJavaScriptReturningResult(
        "(() => { const el = document.getElementById('textcontent'); return el ? el.value : ''; })()",
      );

      // webview_flutter on Android often returns a JSON-encoded string.
      if (result is String) {
        // try decode JSON string to unescape (e.g. "\"abc\"")
        try {
          final decoded = jsonDecode(result);
          if (decoded is String) return decoded;
        } catch (_) {
          // ignore
        }
        return result;
      }
      return result.toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveTxt(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final filename = _suggestFilenameFromText(trimmed);

    // UTF-8 BOM 防乱码（与原 HTML 行为一致）
    final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(trimmed)];

    // 优先：用原生保存对话框，并由插件直接写入用户选择的位置（支持 Android 的 content://）。
    try {
      final savedPath = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          data: Uint8List.fromList(bytes),
          fileName: filename,
          mimeTypesFilter: const ['text/plain'],
        ),
      );

      if (savedPath != null && savedPath.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已保存：$savedPath'), duration: const Duration(seconds: 3)),
          );
        }
        return;
      }
    } catch (_) {
      // ignore and fallback
    }

    // 兜底1：尝试 file_picker（部分设备上可返回可写的真实路径）
    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '保存TXT',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['txt'],
      );
      if (savePath != null && savePath.isNotEmpty && !savePath.startsWith('content:')) {
        final file = File(savePath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已保存：$savePath'), duration: const Duration(seconds: 3)),
          );
        }
        return;
      }
    } catch (_) {
      // ignore
    }

    // 兜底2：保存到应用目录（至少保证“按钮有用”），并提示路径。
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$filename');
      await file.writeAsBytes(bytes, flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存到应用目录：${file.path}'), duration: const Duration(seconds: 4)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e'), duration: const Duration(seconds: 4)),
        );
      }
    }
  }

  Future<void> _loadHtmlContent() async {
    try {
      // 加载HTML工具页面
      String htmlContent;
      try {
        // 用 load(字节) + utf8.decode 更稳：避免某些情况下 loadString 直接解码失败
        //（比如文件不是严格 UTF-8 / 含少量非法字节）。
        final data = await rootBundle.load('assets/tool.html');
        htmlContent = utf8.decode(data.buffer.asUint8List(), allowMalformed: true);
      } catch (loadError) {
        // 进一步判断：是否根本没被打包进 AssetManifest（常见于新增/改 pubspec 后只 hot reload）。
        bool inManifest = false;
        try {
          final manifest = await rootBundle.loadString('AssetManifest.json');
          inManifest = manifest.contains('"assets/tool.html"');
        } catch (_) {
          // ignore: manifest 也可能读取失败，保持默认 false
        }

        if (mounted) {
          final hint = inManifest
              ? '它看起来已被打包，但读取/解码失败：请检查 tool.html 是否为 UTF-8 编码后重试。'
              : '它看起来没有被打包：请确认 pubspec.yaml 的 assets 配置后，执行 flutter pub get，做一次 Hot Restart（必要时 flutter clean 后重跑）。';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('无法读取 assets/tool.html：$loadError\n$hint'),
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      }

      // 使用 data URI 方式加载HTML内容
      // 先尝试直接使用 data URI（URL编码）
      try {
        final encodedContent = Uri.encodeComponent(htmlContent);
        final dataUri = 'data:text/html;charset=utf-8,$encodedContent';
        await _controller.loadRequest(Uri.parse(dataUri));
      } catch (uriError) {
        // 如果直接编码失败，尝试使用 base64
        try {
          final base64Content = base64Encode(utf8.encode(htmlContent));
          final dataUri = 'data:text/html;charset=utf-8;base64,$base64Content';
          await _controller.loadRequest(Uri.parse(dataUri));
        } catch (base64Error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('加载HTML失败: $base64Error'),
                duration: const Duration(seconds: 4),
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载工具页面失败: $e'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: AppPalette.p.accentDeep,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('导出 TXT', style: TextStyle(color: Colors.white, fontSize: 16)),
        actions: [
          Padding(
            // 让图标更贴近右侧边缘，整体更利落
            padding: const EdgeInsets.only(right: 4),
            child: IconButton(
              tooltip: '保存为…',
              icon: const Icon(Icons.save_alt, color: Colors.white),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              onPressed: kIsWeb
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final text = await _getTextFromWebView();
                      if (!context.mounted) return;
                      if (text == null || text.trim().isEmpty) {
                        messenger.showSnackBar(
                          const SnackBar(content: Text('没有可导出的内容'), duration: Duration(seconds: 2)),
                        );
                        return;
                      }
                      await _saveTxt(text);
                    },
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: kIsWeb
            ? const Center(
                child: Text(
                  'WebView 功能暂不支持 Web 平台\n请在移动设备上查看',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                ),
              )
            : Stack(
                children: [
                  WebViewWidget(controller: _controller),
                  if (_isLoading)
                    const Center(
                      child: CircularProgressIndicator(),
                    ),
                ],
              ),
      ),
    );
  }
}

