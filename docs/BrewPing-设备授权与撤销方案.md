# BrewPing 设备授权与撤销方案

> 配套：《BrewPing-安全审计-第二批.md》（P1-01 / P2-05）、《BrewPing-安全传输方案.md》。
> 本文是设计，不含实现；按 §10 的顺序分批落地。

---

## 1. 现状

| 事实 | 证据 |
|---|---|
| 桌面端只有一个长期令牌，所有设备共用 | `Sources/App/PairingStore.swift:64`（`private let token`） |
| 每次配对成功返回同一个令牌 | `:147-175`（`exchange` 直接 `return token`） |
| 桌面端不知道配对过哪些设备 | 全仓无设备表；`/api/pair` 收到的 `deviceName` 未被读取 |
| 客户端"移除设备"只删本地 | `ios/.../DeviceStore.swift:40-51`、`Android/.../DeviceStore.kt:74-80` |
| 没有撤销端点、没有轮换端点 | `HTTPAPI.swift:21-81` 路由表 |

由此产生的三个后果：**无法单独吊销**、**无法追责**、**用户误以为已经吊销**。

---

## 2. 目标与非目标

**目标**

1. 一台设备一个凭据，可单独撤销，撤销即时生效。
2. 桌面端能列出已配对设备（名字、平台、最近活跃时间、来源地址）。
3. 撤销后该设备的旧凭据立刻 401，其它设备不受影响。
4. 现有共享令牌用户有一条不需要"所有人同时升级"的迁移路径。
5. 客户端 UI 不再暗示"删掉就等于撤销"。

**非目标**

- 不做账号体系、不做云端设备管理。
- 不做按端点的细粒度权限（只读设备等）——留待以后。
- 不改变"令牌 = 该机器命令执行权限"这一前提。

---

## 3. 数据模型

`~/.brewping/pairing.json` 升到 v2（Windows 同构）：

```json
{
  "version": 2,
  "devices": [
    {
      "id": "dev_7f3c1a9e",
      "name": "iPhone 15",
      "platform": "ios",
      "secretHash": "sha256:9b1e…",
      "createdAt": "2026-10-28T03:00:00Z",
      "lastSeenAt": "2026-10-28T03:12:41Z",
      "lastAddress": "192.168.1.7",
      "revokedAt": null
    }
  ],
  "legacy": {
    "secretHash": "sha256:4c2a…",
    "createdAt": "2026-09-01T10:00:00Z",
    "revokedAt": null
  }
}
```

设计要点：

- **只存哈希**（SHA-256）。`pairing.json` 泄露不再直接等于命令执行权限。
- `id` 由服务端生成（`dev_` + 8 hex），客户端只保存、从不自造。
- `lastSeenAt` 更新要节流（例如 ≥60s 才落盘一次），避免每请求写盘。
- 设备数量上限 32：超出时拒绝配对并提示"先在电脑上撤销一台"。
- `legacy` 字段承载旧共享令牌，可单独吊销；吊销后所有未升级客户端一起失效。

---

## 4. 凭据格式与校验

### 4.1 格式

```
Authorization: Bearer bp1.<deviceId>.<secret>
```

- `bp1.` 前缀让版本可辨；旧令牌是 64 位 hex、不含 `.`，天然落到 legacy 分支。
- `secret`：32 字节 CSPRNG，base64url 无填充（43 字符）。

### 4.2 校验顺序（`PairingStore.authorize`）

1. 取 `Bearer` 后的字符串。
2. 以 `bp1.` 开头 → 拆三段 → 查 `devices[id]`：
   - 不存在 → 401 `unknown_device`
   - `revokedAt != null` → 401 `device_revoked`
   - `SHA-256(secret)` 与 `secretHash` **定长比较** → 不等则 401 `invalid_token`
   - 通过 → 更新 `lastSeenAt` / `lastAddress`（节流落盘）
3. 否则 → 与 `legacy.secretHash` 定长比较。
4. 后续的时间戳 + nonce 校验**完全不变**（`PairingStore.authorize:275-295`）。

> 定长比较的对象从"明文字符串"变成"32 字节哈希"，语义不变；长度固定，不会泄露前缀。

### 4.3 与现有客户端字段的冲突（重要）

`POST /api/pair` 现在返回的 `deviceId` 是**桌面主机的** id，iOS 用它做中继精确路由
（`ManagedDevice.hostDeviceId`）。**不能**把它换成凭据 id，否则中继路由会静默失效。

因此新增字段：

```json
{
  "success": true,
  "token": "bp1.dev_7f3c1a9e.<secret>",
  "credentialId": "dev_7f3c1a9e",
  "deviceId": "bp_mac_xxxxxxxx",
  "deviceName": "Banmu's MacBook Pro"
}
```

老客户端只读 `token` / `deviceId`，行为不变。

---

## 5. API 变化

| 端点 | 方法 | 鉴权 | 说明 |
|---|---|---|---|
| `/api/devices` | GET | **仅本机**（见 5.1） | 列出设备 |
| `/api/devices/{id}` | DELETE | **仅本机** | 撤销单台 |
| `/api/devices/{id}` | PATCH | **仅本机** | 改名 |
| `/api/devices/revoke-all` | POST | **仅本机** | 撤销全部（含 legacy） |
| `/api/pair` | POST | 公开 | 响应增加 `credentialId` |

### 5.1 为什么设备管理只允许本机

撤销是**这台电脑的授权动作**，不该由任何一台手机代劳：

- 防止被盗令牌把合法用户"踢出去"（可用性攻击）；
- 语义清晰：谁是权威，谁执行撤销。

实现上需要区分"本机"与"远程"。现有 `HTTPRequest.remoteAddress` 在进程内调用与中继隧道下都是
`nil`（`RelayBridge.swift:244-250`），无法据此判断。建议给 `HTTPRequest` 增加
`isLocalProcess: Bool = false`，只由进程内调用路径（桌面 UI / CLI）置真，中继与局域网一律为假。
判定函数集中在一处，避免以后新增路径时漏标。

### 5.2 401 错误体增加机器可读原因

```json
{ "success": false, "error": "device revoked", "reason": "device_revoked" }
```

客户端据此把"被移除"与"配对已失效"分开呈现。老客户端忽略 `reason`，只显示 `error`，不受影响。

---

## 6. 桌面端 UI

`BrewPingDesktop` 设置页新增「已授权的设备」：

| 列 | 内容 |
|---|---|
| 名称 | 配对时客户端上报（首次真正落盘的地方） |
| 平台 | ios / android / wear（缺省 unknown） |
| 最近活跃 | `lastSeenAt` 相对时间 |
| 来源 | `lastAddress`（仅展示，不参与鉴权） |
| 操作 | 重命名 / 撤销 |

额外的两处提示：

- 顶部标注「任何已授权设备都能在这台电脑上执行命令」——把权限模型说清楚。
- 若存在 `legacy` 条目，单独显示「旧版共享令牌（无法区分设备）」+「撤销后所有旧客户端需重新配对」。

---

## 7. 客户端变化

| 端 | 变化 |
|---|---|
| iOS | 凭据连同 `credentialId`、`spkiPin` 存同一个 Keychain item；401 且 `reason=device_revoked` → 清 token 并提示「这台电脑已移除本设备的授权」 |
| Android | 同上，存 Keystore 加密的 SharedPreferences 条目 |
| Wear | 沿用 `:core` 的 `DesktopApiClient`，只改存储结构 |
| Windows 桌面（作为服务端） | `pairing_store.rs` 同构实现；Tauri 设置页复用同一套 UI 文案 |

**删除设备按钮的文案必须改**：

> 现在：`Remove`
> 改为：`Remove from this phone` + 副标题「不会撤销电脑上的授权。要撤销，请在电脑的 BrewPing 设置里操作。」

这条文案是本方案里成本最低、收益最高的一处——它直接消除审计里的 P1-01 误解面。

---

## 8. 边界情形

| 情形 | 行为 |
|---|---|
| 桌面端重启 | `devices` 持久化，撤销状态保持；`lastSeenAt` 继续更新 |
| 设备改名（客户端） | 客户端只能改本地显示名；桌面端以首次上报的名字为准，可在桌面端 PATCH 重命名 |
| 设备改名（桌面端） | PATCH 改 `name`，不影响凭据 |
| 客户端重装（iOS） | Keychain item 默认保留 → 应用启动时若发现凭据但本地设备列表为空，用它恢复条目；Keychain 也被清 → 重新配对生成新条目 |
| `device.json`（主机 id）被重建 | 只影响中继路由与 Bonjour 的 `deviceId`，**不影响任何设备凭据**（两者本来就独立） |
| 重复配对同一台手机 | 生成**新**条目，旧条目变成 stale（`lastSeenAt` 不再更新）→ UI 提供"撤销长期未活跃设备" |
| 达到 32 台上限 | 配对返回 409，提示先撤销 |
| 撤销当前正在使用的设备 | 该设备下一个请求即 401；桌面端列表标记为「已撤销」并保留 7 天后清理 |
| 时间回拨 | `lastSeenAt` 只增不减（取 max），避免 UI 显示错乱 |

---

## 9. 兼容迁移

### 9.1 读旧文件

启动时若 `pairing.json` 无 `version` 字段：

1. 读旧格式 `{token, createdAt}`；
2. 写入 v2：`legacy.secretHash = SHA-256(token)`，`devices = []`；
3. **保留原文件备份**为 `pairing.v1.bak`（一次性，便于回滚）；
4. 旧客户端继续用原令牌 ⇒ 命中 legacy 分支 ⇒ 行为不变。

### 9.2 新客户端连旧服务端

响应里没有 `credentialId` ⇒ 客户端按"legacy 凭据"存储（只存 token），
设备管理入口隐藏。下次服务端升级后重新配对即可拿到独立凭据。

### 9.3 关闭 legacy 的时机

- 桌面端提供显式「撤销旧版共享令牌」按钮，**默认不自动执行**；
- 建议在"设备列表里只剩 legacy 条目"或"发布说明提示满两个版本"后再引导用户点击；
- 撤销后所有未升级客户端 401 → 走既有的"重新配对"引导（两端都已实现该提示）。

---

## 10. 升级顺序

| 步骤 | 内容 | 破坏性 |
|---|---|---|
| 1 | macOS `PairingStore` v2（读旧写新，双分支校验）+ 单测 | 否 |
| 2 | Windows `pairing_store.rs` 同构 + `cargo test` | 否 |
| 3 | 桌面端「已授权设备」UI + 设备管理端点（仅本机） | 否 |
| 4 | iOS/Android 存储结构与 401 `reason` 处理 + 删除文案 | 否 |
| 5 | iOS/Android 配对后使用 `credentialId` | 否（老服务端自动回退） |
| 6 | 发布说明引导撤销 legacy | **是**（旧客户端失效） |

步骤 1–5 都可以单独发布、单独回滚；只有第 6 步需要版本覆盖率支撑。

---

## 11. 测试矩阵

### 11.1 服务端（Swift / Rust 各一套，用例同名）

| 用例 | 断言 |
|---|---|
| 旧文件迁移 | 读 v1 → 写 v2 → legacy 校验通过 → 原文件备份存在 |
| 新配对 | 两台设备拿到**不同** token，`credentialId` 不同 |
| 撤销单台 | 被撤销设备 401 `device_revoked`；另一台 200 |
| 撤销后重启 | 仍是 401（状态持久化） |
| 重复撤销 | 幂等，不报错 |
| 未知 `deviceId` | 401 `unknown_device`，且不泄露是否存在 |
| 哈希比较 | 定长比较；错误 secret 不泄露前缀（用长度相同的错误值测） |
| legacy 分支 | 旧令牌仍可用；撤销 legacy 后 401 |
| 设备上限 | 第 33 台返回 409 |
| 本机限制 | 远程 DELETE `/api/devices/{id}` 返回 403；进程内调用成功 |
| 时间戳/nonce | 新凭据下重放仍被拒（回归第一批） |

### 11.2 客户端

| 用例 | 断言 |
|---|---|
| 401 `device_revoked` | 清 token、显示"已被移除"、不进入自动重试循环 |
| 401 `unknown_device` | 同上（服务端数据被清空） |
| 删除设备 | 只删本地；UI 明确提示未撤销 |
| 重装恢复 | Keychain 有凭据、列表为空 → 自动恢复条目 |
| 多设备 | 同一手机连两台 Mac，凭据互不干扰 |

### 11.3 端到端

- 两台设备配对 → 撤销 A → A 立即 401、B 正常发命令 → 重启桌面端 → 结论不变。
- 配 32 台 → 第 33 台被拒 → 撤销一台 → 可再配。

---

## 12. 未决问题

| 编号 | 问题 | 倾向 |
|---|---|---|
| D-01 | 是否允许**手机端**主动撤销自己（"我不再信任这台电脑"） | 倾向允许，但只删本地凭据，不调服务端 |
| D-02 | 是否需要"只读设备"角色 | 暂不需要，但数据模型预留 `role` 字段 |
| D-03 | `lastSeenAt` 落盘节流窗口 | 60s，可配置 |
| D-04 | 撤销后的条目保留多久 | 7 天，之后清理（保留 `revokedAt` 便于审计） |
| D-05 | Windows 上 `secretHash` 文件保护 | 依赖用户目录 ACL；是否加 DPAPI 外壳待定 |
