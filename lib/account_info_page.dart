import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'image_crop_page.dart';
import 'settings_widgets.dart';

import 'app_palette.dart';
/// 账号信息：头像、昵称、签名、绑定手机号。
class AccountInfoPage extends StatefulWidget {
  const AccountInfoPage({super.key});

  @override
  State<AccountInfoPage> createState() => _AccountInfoPageState();
}

/// 待裁剪的图片请求：相册选图后页面本体原地切换为裁剪界面。
class _CropRequest {
  final String path;
  final double ratio;
  final int maxOutput;
  final bool isAvatar;

  const _CropRequest({
    required this.path,
    required this.ratio,
    required this.maxOutput,
    required this.isAvatar,
  });
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

  /// 裁剪请求：选图后页面本体原地切换为裁剪界面（不推路由），
  /// 避免相册返回时路由弹跳造成「先回到上一页、再弹出裁剪页」。
  _CropRequest? _crop;

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'gif'],
      // 关闭插件内置压缩：避免选图后长时间等待才返回，且原图保真度更高（裁剪页内自行缩放）。
      allowCompression: false,
    );
    if (result == null || result.files.single.path == null) return;
    if (!mounted) return;
    setState(() {
      _crop = _CropRequest(
        path: result.files.single.path!,
        ratio: 1.0,
        maxOutput: 512,
        isAvatar: true,
      );
    });
  }

  Future<void> _pickBanner() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        allowCompression: false,
      );
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;
      // 按横幅实际展示比例（屏宽 / 160 高）裁剪选区。
      final ratio = MediaQuery.of(context).size.width / 160.0;
      setState(() {
        _crop = _CropRequest(
          path: result.files.single.path!,
          ratio: ratio,
          maxOutput: 800,
          isAvatar: false,
        );
      });
    } catch (_) {}
  }

  /// 裁剪确认：保存为带时间戳的新文件（固定文件名会让 FileImage 缓存命中旧头像）。
  Future<void> _applyCropResult(Uint8List cropped) async {
    final isAvatar = _crop?.isAvatar ?? true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dest = File(
          '${docs.path}/${isAvatar ? 'avatar' : 'user_banner'}_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await dest.writeAsBytes(cropped, flush: true);
      // 只保留最新一张：旧的头像/横幅文件一并删除，避免系统相册
      // （扫描应用目录的 ROM）显示多份重复图片。
      await _cleanupOldImages(docs.path, dest.path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          isAvatar ? 'user_avatar_path' : 'user_banner_path', dest.path);
      if (!mounted) return;
      setState(() {
        _crop = null;
        if (isAvatar) {
          _avatarPath = dest.path;
        } else {
          _bannerPath = dest.path;
        }
      });
      _load();
    } catch (_) {
      if (!mounted) return;
      setState(() => _crop = null);
      if (isAvatar) _showToast('头像设置失败');
    }
  }

  /// 删除该目录下所有旧的头像/横幅图片文件（新文件已生成后），只保留最新一张；
  /// 失败静默。历史遗留的重复图片也会在这里被清掉。
  Future<void> _cleanupOldImages(String docsPath, String keepPath) async {
    try {
      final dir = Directory(docsPath);
      if (!await dir.exists()) return;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        final isAvatarOrBanner =
            (name.startsWith('avatar_') || name.startsWith('user_banner_')) &&
                name.endsWith('.jpg');
        if (isAvatarOrBanner && e.path != keepPath) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
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
        title: Text('编辑资料', style: TextStyle(color: sText, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              maxLength: 12,
              style: TextStyle(color: sText),
              decoration: InputDecoration(
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
              style: TextStyle(color: sText),
              decoration: InputDecoration(
                labelText: '签名',
                labelStyle: TextStyle(color: sTextSec),
                hintText: '一句修学感悟',
                hintStyle: TextStyle(color: sTextHint),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: sTextSec))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, {
              'nickname': nameController.text.trim(),
              'tagline': taglineController.text.trim(),
            }),
            child: Text('保存', style: TextStyle(color: sPrimary, fontWeight: FontWeight.w600)),
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
    // 裁剪模式：页面本体原地切换为裁剪界面（不推路由，避免相册返回时
    // 路由弹跳造成「先回到上一页、再弹出裁剪页」）；系统返回键先退出裁剪。
    final crop = _crop;
    if (crop != null) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          setState(() => _crop = null);
        },
        child: ImageCropPage(
          filePath: crop.path,
          ratio: crop.ratio,
          maxOutput: crop.maxOutput,
          onResult: _applyCropResult,
          onCancel: () {
            if (mounted) setState(() => _crop = null);
          },
        ),
      );
    }
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
                      icon: Icon(Icons.arrow_back_ios_new, color: sText, size: 20),
                    ),
                    const SizedBox(width: 4),
                    Text('账号信息',
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
                        color: AppPalette.p.muted,
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
                              style: TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w700, color: sText)),
                          if (phoneDisplay.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(Icons.phone_iphone_outlined,
                                    size: 13, color: sTextHint),
                                const SizedBox(width: 4),
                                Text(phoneDisplay,
                                    style: TextStyle(fontSize: 13, color: sTextHint)),
                              ],
                            ),
                          ],
                          const SizedBox(height: 6),
                          Text(
                            _tagline,
                            style: TextStyle(fontSize: 13, color: sTextSec),
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
                      style: TextStyle(fontSize: 12.5, color: sTextSec, height: 1.5),
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
