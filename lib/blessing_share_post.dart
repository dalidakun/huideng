import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'blessing_page.dart';
import 'blessing_service.dart';

/// 菩提空间里的「为众祈福」分享帖。
///
/// 正文格式（见 [blessingShareContent]）：
///   【为众祈福】事由
///   回向：...
///   <空行>
///   §§BL§§ + base64(JSON 元数据)
///   <空行>
///   用户备注
/// 渲染时先显示备注，再显示可点击的祈福卡片（无边框、背景色块）。
class BlessingSharePost {
  final String projectId;
  final String title;
  final String target;
  final String dedication;
  final int totalDays;
  final int joinerCount;
  final String status;
  final List<String> methods;
  final String remark;

  const BlessingSharePost({
    this.projectId = '',
    this.title = '',
    this.target = '',
    this.dedication = '',
    this.totalDays = 0,
    this.joinerCount = 0,
    this.status = '',
    this.methods = const [],
    this.remark = '',
  });

  bool get isClosed => status == 'closed';

  static bool isBlessingShare(String content) =>
      content.contains(kBlessingShareMetaPrefix);

  static BlessingSharePost? parse(String content) {
    if (content.isEmpty || !content.contains(kBlessingShareMetaPrefix)) {
      return null;
    }
    final trimmed = content.trimRight();
    final metaIdx = trimmed.indexOf(kBlessingShareMetaPrefix);
    if (metaIdx < 0) return null;
    final metaLine =
        trimmed.substring(metaIdx + kBlessingShareMetaPrefix.length);
    final firstNl = metaLine.indexOf('\n');
    final metaSection =
        firstNl >= 0 ? metaLine.substring(0, firstNl) : metaLine;
    final remark = firstNl >= 0 ? metaLine.substring(firstNl + 1).trim() : '';

    Map<String, dynamic>? data;
    try {
      final decoded = utf8.decode(base64Decode(metaSection.trim()));
      final raw = jsonDecode(decoded);
      if (raw is Map) data = raw.cast<String, dynamic>();
    } catch (_) {}
    if (data == null) return null;

    final methods = <String>[];
    final rawMethods = data['methods'];
    if (rawMethods is List) {
      for (final it in rawMethods) {
        final text = it.toString().trim();
        if (text.isNotEmpty) methods.add(text);
      }
    }

    return BlessingSharePost(
      projectId: (data['id'] ?? '').toString(),
      title: (data['title'] ?? '').toString(),
      target: (data['target'] ?? '').toString(),
      dedication: (data['dedication'] ?? '').toString(),
      totalDays: int.tryParse('${data['totalDays']}') ?? 0,
      joinerCount: int.tryParse('${data['joinerCount']}') ?? 0,
      status: (data['status'] ?? '').toString(),
      methods: methods,
      remark: remark,
    );
  }
}

/// 祈福分享帖渲染组件：备注 + 祈福卡片。
class BlessingSharePostView extends StatelessWidget {
  final BlessingSharePost post;

  const BlessingSharePostView({super.key, required this.post});

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (post.remark.isNotEmpty) ...[
          Text(
            post.remark,
            style: TextStyle(
              fontSize: 15,
              color: p.text,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 10),
        ],
        _buildCard(context, p),
      ],
    );
  }

  Widget _buildCard(BuildContext context, PaletteData p) {
    final radius = BorderRadius.circular(12);
    final canOpen = post.projectId.isNotEmpty;
    return Material(
      color: p.tintBg,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        onTap: canOpen
            ? () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BlessingDetailPage(id: post.projectId),
                  ),
                );
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      Icons.volunteer_activism_outlined,
                      size: 14,
                      color: p.accentDeep,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '为众祈福',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: p.accentDeep,
                    ),
                  ),
                  if (post.isClosed) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: p.accent.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '已圆满',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: p.accentDeep,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (post.joinerCount > 0)
                    Text(
                      '${post.joinerCount} 人祈福',
                      style: TextStyle(fontSize: 11.5, color: p.textHint),
                    ),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: p.textHint,
                  ),
                ],
              ),
              if (post.title.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  post.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                    height: 1.4,
                  ),
                ),
              ],
              if (post.target.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  '回向：${post.target}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: p.textSec,
                    height: 1.4,
                  ),
                ),
              ],
              if (post.totalDays > 0 || post.methods.isNotEmpty) ...[
                const SizedBox(height: 9),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (post.totalDays > 0)
                      _buildTag(p, '共修 ${post.totalDays} 天'),
                    for (final m in post.methods.take(2)) _buildTag(p, m),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTag(PaletteData p, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: p.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: p.accentDeep),
      ),
    );
  }
}
