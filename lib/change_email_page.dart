import 'dart:async';

import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'settings_widgets.dart';

/// 绑定 / 更换登录邮箱：给新邮箱发验证码并验证后完成换绑。
/// 换绑前后是同一个账号，云端笔记、收藏等数据自动保留。
class ChangeEmailPage extends StatefulWidget {
  const ChangeEmailPage({super.key});

  @override
  State<ChangeEmailPage> createState() => _ChangeEmailPageState();
}

class _ChangeEmailPageState extends State<ChangeEmailPage> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  Timer? _timer;
  int _countdown = 0;
  bool _sending = false;
  bool _confirming = false;
  String _verificationId = '';
  String _currentEmail = '';

  @override
  void initState() {
    super.initState();
    _currentEmail = AuthService.instance.currentUser.value?.email ?? '';
    unawaited(_loadEmail());
  }

  Future<void> _loadEmail() async {
    final email = await AuthService.instance.getAccountEmail();
    if (!mounted || email.isEmpty) return;
    setState(() => _currentEmail = email);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  bool get _emailValid => AuthService.isValidEmail(_emailController.text.trim());

  void _startCountdown() {
    setState(() => _countdown = 60);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_countdown <= 1) {
        t.cancel();
        setState(() => _countdown = 0);
      } else {
        setState(() => _countdown--);
      }
    });
  }

  Future<void> _sendCode() async {
    if (!_emailValid) {
      _showToast('请输入正确的邮箱地址');
      return;
    }
    setState(() => _sending = true);
    try {
      final id =
          await AuthService.instance.sendEmailCode(_emailController.text.trim());
      if (!mounted) return;
      setState(() => _verificationId = id);
      _showToast('验证码已发送到邮箱，请查收（含垃圾邮件）');
      _startCountdown();
    } catch (e) {
      _showToast('发送失败：${_friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _confirm() async {
    if (!_emailValid) {
      _showToast('请输入正确的邮箱地址');
      return;
    }
    if (_verificationId.isEmpty) {
      _showToast('请先获取邮箱验证码');
      return;
    }
    if (_codeController.text.trim().length < 4) {
      _showToast('请输入邮箱验证码');
      return;
    }
    final hadEmail = _currentEmail.isNotEmpty;
    setState(() => _confirming = true);
    try {
      await AuthService.instance.bindEmail(
        email: _emailController.text.trim(),
        verificationId: _verificationId,
        code: _codeController.text,
      );
      if (!mounted) return;
      _showToast(hadEmail ? '邮箱更换成功' : '邮箱绑定成功');
      Navigator.pop(context, true);
    } catch (e) {
      _showToast('${hadEmail ? '更换' : '绑定'}失败：${_friendlyError(e)}');
      if (mounted) setState(() => _confirming = false);
    }
  }

  String _friendlyError(Object e) {
    final m = e is CloudApiException
        ? e.message
        : (e is AuthException ? e.message : e.toString());
    if (m.contains('email_taken')) return '该邮箱已被其他账号绑定';
    if (m.contains('invalid_email')) return '邮箱格式不正确';
    if (m.contains('wrong_code') || m.contains('invalid_code')) {
      return '验证码错误或已过期';
    }
    if (m.contains('invalid_verification')) return '验证码已失效，请重新获取';
    if (m.contains('email_mismatch')) return '邮箱与验证码不匹配，请重新获取';
    if (m.contains('unknown action')) return '服务端尚未更新，请稍后再试';
    if (m.contains('unauthorized')) return '登录已失效，请重新登录';
    if (m.contains('captcha') || m.contains('频繁')) return '操作太频繁，请稍后再试';
    return m;
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
                color: sPrimary,
                borderRadius: BorderRadius.circular(20),
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
    Future.delayed(const Duration(milliseconds: 2200), () {
      if (entry.mounted) entry.remove();
    });
  }

  InputDecoration _decoration(String hint) {
    return InputDecoration(
      counterText: '',
      hintText: hint,
      hintStyle: TextStyle(color: sTextHint),
      filled: true,
      fillColor: sCard,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: sGold, width: 1.2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasEmail = _currentEmail.isNotEmpty;
    return SettingsPageScaffold(
      title: hasEmail ? '更换邮箱' : '绑定邮箱',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasEmail)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: sGold.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.mark_email_read_outlined,
                        size: 18, color: sGold),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('当前绑定邮箱：$_currentEmail',
                          style: TextStyle(fontSize: 13, color: sTextSec)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            Text(hasEmail ? '新邮箱' : '邮箱',
                style: TextStyle(
                    fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              maxLength: 254,
              style: TextStyle(fontSize: 16, color: sText),
              decoration: _decoration(hasEmail ? '请输入新邮箱' : '请输入邮箱'),
            ),
            const SizedBox(height: 16),
            Text('验证码',
                style: TextStyle(
                    fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    style: TextStyle(fontSize: 16, color: sText),
                    decoration: _decoration('邮箱验证码'),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed: (_countdown > 0 || _sending) ? null : _sendCode,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: sPrimary,
                      side: BorderSide(color: sGold),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: Text(
                      _countdown > 0
                          ? '$_countdown s'
                          : (_sending ? '发送中...' : '获取验证码'),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: (_confirming || _sending) ? null : _confirm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: sGold,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: sTextHint.withValues(alpha: 0.5),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _confirming
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(hasEmail ? '确认更换' : '确认绑定',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              hasEmail
                  ? '更换邮箱不会影响现有账号，云端笔记、收藏与签到记录都会保留。'
                  : '绑定邮箱后可用邮箱验证码找回密码，也方便订阅服务核对与联系。',
              style: TextStyle(fontSize: 12.5, color: sTextSec, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}
