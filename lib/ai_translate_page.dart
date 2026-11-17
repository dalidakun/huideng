import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'certification_page.dart';
import 'cloud_notes_service.dart';

/// AI 白话翻译底部弹层：展示某段经文的 AI 白话译文。
///
/// 与「段落感想」弹层交互一致：
/// - 从底部上滑出现，顶部圆角 + 阴影；
/// - 顶部标题栏（含拖拽条）可向下拖动关闭，点击标题栏也可关闭；
/// - 作为路由压栈，侧滑 / 系统返回可直接回到阅读页；
/// - 路由透明白色，上方经文仍清晰可见。
class AiTranslatePage extends StatefulWidget {
  final String paragraph;

  /// 译文字号 / 行距：跟随阅读页正文设置。
  final double fontSize;
  final double lineHeight;

  /// 深色背景（阅读背景为索引4深色时），控制面板明暗配色。
  final bool isDark;

  const AiTranslatePage({
    super.key,
    required this.paragraph,
    this.fontSize = 16,
    this.lineHeight = 1.8,
    this.isDark = false,
  });

  /// 打开翻译弹层：下滑渐显过渡、透明白色遮罩、顶部停在标题栏下方。
  static Future<void> open(
    BuildContext context, {
    required String paragraph,
    double fontSize = 16,
    double lineHeight = 1.8,
    bool isDark = false,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        barrierDismissible: true,
        pageBuilder: (_, __, ___) => AiTranslatePage(
          paragraph: paragraph,
          fontSize: fontSize,
          lineHeight: lineHeight,
          isDark: isDark,
        ),
        transitionsBuilder: (_, anim, __, child) {
          final topOffset =
              MediaQuery.of(context).padding.top + kToolbarHeight * 2;
          final full = MediaQuery.of(context).size.height;
          return Stack(
            children: [
              AnimatedBuilder(
                animation: anim,
                builder: (context, _) {
                  final t = Curves.easeOutCubic.transform(anim.value);
                  final top = topOffset + (full - topOffset) * (1 - t);
                  return Positioned(
                    left: 0,
                    right: 0,
                    top: top,
                    bottom: 0,
                    child: DecoratedBox(
                      // 顶部阴影与旧 AI 面板一致：黑色 18% 透明度、上抛 4px。
                      decoration: const BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                            top: Radius.circular(18)),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x2E000000),
                            blurRadius: 16,
                            offset: Offset(0, -4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(18)),
                        child: child,
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        },
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
      ),
    );
  }

  @override
  State<AiTranslatePage> createState() => _AiTranslatePageState();
}

class _AiTranslatePageState extends State<AiTranslatePage> {
  bool _loading = true;
  String? _translation;
  String? _error;
  bool _quotaExhausted = false;

  /// 额度用完弹窗只弹一次；用户点「重试」时重置。
  bool _quotaDialogShown = false;
  bool _diagLoading = false;
  String? _diagText;

  /// 下拉关闭：手指向下拖动的距离。
  double _dragY = 0;

  @override
  void initState() {
    super.initState();
    _translate();
  }

  /// 请求白话翻译（面板打开后 / 重试时调用）。
  /// 本地缓存 → 云端（服务端先按“用户 + 段落”核销额度，再查共享缓存/生成）。
  Future<void> _translate() async {
    setState(() {
      _loading = true;
      _error = null;
      _quotaExhausted = false;
      _quotaDialogShown = false;
    });
    try {
      // 本地缓存键带译文版本号：提示词升级后（云端 AI_TRANSLATE_PROMPT_VERSION
      // 同步为 v2）旧的直译结果自动失效，重新取新版译文。
      final cacheKey = 'ai_translate_v2_${_hashParagraph(widget.paragraph)}';
      final prefs = await SharedPreferences.getInstance();

      // 1. 优先读本地缓存（最快）。同一段重复打开不重复扣额度。
      // 含替换字符（历史解码 bug 产生的问号）的缓存视为脏数据，跳过重新取。
      final local = prefs.getString(cacheKey);
      if (local != null && local.isNotEmpty && !local.contains('\uFFFD')) {
        setState(() {
          _translation = _stripAnnotation(local);
          _loading = false;
        });
        return;
      }

      // 2. 云端：服务端核销“该用户首次打开这一段”的额度，并返回共享缓存或新译文。
      final res = await CloudNotesService.instance.aiTranslateWithQuota(
        paragraph: widget.paragraph,
      );
      if (!mounted) return;
      final text = res['text'] as String;
      // 脏结果不落本地缓存，避免问号被反复展示。
      if (!text.contains('\uFFFD')) await prefs.setString(cacheKey, text);
      setState(() {
        _translation = _stripAnnotation(text);
        _loading = false;
        _quotaExhausted = false;
      });
    } catch (e) {
      if (!mounted) return;
      final msg = e is CloudApiException ? e.message : '翻译失败，请稍后重试';
      final banned = msg.contains('feature_banned');
      final exhausted = msg.contains('ai_quota_exhausted') || msg.contains('额度');
      setState(() {
        _loading = false;
        _quotaExhausted = exhausted && !banned;
        _error = banned
            ? '当前账号已被限制使用 AI 翻译，可在「订阅服务」页提交申诉。'
            : exhausted
                ? '免费翻译额度已用完。开通订阅服务后，可无限次使用 AI 翻译。'
                : msg;
      });
      // 额度用完不再在顶部显示剩余次数，直接弹窗引导开通订阅。
      if (exhausted && !banned) unawaited(_showQuotaDialog());
    }
  }

  /// 免费额度用完：弹窗提示开通订阅服务（AI 无限翻译 + 附赠徽标）。
  Future<void> _showQuotaDialog() async {
    if (!mounted || _quotaDialogShown) return;
    _quotaDialogShown = true;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppPalette.p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '免费翻译额度已用完',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppPalette.p.text,
          ),
        ),
        content: Text(
          '开通订阅服务后，可无限次使用 AI 白话翻译，全经藏段落通用，并附赠支持者徽标。',
          style: TextStyle(fontSize: 14, height: 1.6, color: AppPalette.p.textSec),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('稍后再说', style: TextStyle(color: AppPalette.p.textSec)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.p.accent,
              foregroundColor: Colors.white,
            ),
            child: const Text('去开通'),
          ),
        ],
      ),
    );
    if (go == true && mounted) await _openBadge();
  }

  /// 段落文本哈希，用作本地缓存键（避免原文过长）。
  String _hashParagraph(String text) {
    var hash = 0;
    for (var i = 0; i < text.length; i++) {
      hash = ((hash << 5) - hash + text.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  /// 剔除译文末尾的「注：…」等补充说明，只保留译文正文。
  /// （模型在某些旧缓存 / 旧版本可能仍会输出这类标注。）
  String _stripAnnotation(String text) {
    if (text.isEmpty) return text;
    // 匹配：行首或句末换行后出现的 注/说明/备注/注释 标注（可带【】、（）等装饰）。
    final RegExp noteRe = RegExp(
      r'(?:\r?\n|。|；)[　\s]*(?:【|\[|（|\(|〔|『)?(?:注\s*[:：]?\s*\d*|注\s*释[:：]|说明[:：]|備注[:：]|备注[:：]|注释[:：])',
    );
    final match = noteRe.firstMatch(text);
    if (match != null) {
      return text.substring(0, match.start).trim();
    }
    return text.trim();
  }

  /// 一键网络自诊断：检测云函数到大模型的连通性，把根因显示在面板里。
  Future<void> _runDiag() async {
    if (_diagLoading) return;
    setState(() {
      _diagLoading = true;
      _diagText = null;
    });
    try {
      final res = await CloudNotesService.instance.aiNetProbe();
      if (!mounted) return;
      final b = StringBuffer();
      b.writeln('密钥已配置：${res['keyConfigured'] == true ? '是' : '否'}');
      b.writeln('域名解析(DNS)：${res['dns'] ?? '未测'} ${res['ip'] ?? ''}');
      b.writeln('TCP连接：${res['tcp'] ?? '未测'}${res['tcp'] == 'fail' ? ' ${res['tcpError'] ?? ''}' : ''}');
      b.writeln('TLS握手：${res['tls'] ?? '未测'}${res['tls'] == 'fail' ? ' ${res['tlsError'] ?? ''}' : ''}');
      b.writeln('结论：${res['conclusion'] ?? '未知'}');
      setState(() {
        _diagText = b.toString();
        _diagLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _diagText = '诊断失败：${e is CloudApiException ? e.message : e}';
        _diagLoading = false;
      });
    }
  }

  void _close() {
    Navigator.of(context).pop();
  }

  Future<void> _openBadge() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CertificationPage()),
    );
    if (!mounted || !_quotaExhausted) return;
    // 只有订阅真正生效（无限额度）才自动重译；否则保留错误页，等用户自己点重试，
    // 避免从订阅页返回后立刻又弹一次额度用完的窗口。
    try {
      final quota = await CloudNotesService.instance.getMyAiQuota();
      if (quota['unlimited'] == true && mounted) await _translate();
    } catch (_) {}
  }

  void _onVerticalDragStart(DragStartDetails d) {
    _dragY = 0;
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    // 仅向下拖动生效（向上不跟随），避免与列表滚动冲突。
    final next = _dragY + d.delta.dy;
    setState(() => _dragY = next < 0 ? 0 : next);
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    if (_dragY > 120 || velocity > 600) {
      _close();
      return;
    }
    setState(() => _dragY = 0);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final isDark = widget.isDark;
    final textColor = isDark ? Colors.white : const Color(0xFF212121);
    final subColor =
        isDark ? Colors.white.withOpacity(0.6) : const Color(0xFF999999);
    final headerHeight = kToolbarHeight * 0.9;

    Widget body;
    if (_loading) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(strokeWidth: 3),
              const SizedBox(height: 12),
              Text('正在把这段翻译成白话文…',
                  style: TextStyle(fontSize: 14, color: subColor)),
            ],
          ),
        ),
      );
    } else if (_error != null) {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 28),
            const SizedBox(height: 8),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 15),
            ),
            if (_quotaExhausted) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _openBadge,
                style: FilledButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: Colors.white,
                ),
                child: const Text('开通订阅服务'),
              ),
            ],
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _translate,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _runDiag,
              icon: _diagLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check, size: 18),
              label: Text(_diagLoading ? '诊断中…' : '一键诊断'),
              style: TextButton.styleFrom(foregroundColor: p.accent),
            ),
            if (_diagText != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: textColor.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _diagText!,
                  style: TextStyle(fontSize: 12, height: 1.5, color: subColor),
                ),
              ),
            ],
          ],
        ),
      );
    } else {
      body = SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SelectableText(
          _translation ?? '',
          style: TextStyle(
            color: textColor,
            fontSize: widget.fontSize,
            height: widget.lineHeight,
            letterSpacing: 0.5,
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: _onVerticalDragStart,
      onVerticalDragUpdate: _onVerticalDragUpdate,
      onVerticalDragEnd: _onVerticalDragEnd,
      onVerticalDragCancel: () => setState(() => _dragY = 0),
      child: Transform.translate(
        offset: Offset(0, _dragY),
        child: Material(
          color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              // 顶部标题栏：拖拽条 + 「白话翻译」 + 右上角关闭。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: SizedBox(
                  height: headerHeight,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withOpacity(0.2)
                              : p.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '白话翻译',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: textColor,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Divider(height: 1, thickness: 1, color: p.border),
              Expanded(child: SafeArea(top: false, child: body)),
            ],
          ),
        ),
      ),
    );
  }
}