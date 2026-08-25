import 'package:flutter/material.dart';

import 'cloud_notes_service.dart';
import 'admin_manage_page.dart';
import 'feedback_admin_page.dart';
import 'settings_widgets.dart';
import 'text_input_sheet.dart';

/// 关于我们：应用简介、版本信息。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _checkAdmin();
  }

  Future<void> _checkAdmin() async {
    final ok = await CloudNotesService.instance.isAdmin();
    if (!mounted) return;
    setState(() => _isAdmin = ok);
  }

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
              Text('燃灯', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: sText)),
              const SizedBox(height: 6),
              Text('版本 1.0.0', style: TextStyle(fontSize: 13, color: sTextHint)),
              const SizedBox(height: 14),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  '燃一盏灯，看见自己，照亮别人',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: sTextSec, height: 1.7),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.mail_outline,
                iconColor: sGold,
                title: '联系我们',
                subtitle: '邮箱：liyankun007@gmail.com',
              ),
              const SettingsDivider(),
              SettingsTile(
                icon: Icons.feedback_outlined,
                iconColor: sGold,
                title: '反馈问题',
                subtitle: '告诉我们你的建议或遇到的问题',
                onTap: () => _submitFeedback(context),
              ),
              const SettingsDivider(),
              SettingsTile(
                icon: Icons.favorite_border,
                iconColor: sGold,
                title: '初心',
                subtitle: '愿更多人亲近经典，修习佛法。',
              ),
              if (_isAdmin) ...[
                const SettingsDivider(),
                SettingsTile(
                  icon: Icons.admin_panel_settings_outlined,
                  iconColor: sGold,
                  title: '反馈管理',
                  subtitle: '查看用户提交的反馈',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const FeedbackAdminPage(),
                    ),
                  ),
                ),
                const SettingsDivider(),
                SettingsTile(
                  icon: Icons.groups_outlined,
                  iconColor: sGold,
                  title: '管理员',
                  subtitle: '管理管理员与发布公告',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AdminManagePage(),
                    ),
                  ),
                ),
              ],
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
          Text(
            '© 2026 燃灯 · 保留所有权利',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: sTextHint),
          ),
        ],
      ),
    );
  }

  /// 反馈入口：弹出输入框 → 提交到云端 feedbacks 集合。
  Future<void> _submitFeedback(BuildContext context) async {
    final content = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: sCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const SheetTextInput(
        title: '反馈问题',
        hint: '请描述你遇到的问题或建议…',
        maxLength: 1000,
        confirmText: '提交',
      ),
    );
    final text = content?.trim() ?? '';
    if (text.isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await CloudNotesService.instance.submitFeedback(text);
      messenger.showSnackBar(
        const SnackBar(content: Text('感谢反馈，我们会尽快处理'), duration: Duration(seconds: 2)),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('提交失败：$e'), duration: Duration(seconds: 2)),
      );
    }
  }
}
