import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// 远程最新版本信息。
class UpdateInfo {
  final String version;
  final int versionCode;
  final String downloadPage;
  final String downloadUrl;
  final String notes;

  const UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.downloadPage,
    required this.downloadUrl,
    required this.notes,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      version: json['version'] as String? ?? '',
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      downloadPage: json['downloadPage'] as String? ?? '',
      downloadUrl: json['downloadUrl'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
    );
  }
}

/// App 更新检查服务。
///
/// 发布新版流程（需要一台能放静态文件的服务器/对象存储，本项目推荐
/// 腾讯云开发 CloudBase 静态托管）：
///  1. 构建新 APK，上传到静态托管，例如 `huideng/huideng_v1.0.1.apk`；
///  2. 上传 `huideng/download.html`（下载页，见 release/ 目录）；
///  3. 更新 `huideng/version.json` 中的版本号/链接/说明。
/// 用户打开 App 时会请求 [_checkUrl] 对比版本，发现新版则弹窗提示。
class UpdateService {
  UpdateService._();

  /// 版本检查接口地址（占位）：发布前请替换为真实静态托管域名，
  /// 并把 release/version.json 与 download.html、APK 一起上传到对应路径。
  static const String _checkUrl =
      'https://randeng-d8gs968w22a3d98e8.tcb.qcloud.la/huideng/version.json';

  /// 请求超时（秒）。
  static const int _timeoutSeconds = 8;

  /// 是否已检查过（每次启动只提示一次）。
  static bool _checked = false;

  /// 检查更新：有新版返回 [UpdateInfo]，无新版/失败返回 null。
  static Future<UpdateInfo?> check() async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: _timeoutSeconds);
      final request = await client.getUrl(Uri.parse(_checkUrl));
      final response = await request.close().timeout(
            const Duration(seconds: _timeoutSeconds),
          );
      if (response.statusCode != 200) {
        client.close();
        return null;
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: _timeoutSeconds));
      client.close();

      final info = UpdateInfo.fromJson(
        jsonDecode(body) as Map<String, dynamic>,
      );
      if (info.versionCode <= 0) return null;
      final current = await PackageInfo.fromPlatform();
      final currentCode = int.tryParse(current.buildNumber) ?? 0;
      if (info.versionCode <= currentCode) return null;
      return info;
    } catch (_) {
      return null;
    }
  }

  /// 启动时调用：静默检查，有新版本时弹窗提示。
  static Future<void> checkAndPrompt(BuildContext context) async {
    if (_checked) return;
    _checked = true;
    final info = await check();
    if (info == null) return;
    await prompt(context, info);
  }

  /// 展示更新弹窗（供「关于我们」页手动检查更新后调用）。
  static Future<void> prompt(BuildContext context, UpdateInfo info) {
    return _showUpdateDialog(context, info);
  }

  static Future<void> _showUpdateDialog(
    BuildContext context,
    UpdateInfo info,
  ) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final target = info.downloadPage.isNotEmpty
            ? info.downloadPage
            : info.downloadUrl;
        return AlertDialog(
          title: Text('发现新版本 v${info.version}'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (info.notes.isNotEmpty)
                  Text(
                    info.notes,
                    style: const TextStyle(fontSize: 13, height: 1.6),
                  )
                else
                  const Text('建议升级到最新版本，体验更佳。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('稍后再说'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await launchUrl(Uri.parse(target));
              },
              child: const Text('立即下载'),
            ),
          ],
        );
      },
    );
  }
}
