import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

const Color _primaryLight = Color(0xFF8B6B5A);

/// 用户头像：当前登录用户显示上传的头像图，其他用户/未设置头像时用 App 图标作为默认。
class UserAvatar extends StatelessWidget {
  final String? userId;
  final double radius;
  const UserAvatar({super.key, this.userId, this.radius = 22});

  /// App 图标默认头像（未上传头像前所有用户统一使用）。
  static const AssetImage _defaultImage = AssetImage('assets/images/app_icon.png');

  @override
  Widget build(BuildContext context) {
    final me = AuthService.instance.currentUser.value;
    final isMe = me != null && userId != null && userId == me.id;
    if (!isMe) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: _defaultImage,
        backgroundColor: _primaryLight.withValues(alpha: 0.10),
      );
    }
    return FutureBuilder<String?>(
      future: SharedPreferences.getInstance()
          .then((p) => p.getString('user_avatar_path')),
      builder: (context, snap) {
        final path = snap.data;
        if (path != null && path.isNotEmpty && File(path).existsSync()) {
          return CircleAvatar(
              radius: radius, backgroundImage: FileImage(File(path)));
        }
        return CircleAvatar(
          radius: radius,
          backgroundImage: _defaultImage,
          backgroundColor: _primaryLight.withValues(alpha: 0.10),
        );
      },
    );
  }
}
