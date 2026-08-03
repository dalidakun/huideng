import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'settings_widgets.dart';

/// 设置/修改账号名称与密码。
/// 账号名称全局唯一，可用于「账号密码登录」；设置后可随时修改名称或密码。
class AccountSetupPage extends StatefulWidget {
  const AccountSetupPage({super.key});

  @override
  State<AccountSetupPage> createState() => _AccountSetupPageState();
}

class _AccountSetupPageState extends State<AccountSetupPage> {
  final _nameController = TextEditingController();
  final _pwdController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _submitting = false;
  bool _loading = true;
  String _currentName = '';

  static final RegExp _nameRe = RegExp(r'^[\u4e00-\u9fa5a-zA-Z0-9_]{2,20}$');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pwdController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final name = await AuthService.instance.getAccountName();
    if (!mounted) return;
    setState(() {
      _currentName = name;
      if (name.isNotEmpty) _nameController.text = name;
      _loading = false;
    });
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final pwd = _pwdController.text;
    if (!_nameRe.hasMatch(name)) {
      _showToast('账号名称需为 2-20 位中英文、数字或下划线');
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
      await AuthService.instance.setAccount(username: name, password: pwd);
      if (!mounted) return;
      _showToast('设置成功，可用账号名称登录');
      Navigator.of(context).pop(true);
    } catch (e) {
      _showToast(_friendlyError(e));
    } finally {
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
    int maxLength = 64,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      maxLength: maxLength,
      keyboardType: keyboardType,
      style: const TextStyle(fontSize: 16, color: sText),
      decoration: InputDecoration(
        counterText: '',
        hintText: hint,
        hintStyle: const TextStyle(color: sTextHint),
        filled: true,
        fillColor: sCard,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
      title: '账号名称与密码',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (_currentName.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: sGold.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.badge_outlined, size: 18, color: sGold),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('当前账号名称：$_currentName',
                            style:
                                const TextStyle(fontSize: 13, color: sTextSec)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              const Text('账号名称',
                  style: TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              _field(
                controller: _nameController,
                hint: '2-20 位中英文、数字或下划线',
                maxLength: 20,
                keyboardType: TextInputType.text,
              ),
              const SizedBox(height: 16),
              const Text('密码',
                  style: TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              _field(controller: _pwdController, hint: '6-64 位密码', obscure: true),
              const SizedBox(height: 16),
              const Text('确认密码',
                  style: TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              _field(
                  controller: _confirmController, hint: '再次输入密码', obscure: true),
              const SizedBox(height: 28),
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
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
                      : const Text('保存',
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
                      '账号名称全局唯一，可用于「账号密码登录」。设置后可随时修改名称或密码，修改后云端笔记等数据保持不变。',
                      style: TextStyle(fontSize: 12.5, color: sTextSec, height: 1.6),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
