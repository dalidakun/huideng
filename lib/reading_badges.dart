import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reading_time_service.dart';

import 'app_palette.dart';
/// 修学认证 · 读经徽章系统。
///
/// 依据「累计读经时长」点亮五枚徽章；帖子头部的「阅藏进度」百分比
/// 直接采用经藏页右上角「阅藏进度」的算法：标记完成阅读的经书册数 ÷ 全藏总册数。
/// 全藏共 8982 本、约 9463 万字，按常速研读 300 字/分钟约需 10000 小时。
const int kCanonTotalBooks = 8982;

/// 读毕全藏约需时长（秒）：10000 小时。
const int kCanonTotalSeconds = 10000 * 3600;

Color get _badgeText => AppPalette.p.text;
Color get _badgeTextSec => AppPalette.p.textSec;
Color get _badgeBg => AppPalette.p.bg;
Color get _badgeCard => AppPalette.p.card;
Color get _badgeGold => AppPalette.p.accent;
class ReadingBadge {
  final int level;
  final String title;
  final String name;
  final int hours;
  final IconData icon;
  final Color color;

  const ReadingBadge({
    required this.level,
    required this.title,
    required this.name,
    required this.hours,
    required this.icon,
    required this.color,
  });

  int get thresholdSeconds => hours * 3600;

  String get fullName => '$title · $name';
}

/// 五枚读经徽章：依阅读时长阶梯点亮。
final List<ReadingBadge> kReadingBadges = [
  ReadingBadge(
      level: 1, title: '一品', name: '初发心', hours: 20,
      icon: Icons.spa, color: Color(0xFF6FA96F)),
  ReadingBadge(
      level: 2, title: '二品', name: '闻薰', hours: 200,
      icon: Icons.local_florist, color: Color(0xFF5FA8C8)),
  ReadingBadge(
      level: 3, title: '三品', name: '思惟', hours: 1000,
      icon: Icons.wb_sunny, color: Color(0xFF7C8FE0)),
  ReadingBadge(
      level: 4, title: '四品', name: '行持', hours: 5000,
      icon: Icons.menu_book, color: Color(0xFFB08CD9)),
  ReadingBadge(
      level: 5, title: '五品', name: '通藏', hours: 10000,
      icon: Icons.auto_awesome, color: AppPalette.p.accent),
];

/// 当前已点亮的最高品阶（0 表示尚未点亮任何徽章）。
int readingLevelOf(int seconds) {
  var level = 0;
  for (final b in kReadingBadges) {
    if (seconds >= b.thresholdSeconds) level = b.level;
  }
  return level;
}

/// 主页头部的小字进度文案（如「阅藏0.01%」）。进度为 0 也显示（「阅藏0.00%」），
/// 与经藏页「阅藏进度」同源算法：完成册数 ÷ 全藏总册数，保留两位小数。
String canonPercentText(int read, int total) {
  if (total <= 0) return '阅藏0.00%';
  return '阅藏${(read / total * 100).toStringAsFixed(2)}%';
}

/// 纯百分比数值文案（如「0.01%」）：帖子行「@账户 · 0.01% · 时间戳」用，
/// 与经藏页右上角进度卡片保持一致（两位小数）。
String canonPercentOf(int read, int total) {
  if (total <= 0) return '0.00%';
  return '${(read / total * 100).toStringAsFixed(2)}%';
}

/// 帖子行的阅藏百分比：自己的帖子用本地实时统计（更及时），他人的用云端数据。
String postCanonPercent({
  required bool isSelf,
  required int cloudRead,
  required int cloudTotal,
}) {
  if (isSelf && LocalCanonProgress.loaded) {
    return canonPercentOf(LocalCanonProgress.read, LocalCanonProgress.total);
  }
  return canonPercentOf(cloudRead, cloudTotal);
}

/// 本地阅藏进度缓存：SyncService 周期统计本地 sutras_list.json 后写入，
/// 供「自己的帖子/主页」即时展示（不依赖云端上报延迟/是否已部署）。
class LocalCanonProgress {
  static int read = 0;
  static int total = 0;
  static bool loaded = false;

  /// 统计本地 sutras_list.json：已完成阅读册数与经书总册数。
  static Future<void> refresh() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (await f.exists()) {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is List) {
          total = decoded.length;
          read = decoded
              .whereType<Map>()
              .where((e) => e['isRead'] == true)
              .length;
        }
      }
    } catch (_) {
      // 统计失败时保持旧值，避免误清空已有进度。
    }
    loaded = true;
  }
}

/// 主页头部的「阅藏x%」小徽章：青色书图标 + 文案，点击进入徽章详情。
class ReadingProgressChip extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  const ReadingProgressChip({super.key, required this.text, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap ??
          () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BadgeDetailPage()),
              ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.menu_book, size: 12, color: Color(0xFF70867A)),
          const SizedBox(width: 2),
          Text(text,
              maxLines: 1,
              style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF70867A),
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

/// 昵称行右侧的徽章行：五枚小圆徽章，已点亮彩色、未点亮灰色。
/// [showLocked] 为 false 时只显示已点亮的徽章（无点亮则整体不展示），
/// 用于他人主页；[onTap] 为空时纯展示，否则点击进入徽章详情。
class ReadingBadgesRow extends StatelessWidget {
  final int seconds;
  final double size;
  final VoidCallback? onTap;
  final bool showLocked;
  const ReadingBadgesRow({
    super.key,
    required this.seconds,
    this.size = 22,
    this.onTap,
    this.showLocked = true,
  });

  @override
  Widget build(BuildContext context) {
    final level = readingLevelOf(seconds);
    final badges = showLocked
        ? kReadingBadges
        : [for (final b in kReadingBadges) if (b.level <= level) b];
    if (badges.isEmpty) return const SizedBox.shrink();
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final b in badges) ...[
          if (b.level > 1) const SizedBox(width: 4),
          BadgeDot(badge: b, unlocked: b.level <= level, size: size),
        ],
      ],
    );
    if (onTap == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: row,
    );
  }
}

/// 单枚徽章圆点：点亮时彩色 + 白图标，未点亮灰底 + 灰图标。
class BadgeDot extends StatelessWidget {
  final ReadingBadge badge;
  final bool unlocked;
  final double size;
  const BadgeDot({
    super.key,
    required this.badge,
    required this.unlocked,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: unlocked ? badge.color : AppPalette.p.borderSoft,
        border: unlocked
            ? null
            : Border.all(color: AppPalette.p.muted, width: 1),
      ),
      child: Icon(
        badge.icon,
        size: size * 0.56,
        color: unlocked ? Colors.white : AppPalette.p.muted,
      ),
    );
  }
}

/// 徽章详情页：今日/累积读经时长 + 五品徽章逐枚展示。
class BadgeDetailPage extends StatelessWidget {
  final int seconds;
  const BadgeDetailPage({super.key, this.seconds = 0});

  @override
  Widget build(BuildContext context) {
    final level = readingLevelOf(seconds);
    return Scaffold(
      backgroundColor: _badgeBg,
      appBar: AppBar(
        backgroundColor: _badgeBg,
        foregroundColor: _badgeText,
        elevation: 0,
        centerTitle: true,
        title: Text('修学徽章',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _badgeText)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _badgeCard,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                // 今日读经时长（与修学主页精读卡片同源数据）。
                ValueListenableBuilder<int>(
                  valueListenable: ReadingTimeService.instance.todaySeconds,
                  builder: (context, sec, _) => _TimeStatRow(
                    icon: Icons.timer_outlined,
                    label: '今日读经时长',
                    text: formatReadTime(sec),
                  ),
                ),
                const SizedBox(height: 10),
                // 累积读经时长。
                ValueListenableBuilder<int>(
                  valueListenable: ReadingTimeService.instance.totalSeconds,
                  builder: (context, sec, _) => _TimeStatRow(
                    icon: Icons.history,
                    label: '累积读经时长',
                    text: formatReadTime(sec),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          for (final b in kReadingBadges) ...[
            _BadgeLevelCard(
                badge: b, unlocked: b.level <= level, seconds: seconds),
            const SizedBox(height: 10),
          ],
          Text(
            '徽章依「累计读经时长」点亮，无法速成，唯有真实修学才能获得。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: _badgeTextSec),
          ),
        ],
      ),
    );
  }
}

/// 时长统计行：图标 + 名称 + 数值，与修学主页精读卡片样式一致。
class _TimeStatRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String text;
  const _TimeStatRow({
    required this.icon,
    required this.label,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: const Color(0xFF71867A)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(fontSize: 14, color: _badgeTextSec)),
        const Spacer(),
        Text(text,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: _badgeText)),
      ],
    );
  }
}

/// 读经时长格式化：不足 60 秒显示秒，否则按 分钟/小时 递进（与精读卡片一致）。
String formatReadTime(int seconds) {
  if (seconds < 60) return '$seconds秒';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes分钟';
  final hours = minutes ~/ 60;
  final rem = minutes % 60;
  return rem > 0 ? '$hours小时$rem分钟' : '$hours小时';
}

class _BadgeLevelCard extends StatelessWidget {
  final ReadingBadge badge;
  final bool unlocked;
  final int seconds;
  const _BadgeLevelCard({
    required this.badge,
    required this.unlocked,
    required this.seconds,
  });

  @override
  Widget build(BuildContext context) {
    final progress = seconds >= badge.thresholdSeconds
        ? 1.0
        : (seconds / badge.thresholdSeconds).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _badgeCard,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          BadgeDot(badge: badge, unlocked: unlocked, size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(badge.fullName,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: _badgeText)),
                    const SizedBox(width: 6),
                    if (unlocked)
                      const Icon(Icons.check_circle,
                          size: 15, color: Color(0xFF6FA96F)),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  unlocked ? '已点亮 · 累计读经 ${badge.hours} 小时' : '累计读经 ${badge.hours} 小时点亮',
                  style: TextStyle(fontSize: 12, color: _badgeTextSec),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: AppPalette.p.border,
                    valueColor: AlwaysStoppedAnimation<Color>(
                        unlocked ? badge.color : AppPalette.p.textHint),
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

/// 获得新徽章时弹恭喜窗口；无新徽章时不打扰。
/// 已展示过的品阶记录在本地，不重复弹出。
Future<void> maybeCelebrateNewBadge(BuildContext context, int seconds) async {
  final level = readingLevelOf(seconds);
  if (level <= 0) return;
  final prefs = await SharedPreferences.getInstance();
  final last = prefs.getInt('reading_badge_notified_level') ?? 0;
  if (level <= last) return;
  await prefs.setInt('reading_badge_notified_level', level);
  if (!context.mounted) return;
  final badge = kReadingBadges[level - 1];
  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: _badgeCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BadgeDot(badge: badge, unlocked: true, size: 64),
            const SizedBox(height: 14),
            Text('恭喜你获得新的徽章',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _badgeText)),
            const SizedBox(height: 6),
            Text(badge.fullName,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: _badgeGold)),
            const SizedBox(height: 6),
            Text('累计读经 ${badge.hours} 小时点亮，继续精进！',
                style: TextStyle(fontSize: 13, color: _badgeTextSec)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx),
                style: FilledButton.styleFrom(
                  backgroundColor: _badgeGold,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('好的',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
