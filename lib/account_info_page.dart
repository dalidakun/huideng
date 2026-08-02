import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'change_phone_page.dart';
import 'login_page.dart';
import 'settings_widgets.dart';

/// 账号信息：头像、昵称、签名、绑定手机号。
class AccountInfoPage extends StatefulWidget {
  const AccountInfoPage({super.key});

  @override
  State<AccountInfoPage> createState() => _AccountInfoPageState();
}

class _AccountInfoPageState extends State<AccountInfoPage> {
  String? _avatarPath;
  String _nickname = '同修';
  String _tagline = '与经为伴，与法同行';

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
    super.dispose();
  }

  void _onAuthChanged() => _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final user = AuthService.instance.currentUser.value;
    if (!mounted) return;
    setState(() {
      _avatarPath = prefs.getString('user_avatar_path');
      _nickname = user?.displayName ?? prefs.getString('user_nickname') ?? '同修';
      _tagline = user?.tagline?.isNotEmpty == true
          ? user!.tagline!
          : prefs.getString('user_tagline') ?? '与经为伴，与法同行';
    });
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'gif'],
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
      _load();
    } catch (_) {
      if (mounted) _showToast('头像设置失败');
    }
  }

  Future<void> _editName() async {
    final nameController = TextEditingController(text: _nickname);
    final taglineController = TextEditingController(text: _tagline);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: sCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('编辑资料', style: TextStyle(color: sText, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              maxLength: 12,
              style: const TextStyle(color: sText),
              decoration: const InputDecoration(
                labelText: '昵称',
                labelStyle: TextStyle(color: sTextSec),
                hintText: '输入你的昵称',
                hintStyle: TextStyle(color: sTextHint),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: taglineController,
              maxLength: 20,
              style: const TextStyle(color: sText),
              decoration: const InputDecoration(
                labelText: '签名',
                labelStyle: TextStyle(color: sTextSec),
                hintText: '一句修学感悟',
                hintStyle: TextStyle(color: sTextHint),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消', style: TextStyle(color: sTextSec))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, {
              'nickname': nameController.text.trim(),
              'tagline': taglineController.text.trim(),
            }),
            child: const Text('保存', style: TextStyle(color: sPrimary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (result == null) return;
    final prefs = await SharedPreferences.getInstance();
    final nickname = result['nickname']!;
    final tagline = result['tagline']!.isEmpty ? '与经为伴，与法同行' : result['tagline']!;
    if (nickname.isNotEmpty) await prefs.setString('user_nickname', nickname);
    await prefs.setString('user_tagline', tagline);
    if (_isLoggedIn) {
      try {
        await AuthService.instance.updateProfile(
          nickname: nickname.isEmpty ? null : nickname,
          tagline: tagline,
        );
      } catch (_) {}
    }
    _load();
  }

  void _changePhone() {
    if (!_isLoggedIn) {
      _showToast('请先登录');
      Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePhonePage()));
  }

  void _showToast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  String _maskPhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7) return phone;
    return '${digits.substring(0, 3)}****${digits.substring(digits.length - 4)}';
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.currentUser.value;
    final phone = user?.mobilePhoneNumber;
    return SettingsPageScaffold(
      title: '账号信息',
      child: ListView(
        padding: const EdgeInsets.only(top: 16, bottom: 40),
        children: [
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: _pickAvatar,
                      child: Stack(
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: sCard,
                              boxShadow: [
                                BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10, offset: const Offset(0, 2)),
                              ],
                              image: _avatarPath != null
                                  ? DecorationImage(image: FileImage(File(_avatarPath!)), fit: BoxFit.cover)
                                  : null,
                            ),
                            child: _avatarPath == null
                                ? const Icon(Icons.person, size: 34, color: sTextHint)
                                : null,
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: sGold,
                                border: Border.all(color: sCard, width: 2),
                              ),
                              child: const Icon(Icons.edit_outlined, size: 13, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_nickname, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: sText)),
                          const SizedBox(height: 4),
                          Text(_tagline, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, color: sTextSec)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SettingsDivider(indent: 20),
              SettingsTile(
                icon: Icons.badge_outlined,
                iconColor: sGold,
                title: '昵称',
                subtitle: _nickname,
                onTap: _editName,
              ),
              const SettingsDivider(),
              SettingsTile(
                icon: Icons.format_quote_outlined,
                iconColor: sGold,
                title: '签名',
                subtitle: _tagline,
                onTap: _editName,
              ),
              const SettingsDivider(),
              SettingsTile(
                icon: Icons.phone_iphone_outlined,
                iconColor: sGold,
                title: '更换手机号',
                subtitle: phone != null && phone.isNotEmpty ? _maskPhone(phone) : '未登录',
                onTap: _changePhone,
              ),
            ],
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _isLoggedIn ? '昵称与签名修改后会同步到云端，更换手机号不会影响现有数据。' : '登录后可查看并管理账号信息',
              style: const TextStyle(fontSize: 12.5, color: sTextSec, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
