import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/sect_community_texts.dart';
import 'package:my_flutter_app/sect_page.dart';

void main() {
  test('20 个栏目在 kCommunityIntros 里都有非空社区介绍', () {
    final names = <String>{
      for (final s in kSectList) s.name,
      for (final g in kGateList) g.name,
    };
    expect(names, hasLength(20), reason: '八大宗派 + 十二法门');

    for (final name in names) {
      final intro = kCommunityIntros[name];
      expect(intro, isNotNull,
          reason: '缺少栏目「$name」的社区介绍，键名需与 SectInfo.name 逐字一致');
      expect(intro!.trim(), isNotEmpty, reason: '栏目「$name」的社区介绍为空');
      // 文案至少要能撑起两行，否则首页「展开全文」入口形同虚设。
      expect(intro.length, greaterThan(30), reason: '栏目「$name」介绍过短');
    }
  });

  test('没有多余的介绍键（键名拼错会漏出这里）', () {
    final names = <String>{
      for (final s in kSectList) s.name,
      for (final g in kGateList) g.name,
    };
    final extra = kCommunityIntros.keys.where((k) => !names.contains(k));
    expect(extra, isEmpty, reason: '多余的社区介绍键：$extra');
  });

  test('社区规则十条齐全', () {
    expect(kCommunityRuleIntro.trim(), isNotEmpty);
    expect(kCommunityRules, hasLength(10));
    for (final r in kCommunityRules) {
      expect(r.title.trim(), isNotEmpty);
      expect(r.body.trim(), isNotEmpty, reason: '规则「${r.title}」正文为空');
    }
    expect(kCommunityRules.map((r) => r.title).toSet(), hasLength(10),
        reason: '规则标题应互不重复');
  });
}
