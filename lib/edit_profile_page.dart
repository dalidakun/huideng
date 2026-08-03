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
  bool _showSavedText = false;
  final _nameCtrl = TextEditingController();
  final _taglineCtrl = TextEditingController();

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
        '与经为伴，与法同行';
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
        ? '与经为伴，与法同行'
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
    if (!mounted) return;
    // 横幅下边缘小字号提示，避免云端同步耗时造成卡顿。
    setState(() => _showSavedText = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showSavedText = false);
    });
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
                  GestureDetector(
                    onTap: _pickBanner,
                    child: Stack(
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
                        if (_showSavedText)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 12,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 5),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.45),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Text('已保存',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w500)),
                              ),
                            ),
                          ),
                      ],
                    ),
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
                                    : null,
                              ),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  if (_avatarPath == null)
                                    const Icon(Icons.person,
                                        size: 38, color: _primaryLight),
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
