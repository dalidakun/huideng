import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_palette.dart';

/// App 内文章阅读页：用 WebView 打开微信 / 知乎 / 任意网页链接。
///
/// - 只保留 http/https 在 App 内打开，`weixin://` 等外部 scheme 交给系统；
/// - 顶部有返回、标题、用浏览器打开；
/// - 主文档加载失败时给「重试 / 浏览器打开」。
class ArticleWebPage extends StatefulWidget {
  final String title;
  final String url;

  const ArticleWebPage({super.key, required this.title, required this.url});

  @override
  State<ArticleWebPage> createState() => _ArticleWebPageState();
}

class _ArticleWebPageState extends State<ArticleWebPage> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _failed = false;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _failed = false;
            });
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? true) {
              if (mounted) {
                setState(() {
                  _loading = false;
                  _failed = true;
                });
              }
            }
          },
          onNavigationRequest: (request) {
            final url = request.url;
            if (url.startsWith('http://') || url.startsWith('https://')) {
              return NavigationDecision.navigate;
            }
            // weixin:// 等外部 scheme：交给系统，避免 WebView 报错。
            unawaited(_openExternal(url));
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  Future<void> _openExternal(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: p.bg,
                border: Border(
                    bottom: BorderSide(color: p.borderSoft, width: 0.8)),
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(Icons.arrow_back_ios_new,
                        size: 18, color: p.text),
                    tooltip: '返回',
                  ),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _openExternal(widget.url),
                    icon: Icon(Icons.open_in_new, size: 18, color: p.textSec),
                    tooltip: '用浏览器打开',
                  ),
                ],
              ),
            ),
            if (_loading)
              LinearProgressIndicator(
                value: _progress <= 0 ? null : _progress / 100,
                minHeight: 2,
                backgroundColor: p.borderSoft,
                color: p.accent,
              ),
            Expanded(
              child: _failed
                  ? _buildFailed(p)
                  : WebViewWidget(controller: _controller),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFailed(PaletteData p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.article_outlined, size: 38, color: p.textHint),
            const SizedBox(height: 14),
            Text('这篇文章在 App 内打不开',
                style: TextStyle(fontSize: 14, color: p.text)),
            const SizedBox(height: 6),
            Text('可能是网站限制了内置浏览器，用系统浏览器通常可以打开。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: p.textSec, height: 1.6)),
            const SizedBox(height: 18),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _button(p, '重试', () {
                  setState(() {
                    _failed = false;
                    _loading = true;
                  });
                  unawaited(_controller.reload());
                }),
                const SizedBox(width: 10),
                _button(p, '用浏览器打开', () => _openExternal(widget.url)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _button(PaletteData p, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: p.tintBg,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(label, style: TextStyle(fontSize: 12.5, color: p.text)),
      ),
    );
  }
}
