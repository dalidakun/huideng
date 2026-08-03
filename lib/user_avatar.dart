import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

const Color _primaryLight = Color(0xFF8B6B5A);

/// 用户头像：当前登录用户显示上传的头像图，其他用户显示默认人形图标。
class UserAvatar extends StatelessWidget {
  final String? userId;
  final double radius;
  const UserAvatar({super.key, this.userId, this.radius = 22});

  @override
  Widget build(BuildContext context) {
    final me = AuthService.instance.currentUser.value;
    final isMe = me != null && userId != null && userId == me.id;
    if (!isMe) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: _primaryLight.withValues(alpha: 0.10),
        child: Icon(Icons.person, size: radius, color: _primaryLight),
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
          backgroundColor: _primaryLight.withValues(alpha: 0.10),
          child: Icon(Icons.person, size: radius, color: _primaryLight),
        );
      },
    );
  }
}
