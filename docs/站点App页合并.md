# 站点「App 页」合并说明

原来有两个入口：

| 地址 | 实际内容 |
| --- | --- |
| `/index.html#app` | 首页里的 App 视图，iframe 加载 `/app/index.html` |
| `/app/index.html` | 同一份 App 介绍页，被 iframe 使用，也能被直接打开 |

所以用户会看到两个地址对应同一页。现在统一保留 **`/index.html#app`**：

1. 页面上的「大正藏经」导航、分享页 CTA、社区页页脚全部改成 `/index.html#app`；
2. `/app/index.html` 仍然是 iframe 的内容源（不能删），但**直接打开时**会在 `<head>` 里
   `location.replace('../index.html#app')`，只作为内部文件存在；
3. `app/index.html` 的 canonical / `og:url` 也指向 `/index.html#app`，分享卡片落到合并后的地址。

判断是否在 iframe 里用 `window.self === window.top`：嵌入时不重定向，直接打开才重定向。
因为是静态托管，没有服务端 301；如果以后要更彻底的 301，需要在 CloudBase 静态托管/CDN 上配重定向规则。

相关文件：

- `site/index.html`（`data-view="app"` 的 href）
- `site/app/index.html`（顶部重定向脚本 + canonical）
- `site/post.html`（顶部「打开 App」和底部 CTA）
- `site/community.template.html`（页脚）
- `site/changelog.html` / `download.html` / `legal.template.html` / `app/download.html`（导航）
