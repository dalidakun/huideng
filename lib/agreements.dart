import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_widgets.dart';

/// 《用户协议》与《隐私政策》首次启动同意管理。
///
/// 华为等国内应用商店要求：首次启动必须弹出协议，用户同意前不得进行任何
/// 联网采集（main.dart 据此决定是否启动登录恢复/云同步等服务）。
class PrivacyConsent {
  PrivacyConsent._();

  static const String _prefsKey = 'privacy_agreed_version';

  /// 协议版本号：协议内容发生重大变更时 +1，已同意旧版的用户会重新看到弹窗。
  static const int currentVersion = 1;

  /// 用户是否已同意当前版本的协议。
  static Future<bool> isAgreed() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_prefsKey) ?? 0) >= currentVersion;
  }

  /// 记录用户已同意。
  static Future<void> agree() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKey, currentVersion);
  }
}

/// 应用内查看协议全文的页面：从 assets/agreements/ 加载 Markdown 文本，
/// 做轻量渲染（标题加粗放大、列表缩进），无需第三方 Markdown 库。
class AgreementViewerPage extends StatefulWidget {
  final String title;
  final String assetPath;

  const AgreementViewerPage({
    super.key,
    required this.title,
    required this.assetPath,
  });

  @override
  State<AgreementViewerPage> createState() => _AgreementViewerPageState();
}

class _AgreementViewerPageState extends State<AgreementViewerPage> {
  Future<String>? _content;

  @override
  void initState() {
    super.initState();
    _content = rootBundle.loadString(widget.assetPath);
  }

  /// 把一行 Markdown 文本转成展示 Widget。
  Widget _buildLine(String raw) {
    // 去掉行内加粗标记 **，纯文本展示。
    final line = raw.replaceAll('**', '').trimRight();
    if (line.isEmpty) return const SizedBox(height: 8);
    if (line.startsWith('# ')) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          line.substring(2).trim(),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: sText,
            height: 1.4,
          ),
        ),
      );
    }
    if (line.startsWith('## ')) {
      return Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Text(
          line.substring(3).trim(),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: sText,
            height: 1.4,
          ),
        ),
      );
    }
    final isBullet = line.startsWith('- ') || RegExp(r'^\d+\.\s').hasMatch(line);
    return Padding(
      padding: EdgeInsets.only(left: isBullet ? 10 : 0, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isBullet)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: sTextHint,
                ),
              ),
            ),
          if (isBullet) const SizedBox(width: 8),
          Expanded(
            child: Text(
              isBullet ? line.replaceFirst(RegExp(r'^-\s'), '') : line,
              style: TextStyle(
                fontSize: 14,
                color: sTextSec,
                height: 1.65,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: widget.title,
      child: FutureBuilder<String>(
        future: _content,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: sCard,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children:
                      snap.data!.split('\n').map(_buildLine).toList(growable: false),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 首次启动的协议同意页：未同意前它是应用的根页面，
/// 点「同意并继续」才进入应用并启动后台服务。
class PrivacyConsentPage extends StatelessWidget {
  final VoidCallback onAgreed;

  const PrivacyConsentPage({super.key, required this.onAgreed});

  Future<void> _openAgreement(BuildContext context, String title, String asset) {
    return Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AgreementViewerPage(title: title, assetPath: asset)),
    );
  }

  void _onDisagree(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: sCard,
        title: Text('温馨提示', style: TextStyle(color: sText)),
        content: Text(
          '不同意《用户协议》和《隐私政策》将无法使用本应用。'
          '\n\n点击「仍不同意」将退出应用。',
          style: TextStyle(color: sTextSec, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () {
              // 退出应用（Android 上 SystemNavigator.pop 会结束 Activity）。
              SystemNavigator.pop();
            },
            child: Text('仍不同意', style: TextStyle(color: sTextHint)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('重新查看', style: TextStyle(color: sGold, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: sBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const Spacer(flex: 1),
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: sCard,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.asset('assets/images/app_icon.png', fit: BoxFit.cover),
              ),
              const SizedBox(height: 18),
              Text(
                '欢迎使用燃灯',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: sText),
              ),
              const SizedBox(height: 8),
              Text(
                '燃一盏灯，看见自己，照亮别人',
                style: TextStyle(fontSize: 14, color: sTextSec),
              ),
              const SizedBox(height: 32),
              Align(
                alignment: Alignment.centerLeft,
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 14, color: sTextSec, height: 1.7),
                    children: [
                      const TextSpan(text: '为了更好地保障你的合法权益，请阅读并同意以下协议'),
                      WidgetSpan(
                        child: GestureDetector(
                          onTap: () => _openAgreement(
                            context,
                            '用户服务协议',
                            'assets/agreements/user_agreement.md',
                          ),
                          child: Text('《用户协议》',
                              style: TextStyle(fontSize: 14, color: sGold, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const TextSpan(text: '和'),
                      WidgetSpan(
                        child: GestureDetector(
                          onTap: () => _openAgreement(
                            context,
                            '隐私政策',
                            'assets/agreements/privacy_policy.md',
                          ),
                          child: Text('《隐私政策》',
                              style: TextStyle(fontSize: 14, color: sGold, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const TextSpan(
                          text: '，我们将在你同意后开始提供云同步、账号登录等服务。'),
                    ],
                  ),
                ),
              ),
              const Spacer(flex: 2),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () async {
                    await PrivacyConsent.agree();
                    onAgreed();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: sGold,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('同意并继续',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: TextButton(
                  onPressed: () => _onDisagree(context),
                  style: TextButton.styleFrom(
                    foregroundColor: sTextHint,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('不同意', style: TextStyle(fontSize: 15)),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
