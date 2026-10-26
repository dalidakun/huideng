# BTC 行情页稳定性优化

> 状态：已实现并上线（2026-10-25，`trade.js?v=1e57113c`）  
> 涉及文件：`site/assets/js/trade.js`、`site/index.html`、`site/assets/trade.css`、
> `site/site.config.json`、`tools/build_site.py`、新增 `tools/trade_page_test.js`

页面：<https://aibuilder.top/>（BTC 行情 / 模拟盘）

> 主图均线（MA5/10/20/60）和副图 MACD 的设计、参数与验证见
> `docs/BTC行情页技术指标.md`。

## 一、症状

用户反馈：BTC 行情和走势图「经常掉线」。表现为三种情况，其实是同一批原因：

1. 打开页面要等很久才出价，甚至一直停在「正在连接行情源…」；
2. 用着用着价格不动了，但状态还显示「实时」，K 线也不涨；
3. K 线中间出现断档，或者刷新一下才有数据。

## 二、根因（都有实测依据）

### 1. 被墙的源排在第一位，每次都要先白等

实测（国内网络）：

| 地址 | 结果 |
| --- | --- |
| `wss://data-stream.binance.vision` | 1.4 秒内连上，`@ticker` / `@kline_1m` 都正常 |
| `wss://stream.binance.com:9443` | 6 秒握手超时 |
| `wss://stream.binance.com:443` | 6 秒握手超时 |
| `https://api.binance.com` | 8 秒超时 |
| `https://api1.binance.com` | 8 秒超时 |
| `https://data-api.binance.vision` | 1 秒内 200 |

旧代码把 `stream.binance.com:9443` 和 `api.binance.com` 放在数组第一位，
于是**每次刷新**都要先撞一次墙：WS 干等 7 秒握手超时，REST 要等 9 秒超时才换源。

### 2. 没有「假死」检测，连接断了页面不知道

浏览器只有在对端正常关闭 TCP 时才会触发 `onclose`。但手机切换网络、路由器/NAT 超时、
运营商中间设备掐断时，连接是**半开**的：`readyState` 一直是 1，再也不来数据，
`onclose` 永远不触发。

旧代码只每 60 秒发一次 PING，却从不检查有没有回音、多久没收到帧。
所以页面会一直显示「实时 · …」，价格其实是十分钟前的——这就是「掉线」最主要的观感来源。

### 3. 失败后的等待时间太长

旧代码：两个 WS 源都失败就转入轮询，然后**固定等 60 秒**才再试一次 WS。
这段时间里图表只能靠 4 秒一次的轮询，而且只要网抖一下就会重新进入这个 60 秒周期。

### 4. 轮询一次拉 1000 根 K 线

`pollOnce()` 每 4 秒同时请求 ticker 和 `klines?limit=1000`。1000 根 1 分钟 K 线约
150 KB，也就是**约 40 KB/s 的持续流量**，在移动网络上是页面自己在打满自己；
请求一超时，图上就缺数据。

### 5. 一次把 6 个源全打出去，失败的不 abort

旧 `restGet` 在主源失败后 `firstSuccess` 会把其余 5 个源**同时**打出去。
被墙的源每个要挂 9 秒才超时，成功之后剩下的请求也不取消。
轮询每 4 秒来一轮，页面上长期挂着十几个死连接——越刷越卡。

### 6. 掉线期间漏掉的 K 线永远补不回来

WS 的 `@kline` 只推「当前这一根」的变化，断线那几分钟的 K 线不会重发。
旧代码重连后不补数据，图上就永久留一个洞；如果正好在换周期，还会因为时间对不上把数据丢掉。

### 7. 后台 / 切网没有处理

切到后台时 Chrome 会冻结定时器，socket 却还留着，回来时多半已经假死；
手机从 Wi-Fi 切到 4G 时，`online` / `offline` 也没有监听。

### 8. 每秒重建 1000 根数组 + 每 800ms 重画表格

旧 `applyKlines` 每收到一根（1 秒一次）就重建 1000 条的 map、排序、再整表重画；
表格也是每 800ms 整个 `<tbody>` 重建。低端机上会明显掉帧，看着也像「卡死」。

## 三、改法

### 数据源顺序

```js
var REST_HOSTS = [
  'https://data-api.binance.vision',  // 国内可通，排第一
  'https://api.binance.com',          // 备份
  ...
];
var WS_HOSTS = [
  'wss://data-stream.binance.vision', // 国内可通，排第一
  'wss://stream.binance.com:9443',    // 备份
  'wss://stream.binance.com:443'      // 备份
];
```

上次连通的源记在 `localStorage`（`huideng.trade.host` / `huideng.trade.ws`），
下次打开直接用它，不再重复撞墙。

### WS 连接（`wsConnect` / `wsFail` / `startWatchdog`）

| 机制 | 参数 | 作用 |
| --- | --- | --- |
| 握手超时 | `WS_OPEN_MS = 5000` | 连不上就立刻换下一个源，不再干等 |
| 假死看门狗 | `WS_STALL_MS = 12000`，每 4 秒检查 | 12 秒没收到**任何帧**就主动踢掉重连 |
| 退避 | `800ms × 2^n`，上限 8s，±25% 抖动 | 快速恢复，又不会在断网时疯狂重试 |
| 心跳 | 45 秒一次 `PING` | 保活，同时它的 `pong` 也算「有帧」 |

一旦连上：`WS.fails` 清零、停掉轮询、把源记进 localStorage、调一次 `healBars()` 补数据。

### 降级轮询（`startPoll` / `pollKlines`）

- 行情条：4 秒一次 `ticker/24hr`；
- K 线：5 秒一次，**只取最新 3 根**（约 1 KB），不再拉 1000 根；
- 首屏没拿到历史时才用 `limit=1000` 补一次；
- WS 一开就 `stopPoll()`，不重复请求。

### REST 取数（`restGet`）

改成「顺序 + 延迟并行」：

1. 先打上次成功的源；
2. 1.4 秒还没回，才并行开下一个源；
3. 谁先成功用谁，**其余立刻 `AbortController.abort()`**；
4. 失败的源进 60 秒冷却，不再每轮都撞；
5. 单次 `restGet` 总时限 15 秒。

首屏因此只发 1～2 个请求，而不是 6 个。

### 补 K 线（`healBars`）

三种时机：WS 重连成功、页面回到前台、发现时间断层（新 K 线时间和最后一根差了一根以上）。

- 普通补：`limit=60`（约 2 KB），并进现有数组；
- 断档补：`limit=300`；
- 两次补数据至少间隔 3 秒，避免抖动时刷接口；
- 能顺接就逐根 `update`，有洞就 `setData` 整段重画（Lightweight Charts 的 `update`
  不允许插入比最后一根更早的数据）。

### 页面生命周期

- `visibilitychange`：切后台**主动断开** WS、停轮询；回前台立刻重连 + 补数据；
- `online` / `offline`：断网提示、恢复后重连；
- `pageshow (persisted)`：从 bfcache 回来也重连。

### 观感与卡顿

- `updatedAt` 每秒刷新，超过 3 秒显示「延迟 N 秒」，超过 8 秒价格变灰（`.is-stale`）；
- 状态文案只有三种：`实时 · 源`、`轮询模式 · 每 4 秒刷新`、`行情源不可用，正在重试…`；
- K 线合并走快路径（单根 / 顺接只 `update`），不再每秒重建 1000 根；
- 表格重绘从 800ms 放宽到 1 秒，页面在后台时不重绘；
- `chartUpdate` / `chartSet` 包了 try/catch，顺序异常时整段重画而不是把图表卡死。

## 四、行为对照

| 场景 | 改前 | 改后 |
| --- | --- | --- |
| 首次打开 | 先等被墙的源 7～9 秒 | 0.5～1.5 秒出价 |
| 半开连接（假死） | 永远显示「实时」，不再更新 | 12 秒内发现并重连 |
| WS 两个源都失败 | 固定等 60 秒 | 0.8→8 秒退避重试，期间轻量轮询 |
| 轮询流量 | 每 4 秒 150 KB+ | 每 5 秒约 1 KB |
| 并发请求 | 每轮最多 6 个，失败不取消 | 先 1 个，1.4 秒后才并开 |
| 掉线期间 K 线 | 永久缺口 | 重连后自动补齐 |
| 切后台再回来 | socket 假死，等 60 秒 | 立刻重连并补数据 |
| 每秒开销 | 重建 1000 根 + 重画表格 | 单根 update + 1 秒节流 |

## 五、怎么验证

### 自动回归（推荐，无需浏览器）

```powershell
node tools/trade_page_test.js
```

用假 `fetch` / `WebSocket` / 时钟把 `trade.js` 跑一遍，覆盖 23 项：
首屏源选择、推送更新、断档补齐、断开降级、退避重连、假死看门狗、前后台切换。
改数据层后先跑它。

### 手动验证（真机 / 浏览器）

1. 打开 <https://aibuilder.top/>，Network 里应只有 `data-api.binance.vision`，
   没有 `api.binance.com`；WS 是 `data-stream.binance.vision`。
2. DevTools → Network → 勾选 Offline 5 秒再取消：状态应变成轮询，随后自动回到「实时」。
3. DevTools → Application → Service Workers 无；直接切到别的标签页 30 秒再回来，
   K 线应补齐，价格立刻跳动。
4. 手机锁屏 1 分钟再解锁，价格应在 2 秒内恢复更新。
5. 控制台不应有 `Cannot update oldest data` 之类的图表报错。

## 六、部署

```powershell
# 只更新网站（不发布新 APK）
python tools/build_site.py --sync

# 上传：根目录（aibuilder.top）+ App 引用的子目录（/huideng）
tcb hosting deploy site/dist -e randeng-d8gs968w22a3d98e8
tcb hosting deploy site/dist huideng -e randeng-d8gs968w22a3d98e8
```

`ASSET_VER` 是 `site/assets` 下所有 css/js 的内容指纹，改了 `trade.js` 会自动拼新的
`?v=` 查询串，不用手动清缓存。

## 七、如果哪天 .vision 也被墙了：自建反代

客户端再稳，也怕源彻底不通。这时在**境外或香港**的小机器（或带 WebSocket 的
Serverless）上放一个反代，把地址填进 `site.config.json`：

```json
"market": {
  "restBase": "https://market.example.com",
  "wsBase": "wss://market.example.com"
}
```

构建时会替换进 `index.html` 的 `TradePage.start({...})`，`trade.js` 会把它们顶到
数据源列表最前面，代码不用改。

Nginx 示例：

```nginx
server {
  listen 443 ssl http2;
  server_name market.example.com;
  ssl_certificate     /etc/letsencrypt/live/market.example.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/market.example.com/privkey.pem;

  # REST：/api/v3/...
  location /api/ {
    proxy_pass https://data-api.binance.vision;
    proxy_ssl_server_name on;
    proxy_set_header Host data-api.binance.vision;
    proxy_read_timeout 30s;
    add_header Cache-Control "no-store";
  }

  # WebSocket：/stream?streams=...
  location /stream {
    proxy_pass https://data-stream.binance.vision;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host data-stream.binance.vision;
    proxy_read_timeout 3600s;
    proxy_buffering off;
  }
}
```

注意：

- 路径必须原样透传（`/api/...`、`/stream?...`），`proxy_pass` 末尾**不要加斜杠**；
- WS 不能被 CDN 缓存或改写成短连接，CloudBase 的 HTTP 网关/云函数撑不住长连接，
  别拿它做 WS 中继；
- 反代机器本身要能稳定访问 Binance，且带宽够（行情推送约 10～30 KB/s）。

## 八、参数速查（`trade.js` 顶部）

| 常量 | 值 | 含义 |
| --- | --- | --- |
| `POLL_MS` | 4000 | 降级轮询：行情条 |
| `KLINE_POLL_MS` | 5000 | 降级轮询：K 线 |
| `REQ_MS` | 8000 | 单个 REST 超时 |
| `REQ_DEADLINE_MS` | 15000 | 一次 `restGet` 总时限 |
| `HEDGE_MS` | 1400 | 多久没回就并开下一个源 |
| `HOST_COOLDOWN_MS` | 60000 | 失败源冷却 |
| `WS_OPEN_MS` | 5000 | 握手超时 |
| `WS_STALL_MS` | 12000 | 多久没帧算假死 |
| `WS_RETRY_MIN` / `MAX` | 800 / 8000 | 重连退避区间 |
| `HEAL_MIN_MS` | 3000 | 两次补数据最小间隔 |
| `RENDER_MS` | 1000 | 账户/表格重绘节流 |

## 九、改动禁区

1. **不要把 `api.binance.com` / `stream.binance.com` 挪回数组第一位。**
   国内打开会先白等 5～9 秒，用户感知就是「又连不上」。
2. **不要去掉看门狗。** 半开连接不会触发 `onclose`，没有看门狗页面就会假装实时。
3. **不要恢复「两个源都失败就等 60 秒」。** 那是掉线感最强的来源之一。
4. **轮询不要改回 `limit=1000`。** 4 秒 150 KB，移动网络会被页面自己打满。
5. **不要去掉 `healBars`。** 否则每次掉线都在图上留一个永久的洞。
6. 改完跑 `node tools/trade_page_test.js`。
