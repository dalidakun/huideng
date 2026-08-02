import 'package:flutter/material.dart';

import 'settings_widgets.dart';

/// 关于我们：应用简介、版本信息。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: '关于我们',
      child: ListView(
        padding: const EdgeInsets.only(top: 40, bottom: 40),
        children: [
          Column(
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: sCard,
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 3)),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.asset('assets/images/app_icon.png', fit: BoxFit.cover),
              ),
              const SizedBox(height: 16),
              const Text('燃灯', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: sText)),
              const SizedBox(height: 6),
              const Text('版本 1.0.0', style: TextStyle(fontSize: 13, color: sTextHint)),
              const SizedBox(height: 14),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  '一盏燃灯，照见自己。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: sTextSec, height: 1.7),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          SettingsCard(
            children: [
              const SettingsTile(
                icon: Icons.mail_outline,
                iconColor: sGold,
                title: '联系我们',
                subtitle: '邮箱：liyankun007@gmail.com',
              ),
              const SettingsDivider(),
              const SettingsTile(
                icon: Icons.favorite_border,
                iconColor: sGold,
                title: '初心',
                subtitle: '愿更多人亲近经典，修习佛法。',
              ),
            ],
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('当前已是最新版本'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: sGold,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('升级', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            '© 2026 燃灯 · 保留所有权利',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: sTextHint),
          ),
        ],
      ),
    );
  }
}
