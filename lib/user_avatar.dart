import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'user_avatar_cache.dart';

const Color _primaryLight = Color(0xFF8B6B5A);

/// base64 → 解码后的字节缓存（按 base64 字符串复用同一份字节）。
///
/// [Image.memory] 底层用 [MemoryImage]，其相等性按「字节对象同一性」判断；
/// 若每次重建都重新 [base64Decode]，会生成新的字节对象 → 新的 ImageProvider →
/// 页面 setState（如点赞）时所有头像被清空重解码，视觉上「闪一下」。
/// 同一头像字符串复用同一份字节，可命中 ImageCache，重建不再闪烁。
final Map<String, Uint8List> _decodedAvatarBytes = {};

/// 解码头像 base64（同一字符串返回同一份字节对象）。
Uint8List decodeAvatarBase64(String b64) =>
    _decodedAvatarBytes.putIfAbsent(b64, () => base64Decode(b64));

/// 用户头像：优先展示传入的 base64 头像；其次当前登录用户显示本地上传的头像；
/// 其他用户经 [UserAvatarCache] 从云端批量拉取头像（帖子/评论/回复通用）；
/// 都没有时用 App 图标作为默认。
class UserAvatar extends StatelessWidget {
  final String? userId;
  final double radius;

  /// 远端头像 base64（通知等场景由云端直接返回时传入），非空时优先使用。
  final String imageBase64;

  const UserAvatar({
    super.key,
    this.userId,
    this.radius = 22,
    this.imageBase64 = '',
  });

  /// App 图标默认头像（未上传头像前所有用户统一使用）。
  static const AssetImage _defaultImage = AssetImage('assets/images/app_icon.png');

  @override
  Widget build(BuildContext context) {
    if (imageBase64.isNotEmpty) {
      try {
        return ClipOval(
          child: Image.memory(
            decodeAvatarBase64(imageBase64),
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _default(),
          ),
        );
      } catch (_) {}
    }
    final me = AuthService.instance.currentUser.value;
    final isMe = me != null && userId != null && userId == me.id;
    if (isMe) {
      return FutureBuilder<String?>(
        future: SharedPreferences.getInstance()
            .then((p) => p.getString('user_avatar_path')),
        builder: (context, snap) {
          final path = snap.data;
          if (path != null && path.isNotEmpty && File(path).existsSync()) {
            return CircleAvatar(
                radius: radius, backgroundImage: FileImage(File(path)));
          }
          return _default();
        },
      );
    }
    // 他人头像：查云端缓存（未命中触发批量拉取，到达后通知重建）。
    final uid = userId ?? '';
    if (uid.isEmpty) return _default();
    return ListenableBuilder(
      listenable: UserAvatarCache.instance,
      builder: (context, _) {
        final b64 = UserAvatarCache.instance.request(uid);
        if (b64 == null || b64.isEmpty) return _default();
        try {
          return ClipOval(
            child: Image.memory(
              decodeAvatarBase64(b64),
              width: radius * 2,
              height: radius * 2,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _default(),
            ),
          );
        } catch (_) {
          return _default();
        }
      },
    );
  }

  Widget _default() {
    return CircleAvatar(
      radius: radius,
      backgroundImage: _defaultImage,
      backgroundColor: _primaryLight.withValues(alpha: 0.10),
    );
  }
}
