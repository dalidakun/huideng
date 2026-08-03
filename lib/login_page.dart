import 'dart:async';

import 'package:flutter/material.dart';

import 'auth_service.dart';

const Color _primary = Color(0xFF5C4033);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _gold = Color(0xFFD4A06A);

/// 手机号 + 验证码登录/注册页。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  Timer? _timer;
  int _countdown = 0;
  bool _sending = false;
  bool _loggingIn = false;

  /// 登录方式：0 = 手机号验证码，1 = 账号名称 + 密码。
  int _mode = 0;

  @override
  void dispose() {
    _timer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    _accountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String get _phone {
    var p = _phoneController.text.trim().replaceAll(' ', '');
    if (p.isNotEmpty && !p.startsWith('+')) p = '+86$p';
    return p;
  }

  bool get _phoneValid {
    final p = _phoneController.text.trim();
    return RegExp(r'^1[3-9]\d{9}$').hasMatch(p);
  }

  bool get _accountValid {
    final u = _accountController.text.trim();
    return RegExp(r'^[\u4e00-\u9fa5a-zA-Z0-9_]{2,20}$').hasMatch(u);
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

  Future<void> _login() async {
    if (!_phoneValid) {
      _showToast('请输入正确的手机号');
      return;
    }
    if (_codeController.text.trim().length != 6) {
      _showToast('请输入 6 位验证码');
      return;
    }
    setState(() => _loggingIn = true);
    try {
      await AuthService.instance
          .loginWithSmsCode(_phone, _codeController.text.trim());
      if (mounted) {
        _showToast('登录成功');
        Navigator.of(context).pop();
      }
    } catch (e) {
      final msg = e is AuthException ? e.message : e.toString();
      _showToast('登录失败：$msg');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _loginWithAccount() async {
    if (!_accountValid) {
      _showToast('账号名称需为 2-20 位中英文、数字或下划线');
      return;
    }
    if (_passwordController.text.isEmpty) {
      _showToast('请输入密码');
      return;
    }
    setState(() => _loggingIn = true);
    try {
      await AuthService.instance.loginWithAccount(
        username: _accountController.text.trim(),
        password: _passwordController.text,
      );
      if (mounted) {
        _showToast('登录成功');
        Navigator.of(context).pop();
      }
    } catch (e) {
      final msg = e is AuthException ? e.message : e.toString();
      _showToast('登录失败：${_friendlyLoginError(msg)}');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  String _friendlyLoginError(String raw) {
    if (raw.contains('account_not_found')) return '账号名称不存在，请先设置';
    if (raw.contains('wrong_password')) return '密码错误';
    if (raw.contains('ticket_error')) return '服务暂不可用，请稍后再试';
    if (raw.contains('username_taken')) return '该账号名称已被使用';
    return raw;
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
                color: _primary,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: const Text('登录',
            style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            Icon(Icons.auto_stories_rounded, size: 56, color: _gold),
            const SizedBox(height: 12),
            Text(
              '登录后即可分享笔记到菩提空间',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14, color: _textSec, height: 1.6),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(child: _modeBtn(0, '手机号登录')),
                  Expanded(child: _modeBtn(1, '账号密码登录')),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (_mode == 0) ...[
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                maxLength: 11,
                style: const TextStyle(fontSize: 16, color: _text),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '请输入手机号',
                  hintStyle: TextStyle(color: _textHint),
                  filled: true,
                  fillColor: _card,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: _gold, width: 1.2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _codeController,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      style: const TextStyle(fontSize: 16, color: _text),
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: '6 位验证码',
                        hintStyle: TextStyle(color: _textHint),
                        filled: true,
                        fillColor: _card,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 16),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: _gold, width: 1.2),
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
                        foregroundColor: _primary,
                        side: BorderSide(color: _gold),
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
            ] else ...[
              TextField(
                controller: _accountController,
                maxLength: 20,
                style: const TextStyle(fontSize: 16, color: _text),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '账号名称',
                  hintStyle: TextStyle(color: _textHint),
                  filled: true,
                  fillColor: _card,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: _gold, width: 1.2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: true,
                maxLength: 64,
                style: const TextStyle(fontSize: 16, color: _text),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '密码',
                  hintStyle: TextStyle(color: _textHint),
                  filled: true,
                  fillColor: _card,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: _gold, width: 1.2),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 28),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: (_loggingIn || _sending)
                    ? null
                    : (_mode == 0 ? _login : _loginWithAccount),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _textHint.withValues(alpha: 0.5),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _loggingIn
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(_mode == 0 ? '登录 / 注册' : '登录',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _mode == 0
                  ? '未注册的手机号验证通过后将自动注册'
                  : '尚未设置账号？登录后进入「我的-设置-账号名称与密码」进行设置',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: _textHint),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeBtn(int mode, String label) {
    final active = _mode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _mode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? _gold : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : _textSec,
          ),
        ),
      ),
    );
  }
}
