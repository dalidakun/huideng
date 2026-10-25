/// 菩提空间帖子分享落地页。
///
/// 分享出去的是 `https://aibuilder.top/post/<id>.html`：这条路径由 CloudBase
/// HTTP 网关路由到 `api` 云函数（配置见 docs/帖子分享链接卡片方案.md），云函数把
/// 帖子正文和 og:title / og:description / og:image 一起写进**首字节 HTML**。
///
/// 微信收到链接时不执行 JavaScript，只读首字节里的 og 标签来生成聊天里的链接
/// 卡片（左侧缩略图 + 标题 + 摘要）；点卡片就在微信内置浏览器里打开同一个地址，
/// 看到的就是这条帖子。所以分享页必须是服务端渲染，纯前端 fetch 的页面抓不到
/// 内容，卡片只会是站点级的通用标题。
///
/// 站点地址与 `site/site.config.json` 的 `baseUrl` 保持一致，由
/// `test/post_share_test.dart` 校验。
const String kPostShareBase = 'https://aibuilder.top';

/// 帖子详情页完整地址；[noteId] 为空时退回下载页，保证链接永不落空。
String postShareUrl(String noteId) {
  final id = noteId.trim();
  if (id.isEmpty) return '$kPostShareBase/download.html';
  return '$kPostShareBase/post/${Uri.encodeComponent(id)}.html';
}

/// 系统分享面板的文案。
///
/// 只放链接：微信等聊天工具只对「纯链接消息」去抓页面并渲染成链接卡片，文案里
/// 掺了字就退化成普通文本气泡。摘要不用写在这儿——它就写在页面的 og:description
/// 里，卡片上照样显示（服务端从正文首段自动生成）。
String postShareText(String noteId) => postShareUrl(noteId);

/// 祈福（共修）页面的分享地址。
///
/// 与帖子共用一条路径：云函数按 id 先查帖子、查不到再查祈福项目，所以祈福详情页
/// 右上角分享出去的 `post/<祈福id>.html` 也能出卡片，点开就是这条祈福。
String blessingShareUrl(String projectId) => postShareUrl(projectId);

/// 祈福分享到系统分享面板的文案（同样只放链接，理由见 [postShareText]）。
String blessingShareText(String projectId) => blessingShareUrl(projectId);
