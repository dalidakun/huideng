import 'dart:async';

import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'settings_widgets.dart';

/// 忘记密码：通过绑定手机号接收短信验证码，验证身份后重置登录密码。
/// 未登录也能使用；已登录时自动带出当前手机号。
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _pwdController = TextEditingController();
  final _confirmController = TextEditingController();
  Timer? _timer;
  int _countdown = 0;
  bool _sending = false;
  bool _submitting = false;
  bool _showPwd = false;
  bool _showConfirmPwd = false;

  @override
  void initState() {
    super.initState();
    _phoneController.text = _prefillPhone(
        AuthService.instance.currentUser.value?.mobilePhoneNumber);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    _pwdController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  String get _phone {
    var p = _phoneController.text.trim().replaceAll(' ', '');
    if (p.isNotEmpty && !p.startsWith('+')) p = '+86$p';
    return p;
  }

  bool get _phoneValid =>
      RegExp(r'^1[3-9]\d{9}$').hasMatch(_phoneController.text.trim());

  /// 去掉 +86 / 空格，用于预填手机号输入框。
  String _prefillPhone(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length == 13 && digits.startsWith('86')) return digits.substring(2);
    if (digits.length == 11 && digits.startsWith('1')) return digits;
    return raw;
  }

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
    if (!_phoneValid) {
      _showToast('请输入正确的手机号');
      return;
    }
    setState(() => _sending = true);
    try {
      await AuthService.instance.requestSmsCode(_phone);
      _showToast('验证码已发送');
      _startCountdown();
    } catch (e) {
      _showToast('发送失败：${e is AuthException ? e.message : e.toString()}');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _reset() async {
    final pwd = _pwdController.text;
    if (!_phoneValid) {
      _showToast('请输入正确的手机号');
      return;
    }
    if (_codeController.text.trim().length != 6) {
      _showToast('请输入 6 位验证码');
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
      await AuthService.instance.resetPassword(
        phone: _phone,
        smsCode: _codeController.text.trim(),
        newPassword: pwd,
      );
      if (!mounted) return;
      _showToast('密码重置成功，请使用新密码登录');
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
    if (m.contains('username_taken')) return '该账号名称已被其他用户使用，请换一个';
    if (m.contains('invalid_username')) return '账号名称需为 2-20 位中英文、数字或下划线';
    if (m.contains('invalid_password')) return '密码长度需为 6-64 位';
    if (m.contains('no_pending_otp')) return '请先获取验证码';
    if (m.contains('wrong_code') || m.contains('verification_code')) return '验证码错误，请重新输入';
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
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (entry.mounted) entry.remove();
    });
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
    VoidCallback? onToggleObscure,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      maxLength: 64,
      style: const TextStyle(fontSize: 16, color: sText),
      decoration: InputDecoration(
        counterText: '',
        hintText: hint,
        hintStyle: const TextStyle(color: sTextHint),
        filled: true,
        fillColor: sCard,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
          borderSide: const BorderSide(color: sGold, width: 1.2),
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
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.verified_user_outlined, size: 18, color: sGold),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('通过绑定手机号接收验证码，验证身份后即可重置登录密码。',
                        style: TextStyle(fontSize: 13, color: sTextSec, height: 1.5)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text('手机号',
                style: TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              maxLength: 11,
              style: const TextStyle(fontSize: 16, color: sText),
              decoration: InputDecoration(
                counterText: '',
                hintText: '请输入绑定手机号',
                hintStyle: const TextStyle(color: sTextHint),
                filled: true,
                fillColor: sCard,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: sGold, width: 1.2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('验证码',
                style: TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    style: const TextStyle(fontSize: 16, color: sText),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: '6 位验证码',
                      hintStyle: const TextStyle(color: sTextHint),
                      filled: true,
                      fillColor: sCard,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 16),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: sGold, width: 1.2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed: (_countdown > 0 || _sending) ? null : _sendCode,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: sPrimary,
                      side: const BorderSide(color: sGold),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
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
            const Text('新密码',
                style: TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _field(
              controller: _pwdController,
              hint: '6-64 位新密码',
              obscure: !_showPwd,
              onToggleObscure: () => setState(() => _showPwd = !_showPwd),
            ),
            const SizedBox(height: 16),
            const Text('确认新密码',
                style: TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
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
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 15, color: sTextHint),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '重置后请使用新密码通过「账号密码登录」登录，云端笔记等数据保持不变。',
                    style: TextStyle(fontSize: 12.5, color: sTextSec, height: 1.6),
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
