import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'cloud_notes_service.dart';
import 'post_rich_content.dart';

/// 专门的段落查看页：显示某段经文原文，右下角带 AI 翻译按钮。
/// AI 翻译：优先读取共享缓存（其他同修/自己之前翻译过的结果），
/// 未命中时自动调用 AI 生成。
class SutraParagraphPage extends StatefulWidget {
  final String sutraTitle;
  final String paragraph;

  /// 回到该经文的讨论页（点击 $经名 时）。
  final String? filePath;

  const SutraParagraphPage({
    super.key,
    required this.sutraTitle,
    required this.paragraph,
    this.filePath,
  });

  @override
  State<SutraParagraphPage> createState() => _SutraParagraphPageState();
}

class _SutraParagraphPageState extends State<SutraParagraphPage> {
  String? _translation;
  bool _translationLoading = false;

  @override
  void initState() {
    super.initState();
    // 自动预询问是否有其他同修翻译过（不生成），命中则展示。
    _prefetchCached();
  }

  Future<void> _prefetchCached() async {
    if (widget.paragraph.isEmpty) return;
    try {
      final t = await CloudNotesService.instance
          .getCachedParagraphTranslation(widget.paragraph);
      if (!mounted || t == null) return;
      setState(() {
        _translation = t;
      });
    } catch (_) {}
  }

  /// 点击 AI 翻译：先查共享缓存，未命中自动请求 AI 生成。
  Future<void> _requestTranslate() async {
    if (_translationLoading || widget.paragraph.isEmpty) return;
    setState(() {
      _translationLoading = true;
    });
    try {
      // 先查缓存（不重复调用 API）。
      final cached =
          await CloudNotesService.instance.getCachedParagraphTranslation(widget.paragraph);
      if (cached != null) {
        if (!mounted) return;
        setState(() {
          _translation = cached;
          _translationLoading = false;
        });
        return;
      }
      // 无缓存：请求 AI 生成。
      final text = await CloudNotesService.instance
          .aiTranslate(paragraph: widget.paragraph);
      if (!mounted) return;
      setState(() {
        _translation = text;
        _translationLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _translationLoading = false;
      });
      _showToast(e is CloudApiException ? e.message : '翻译失败，请稍后重试');
    }
  }

  void _showToast(String text) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final topInset = MediaQuery.of(ctx).padding.top;
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: EdgeInsets.only(top: topInset + kToolbarHeight + 10),
            child: Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: AppPalette.p.primary,
                borderRadius: BorderRadius.circular(20),
                elevation: 0,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (entry.mounted) entry.remove();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        title: Text('段落经文',
            style: TextStyle(
                color: p.text, fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 经名：顶部只显示 $经名，无书本图标
              if (widget.sutraTitle.isNotEmpty)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    final path = widget.filePath;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SutraDiscussionPage(
                          title: widget.sutraTitle,
                          filePath: path ?? widget.sutraTitle,
                        ),
                      ),
                    );
                  },
                  child: Text(
                    '\$${widget.sutraTitle}',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: p.accent,
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              // 段原文：整段完整显示（页面可下滑），无边框框线
              Text(
                widget.paragraph,
                style: TextStyle(
                  fontSize: 16,
                  height: 1.8,
                  color: p.text,
                ),
              ),
              const SizedBox(height: 16),
              if (_translation != null)
                _buildTranslationSection()
              else
                Align(
                  alignment: Alignment.centerRight,
                  child: _translationLoading
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: p.accent),
                              ),
                              const SizedBox(width: 8),
                              Text('翻译中…',
                                  style: TextStyle(
                                      fontSize: 13, color: p.textSec)),
                            ],
                          ),
                        )
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _requestTranslate,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: p.accent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.auto_awesome,
                                    size: 15, color: p.accentDeep),
                                const SizedBox(width: 4),
                                Text(
                                  'AI翻译',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: p.accentDeep,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTranslationSection() {
    final p = AppPalette.p;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: p.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.translate, size: 18, color: p.accent),
              const SizedBox(width: 6),
              Text('白话翻译',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: p.text)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _translation ?? '',
            style: TextStyle(
              fontSize: 15,
              height: 1.8,
              color: p.text,
            ),
          ),
        ],
      ),
    );
  }
}
