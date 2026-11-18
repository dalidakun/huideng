import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'change_email_page.dart';
import 'image_crop_page.dart';
import 'profile_account_info.dart';

import 'app_palette.dart';
Color get _gold => AppPalette.p.accent;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
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

class _EditProfilePageState extends State<EditProfilePage> {
  String? _avatarPath;
  String? _bannerPath;
  String _loadedAccount = '';
  String _email = '';
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
      _email = user?.email ?? prefs.getString('user_account_email') ?? '';
    });
    _nameCtrl.text = user?.displayName ?? prefs.getString('user_nickname') ?? '同修';
    _taglineCtrl.text = (user?.tagline?.isNotEmpty == true
            ? user!.tagline!
            : prefs.getString('user_tagline')) ??
        '燃一盏灯，看见自己，照亮别人。';
    if (_isLoggedIn) {
      final account = await AuthService.instance.getAccountName();
      final email = await AuthService.instance.getAccountEmail();
      if (!mounted) return;
      setState(() {
        _loadedAccount = account;
        _accountCtrl.text = account;
        if (email.isNotEmpty) _email = email;
      });
    }
  }

  /// 裁剪请求：选图后页面本体原地切换为裁剪界面（不推路由），
  /// 避免相册返回时路由弹跳造成「先回到上一页、再弹出裁剪页」。
  _CropRequest? _crop;

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
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

  /// 裁剪确认：保存为带时间戳的新文件（FileImage 缓存按路径+缩放键控，
  /// 固定文件名会导致 ImageCache 一直命中旧头像），并退出裁剪界面。
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
        email: current.email,
        nickname: nickname,
        tagline: tagline,
      );
    }
    // 账号修改：账号名变化时直接更新（仅改账号名，密码不变）。
    final account = _accountCtrl.text.trim();
    final accountChanged = _isLoggedIn && account != _loadedAccount;
    if (accountChanged) {
      if (!_nameRe.hasMatch(account)) {
        _showToast('账号名称需为 2-20 位中英文、数字或下划线');
        return;
      }
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

  /// 打开邮箱绑定/更换页；返回后重读资料，邮箱与绑定提示立即更新。
  Future<void> _openChangeEmail() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChangeEmailPage()),
    );
    if (mounted) await _load();
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
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: AppPalette.p.muted,
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
                          Text('昵称',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: _textSec)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _nameCtrl,
                            maxLength: 12,
                            style: TextStyle(
                                fontSize: 16, color: _text),
                            decoration: InputDecoration(
                              hintText: '输入你的昵称',
                              hintStyle:
                                  TextStyle(color: _textHint),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: AppPalette.p.borderSoft),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: AppPalette.p.borderSoft),
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
                          Text('签名',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: _textSec)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _taglineCtrl,
                            maxLength: 20,
                            style: TextStyle(
                                fontSize: 16, color: _text),
                            decoration: InputDecoration(
                              hintText: '一句修学感想',
                              hintStyle:
                                  TextStyle(color: _textHint),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: AppPalette.p.borderSoft),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: AppPalette.p.borderSoft),
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
                          Text('账号',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: _textSec)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _accountCtrl,
                            maxLength: 20,
                            style: TextStyle(
                                fontSize: 16, color: _text),
                            decoration: InputDecoration(
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
                                    color: AppPalette.p.borderSoft),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                    Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: AppPalette.p.borderSoft),
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
                                  '账号名修改后立即生效；忘记密码可通过绑定邮箱找回',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF757575),
                                      height: 1.0),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          ProfileAccountInfo(
                            email: _email,
                            uid: AuthService.instance.currentUser.value?.id ??
                                '',
                            onBindEmail: _openChangeEmail,
                          ),
                          const SizedBox(height: 12),
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
