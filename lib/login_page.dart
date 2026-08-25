import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auth_service.dart';
import 'forgot_password_page.dart';

import 'app_palette.dart';
Color get _primary => AppPalette.p.primary;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _gold => AppPalette.p.accent;
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
  bool _showPwd = false;

  /// 登录页自身路由：成功后用 removeRoute 精确移除本页。
  /// 背景：全局未处理异常会把「错误详情」页 push 到登录页之上；
  /// 若用 Navigator.pop()，弹掉的是压在上面的错误页而非登录页，
  /// 表现为「闪现错误页 → 自动关闭 → 又回到登录页」，需再点一次登录。
  ModalRoute? _ownRoute;

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ownRoute ??= ModalRoute.of(context);
  }

  /// 只移除登录页自身，无论它上面是否压着其它路由（如错误详情页）。
  void _closeSelf() {
    final route = _ownRoute;
    if (route != null && route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
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
        _closeSelf();
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
      final registered = await AuthService.instance.loginWithAccount(
        username: _accountController.text.trim(),
        password: _passwordController.text,
      );
      if (mounted) {
        _showToast(registered ? '注册成功，请牢记账号密码' : '登录成功');
        _closeSelf();
      }
    } catch (e) {
      final msg = e is AuthException ? e.message : e.toString();
      _showToast('登录失败：${_friendlyLoginError(msg)}');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  String _friendlyLoginError(String raw) {
    if (raw.contains('account_not_found')) return '账号不存在，请先用手机号登录';
    if (raw.contains('wrong_password')) return '密码错误';
    if (raw.contains('invalid_password')) return '密码长度需为 6-64 位';
    if (raw.contains('ticket_error')) return '服务暂不可用，请稍后再试';
    if (raw.contains('username_taken')) return '该账号已被使用';
    return raw;
  }

  Future<void> _forgotPassword() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ForgotPasswordPage()),
    );
    if (ok == true && mounted) _closeSelf();
  }

  Future<void> _copyCredentials() async {
    final account = _accountController.text.trim();
    final pwd = _passwordController.text;
    if (account.isEmpty || pwd.isEmpty) {
      _showToast('请先输入账号和密码');
      return;
    }
    await Clipboard.setData(
        ClipboardData(text: '燃灯App\n账号：$account\n密码：$pwd'));
    if (mounted) _showToast('已复制，粘贴到微信收藏即可保存');
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
        title: Text('登录',
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
              '登录后即可体验完整功能',
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
                style: TextStyle(fontSize: 16, color: _text),
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
                      style: TextStyle(fontSize: 16, color: _text),
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
                style: TextStyle(fontSize: 16, color: _text),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '账号',
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
                obscureText: !_showPwd,
                maxLength: 64,
                style: TextStyle(fontSize: 16, color: _text),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '密码',
                  hintStyle: TextStyle(color: _textHint),
                  filled: true,
                  fillColor: _card,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _showPwd = !_showPwd),
                    icon: Icon(
                      _showPwd ? Icons.visibility_off : Icons.visibility,
                      color: _textHint,
                      size: 20,
                    ),
                  ),
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
                    : Text(_mode == 0 ? '登录' : '登录 / 注册',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 20),
            if (_mode == 1)
              Align(
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _copyCredentials,
                        borderRadius: BorderRadius.circular(8),
                        splashColor: Colors.white,
                        highlightColor: Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.copy,
                                  size: 16, color: Color(0xFF70867A)),
                              SizedBox(width: 4),
                              Text(
                                '复制账号密码',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFF70867A),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Text(
                      ' 到微信收藏，方便保存记忆',
                      style: TextStyle(fontSize: 12, color: _textSec),
                    ),
                  ],
                ),
              ),
            if (_mode == 1) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.center,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _forgotPassword,
                    borderRadius: BorderRadius.circular(8),
                    splashColor: Colors.white,
                    highlightColor: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text(
                        '忘记密码？',
                        style: TextStyle(
                          fontSize: 13,
                          color: _textSec,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
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
