import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'cloud_notes_service.dart';

/// 人天利益分享帖的结构化标记；后接 base64(JSON) 元数据。
const String kBenefitShareMetaPrefix = '§§BT§§';

/// 组装一条人天利益分享到菩提空间的正文。
///
/// 末尾用 [kBenefitShareMetaPrefix] 附带卡片所需的完整数据，
/// 标记行之后的文本为用户备注，渲染时显示在人天利益卡片上方。
String benefitShareContent(
  String paragraph, {
  String remark = '',
  String targetType = '',
  String targetName = '',
  String targetKey = '',
}) {
  final note = remark.trim();
  final data = <String, dynamic>{
    'paragraph': paragraph,
    if (targetType.isNotEmpty) 'targetType': targetType,
    if (targetName.isNotEmpty) 'targetName': targetName,
    if (targetKey.isNotEmpty) 'targetKey': targetKey,
  };
  final meta = base64Encode(utf8.encode(jsonEncode(data)));
  final lines = <String>[
    '【人天利益】',
    paragraph,
    '',
    '$kBenefitShareMetaPrefix$meta',
    if (note.isNotEmpty) '',
    if (note.isNotEmpty) note,
  ];
  return lines.join('\n');
}

/// 分享一段人天利益到菩提空间，返回云端帖子 id。
Future<String> shareBenefitToBodhiSpace(
  String paragraph, {
  String remark = '',
  String targetType = '',
  String targetName = '',
  String targetKey = '',
}) {
  return CloudNotesService.instance.publishNote(
    title: '人天利益',
    content: benefitShareContent(
      paragraph,
      remark: remark,
      targetType: targetType,
      targetName: targetName,
      targetKey: targetKey,
    ),
  );
}

/// 菩提空间里的「人天利益」分享帖：备注 + 人天利益卡片。
class BenefitSharePost {
  final String paragraph;
  final String remark;

  /// 分享来源：'entry' = 佛号，'mantra' = 神咒。
  final String targetType;
  final String targetName;
  final String targetKey;

  const BenefitSharePost({
    this.paragraph = '',
    this.remark = '',
    this.targetType = '',
    this.targetName = '',
    this.targetKey = '',
  });

  bool get hasTarget =>
      targetName.isNotEmpty &&
      (targetType == 'entry' || targetType == 'mantra');

  static bool isBenefitShare(String content) =>
      content.contains(kBenefitShareMetaPrefix);

  static BenefitSharePost? parse(String content) {
    if (content.isEmpty || !content.contains(kBenefitShareMetaPrefix)) {
      return null;
    }
    final trimmed = content.trimRight();
    final metaIdx = trimmed.indexOf(kBenefitShareMetaPrefix);
    if (metaIdx < 0) return null;
    final metaLine =
        trimmed.substring(metaIdx + kBenefitShareMetaPrefix.length);
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

    return BenefitSharePost(
      paragraph: (data['paragraph'] ?? '').toString(),
      remark: remark,
      targetType: (data['targetType'] ?? '').toString(),
      targetName: (data['targetName'] ?? '').toString(),
      targetKey: (data['targetKey'] ?? '').toString(),
    );
  }
}

/// 人天利益分享帖渲染组件：备注 + 内容卡片。
class BenefitSharePostView extends StatelessWidget {
  final BenefitSharePost post;

  /// 点击卡片：打开分享来源对应的佛号 / 神咒抽屉。
  final VoidCallback? onTap;

  const BenefitSharePostView({super.key, required this.post, this.onTap});

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
        _buildCard(p),
      ],
    );
  }

  Widget _buildCard(PaletteData p) {
    final radius = BorderRadius.circular(12);
    return Material(
      color: p.tintBg,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Text.rich(
            TextSpan(
              children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: p.accentDeep.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '人天利益',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        color: p.accentDeep,
                      ),
                    ),
                  ),
                ),
                const TextSpan(text: '  '),
                TextSpan(text: post.paragraph),
              ],
            ),
            style: TextStyle(fontSize: 15, color: p.text, height: 1.8),
          ),
        ),
      ),
    );
  }
}
