import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:file_picker/file_picker.dart';

import 'settings_widgets.dart';

/// 资助：以温暖克制的随喜方式展示收款码，增强信任与资助意愿。
class DonatePage extends StatelessWidget {
  const DonatePage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: '资助',
      child: ListView(
        padding: const EdgeInsets.only(top: 6, bottom: 40),
        children: [
          _buildHero(),
          const SizedBox(height: 26),
          _sectionLabel('资助用途'),
          const SizedBox(height: 10),
          SettingsCard(
            children: [
              const _PurposeTile(
                icon: Icons.dns_outlined,
                title: '服务器与带宽',
                subtitle: '保障笔记与分享稳定访问',
              ),
              const SettingsDivider(),
              const _PurposeTile(
                icon: Icons.cloud_outlined,
                title: '云存储与数据库',
                subtitle: '安全保存您的每一份笔记',
              ),
              const SettingsDivider(),
              const _PurposeTile(
                icon: Icons.handyman_outlined,
                title: '持续开发维护',
                subtitle: '优化体验，更新经藏内容',
              ),
            ],
          ),
          const SizedBox(height: 26),
          _sectionLabel('随喜资助'),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildQrCard(
                context,
                image: 'assets/images/weixin.png',
                fileName: 'weixin_qr.png',
                label: '微信',
              ),
              const SizedBox(width: 14),
              _buildQrCard(
                context,
                image: 'assets/images/zhifubao.png',
                fileName: 'zhifubao_qr.png',
                label: '支付宝',
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              '打开微信 / 支付宝扫一扫即可转账，\n或长按收款码保存后付款。金额不限，随喜随心。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: sTextSec, height: 1.7),
            ),
          ),
          const SizedBox(height: 26),
          _buildBlessing(),
        ],
      ),
    );
  }

  Widget _buildHero() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF8E9CD), Color(0xFFFCF4E7)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: sCard,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset('assets/images/app_icon.png', fit: BoxFit.cover),
          ),
          const SizedBox(height: 14),
          const Text(
            '燃一盏灯 · 照一路人',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: sText),
          ),
          const SizedBox(height: 10),
          const Text(
            '燃灯由我一人独自维护。若它曾给您带来清净与欢喜，随喜资助即可——每一份心意，都将用于维持服务器与持续开发，化作照亮更多人前路的光。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: sTextSec, height: 1.8),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, color: sTextSec, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildQrCard(
    BuildContext context, {
    required String image,
    required String fileName,
    required String label,
  }) {
    return Expanded(
      child: SettingsCard(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 6),
            child: GestureDetector(
              onTap: () => _showFullScreen(context, image, fileName, label),
              onLongPress: () => _saveQr(context, image, fileName, label),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  image,
                  width: double.infinity,
                  height: 168,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 15, color: sText, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.download_outlined, size: 13, color: sTextHint),
              const SizedBox(width: 3),
              Text(
                '长按保存',
                style: TextStyle(fontSize: 11, color: Colors.green.withValues(alpha: 0.9)),
              ),
            ],
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }

  Widget _buildBlessing() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: [
          const Expanded(child: Divider(color: Color(0xFFE3D2BC))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              '随喜功德 · 感恩同行',
              style: TextStyle(fontSize: 13, color: sGold.withValues(alpha: 0.85), fontWeight: FontWeight.w600),
            ),
          ),
          const Expanded(child: Divider(color: Color(0xFFE3D2BC))),
        ],
      ),
    );
  }

  /// 长按保存收款码：优先原生保存对话框，失败则回退系统选择器与文档目录。
  Future<void> _saveQr(
    BuildContext context,
    String asset,
    String fileName,
    String label,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final Uint8List bytes;
    try {
      final data = await rootBundle.load(asset);
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('读取收款码失败，请稍后再试'), duration: Duration(seconds: 2)),
      );
      return;
    }

    try {
      final savedPath = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          data: bytes,
          fileName: fileName,
          mimeTypesFilter: const ['image/png'],
        ),
      );
      if (savedPath != null && savedPath.isNotEmpty) {
        _toast(messenger, '$label收款码已保存');
        return;
      }
    } catch (_) {
      // 继续尝试回退
    }

    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '保存$label收款码',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['png'],
      );
      if (savePath != null && !savePath.startsWith('content:')) {
        final file = File(savePath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        _toast(messenger, '$label收款码已保存');
        return;
      }
    } catch (_) {
      // 继续尝试回退
    }

    _toast(messenger, '保存未完成，可长按图片自行截取');
  }

  void _toast(ScaffoldMessengerState messenger, String text) {
    messenger.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  /// 全屏查看收款码：黑色背景大图展示，支持双指缩放。
  /// 点击任意处关闭，长按保存（与列表页一致）。
  void _showFullScreen(
    BuildContext context,
    String image,
    String fileName,
    String label,
  ) {
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.92),
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (context, animation, secondaryAnimation) {
          return GestureDetector(
            onTap: () => Navigator.pop(context),
            onLongPress: () => _saveQr(context, image, fileName, label),
            child: Dialog(
              backgroundColor: Colors.transparent,
              elevation: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InteractiveViewer(
                    maxScale: 5,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Image.asset(
                        image,
                        width: MediaQuery.sizeOf(context).width - 72,
                        height: MediaQuery.sizeOf(context).width - 72,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '$label收款码 · 点击图片关闭 · 长按保存',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PurposeTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _PurposeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: sGold.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: sGold, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 15, color: sText, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 12, color: sTextHint),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}