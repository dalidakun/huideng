import 'package:flutter/material.dart';

import 'app_palette.dart';
Color get sPrimary => AppPalette.p.primary;
Color get sGold => AppPalette.p.accent;
Color get sBg => AppPalette.p.bg;
Color get sCard => AppPalette.p.card;
Color get sText => AppPalette.p.text;
Color get sTextSec => AppPalette.p.textSec;
Color get sTextHint => AppPalette.p.textHint;
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
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppPalette.p.gradTop, AppPalette.p.gradBot],
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
                      icon: Icon(Icons.arrow_back_ios_new, color: sText, size: 20),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(title, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: sText), overflow: TextOverflow.ellipsis),
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
      child: Divider(height: 1, thickness: 0.5, color: AppPalette.p.borderSoft),
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
                  Text(title, style: TextStyle(fontSize: 16, color: sText, fontWeight: FontWeight.w500)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: sTextHint)),
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
