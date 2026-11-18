import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_palette.dart';

/// 个人资料 / 编辑资料页共用的账户信息块：
/// - 当前绑定邮箱；未绑定时留空，并给出「绑定邮箱」入口（用于找回密码）；
/// - 注册用户 ID（UID）：注册后不可更改，联系管理员开通无限翻译时会用到。
class ProfileAccountInfo extends StatelessWidget {
  final String email;
  final String uid;
  final VoidCallback onBindEmail;

  const ProfileAccountInfo({
    super.key,
    required this.email,
    required this.uid,
    required this.onBindEmail,
  });

  bool get _hasEmail => email.trim().isNotEmpty;

  Future<void> _copyUid(BuildContext context) async {
    final value = uid.trim();
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('用户ID已复制'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mark_email_read_outlined, size: 15, color: p.textHint),
              const SizedBox(width: 6),
              Text('邮箱',
                  style: TextStyle(fontSize: 12.5, color: p.textSec)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  // 未绑定时留空，不显示占位文案；下方单独提示绑定。
                  _hasEmail ? email.trim() : '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: p.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onBindEmail,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Text(
                    _hasEmail ? '更换' : '绑定邮箱',
                    style: TextStyle(
                      fontSize: 12,
                      color: p.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (!_hasEmail) ...[
            const SizedBox(height: 3),
            Text(
              '尚未绑定邮箱；点右侧「绑定邮箱」完成绑定，用于找回密码与订阅核对。',
              style: TextStyle(fontSize: 10.5, color: p.textHint, height: 1.4),
            ),
          ],
          const SizedBox(height: 8),
          Divider(height: 1, thickness: 0.5, color: p.borderSoft),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.badge_outlined, size: 15, color: p.textHint),
              const SizedBox(width: 6),
              Text('用户ID',
                  style: TextStyle(fontSize: 12.5, color: p.textSec)),
              const SizedBox(width: 10),
              Expanded(
                // 让完整 UID 与「用户ID」保持在同一行：宽度不够时等比缩小。
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    uid.trim().isEmpty ? '—' : uid.trim(),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: p.text,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '注册后不可更改',
                  style: TextStyle(
                      fontSize: 10.5, color: p.textHint, height: 1.4),
                ),
              ),
              // 复制按钮放在区块右下角，不占用 UID 那一行的宽度。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _copyUid(context),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.copy_rounded, size: 12, color: p.accent),
                      const SizedBox(width: 3),
                      Text('复制',
                          style: TextStyle(
                              fontSize: 10.5,
                              color: p.accent,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
