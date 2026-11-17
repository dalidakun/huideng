# 燃灯 App（huideng）

Flutter 客户端。官网（<https://aibuilder.top/>）与云函数已经拆到独立仓库
**aibuilder-web**，本仓库只留 App 代码。

## App 与官网的关系

App 运行时不引用官网源码，只通过固定 URL 使用官网服务：

| 文件 | 依赖的地址 |
| --- | --- |
| `lib/update_service.dart` | `https://randeng-d8gs968w22a3d98e8-1461892767.tcloudbaseapp.com/huideng/version.json`（版本检查） |
| `lib/post_share.dart` | `https://aibuilder.top/post/<id>.html`（帖子/祈福分享落地页） |
| `lib/community_invite.dart` | `https://aibuilder.top/community/<slug>.html`、`/download.html`（栏目社区分享） |
| `lib/cloudbase_config.dart` | 云环境 `randeng-d8gs968w22a3d98e8`（云函数 `api` 在官网仓库里维护） |

这些是双方契约，改域名、路径、`version.json` 字段、云函数接口或栏目 slug 时，
要同时改官网仓库；只改网页页面/样式/文案不会影响 App。

## 官网仓库

- 本地：`E:\aibuilder-web`
- 内容：`site/`、`cloudfunctions/api/`、构建与部署脚本、官网文档
- 发版流程：本仓库 `flutter build apk --release` → 在官网仓库运行
  `python tools\update_site.py --apk <这里打出来的 apk> --version x.y.z+NN`
  （收包、写 `version.json`、重建站点、部署）

## 开发

```bash
flutter pub get
flutter run
flutter test
```

## 其它目录

- `miniprogram/`：微信小程序（独立项目，和 App 共用部分经文数据）
- `assets/agreements/`：App 内展示的隐私政策 / 用户协议（官网另有一份在 `site/data/legal/`）
