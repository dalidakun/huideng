import 'package:flutter/material.dart';

import 'settings_widgets.dart';

import 'app_palette.dart';
/// 经文阅读页「使用说明」：告诉用户阅读页的三个实用小技巧。
class ReadingGuidePage extends StatelessWidget {
  const ReadingGuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: '使用说明',
      child: ListView(
        padding: const EdgeInsets.only(top: 16, left: 16, right: 16, bottom: 32),
        children: const [
          _GuideBanner(),
          SizedBox(height: 20),
          _StepTitle(text: '阅读小技巧'),
          SizedBox(height: 10),
          _GuideCard(
            step: 1,
            icon: Icons.vertical_align_top,
            title: '双击标题回到开头',
            content: '在阅读页顶部，快速双击经文标题，即可直接回到经文开头位置，无需手动向上滑动。',
          ),
          _GuideCard(
            step: 2,
            icon: Icons.content_copy,
            title: '长按标题栏复制经文标题',
            content: '长按顶部经文标题，即可将经文标题复制到剪贴板；随后在 AI 输入框中粘贴，即可定位到该经文，借助 AI 讨论问题。',
          ),
          _GuideCard(
            step: 3,
            icon: Icons.mark_chat_read,
            title: '读完后标记完成',
            content: '读完这部经后，可在右上角「⋯」中选择「标记完成」，将其加入阅藏进度，留下一份精进的记录。',
          ),
          SizedBox(height: 12),
          _HelpNote(),
        ],
      ),
    );
  }
}

/// 顶部引导横幅：经书图标 + 页面说明。
class _GuideBanner extends StatelessWidget {
  const _GuideBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppPalette.p.gradTop, AppPalette.p.tintBg],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: sCard,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(Icons.menu_book, color: sGold, size: 32),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '经文阅读 · 使用说明',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: sText,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 6),
                Text(
                  '掌握以下三个小技巧，让读经更加顺畅',
                  style: TextStyle(fontSize: 13, color: sTextSec, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 栏目标题。
class _StepTitle extends StatelessWidget {
  final String text;
  const _StepTitle({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: sGold,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: sText,
          ),
        ),
      ],
    );
  }
}

/// 单条说明卡片：序号徽标 + 图标 + 标题 + 描述。
class _GuideCard extends StatelessWidget {
  final int step;
  final IconData icon;
  final String title;
  final String content;

  const _GuideCard({
    required this.step,
    required this.icon,
    required this.title,
    required this.content,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 18, 18, 18),
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: sGold,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$step',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 18, color: sGold),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: sText,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  content,
                  style: TextStyle(
                    fontSize: 14,
                    color: sTextSec,
                    height: 1.7,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部提示
class _HelpNote extends StatelessWidget {
  const _HelpNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sGold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.lightbulb_outline, size: 18, color: sGold),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '如在使用中遇到其他问题，可在「我的 → 反馈问题」中告诉我们。',
              style: TextStyle(fontSize: 13, color: sTextSec, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}