import 'dart:async';

import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'settings_widgets.dart';

/// 忘记密码：用注册/绑定的邮箱接收验证码，验证后重置登录密码。
/// 未登录也能使用；已登录时自动带出当前绑定邮箱。
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _pwdController = TextEditingController();
  final _confirmController = TextEditingController();
  Timer? _timer;
  int _countdown = 0;
  bool _sending = false;
  bool _submitting = false;
  bool _showPwd = false;
  bool _showConfirmPwd = false;
  String _verificationId = '';

  @override
  void initState() {
    super.initState();
    _emailController.text =
        AuthService.instance.currentUser.value?.email ?? '';
    unawaited(_prefillEmail());
  }

  /// 已登录时从账号体系补拉绑定邮箱预填（自定义登录的会话用户不带邮箱）。
  Future<void> _prefillEmail() async {
    if (_emailController.text.isNotEmpty) return;
    final email = await AuthService.instance.getAccountEmail();
    if (!mounted || email.isEmpty) return;
    if (_emailController.text.isNotEmpty) return;
    setState(() => _emailController.text = email);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    _pwdController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  bool get _emailValid =>
      AuthService.isValidEmail(_emailController.text.trim());

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

  Future<void> _reset() async {
    final pwd = _pwdController.text;
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
    if (pwd.length < 6 || pwd.length > 64) {
      _showToast('密码长度需为 6-64 位');
      return;
    }
    if (pwd != _confirmController.text) {
      _showToast('两次输入的密码不一致');
      return;
    }
    setState(() => _submitting = true);
    try {
      await AuthService.instance.resetPasswordWithEmail(
        email: _emailController.text.trim(),
        verificationId: _verificationId,
        code: _codeController.text,
        newPassword: pwd,
      );
      if (!mounted) return;
      _showToast('密码重置成功，已自动登录');
      Navigator.of(context).pop(true);
    } catch (e) {
      _showToast(_friendlyError(e));
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _friendlyError(Object e) {
    final m = e is CloudApiException
        ? e.message
        : (e is AuthException ? e.message : e.toString());
    if (m.contains('email_not_registered')) return '该邮箱尚未注册或未绑定账号';
    if (m.contains('invalid_email')) return '邮箱格式不正确';
    if (m.contains('invalid_password')) return '密码长度需为 6-64 位';
    if (m.contains('wrong_code') || m.contains('invalid_code')) {
      return '验证码错误或已过期';
    }
    if (m.contains('invalid_verification')) return '验证码已失效，请重新获取';
    if (m.contains('email_mismatch')) return '邮箱与验证码不匹配，请重新获取';
    if (m.contains('ticket_error')) return '服务暂不可用，请稍后再试';
    if (m.contains('unknown action')) return '服务端尚未更新，请稍后再试';
    if (m.contains('unauthorized')) return '请检查网络后重试';
    if (m.contains('captcha') || m.contains('频繁')) {
      return '操作太频繁，请稍后再试';
    }
    if (m.contains('请求超时')) return '网络较慢，请稍后重试';
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

  Widget _field({
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
    int maxLength = 64,
    TextInputType? keyboardType,
    VoidCallback? onToggleObscure,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      maxLength: maxLength,
      keyboardType: keyboardType,
      style: TextStyle(fontSize: 16, color: sText),
      decoration: InputDecoration(
        counterText: '',
        hintText: hint,
        hintStyle: TextStyle(color: sTextHint),
        filled: true,
        fillColor: sCard,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        suffixIcon: onToggleObscure != null
            ? IconButton(
                onPressed: onToggleObscure,
                icon: Icon(
                  obscure ? Icons.visibility_off : Icons.visibility,
                  color: sTextHint,
                  size: 20,
                ),
              )
            : null,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: sGold, width: 1.2),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: '忘记密码',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: sGold.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.mark_email_read_outlined, size: 18, color: sGold),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('通过注册/绑定的邮箱接收验证码，验证身份后即可重置登录密码。',
                        style:
                            TextStyle(fontSize: 13, color: sTextSec, height: 1.5)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text('邮箱',
                style:
                    TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _field(
              controller: _emailController,
              hint: '请输入注册或绑定的邮箱',
              maxLength: 254,
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 16),
            Text('验证码',
                style:
                    TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _field(
                    controller: _codeController,
                    hint: '邮箱验证码',
                    maxLength: 8,
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed:
                        (_countdown > 0 || _sending) ? null : _sendCode,
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
            const SizedBox(height: 16),
            Text('新密码',
                style:
                    TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _field(
              controller: _pwdController,
              hint: '6-64 位新密码',
              obscure: !_showPwd,
              onToggleObscure: () => setState(() => _showPwd = !_showPwd),
            ),
            const SizedBox(height: 16),
            Text('确认新密码',
                style:
                    TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _field(
              controller: _confirmController,
              hint: '再次输入新密码',
              obscure: !_showConfirmPwd,
              onToggleObscure: () =>
                  setState(() => _showConfirmPwd = !_showConfirmPwd),
            ),
            const SizedBox(height: 28),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: (_submitting || _sending) ? null : _reset,
                style: ElevatedButton.styleFrom(
                  backgroundColor: sGold,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: sTextHint.withValues(alpha: 0.5),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('重置密码',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 15, color: sTextHint),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '重置成功后会自动登录；云端笔记、收藏与打卡记录都保持不变。'
                    '没绑定邮箱的老账号，请先用账号密码登录，再到「账号信息」里绑定邮箱。',
                    style:
                        TextStyle(fontSize: 12.5, color: sTextSec, height: 1.6),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
