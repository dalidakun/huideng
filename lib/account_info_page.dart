import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'settings_widgets.dart';

/// 账号信息：头像、昵称、签名、绑定手机号。
class AccountInfoPage extends StatefulWidget {
  const AccountInfoPage({super.key});

  @override
  State<AccountInfoPage> createState() => _AccountInfoPageState();
}

class _AccountInfoPageState extends State<AccountInfoPage> {
  String? _avatarPath;
  String? _bannerPath;
  String _nickname = '同修';
  String _tagline = '燃一盏灯，看见自己，照亮别人。';
  String _phone = '';

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
      _bannerPath = prefs.getString('user_banner_path');
      _nickname = user?.displayName ?? prefs.getString('user_nickname') ?? '同修';
      _tagline = user?.tagline?.isNotEmpty == true
          ? user!.tagline!
          : prefs.getString('user_tagline') ?? '燃一盏灯，看见自己，照亮别人。';
      _phone = user?.mobilePhoneNumber ?? '';
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
    final tagline = result['tagline']!.isEmpty ? '燃一盏灯，看见自己，照亮别人。' : result['tagline']!;
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

  void _showToast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final phoneDisplay = _phone.isNotEmpty
        ? '${_phone.substring(0, math.min(3, _phone.length))}****${_phone.length >= 7 ? _phone.substring(_phone.length - 4) : ''}'
        : '';

    return Scaffold(
      backgroundColor: sBg,
      body: SafeArea(
        top: true,
        child: Column(
          children: [
            // back button
            Container(
              color: sBg,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 20, 10),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_ios_new, color: sText, size: 20),
                    ),
                    const SizedBox(width: 4),
                    const Text('账号信息',
                        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: sText)),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  // banner
                  GestureDetector(
                    onTap: _pickBanner,
                    child: Container(
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
                              child: Icon(Icons.camera_alt_outlined, size: 28, color: Colors.white38),
                            )
                          : null,
                    ),
                  ),
                  // avatar overlapping banner
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
                                color: sCard,
                                border: Border.all(color: Colors.white, width: 3),
                                boxShadow: [
                                  BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.12),
                                      blurRadius: 12,
                                      offset: const Offset(0, 2)),
                                ],
                                image: _avatarPath != null
                                    ? DecorationImage(
                                        image: FileImage(File(_avatarPath!)),
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
                                      shape: BoxShape.circle,
                                      color: sGold,
                                      border: Border.all(color: sCard, width: 2),
                                    ),
                                    child: const Icon(Icons.edit_outlined, size: 12, color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // name / phone / tagline
                  Transform.translate(
                    offset: const Offset(0, -24),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_nickname,
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w700, color: sText)),
                          if (phoneDisplay.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.phone_iphone_outlined,
                                    size: 13, color: sTextHint),
                                const SizedBox(width: 4),
                                Text(phoneDisplay,
                                    style: const TextStyle(fontSize: 13, color: sTextHint)),
                              ],
                            ),
                          ],
                          const SizedBox(height: 6),
                          Text(
                            _tagline,
                            style: const TextStyle(fontSize: 13, color: sTextSec),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // edit fields
                  SettingsCard(
                    children: [
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
                    ],
                  ),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _isLoggedIn ? '昵称与签名修改后会同步到云端。' : '登录后可查看并管理账号信息',
                      style: const TextStyle(fontSize: 12.5, color: sTextSec, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
