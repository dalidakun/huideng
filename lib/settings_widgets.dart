import 'package:flutter/material.dart';

const Color sPrimary = Color(0xFF5C4033);
const Color sGold = Color(0xFFD4A06A);
const Color sBg = Color(0xFFF5EDE3);
const Color sCard = Color(0xFFFFFAF5);
const Color sText = Color(0xFF3E2723);
const Color sTextSec = Color(0xFF8B6B5A);
const Color sTextHint = Color(0xFFC4B5A8);

/// 设置类页面统一外壳：渐变圆角头部 + 返回按钮 + 标题 + 可选右上角操作 + 滚动主体。
class SettingsPageScaffold extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const SettingsPageScaffold({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: sBg,
      body: Column(
        children: [
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFF3E8DB), Color(0xFFF9F1E7)],
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 20, 18),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_ios_new, color: sText, size: 20),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: sText), overflow: TextOverflow.ellipsis),
                    ),
                    if (trailing != null) trailing!,
                  ],
                ),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 设置分区卡片：圆角白底 + 阴影，内部放若干 [SettingsTile]。
class SettingsCard extends StatelessWidget {
  final List<Widget> children;

  const SettingsCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: sCard,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(children: children),
    );
  }
}

/// 设置卡片里的分隔线（缩进对齐文字起点）。
class SettingsDivider extends StatelessWidget {
  final double indent;
  const SettingsDivider({super.key, this.indent = 60});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: const Divider(height: 1, thickness: 0.5, color: Color(0xFFEFE6DB)),
    );
  }
}

/// 设置菜单行：可选前置图标、标题、副标题、尾部控件、点击回调。
class SettingsTile extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const SettingsTile({
    super.key,
    this.icon,
    this.iconColor,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            if (icon != null) ...[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: (iconColor ?? sTextSec).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor ?? sTextSec, size: 20),
              ),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, color: sText, fontWeight: FontWeight.w500)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: sTextHint)),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
