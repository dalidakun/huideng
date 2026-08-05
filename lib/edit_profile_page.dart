import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

const Color _primaryLight = Color(0xFF8B6B5A);
const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  String? _avatarPath;
  String? _bannerPath;
  String _loadedAccount = '';
  final _nameCtrl = TextEditingController();
  final _taglineCtrl = TextEditingController();
  final _accountCtrl = TextEditingController();

  static final RegExp _nameRe =
      RegExp(r'^[\u4e00-\u9fa5a-zA-Z0-9_]{2,20}$');

  bool get _isLoggedIn => AuthService.instance.isLoggedIn;

  @override
  void initState() {
    super.initState();
    _load();
    AuthService.instance.currentUser.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    AuthService.instance.currentUser.removeListener(_onAuthChanged);
    _nameCtrl.dispose();
    _taglineCtrl.dispose();
    _accountCtrl.dispose();
    super.dispose();
  }

  void _onAuthChanged() => _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final user = AuthService.instance.currentUser.value;
    if (!mounted) return;
    setState(() {
      _avatarPath = prefs.getString('user_avatar_path');
      _bannerPath = prefs.getString('user_banner_path');
    });
    _nameCtrl.text = user?.displayName ?? prefs.getString('user_nickname') ?? '同修';
    _taglineCtrl.text = (user?.tagline?.isNotEmpty == true
            ? user!.tagline!
            : prefs.getString('user_tagline')) ??
        '燃一盏灯，看见自己，照亮别人。';
    if (_isLoggedIn) {
      final account = await AuthService.instance.getAccountName();
      if (!mounted) return;
      setState(() {
        _loadedAccount = account;
        _accountCtrl.text = account;
      });
    }
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.single.path == null) return;
    try {
      final src = File(result.files.single.path!);
      final ext = src.path.split('.').last;
      final docs = await getApplicationDocumentsDirectory();
      final dest = File('${docs.path}/avatar.$ext');
      if (dest.existsSync()) dest.deleteSync();
      await src.copy(dest.path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_avatar_path', dest.path);
      if (!mounted) return;
      setState(() => _avatarPath = dest.path);
    } catch (_) {
      if (mounted) _showToast('头像设置失败');
    }
  }

  Future<void> _pickBanner() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = File(result.files.single.path!);
      final dir = await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}/user_banner_${DateTime.now().millisecondsSinceEpoch}.png');
      await picked.copy(dest.path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_banner_path', dest.path);
      if (!mounted) return;
      setState(() => _bannerPath = dest.path);
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final nickname = _nameCtrl.text.trim();
    final tagline = _taglineCtrl.text.trim().isEmpty
        ? '燃一盏灯，看见自己，照亮别人。'
        : _taglineCtrl.text.trim();
    if (nickname.isNotEmpty) {
      await prefs.setString('user_nickname', nickname);
    }
    await prefs.setString('user_tagline', tagline);
    // 本地登录态立即生效（触发「我的」页刷新昵称）。
    final current = AuthService.instance.currentUser.value;
    if (current != null && nickname.isNotEmpty) {
      AuthService.instance.currentUser.value = AuthUser(
        id: current.id,
        mobilePhoneNumber: current.mobilePhoneNumber,
        nickname: nickname,
        tagline: tagline,
      );
    }
    // 账号修改：账号有变化时需先手机号验证，通过后才更新账号（仅改账号名，密码不变）。
    final account = _accountCtrl.text.trim();
    final accountChanged = _isLoggedIn && account != _loadedAccount;
    if (accountChanged) {
      if (!_nameRe.hasMatch(account)) {
        _showToast('账号名称需为 2-20 位中英文、数字或下划线');
        return;
      }
      final verified = await _verifyPhoneChange();
      if (!mounted) return;
      if (!verified) return; // 验证取消或失败，不保存账号修改
      try {
        await AuthService.instance.setAccount(username: account);
        _loadedAccount = account;
      } catch (e) {
        final m = e.toString();
        if (m.contains('username_taken')) {
          _showToast('该账号名称已被其他用户使用，请换一个');
        } else {
          _showToast('账号更新失败，请稍后重试');
        }
        return;
      }
    }
    if (!mounted) return;
    // 云端同步放到后台执行，不阻塞保存反馈。
    if (_isLoggedIn) {
      unawaited(() async {
        try {
          await AuthService.instance.updateProfile(
            nickname: nickname.isEmpty ? null : nickname,
            tagline: tagline,
          );
        } catch (_) {}
      }());
    }
    // 保存成功，返回个人主页（带回"已保存"标记）。
    Navigator.pop(context, true);
  }

  /// 修改账号前先验证当前绑定手机号：发验证码 → 用户输入 → 校验通过返回 true。
  Future<bool> _verifyPhoneChange() async {
    final phone = AuthService.instance.currentUser.value?.mobilePhoneNumber;
    if (phone == null || phone.isEmpty) {
      _showToast('当前账号未绑定手机号，无法验证');
      return false;
    }
    try {
      await AuthService.instance.requestSmsCode(phone);
    } catch (_) {
      _showToast('验证码发送失败，请稍后重试');
      return false;
    }
    if (!mounted) return false;
    final code = await showDialog<String>(
      context: context,
      builder: (_) => _SmsCodeDialog(phone: phone),
    );
    if (code == null || code.length != 6) return false;
    try {
      await AuthService.instance.loginWithSmsCode(phone, code);
      return true;
    } catch (_) {
      if (mounted) _showToast('验证码错误或已过期');
      return false;
    }
  }

  void _showToast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Color(0xFFD2C5B3),
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: SafeArea(
        top: true,
        child: Scaffold(
          backgroundColor: _bg,
          body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  Stack(
                    children: [
                      Container(
                        width: double.infinity,
                        height: 160,
                          decoration: BoxDecoration(
                            color: const Color(0xFFD2C5B3),
                            image: _bannerPath != null
                                ? DecorationImage(
                                    image: FileImage(File(_bannerPath!)),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: _bannerPath == null
                              ? const Center(
                                  child: Icon(Icons.camera_alt_outlined,
                                      size: 28, color: Colors.white38),
                                )
                              : null,
                        ),
                        Positioned(
                          left: 8,
                          top: 4,
                          child: GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.2),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.arrow_back_ios_new,
                                  size: 18, color: Colors.white),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _pickBanner,
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.3),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.edit,
                                  size: 16, color: Colors.white),
                            ),
                          ),
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 20),
                    child: Transform.translate(
                      offset: const Offset(0, -38),
                      child: GestureDetector(
                        onTap: _pickAvatar,
                        child: Stack(
                          children: [
                            Container(
                              width: 76,
                              height: 76,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _card,
                                border: Border.all(
                                    color: Colors.white, width: 3),
                                boxShadow: [
                                  BoxShadow(
                                      color: Colors.black
                                          .withValues(alpha: 0.12),
                                      blurRadius: 12,
                                      offset: const Offset(0, 2)),
                                ],
                                image: _avatarPath != null
                                    ? DecorationImage(
                                        image:
                                            FileImage(File(_avatarPath!)),
                                        fit: BoxFit.cover)
                                    : const DecorationImage(
                                        image: AssetImage(
                                            'assets/images/app_icon.png'),
                                        fit: BoxFit.cover),
                              ),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Container(
                                    width: 22,
                                    height: 22,
                                    decoration: BoxDecoration(
                                      color: _gold,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: _card, width: 2),
                                    ),
                                    child: const Icon(Icons.edit,
                                        size: 12, color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: const Offset(0, -24),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 20),
                          const Text('昵称',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: _textSec)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _nameCtrl,
                            maxLength: 12,
                            style: const TextStyle(
                                fontSize: 16, color: _text),
                            decoration: const InputDecoration(
                              hintText: '输入你的昵称',
                              hintStyle:
                                  TextStyle(color: _textHint),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: Color(0xFFEFE6DB)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: Color(0xFFEFE6DB)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: _gold, width: 1.5),
                              ),
                              filled: true,
                              fillColor: _card,
                              contentPadding:
                                  EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 14),
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text('签名',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: _textSec)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _taglineCtrl,
                            maxLength: 20,
                            style: const TextStyle(
                                fontSize: 16, color: _text),
                            decoration: const InputDecoration(
                              hintText: '一句修学感悟',
                              hintStyle:
                                  TextStyle(color: _textHint),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: Color(0xFFEFE6DB)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: Color(0xFFEFE6DB)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: _gold, width: 1.5),
                              ),
                              filled: true,
                              fillColor: _card,
                              contentPadding:
                                  EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 14),
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text('账号',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: _textSec)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _accountCtrl,
                            maxLength: 20,
                            style: const TextStyle(
                                fontSize: 16, color: _text),
                            decoration: const InputDecoration(
                              prefixText: '@ ',
                              prefixStyle:
                                  TextStyle(color: _textSec, fontSize: 16),
                              hintText: '输入账号名',
                              hintStyle:
                                  TextStyle(color: _textHint),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: Color(0xFFEFE6DB)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: Color(0xFFEFE6DB)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: _gold, width: 1.5),
                              ),
                              filled: true,
                              fillColor: _card,
                              contentPadding:
                                  EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 14),
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.center,
                            children: [
                              Icon(Icons.info_outline,
                                  size: 14, color: Color(0xFF70867A)),
                              SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '修改账户名需要绑定的手机号验证',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF757575),
                                      height: 1.0),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 12),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: const Text('保存',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// 短信验证码弹窗：自持 TextEditingController 并在自身 dispose 时释放，
/// 避免弹窗退出动画期间 dispose 控制器触发 `_dependents.isEmpty` 断言红屏。
class _SmsCodeDialog extends StatefulWidget {
  final String phone;

  const _SmsCodeDialog({required this.phone});

  @override
  State<_SmsCodeDialog> createState() => _SmsCodeDialogState();
}

class _SmsCodeDialogState extends State<_SmsCodeDialog> {
  late final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _maskedPhone {
    final p = widget.phone;
    if (p.length < 7) return p;
    return '${p.substring(0, 3)}****${p.substring(p.length - 4)}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('手机验证',
          style: TextStyle(
              color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('验证码已发送至 $_maskedPhone',
              style: const TextStyle(fontSize: 13, color: _textSec)),
          const SizedBox(height: 10),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: 6,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 16, color: _text),
            decoration: const InputDecoration(hintText: '请输入短信验证码'),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消', style: TextStyle(color: _textSec))),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('确定',
              style: TextStyle(color: _text, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
