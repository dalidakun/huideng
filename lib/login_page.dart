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

/// 登录 / 注册页。
///
/// 已移除手机号 + 短信验证码方式，改为：
///  - 登录：账号名称 + 密码；
///  - 注册：① 账号 + 密码（自选账号名，邮箱验证）② 邮箱注册（账号由服务端自动生成）；
///  - 忘记密码：邮箱验证码找回（见 [ForgotPasswordPage]）。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  // 登录
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();

  // 注册（账号密码）
  final _regAccountController = TextEditingController();
  final _regEmailController = TextEditingController();
  final _regCodeController = TextEditingController();
  final _regPasswordController = TextEditingController();
  final _regPassword2Controller = TextEditingController();

  // 注册（邮箱自动生成账号）
  final _emailRegEmailController = TextEditingController();
  final _emailRegCodeController = TextEditingController();
  final _emailRegPasswordController = TextEditingController();
  final _emailRegPassword2Controller = TextEditingController();

  Timer? _regTimer;
  Timer? _emailTimer;
  int _regCountdown = 0;
  int _emailCountdown = 0;
  bool _regSending = false;
  bool _emailSending = false;
  bool _busy = false;
  bool _showPwd = false;
  bool _showRegPwd = false;
  bool _showEmailRegPwd = false;

  /// 邮箱验证码发送后返回的 verificationId，注册时回传云端复核。
  String _regVerificationId = '';
  String _emailVerificationId = '';

  /// 登录页自身路由：成功后用 removeRoute 精确移除本页。
  ModalRoute? _ownRoute;

  /// 0 = 登录，1 = 注册。
  int _mode = 0;

  /// 注册方式：0 = 账号 + 密码，1 = 邮箱注册（账号自动生成）。
  int _registerMode = 0;

  @override
  void dispose() {
    _regTimer?.cancel();
    _emailTimer?.cancel();
    _accountController.dispose();
    _passwordController.dispose();
    _regAccountController.dispose();
    _regEmailController.dispose();
    _regCodeController.dispose();
    _regPasswordController.dispose();
    _regPassword2Controller.dispose();
    _emailRegEmailController.dispose();
    _emailRegCodeController.dispose();
    _emailRegPasswordController.dispose();
    _emailRegPassword2Controller.dispose();
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

  bool get _accountValid =>
      RegExp(r'^[\u4e00-\u9fa5a-zA-Z0-9_]{2,20}$')
          .hasMatch(_regAccountController.text.trim());

  /// 登录支持账号名或注册邮箱（后端两边共用一套账号）。
  bool _loginAccountValid(String value) {
    final v = value.trim();
    if (AuthService.isValidEmail(v)) return true;
    return RegExp(r'^[\u4e00-\u9fa5a-zA-Z0-9_]{2,20}$').hasMatch(v);
  }

  bool _emailValid(String value) => AuthService.isValidEmail(value.trim());

  void _startCountdown({required bool emailMode}) {
    if (emailMode) {
      setState(() => _emailCountdown = 60);
      _emailTimer?.cancel();
      _emailTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        if (_emailCountdown <= 1) {
          t.cancel();
          setState(() => _emailCountdown = 0);
        } else {
          setState(() => _emailCountdown--);
        }
      });
    } else {
      setState(() => _regCountdown = 60);
      _regTimer?.cancel();
      _regTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        if (_regCountdown <= 1) {
          t.cancel();
          setState(() => _regCountdown = 0);
        } else {
          setState(() => _regCountdown--);
        }
      });
    }
  }

  Future<void> _sendCode({required bool emailMode}) async {
    final email = (emailMode
            ? _emailRegEmailController.text
            : _regEmailController.text)
        .trim();
    if (!_emailValid(email)) {
      _showToast('请输入正确的邮箱地址');
      return;
    }
    setState(() {
      if (emailMode) {
        _emailSending = true;
      } else {
        _regSending = true;
      }
    });
    try {
      final id = await AuthService.instance.sendEmailCode(email);
      if (!mounted) return;
      setState(() {
        if (emailMode) {
          _emailVerificationId = id;
        } else {
          _regVerificationId = id;
        }
      });
      _showToast('验证码已发送到邮箱，请查收（含垃圾邮件）');
      _startCountdown(emailMode: emailMode);
    } catch (e) {
      _showToast('发送失败：${_friendlyError(e)}');
    } finally {
      if (mounted) {
        setState(() {
          if (emailMode) {
            _emailSending = false;
          } else {
            _regSending = false;
          }
        });
      }
    }
  }

  Future<void> _loginWithAccount() async {
    final account = _accountController.text.trim();
    if (!_loginAccountValid(account)) {
      _showToast('请输入账号或注册邮箱');
      return;
    }
    if (_passwordController.text.isEmpty) {
      _showToast('请输入密码');
      return;
    }
    setState(() => _busy = true);
    try {
      final registered = await AuthService.instance.loginWithAccount(
        username: account,
        password: _passwordController.text,
      );
      if (mounted) {
        _showToast(registered ? '登录成功，已为老账号设置密码' : '登录成功');
        _closeSelf();
      }
    } catch (e) {
      _showToast('登录失败：${_friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _registerWithAccount() async {
    if (!_accountValid) {
      _showToast('账号名称需为 2-20 位中英文、数字或下划线');
      return;
    }
    final email = _regEmailController.text.trim();
    if (!_emailValid(email)) {
      _showToast('请输入正确的邮箱地址（用于找回密码）');
      return;
    }
    if (_regVerificationId.isEmpty) {
      _showToast('请先获取邮箱验证码');
      return;
    }
    if (_regCodeController.text.trim().length < 4) {
      _showToast('请输入邮箱验证码');
      return;
    }
    if (_regPasswordController.text.length < 6) {
      _showToast('密码至少 6 位');
      return;
    }
    if (_regPasswordController.text != _regPassword2Controller.text) {
      _showToast('两次输入的密码不一致');
      return;
    }
    setState(() => _busy = true);
    try {
      final account = await AuthService.instance.registerWithAccount(
        email: email,
        verificationId: _regVerificationId,
        code: _regCodeController.text,
        password: _regPasswordController.text,
        username: _regAccountController.text.trim(),
      );
      if (!mounted) return;
      await _showAccountCreated(account);
      if (mounted) _closeSelf();
    } catch (e) {
      _showToast('注册失败：${_friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _registerWithEmail() async {
    final email = _emailRegEmailController.text.trim();
    if (!_emailValid(email)) {
      _showToast('请输入正确的邮箱地址');
      return;
    }
    if (_emailVerificationId.isEmpty) {
      _showToast('请先获取邮箱验证码');
      return;
    }
    if (_emailRegCodeController.text.trim().length < 4) {
      _showToast('请输入邮箱验证码');
      return;
    }
    if (_emailRegPasswordController.text.length < 6) {
      _showToast('密码至少 6 位');
      return;
    }
    if (_emailRegPasswordController.text != _emailRegPassword2Controller.text) {
      _showToast('两次输入的密码不一致');
      return;
    }
    setState(() => _busy = true);
    try {
      final account = await AuthService.instance.registerWithAccount(
        email: email,
        verificationId: _emailVerificationId,
        code: _emailRegCodeController.text,
        password: _emailRegPasswordController.text,
        autoUsername: true,
      );
      if (!mounted) return;
      await _showAccountCreated(account);
      if (mounted) _closeSelf();
    } catch (e) {
      _showToast('注册失败：${_friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 注册成功：展示自动生成的账号名（邮箱注册）或注册结果，方便用户记录。
  Future<void> _showAccountCreated(RegisteredAccount account) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('注册成功',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('已自动登录。请记住下面的账号；密码为你刚设置的密码，忘记时可用绑定邮箱找回。',
                style: TextStyle(fontSize: 13, color: _textSec, height: 1.5)),
            const SizedBox(height: 14),
            _credentialRow('账号', account.username),
            const SizedBox(height: 8),
            _credentialRow('邮箱', account.email),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(
                  text: '燃灯App\n账号：${account.username}\n邮箱：${account.email}'));
              if (ctx.mounted) Navigator.pop(ctx);
              _showToast('已复制账号，可粘贴到微信收藏保存');
            },
            child: Text('复制并关闭',
                style: TextStyle(color: _gold, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _credentialRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 42,
          child: Text(label,
              style: TextStyle(fontSize: 13, color: _textHint, height: 1.6)),
        ),
        Expanded(
          child: SelectableText(value,
              style: TextStyle(
                  fontSize: 14, color: _text, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  String _friendlyError(Object e) {
    final raw = e is AuthException
        ? e.message
        : (e is Exception ? e.toString() : e.toString());
    final m = raw.replaceFirst('Exception: ', '');
    if (m.contains('account_not_found')) return '账号或邮箱不存在，请先注册';
    if (m.contains('wrong_password')) return '密码错误';
    if (m.contains('invalid_password')) return '密码长度需为 6-64 位';
    if (m.contains('invalid_username')) return '账号名称需为 2-20 位中英文、数字或下划线';
    if (m.contains('invalid_email')) return '邮箱格式不正确';
    if (m.contains('email_taken')) return '该邮箱已注册，请直接登录或找回密码';
    if (m.contains('email_not_registered')) return '该邮箱尚未注册，请先注册';
    if (m.contains('email_mismatch')) return '邮箱与验证码不匹配，请重新获取验证码';
    if (m.contains('wrong_code') || m.contains('invalid_code')) {
      return '验证码错误或已过期';
    }
    if (m.contains('invalid_verification')) return '验证码已失效，请重新获取';
    if (m.contains('username_taken')) return '该账号已被使用，请换一个';
    if (m.contains('ticket_error')) return '服务暂不可用，请稍后再试';
    if (m.contains('unknown action')) return '服务端尚未更新，请稍后再试';
    if (m.contains('unauthorized')) return '请检查网络后重试';
    if (m.contains('captcha') || m.contains('频繁')) {
      return '操作太频繁，请稍后再试';
    }
    if (m.contains('请求超时')) return '网络较慢，请稍后重试';
    return m;
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
    Future.delayed(const Duration(milliseconds: 2200), () {
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
        title: Text(_mode == 0 ? '登录' : '注册',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Icon(Icons.auto_stories_rounded, size: 56, color: _gold),
            const SizedBox(height: 12),
            Text(
              _mode == 0 ? '登录后即可体验完整功能' : '注册后即可同步笔记、收藏与打卡',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: _textSec, height: 1.6),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(child: _modeBtn(0, '登录')),
                  Expanded(child: _modeBtn(1, '注册')),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (_mode == 0) ..._buildLoginFields() else ..._buildRegisterFields(),
            const SizedBox(height: 26),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _busy
                    ? null
                    : (_mode == 0
                        ? _loginWithAccount
                        : (_registerMode == 0
                            ? _registerWithAccount
                            : _registerWithEmail)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _textHint.withValues(alpha: 0.5),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(_mode == 0 ? '登录' : '注册',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 18),
            if (_mode == 0) ...[
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
                        '忘记密码？通过邮箱找回',
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
            ] else
              Text(
                '邮箱仅用于接收验证码和找回密码，不会公开显示。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: _textHint, height: 1.5),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildLoginFields() {
    return [
      _field(
        controller: _accountController,
        hint: '账号或邮箱',
        maxLength: 254,
      ),
      const SizedBox(height: 12),
      _field(
        controller: _passwordController,
        hint: '密码',
        obscure: !_showPwd,
        maxLength: 64,
        suffix: IconButton(
          onPressed: () => setState(() => _showPwd = !_showPwd),
          icon: Icon(_showPwd ? Icons.visibility_off : Icons.visibility,
              color: _textHint, size: 20),
        ),
      ),
    ];
  }

  List<Widget> _buildRegisterFields() {
    return [
      Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Expanded(child: _registerBtn(0, '账号密码注册')),
            Expanded(child: _registerBtn(1, '邮箱注册')),
          ],
        ),
      ),
      const SizedBox(height: 18),
      if (_registerMode == 0) ...[
        _field(
          controller: _regAccountController,
          hint: '账号名称（2-20 位中英文、数字或下划线）',
          maxLength: 20,
        ),
        const SizedBox(height: 12),
        _field(
          controller: _regEmailController,
          hint: '邮箱（用于找回密码）',
          keyboardType: TextInputType.emailAddress,
          maxLength: 254,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _field(
                controller: _regCodeController,
                hint: '邮箱验证码',
                keyboardType: TextInputType.number,
                maxLength: 8,
              ),
            ),
            const SizedBox(width: 12),
            _codeButton(
              sending: _regSending,
              countdown: _regCountdown,
              onPressed: () => _sendCode(emailMode: false),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _field(
          controller: _regPasswordController,
          hint: '密码（至少 6 位）',
          obscure: !_showRegPwd,
          maxLength: 64,
          suffix: IconButton(
            onPressed: () => setState(() => _showRegPwd = !_showRegPwd),
            icon: Icon(_showRegPwd ? Icons.visibility_off : Icons.visibility,
                color: _textHint, size: 20),
          ),
        ),
        const SizedBox(height: 12),
        _field(
          controller: _regPassword2Controller,
          hint: '确认密码',
          obscure: !_showRegPwd,
          maxLength: 64,
        ),
      ] else ...[
        _field(
          controller: _emailRegEmailController,
          hint: '邮箱',
          keyboardType: TextInputType.emailAddress,
          maxLength: 254,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _emailRegCodeController,
                keyboardType: TextInputType.number,
                maxLength: 8,
                style: TextStyle(fontSize: 16, color: _text),
                decoration: _decoration('邮箱验证码'),
              ),
            ),
            const SizedBox(width: 12),
            _codeButton(
              sending: _emailSending,
              countdown: _emailCountdown,
              onPressed: () => _sendCode(emailMode: true),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _field(
          controller: _emailRegPasswordController,
          hint: '密码（至少 6 位）',
          obscure: !_showEmailRegPwd,
          maxLength: 64,
          suffix: IconButton(
            onPressed: () =>
                setState(() => _showEmailRegPwd = !_showEmailRegPwd),
            icon: Icon(
                _showEmailRegPwd ? Icons.visibility_off : Icons.visibility,
                color: _textHint,
                size: 20),
          ),
        ),
        const SizedBox(height: 12),
        _field(
          controller: _emailRegPassword2Controller,
          hint: '确认密码',
          obscure: !_showEmailRegPwd,
          maxLength: 64,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.info_outline, size: 14, color: _textHint),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '注册成功后会自动生成账号名并登录，账号名会弹窗展示。',
                style: TextStyle(fontSize: 11.5, color: _textHint, height: 1.4),
              ),
            ),
          ],
        ),
      ],
    ];
  }

  InputDecoration _decoration(String hint) {
    return InputDecoration(
      counterText: '',
      hintText: hint,
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
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
    int? maxLength,
    TextInputType? keyboardType,
    Widget? suffix,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      maxLength: maxLength,
      style: TextStyle(fontSize: 16, color: _text),
      decoration: _decoration(hint).copyWith(suffixIcon: suffix),
    );
  }

  Widget _codeButton({
    required bool sending,
    required int countdown,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      height: 52,
      child: OutlinedButton(
        onPressed: (countdown > 0 || sending || _busy) ? null : onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: _primary,
          side: BorderSide(color: _gold),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        child: Text(
          countdown > 0 ? '$countdown s' : (sending ? '发送中...' : '获取验证码'),
          style: const TextStyle(fontSize: 14),
        ),
      ),
    );
  }

  Widget _modeBtn(int mode, String label) {
    final active = _mode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _busy ? null : () => setState(() => _mode = mode),
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

  Widget _registerBtn(int mode, String label) {
    final active = _registerMode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _busy ? null : () => setState(() => _registerMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: active ? _gold : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : _textSec,
          ),
        ),
      ),
    );
  }
}
