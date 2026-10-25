import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/post_share.dart';

void main() {
  test('帖子分享链接是 /post/<id>.html', () {
    expect(postShareUrl('abc123'), '$kPostShareBase/post/abc123.html');
    expect(postShareText('abc123'), postShareUrl('abc123'));
  });

  test('帖子 id 会做 URL 编码', () {
    expect(postShareUrl('a b&c'), '$kPostShareBase/post/a%20b%26c.html');
  });

  test('帖子 id 为空时退回下载页', () {
    expect(postShareUrl('  '), '$kPostShareBase/download.html');
  });

  test('分享文案只有链接（掺字会丢掉微信链接卡片）', () {
    final text = postShareText('abc123');
    expect(text, isNot(contains('\n')));
    expect(text, startsWith('http'));
  });

  test('祈福分享链接与帖子同一条 /post/<id>.html 路径', () {
    expect(blessingShareUrl('p1'), '$kPostShareBase/post/p1.html');
    expect(blessingShareText('p1'), blessingShareUrl('p1'));
    expect(blessingShareUrl('  '), '$kPostShareBase/download.html');
  });

  test('祈福详情页三点菜单：分享到…… / 转发到菩提空间', () {
    final page = File('lib/blessing_page.dart').readAsStringSync();
    expect(page, contains('blessingShareText('));
    expect(page, contains('SharePlus.instance.share'));
    // 恢复三个点，两个动作都收进菜单里
    expect(page, contains('Icons.more_horiz'));
    expect(page, contains('分享到……'));
    expect(page, contains('转发到菩提空间'));
    // 菜单项不带图标（避免图标与文字颜色不一致）：菜单里只有 icon 那一个 more_horiz
    expect(page, isNot(contains('_barIcon')));
    expect(page, isNot(contains('Icons.share_rounded')));
    // 三个点不要贴着屏幕右缘
    expect(page, contains('EdgeInsets.only(right: 12)'));
  });

  test('主页祈福卡片不再有分享图标', () {
    final hub = File('lib/study_hub_page.dart').readAsStringSync();
    expect(hub, isNot(contains('_blessingShareButton')));
    expect(hub, isNot(contains('_shareBlessing(')));
  });

  test('kPostShareBase 与 site/site.config.json 的 baseUrl 一致', () {
    final config = jsonDecode(File('site/site.config.json').readAsStringSync())
        as Map<String, dynamic>;
    expect(config['baseUrl'], kPostShareBase,
        reason: '站点地址改了，请同步 lib/post_share.dart');
  });

  test('云函数分享页与站点配置一致（域名 / 站点名 / 备案号）', () {
    final config = jsonDecode(File('site/site.config.json').readAsStringSync())
        as Map<String, dynamic>;
    final js = File('cloudfunctions/api/post_page.js').readAsStringSync();
    expect(js, contains("'$kPostShareBase'"),
        reason: 'site.config.json 的 baseUrl 变了，post_page.js 里的 BASE_URL 要同步');
    expect(js, contains("'${config['siteName']}'"),
        reason: 'site.config.json 的 siteName 变了，post_page.js 里的 SITE_NAME 要同步');
    expect(js, contains(config['icpNumber'] as String),
        reason: 'site.config.json 的 icpNumber 变了，post_page.js 里的 ICP_NUMBER 要同步');
  });

  test('分享页路由与云函数入口都已接上', () {
    final parser = File('cloudfunctions/api/post_page.js').readAsStringSync();
    final index = File('cloudfunctions/api/index.js').readAsStringSync();
    // 页面要能识别 /post/<id>.html 与旧链接 /post.html?id=
    expect(parser, contains(r'/^\/post(\.html)?(\/|$)'));
    expect(index, contains('postPage.handleHttp'),
        reason: '云函数 index.js 没有把 /post 请求交给分享页处理');
  });
}
