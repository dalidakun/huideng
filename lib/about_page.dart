import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'agreements.dart';
import 'app_palette.dart';
import 'cloud_notes_service.dart';
import 'admin_manage_page.dart';
import 'feedback_admin_page.dart';
import 'settings_widgets.dart';
import 'text_input_sheet.dart';
import 'update_service.dart';

/// 关于我们：应用简介、版本信息、协议入口。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  /// null 表示管理员身份还在确认：整页先不渲染，避免普通选项先出现、
  /// 管理员入口稍后补进来造成的跳动。
  bool? _isAdmin;
  String _version = '';
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    // 优先使用会话内已确认的结果（「我的」页会预热），有缓存时立即可见。
    _isAdmin = CloudNotesService.instance.cachedIsAdmin;
    _checkAdmin();
    _loadVersion();
  }

  /// 从包信息读取真实版本号（pubspec.yaml 的 version），不再硬编码。
  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _version = info.version);
    } catch (_) {}
  }

  Future<void> _checkAdmin() async {
    final ok = await CloudNotesService.instance.isAdmin(force: true);
    if (!mounted) return;
    setState(() => _isAdmin = ok);
  }

  /// 手动检查更新：与每周自动检查不同，这里给出明确结果反馈。
  Future<void> _manualCheckUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    final messenger = ScaffoldMessenger.of(context);
    final result = await UpdateService.checkDetailed();
    // 手动检查同样计入「上次检查时间」，避免自动检查紧接着又请求一次。
    await UpdateService.markCheckedNow();
    if (!mounted) return;
    setState(() => _checkingUpdate = false);
    final info = result.info;
    if (info != null) {
      await UpdateService.prompt(context, info);
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(result.error.isEmpty ? '当前已是最新版本' : result.error),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: '关于我们',
      child: _isAdmin == null
          ? Center(child: CircularProgressIndicator(color: sGold))
          : ListView(
              padding: const EdgeInsets.only(top: 14, bottom: 40),
              children: [
                SettingsCard(
                  children: [
                    // 图标在左，名称/版本/一句话在图标右侧竖排（与下方条目同 20 内边距）。
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppPalette.p.tintBg,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Image.asset('assets/images/app_icon.png',
                                fit: BoxFit.cover),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('燃灯',
                                    style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w700,
                                        color: sText)),
                                const SizedBox(height: 4),
                                Text(_version.isEmpty ? '' : '版本 $_version',
                                    style: TextStyle(
                                        fontSize: 13, color: sTextHint)),
                                // 与版本号贴紧一些，整块更紧凑。
                                const SizedBox(height: 2),
                                Text(
                                  '燃一盏灯，看见自己，照亮别人',
                                  style: TextStyle(
                                      fontSize: 14,
                                      color: sTextSec,
                                      height: 1.5),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                SettingsCard(
                  children: [
                    SettingsTile(
                      icon: Icons.feedback_outlined,
                      iconColor: sGold,
                      title: '反馈问题',
                      subtitle: '告诉我们你的建议或遇到的问题',
                      onTap: () => _submitFeedback(context),
                    ),
                    const SettingsDivider(),
                    SettingsTile(
                      icon: Icons.mail_outline,
                      iconColor: sGold,
                      title: '联系我们',
                      subtitle: '邮箱：liyankun007@gmail.com',
                    ),
                    if (_isAdmin == true) ...[
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
                // 协议入口：应用商店审核要求协议可在应用内随时再次查看。
                const SizedBox(height: 24),
                SettingsCard(
                  children: [
                    SettingsTile(
                      icon: Icons.description_outlined,
                      iconColor: sGold,
                      title: '用户服务协议',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AgreementViewerPage(
                            title: '用户服务协议',
                            assetPath: 'assets/agreements/user_agreement.md',
                          ),
                        ),
                      ),
                    ),
                    const SettingsDivider(),
                    SettingsTile(
                      icon: Icons.privacy_tip_outlined,
                      iconColor: sGold,
                      title: '隐私政策',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AgreementViewerPage(
                            title: '隐私政策',
                            assetPath: 'assets/agreements/privacy_policy.md',
                          ),
                        ),
                      ),
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
                      onPressed: _checkingUpdate ? null : _manualCheckUpdate,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: sGold,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _checkingUpdate
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('检查更新',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
                // 后台下载状态条：下载中显示实时进度，下载完成直接给出安装入口。
                ValueListenableBuilder<UpdateDownloadStatus>(
                  valueListenable: UpdateService.downloadStatus,
                  builder: (context, status, _) {
                    if (status.isIdle) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: _buildDownloadStatus(status),
                    );
                  },
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

  /// 后台下载状态条：让「点过下载之后到底在干嘛」一眼可见。
  ///
  /// 下载中显示实时进度（可取消）；下载完成给出「立即安装」；失败给出重试。
  Widget _buildDownloadStatus(UpdateDownloadStatus status) {
    final downloading = status.isDownloading;
    final completed = status.isCompleted;
    final versionText = status.version.isEmpty ? '' : ' v${status.version}';
    final title = downloading
        ? '正在后台下载新版本$versionText'
        : completed
            ? '新版本$versionText 已下载完成'
            : '新版本下载未完成';
    final subtitle = downloading
        ? '${status.percentText} · ${status.sizeText}'
        : completed
            ? '安装包已就绪，点击「立即安装」即可升级'
            : (status.error.isEmpty ? '请重新下载' : status.error);
    final icon = downloading
        ? Icons.downloading
        : completed
            ? Icons.download_done
            : Icons.error_outline;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
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
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: completed ? sGold : sTextSec),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: sText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 12, color: sTextHint),
                    ),
                  ],
                ),
              ),
              if (completed)
                TextButton(
                  onPressed: () => installDownloadedWithFeedback(context),
                  child: Text(
                    '立即安装',
                    style: TextStyle(
                      color: sGold,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else if (downloading)
                TextButton(
                  onPressed: () => UpdateService.cancelDownload(),
                  child: Text(
                    '取消',
                    style: TextStyle(color: sTextHint, fontSize: 13),
                  ),
                )
              else
                TextButton(
                  onPressed: _manualCheckUpdate,
                  child: Text(
                    '重试',
                    style: TextStyle(
                      color: sGold,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          if (downloading) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: status.total > 0 ? status.progress : null,
                minHeight: 4,
                backgroundColor: sGold.withValues(alpha: 0.15),
                color: sGold,
              ),
            ),
          ],
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
        const SnackBar(
            content: Text('感谢反馈，我们会尽快处理'), duration: Duration(seconds: 2)),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('提交失败：$e'), duration: Duration(seconds: 2)),
      );
    }
  }
}
