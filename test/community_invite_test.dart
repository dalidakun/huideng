import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/community_invite.dart';
import 'package:my_flutter_app/sect_community_texts.dart';
import 'package:my_flutter_app/sect_page.dart';

void main() {
  /// 八大宗派 + 十二法门的名字，键名必须与 `SectInfo.name` 逐字一致。
  final names = <String>{
    for (final s in kSectList) s.name,
    for (final g in kGateList) g.name,
  };

  test('20 个栏目各有唯一 slug，且 slug 是小写 URL 文件名', () {
    expect(names, hasLength(20), reason: '八大宗派 + 十二法门');

    final slugs = kCommunityInviteSlugs.values.toList();
    for (final name in names) {
      final slug = kCommunityInviteSlugs[name];
      expect(slug, isNotNull, reason: 'community_invite.dart 缺少「$name」的 slug');
      expect(slug, matches(RegExp(r'^[a-z]+$')),
          reason: '栏目「$name」的 slug $slug 只能是小写字母');
    }
    expect(kCommunityInviteSlugs, hasLength(20), reason: '多余的 slug 键');
    expect(slugs.toSet(), hasLength(slugs.length), reason: 'slug 有重复');
  });

  test('落地页地址指向 community/<slug>.html，未知栏目退回下载页', () {
    for (final name in names) {
      final url = communityInviteUrl(name);
      expect(url,
          '$kCommunityInviteBase/community/${kCommunityInviteSlugs[name]}.html',
          reason: '栏目「$name」的落地页地址不对：$url');
    }
    expect(communityInviteUrl('不存在的栏目'), '$kCommunityInviteBase/download.html');
    expect(communityInviteUrl(''), '$kCommunityInviteBase/download.html');
  });

  test('分享文案是两行：首句 + 点击查看——>链接', () {
    for (final name in names) {
      final text = communityShareText(name);
      final lines = text.split('\n');
      expect(lines, hasLength(2), reason: '栏目「$name」的分享文案不是两行：$text');

      expect(lines[0], '我发现了一个「$name」社区：'
          '${kCommunityIntros[name]!.split(RegExp(r'[。\n]')).first.trim()}。',
          reason: '栏目「$name」分享文案第一行不对：${lines[0]}');
      expect(lines[1], '点击查看——>${communityInviteUrl(name)}',
          reason: '栏目「$name」分享文案第二行不对：${lines[1]}');
      expect(text, isNot(contains('来自【燃灯】')),
          reason: '旧版多行分享文案残留');
    }
  });

  test('净土宗分享文案与产品要求逐字一致', () {
    const base = 'https://randeng-d8gs968w22a3d98e8-1461892767'
        '.tcloudbaseapp.com/huideng';
    expect(
      communityShareText('净土宗'),
      '我发现了一个「净土宗」社区：以信愿念佛、求生净土为主要修行方向，'
      '强调以念佛摄心、培植善根。\n'
      '点击查看——>$base/community/jingtuzong.html',
    );
  });

  test('kCommunityInviteBase 与 site/site.config.json 的 baseUrl 一致', () {
    final config = jsonDecode(File('site/site.config.json').readAsStringSync())
        as Map<String, dynamic>;
    expect(config['baseUrl'], kCommunityInviteBase,
        reason: '站点地址改了，请同步 lib/community_invite.dart');
  });
}
