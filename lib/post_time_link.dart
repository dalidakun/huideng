import 'package:flutter/material.dart';

/// 帖子时间戳链接：按下时显示下划线，点击触发回调（进入帖子详情）。
class PostTimeLink extends StatefulWidget {
  final String text;
  final VoidCallback onTap;
  const PostTimeLink({super.key, required this.text, required this.onTap});

  @override
  State<PostTimeLink> createState() => _PostTimeLinkState();
}

class _PostTimeLinkState extends State<PostTimeLink> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: Text(
        widget.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          color: const Color(0xFF8C8C8C),
          decoration: _pressed ? TextDecoration.underline : null,
          decorationColor: const Color(0xFF8C8C8C),
        ),
      ),
    );
  }
}

/// @账户名链接：以青色显示，提示用户可点击；点击进入用户主页。
class AccountLink extends StatefulWidget {
  final String account;
  final VoidCallback? onTap;
  const AccountLink({super.key, required this.account, this.onTap});

  @override
  State<AccountLink> createState() => _AccountLinkState();
}

class _AccountLinkState extends State<AccountLink> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: Text(
        // 账号名过长时省略显示，避免把昵称/百分比挤到换行。
        '@${widget.account}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: _pressed ? const Color(0xFF6E6E6E) : const Color(0xFF8C8C8C),
        ),
      ),
    );
  }
}
