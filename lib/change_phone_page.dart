import 'dart:async';

import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'settings_widgets.dart';

/// 更换绑定手机：给新手机号发验证码并验证后完成换绑。
/// 换绑前后是同一个账号，云端笔记、收藏等数据自动保留。
class ChangePhonePage extends StatefulWidget {
  const ChangePhonePage({super.key});

  @override
  State<ChangePhonePage> createState() => _ChangePhonePageState();
}

class _ChangePhonePageState extends State<ChangePhonePage> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  Timer? _timer;
  int _countdown = 0;
  bool _sending = false;
  bool _confirming = false;

  @override
  void dispose() {
    _timer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  bool get _phoneValid => RegExp(r'^1[3-9]\d{9}$').hasMatch(_phoneController.text.trim());

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
      await AuthService.instance.requestPhoneChange(_phoneController.text.trim());
      _showToast('验证码已发送到新手机号');
      _startCountdown();
    } catch (e) {
      _showToast('发送失败：${e is AuthException ? e.message : e.toString()}');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _confirm() async {
    if (!_phoneValid) {
      _showToast('请输入正确的手机号');
      return;
    }
    if (_codeController.text.trim().length != 6) {
      _showToast('请输入 6 位验证码');
      return;
    }
    setState(() => _confirming = true);
    try {
      await AuthService.instance.confirmPhoneChange(_codeController.text.trim());
      if (mounted) {
        _showToast('手机号更换成功');
        Navigator.of(context).pop();
      }
    } catch (e) {
      _showToast('更换失败：${e is AuthException ? e.message : e.toString()}');
    } finally {
      if (mounted) setState(() => _confirming = false);
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
                color: sPrimary,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
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
    final phone = AuthService.instance.currentUser.value?.mobilePhoneNumber;
    return SettingsPageScaffold(
      title: '更换手机号',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (phone != null && phone.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: sGold.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.phone_iphone, size: 18, color: sGold),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('当前绑定手机号：$phone',
                          style: const TextStyle(fontSize: 13, color: sTextSec)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            const Text('新手机号', style: TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              maxLength: 11,
              style: const TextStyle(fontSize: 16, color: sText),
              decoration: InputDecoration(
                counterText: '',
                hintText: '请输入新手机号',
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
            ),
            const SizedBox(height: 16),
            const Text('验证码', style: TextStyle(fontSize: 14, color: sText, fontWeight: FontWeight.w600)),
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
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: Text(
                      _countdown > 0 ? '$_countdown s' : (_sending ? '发送中...' : '获取验证码'),
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _confirming
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('确认更换', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 15, color: sTextHint),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '更换手机号不会影响现有账号，云端笔记、收藏与签到记录都会保留。',
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
