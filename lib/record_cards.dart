import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'record_index.dart';
import 'sutra_underline.dart';

/// 记录卡片：三种记录各用各的版式，分别对齐读经页速览面板里
/// 「画线 / 感想 / 笔记」三个汇总页的既有样式，不做成统一卡片。
///
/// - 画线：平铺卡 + 逐行点线（对齐「画线归集」页）
/// - 感想：经文引用 + 浅色感想气泡（对齐「感想」页）
/// - 笔记：带阴影的卡 + 正文 + 底部时间/分享状态行（对齐「读经笔记」页）
///
/// 与汇总页的差别：卡片只读（无 AI译 / 复制 / 删除），顶部多一行
/// 「类型 + 经名 + 时间」用于时间线溯源。

/// 感想正文色：三页统一使用的深绿，两种外观下保持一致。
const Color _thoughtColor = Color(0xFF3D5C3A);

/// 感想气泡底色：米黄外观沿用汇总页的暖灰，素白外观改同色系冷灰。
Color get _thoughtBubble {
  return AppPalette.instance.isPlain
      ? const Color(0xFFF1F4F1)
      : const Color(0xFFF3F0EA);
}

/// 卡片顶部一行：类型标记 + 经名 + 时间。
class RecordCardHead extends StatelessWidget {
  const RecordCardHead({
    super.key,
    required this.type,
    required this.sutraName,
    required this.timeText,
    this.footnote,
    this.showTime = true,
  });

  final RecordType type;
  final String sutraName;
  final String timeText;

  /// 笔记卡的时间显示在底部状态行，顶部不再重复。
  final bool showTime;

  /// 角标补充说明（如「已分享」「原文待补全」）。
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final accent = p.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _typeMark(type, accent),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              sutraName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 17,
                height: 1.3,
                // 经名是纯黑标题，不随外观变灰。
                color: Colors.black,
                // 经名加粗，一眼看清是哪部经的记录。
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if ((footnote ?? '').isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              footnote!,
              style: TextStyle(fontSize: 13, height: 1.3, color: p.textHint),
            ),
          ],
          const SizedBox(width: 8),
          if (showTime)
            Text(
              timeText,
              style: TextStyle(fontSize: 13, height: 1.3, color: p.textHint),
            ),
        ],
      ),
    );
  }

  Widget _typeMark(RecordType type, Color accent) {
    switch (type) {
      case RecordType.highlight:
        return markPill('画线', accent);
      case RecordType.thought:
        return markPill('感想', accent);
      case RecordType.note:
        return markPill('笔记', accent);
    }
  }
}

/// 类型标记药丸：浅色底 + 深绿字。「画线 / 感想 / 笔记 / 经文」共用同一款样式。
Widget markPill(String label, Color accent) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: accent.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 12,
        height: 1.3,
        fontWeight: FontWeight.w600,
        color: _thoughtColor,
      ),
    ),
  );
}

/// 画线条：平铺卡 + 逐行点线，无折叠。
class HighlightRecordCard extends StatelessWidget {
  const HighlightRecordCard({
    super.key,
    required this.item,
    required this.sutraName,
    required this.timeText,
  });

  final RecordItem item;

  /// 已统一成「经名 + 卷X」的显示名（由记录页解析后传入）。
  final String sutraName;
  final String timeText;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final text = item.text.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RecordCardHead(
            type: RecordType.highlight,
            sutraName: sutraName,
            timeText: timeText,
            footnote: text.isEmpty ? '原文待补全' : null,
          ),
          if (text.isEmpty)
            // 云端回填的画线没有段落原文（接口不返回），只标出位置。
            Text(
              '第 ${item.para + 1} 段的一处画线',
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: p.textHint,
              ),
            )
          else
            SutraUnderlineText(
              text: text,
              style: TextStyle(
                fontSize: 14,
                // 画线是经文原文，行距放宽（与读经页 1.8 接近）便于阅读。
                height: 1.9,
                color: p.text,
              ),
              lineColor: p.accent.withValues(alpha: 0.8),
            ),
        ],
      ),
    );
  }
}

/// 感想条：上方经文引用（长文 3 行折叠），下方浅色感想气泡（120 字折叠）。
class ThoughtRecordCard extends StatelessWidget {
  const ThoughtRecordCard({
    super.key,
    required this.item,
    required this.sutraName,
    required this.timeText,
    required this.paraExpanded,
    required this.noteExpanded,
    this.onTogglePara,
    this.onToggleNote,
  });

  final RecordItem item;

  /// 已统一成「经名 + 卷X」的显示名（由记录页解析后传入）。
  final String sutraName;
  final String timeText;
  final bool paraExpanded;
  final bool noteExpanded;
  final VoidCallback? onTogglePara;
  final VoidCallback? onToggleNote;

  /// 经文折叠阈值（与「感想」页一致）。
  static const int paraFoldThreshold = 60;

  /// 感想折叠阈值（与「感想」页一致）。
  static const int noteFoldThreshold = 120;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final accent = p.accent;
    final para = item.paraText.trim();
    final note = item.text.trim();
    final paraLong = para.length > paraFoldThreshold;
    final noteLong = note.length > noteFoldThreshold;
    final shownNote = noteLong && !noteExpanded
        ? '${note.substring(0, noteFoldThreshold)}…'
        : note;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RecordCardHead(
              type: RecordType.thought,
              sutraName: sutraName,
              timeText: timeText,
              footnote: para.isEmpty ? '原文待补全' : null,
            ),
            if (para.isNotEmpty) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 3, right: 8),
                    child: markPill('经文', accent),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          para,
                          maxLines: paraLong && !paraExpanded ? 3 : null,
                          overflow: paraLong && !paraExpanded
                              ? TextOverflow.ellipsis
                              : TextOverflow.visible,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.6,
                            color: p.text,
                          ),
                        ),
                        if (paraLong)
                          _foldLink(
                            expanded: paraExpanded,
                            onTap: onTogglePara,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: _thoughtBubble,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shownNote,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: _thoughtColor,
                    ),
                  ),
                  if (noteLong)
                    _foldLink(expanded: noteExpanded, onTap: onToggleNote),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 笔记条：带阴影的卡 + 正文 + 底部时间 / 分享状态行。
class SutraNoteRecordCard extends StatelessWidget {
  const SutraNoteRecordCard({
    super.key,
    required this.item,
    required this.sutraName,
    required this.timeText,
    required this.expanded,
    this.onToggleExpand,
  });

  final RecordItem item;

  /// 已统一成「经名 + 卷X」的显示名（由记录页解析后传入）。
  final String sutraName;
  final String timeText;
  final bool expanded;
  final VoidCallback? onToggleExpand;

  /// 折叠阈值（与「读经笔记」页一致）。
  static const int foldThreshold = 120;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final body = item.text.trim();
    final isLong = body.length > foldThreshold;
    final shown =
        isLong && !expanded ? '${body.substring(0, foldThreshold)}…' : body;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RecordCardHead(
              type: RecordType.note,
              sutraName: sutraName.isEmpty ? '未标注经名' : sutraName,
              timeText: timeText,
              showTime: false,
            ),
            Text(
              shown,
              style: TextStyle(
                fontSize: 14,
                height: 1.7,
                color: p.text,
              ),
            ),
            if (isLong)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onToggleExpand,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    expanded ? '折叠' : '展开',
                    style: TextStyle(
                      fontSize: 14,
                      color: p.accent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.access_time, size: 13, color: p.textHint),
                const SizedBox(width: 4),
                Text(
                  timeText,
                  style: TextStyle(fontSize: 12, color: p.textHint),
                ),
                const Spacer(),
                Icon(
                  item.shared ? Icons.cloud_done : Icons.cloud_off,
                  size: 13,
                  color: item.shared
                      ? const Color(0xFF71867A)
                      : p.textHint.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 4),
                Text(
                  item.shared ? '已分享' : '未分享',
                  style: TextStyle(
                    fontSize: 12,
                    color: item.shared
                        ? const Color(0xFF71867A)
                        : p.textHint.withValues(alpha: 0.7),
                    fontWeight:
                        item.shared ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 展开 / 收起链接（与「感想」页一致：文字 + 箭头）。
Widget _foldLink({
  required bool expanded,
  required VoidCallback? onTap,
  String? label,
}) {
  final p = AppPalette.p;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label ?? (expanded ? '收起' : '展开'),
            style: TextStyle(
              fontSize: 14,
              color: p.accent,
              fontWeight: FontWeight.w500,
            ),
          ),
          Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
            color: p.accent,
          ),
        ],
      ),
    ),
  );
}

/// 时间线日期分组头。
class RecordDateHeader extends StatelessWidget {
  const RecordDateHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: p.textSec,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Divider(color: p.divider, height: 1, thickness: 0.8),
          ),
        ],
      ),
    );
  }
}
