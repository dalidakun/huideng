// 社区分享落地页：slug 表、落地页地址、系统分享文案。
//
// 落地页是官网静态站里的一组页面（`site/community.template.html` 渲染成
// `community/<slug>.html`），由 `tools/build_site.py` 生成——那边直接解析
// 本文件的 kCommunityInviteSlugs 与 `sect_community_texts.dart` 的
// kCommunityIntros，所以这两处就是唯一真源，改完跑一次构建脚本即可。
// 页面上的「打开 燃灯」按钮把访客带到下载页。
import 'sect_community_texts.dart';

/// 静态站 baseUrl：与 site/site.config.json 的 `baseUrl` 逐字一致，
/// 由 test/community_invite_test.dart 对照校验（改站点地址两处一起动）。
const String kCommunityInviteBase =
    'https://randeng-d8gs968w22a3d98e8-1461892767.tcloudbaseapp.com/huideng';

/// 20 个栏目社区的落地页 slug：键 = `SectInfo.name`，值 = 页面文件名。
///
/// 八大宗派取可读拼音（净土宗与净土法门靠 `jingtuzong` / `jingtu` 区分），
/// 十二法门沿用图标切图的拼音码。新增栏目时这里补一行，
/// 再跑 `python tools/build_site.py --sync` 就会多出一页。
const Map<String, String> kCommunityInviteSlugs = {
  // ── 八大宗派 ──
  '禅宗': 'chan',
  '净土宗': 'jingtuzong',
  '天台宗': 'tiantai',
  '华严宗': 'huayan',
  '密宗': 'mizong',
  '律宗': 'lvzong',
  '法相宗': 'faxiang',
  '三论宗': 'sanlun',
  // ── 十二法门 ──
  '地藏法门': 'dizang',
  '观世音法门': 'guanyin',
  '药师法门': 'yaoshi',
  '弥勒法门': 'mile',
  '净土法门': 'jingtu',
  '般若法门': 'bore',
  '楞严法门': 'lengyan',
  '普贤行愿法门': 'puxianxingyuan',
  '拜忏法门': 'baichan',
  '施食法门': 'shishi',
  '四念处法门': 'sinianchu',
  '头陀法门': 'toutuo',
};

/// [name] 栏目的落地页完整地址；查不到 slug 时退回下载页（链接永不落空）。
String communityInviteUrl(String name) {
  final slug = kCommunityInviteSlugs[name];
  if (slug == null || slug.isEmpty) return '$kCommunityInviteBase/download.html';
  return '$kCommunityInviteBase/community/$slug.html';
}

/// 系统分享文案，两行：
///
/// ```text
/// 我发现了一个「净土宗」社区：以信愿念佛、求生净土为主要修行方向……。
/// 点击查看——><落地页地址>
/// ```
///
/// 第一行 = [kCommunityIntros] 该栏目的首句（到第一个句号为止）。
String communityShareText(String name) {
  final intro = (kCommunityIntros[name] ?? '').trim();
  final first = intro.split(RegExp(r'[。\n]')).first.trim();
  final lead = first.isEmpty ? '' : '$first。';
  final head = lead.isEmpty
      ? '我发现了一个「$name」社区'
      : '我发现了一个「$name」社区：$lead';
  return '$head\n点击查看——>${communityInviteUrl(name)}';
}
