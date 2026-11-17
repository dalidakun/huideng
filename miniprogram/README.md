# 古籍阅读 · 微信小程序（首版）

这是「慧灯」App 书籍阅读部分的最小可提审版本，定位为**本地古籍原文阅读工具**：

- 书目 + 正文全部内置，打开即读，不依赖网络；
- 支持字号、背景（纸黄/纯白/夜间）、阅读进度、段落笔记、书内检索；
- **无登录、无支付、无 AI、无社区、无 UGC 公开内容、无外链**。

首版只内置 8 部短经（约 19 万字节），目的是先把「类目 + 审核」跑通；
全量 8,982 部后续改走云存储按需下载，见文末「后续接全量」。

---

## 一、目录结构

```
miniprogram/
├── app.js / app.json / app.wxss      # 入口、路由、全局样式
├── project.config.json               # 开发者工具项目配置（appid 在这里改）
├── sitemap.json
├── data/
│   ├── books.js                      # 书目（自动生成）
│   ├── docs.js                       # 隐私政策/用户协议/免责声明
│   └── texts/                        # 正文模块（自动生成，每本一个 js）
├── services/
│   └── library.js                    # 书库访问层（后续换云存储只改这里）
├── utils/
│   ├── config.js                     # 名称、版本、备案号、联系方式
│   ├── paragraphs.js                 # 分段规则（与 App 对齐）
│   ├── store.js                      # 本地进度/笔记/设置
│   └── format.js
└── pages/
    ├── shelf/                        # 书架 + 搜索
    ├── reader/                       # 阅读器（滚动、字号、背景、检索、笔记）
    ├── notes/                        # 笔记列表
    ├── note-edit/                    # 写/改笔记
    ├── about/                        # 我的
    └── doc/                          # 隐私政策等静态页
```

## 二、导入运行

1. 打开微信开发者工具 → **导入项目**；
2. 目录选 `E:\5-huideng_apk\miniprogram`；
3. AppID：
   - 还没注册：选「测试号 / 游客模式」，`project.config.json` 里已是 `touristappid`；
   - 已注册：把 `project.config.json` 的 `appid` 换成你的小程序 AppID；
4. 点「编译」即可预览。

> 没有安装开发者工具的话，先把代码提交到 git；安装后导入同一目录即可。

## 三、提审前要改的 4 处

| 位置 | 改什么 |
| --- | --- |
| `utils/config.js` | `appName`（建议「古籍阅读」，别带佛/禅/寺）、`recordNo`（备案号下来后填） |
| `project.config.json` | `appid` 换成真实 AppID |
| 小程序后台 → 基本设置 | 名称、头像、简介、服务类目 |
| 小程序后台 → 设置 → 隐私 | 按后台模板填写《隐私保护指引》，声明不收集用户信息 |

### 建议的类目与简介

- 首选类目：**工具 → 效率**（或工具下的阅读类，以后台可选项为准）；
- 备选：**图书报刊/音像/影视/游戏/动漫 → 图书报刊**（需要《出版物经营许可证》）；
- 简介建议：

  > 提供大正藏汉文古籍原文的在线阅读、检索与本地笔记工具，内容为公版文献，不含宗教活动、募捐或付费服务。

- 截图：书架、阅读页、笔记页各一张即可，不要放佛像、法会、募捐二维码。

### 提审前自查

- [ ] 首页、阅读页、笔记页都能正常打开，无白屏；
- [ ] 「我的」里隐私政策、用户协议、免责声明可打开；
- [ ] 没有“购买 / 会员 / 资助 / 功德 / 随喜 / 加微信”等字样；
- [ ] 没有外链、没有跳转 App、没有下载 APK；
- [ ] 没有 `open-type="getUserInfo"`、手机号、定位等授权；
- [ ] 后台已填隐私保护指引，且与实际功能一致；
- [ ] 已开通「客服」（`我的 → 联系我们` 用到 `open-type="contact"`）。

> 如果被驳回「类目不符」，按驳回理由改类目；如果被要求《互联网宗教信息服务许可证》，
> 说明审核把内容归到宗教类目了，这时只有补证或收窄内容两条路。

## 四、后续接全量经书（8,982 部）

首版正文在 `data/texts/*.js`，全量 263MB 不可能进 2MB 主包，必须改成按需下载：

1. 把 `assets/sutras_ascii/**/*.txt` 上传到 **云开发云存储**：
   `books/<卷>/<ID>.txt`，例如 `books/T08/T08n0251_001.txt`；
2. 云数据库建 `sutras` 集合：`id / title / volume / tag / chars / fileID`；
3. 小程序端：

```js
const { tempFilePath } = await wx.cloud.downloadFile({ fileID });
const dest = `${wx.env.USER_DATA_PATH}/books/${id}.txt`;
await new Promise((resolve, reject) => {
  wx.getFileSystemManager().saveFile({
    tempFilePath,
    filePath: dest,
    success: resolve,
    fail: reject,
  });
});
const text = wx.getFileSystemManager().readFileSync(dest, 'utf8');
```

4. 只需把 `services/library.js` 的 `getText()` 从同步改成异步（返回 Promise），
   阅读页 `onLoad` 里加 loading / 失败重试；`utils/paragraphs.js`、笔记、阅读器都不用动。
5. 本地缓存上限约 200MB，做 LRU：超过 150MB 时删最久未读的书；正在读的白名单保留。

> 云存储下载走 `wx.cloud.downloadFile`，不占服务器域名白名单，也不需要给 GitHub 做备案。
> 付费书不要直接下发公开 `fileID`，要由云函数校验权益后发临时链接。

### 新增内置书

```bash
# 改 tools/build-miniprogram-texts.js 里的 BOOKS 数组，然后：
node tools/build-miniprogram-texts.js
```

## 五、首版刻意没做的功能

| 功能 | 原因 |
| --- | --- |
| 左右翻页 | 小程序没有 TextPainter，分页要重写；先做滚动阅读 |
| 字符级画线 | `text` 无系统选区，需自绘手柄；工作量大，二期 |
| AI 译经/问答 | 宗教内容 + 生成式 AI 标识/备案风险，首版不放 |
| 登录 / 云同步 | 先用本地存储，降低审核面 |
| 支付 / 会员 | 类目与 iOS 虚拟支付未确定，过审后再做 |
| 社区 / 评论 | 明确不做 |

## 六、合规提醒

- 大正藏原典为公版；电子文本整理参考 CBETA，**标点、校勘等整理权利归原整理者**。
  免费阅读通常没问题，收费前先取得授权或换公版扫描源。
- 隐私政策里写的是“当前版本”的行为；以后加云同步、账号、支付，必须同步更新政策与
  后台的隐私保护指引。
- 小程序上线前需要完成**小程序备案**；没有备案不能发布。
- 微信支付只对企业/个体户开放；iOS 端不能卖电子书/会员这类虚拟内容。
