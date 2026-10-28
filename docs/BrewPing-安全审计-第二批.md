# BrewPing 安全审计（第二批）

> 范围：局域网控制链路的授权、传输、审批与跨端一致性。
> 基线：`main` @ `6d63fee`（第一批 HTTP 解析与配对限速已合入）。
> 方法：逐文件读码取证，不依赖注释与文档自述；未运行的部分在「暂未验证」中单列。
>
> **分类约定**（全文统一）：
> - **已确认问题** —— 代码路径已核实，能指出具体文件与行。
> - **潜在风险** —— 需要额外前提才成立，前提写在条目里。
> - **当前设计限制** —— 有意为之或架构决定，不是 bug，但必须让用户知道。
> - **暂未验证** —— 有推断但没跑过，不下结论。

---

## 0. 结论摘要

产品把「6 位配对码换长期令牌」当作唯一的安全边界。这个边界本身实现得比较扎实（定长比较、
一次性码、时间戳 + nonce 防重放、文件 0600、失败限速），但**边界之外是三处结构性缺口**：

1. **令牌走明文 HTTP**。同网段被动嗅探到一个请求头，就等于拿到这台机器的命令执行权限。
   配对码防的是"没有令牌的人"，防不住"能看到流量的人"。
2. **令牌不可拆分、不可吊销**。所有设备共用一个令牌；客户端"移除设备"只删本地凭据，
   服务端照旧授权。用户对"我已经把那台手机踢掉了"的直觉是错的。
3. **审批门不是安全边界，而且可以被远程关掉**。任何持令牌的设备都能 `POST /api/approvals/mode`
   切到 `auto`，此后所有命令免确认；"总是允许"白名单全局持久化且没有撤销入口。
   审批门防的是**误操作**，不是**被盗令牌**——这一点必须在文档和 UI 里说清楚。

风险清单：**P0 × 1、P1 × 4、P2 × 9**。没有发现"未认证即可执行命令"的漏洞。

---

## 1. 鉴权覆盖面（问题 1）

### 1.1 判定位置

macOS 的鉴权是**路由前**统一判定，不在各个 handler 里各写一遍：

```swift
// Sources/App/HTTPAPI.swift:9-19
if request.method == "POST", request.path == "/api/pair" { return pairResponse(request) }
if request.method == "GET", request.path == "/api/status" { return statusResponse(...) }
if case .denied(let status, let error) = PairingStore.shared.authorize(request) { ... }
```

Windows 侧是同一套规则的 axum 中间件，挂在 `route_layer` 上：

```rust
// Sources/BrewPingwinDesktop/src-tauri/src/services/http_server.rs:319-332
let is_public = (method == "POST" && path == "/api/pair")
    || (method == "GET" && path == "/api/status");
```

`route_layer` 在 axum 0.8 里**只包裹已注册的 routes**（`path_router.rs:311-341`：
`routes` 逐个套 layer，`fallback` 不在其中），所以**未知路径不走鉴权**，直接由
`handle_not_found` 返回静态 404。窗口内的业务逻辑不受影响，但与 macOS 的行为不同
（macOS 是路由前判定，未知路径无令牌返回 401），见 P2-06。

### 1.2 逐条核对

| 能力 | 端点 | 鉴权 | 备注 |
|---|---|---|---|
| 发指令 / 执行 | `POST /api/message` | ✅ 令牌 + 时间戳 + nonce，且过审批门 | 最高危入口 |
| 决定审批 | `POST /api/approvals/{id}` | ✅ 同上 | 决定本身不再需要二次确认 |
| 改审批档位 | `POST /api/approvals/mode` | ✅ 同上 | **不经审批门**（见 P1-02） |
| 切 Agent | `POST /api/agents/{id}/switch` | ✅ 令牌 + 时间戳 + nonce | |
| 改默认 Agent | `POST /api/agents/default` | ✅ | |
| 切模型 | `POST /api/agents/models/default` | ✅ | |
| 改工作目录 | `POST /api/agents/workdir` | ✅ | 决定 agent 在哪个目录里跑 |
| 浏览目录 | `GET /api/folders`、`/roots` | ✅ 仅令牌（GET 免 nonce） | 可枚举整机文件系统 |
| 建/改/删对话 | `POST/PATCH/DELETE /api/conversations…` | ✅ | 删对话不可恢复 |
| 会话启停 | `POST /api/session/start|stop` | ✅ | |
| 配对 | `POST /api/pair` | ❌ 公开（设计如此） | 有失败限速 |
| 健康检查 | `GET /api/status` | ❌ 公开（设计如此） | **泄露主机名与 Agent 清单**（P2-01） |

所有 `POST/PATCH/DELETE` 都要求 `X-BrewPing-Timestamp` + `X-BrewPing-Nonce`；
`GET` 只要 Bearer（理由是会频繁轮询，见 `PairingStore.authorize`）。

**结论：没有"未鉴权就能改配置或执行"的端点。** 唯一越界的是 `/api/status` 的信息量。

### 1.3 一个必须说明的性质

令牌是**全权限**的：没有只读设备、没有按端点分权。任何一台配对成功的手机都能删除对话、
改工作目录、把审批切到 `auto`、再执行任意命令。这是"单令牌模型"的直接后果（见 P1-01）。

---

## 2. 令牌生命周期（问题 2、3、4）

### 2.1 现状

`PairingStore` 只有一个 `token` 字段（`Sources/App/PairingStore.swift:64`），
`exchange` 对任何一次成功配对都返回**同一个**值（`:147-175`）。Windows 侧结构完全一致
（`pairing_store.rs:314-351`）。

因此：

- **问题 4 的答案**：多设备**不**使用独立凭据，所有设备共享同一个 64 位 hex 令牌。
  具体限制：无法单独吊销、无法区分设备、无法统计"谁在用"、无法做按设备限速。
- **问题 3 的答案**：用户移除客户端设备后，桌面端**没有**撤销任何授权。桌面端根本不知道
有过哪些设备——`/api/pair` 请求里的 `deviceName` 甚至没有被读取（`HTTPAPI.pairResponse`
只把**主机自己**的名字写进响应，见 `:114-118`）。

### 2.2 客户端"移除设备"做了什么

| 客户端 | 代码 | 实际动作 |
|---|---|---|
| iOS | `ios/BrewPing/DeviceStore.swift:40-51` | 清 Keychain + 从本地列表移除 |
| Android | `Android/.../store/DeviceStore.kt:74-80` | 从 SharedPreferences 移除 |

两端都**没有任何网络调用**，桌面端也没有对应端点可调。iOS 的入口是一个
`role: .destructive` 的 "Remove" 按钮（`ContentView.swift:934-935`），语义上很容易被读成
"解除授权"。**这是本次审计里最容易被误解的一处。**

### 2.3 令牌重放

写操作要求 ±120s 时间戳 + 一次性 nonce（`PairingStore.authorize:275-295`），
捕获的 POST **不能**原样重放。但要注意它防的是"重放"，不是"伪造"：

> 拿到令牌的人可以自己生成新的时间戳和 nonce，构造任意新请求。
> nonce 机制不能替代机密性——只有 TLS 能阻止令牌被拿走。

`GET` 免 nonce 是合理的取舍（轮询量大），但 `GET /api/message/:id` 会写本地终端状态
（`HTTPAPI.swift:572-598`），严格说不是"无副作用"，见 P2-04。

### 2.4 授权状态不同步

| 场景 | 桌面端 | 客户端 | 结果 |
|---|---|---|---|
| 客户端删设备 | 无感知，令牌仍有效 | 本地凭据已清 | 客户端"以为解除了"，服务端仍授权（P1-01） |
| 桌面端删 `pairing.json` 重启 | 生成新令牌 | 仍持旧令牌 | 全部 401 → 两端都有"重新配对"提示（行为正确） |
| 设备改名 | 无感知 | 本地改名 | 无影响（桌面端本来就没记录） |
| 客户端重装（iOS） | 无感知 | Keychain 条目默认**保留**、UserDefaults 设备列表丢失 | 令牌成为孤儿：应用看不到它，但它仍然有效（待验证） |

---

## 3. 审批门能拦什么（问题 5）

### 3.1 机制

判定发生在**命令进入 agent 之前**，对用户消息正文做本地正则匹配
（`ApprovalGate.check` → `DangerPattern.detect`），档位三选一：

| 档位 | 行为 |
|---|---|
| `safe`（默认） | 命中危险模式才挂起；"总是允许"过的 code 不再挂起 |
| `askAll` | 每条都挂起 |
| `auto` | 全部放行，等同 `--dangerously-skip-permissions` |

危险规则共 11 条（`DangerPattern.swift:33-55`）：`rm -rf /`、递归删除、`git push --force`、
`git reset --hard`、`curl | sh`、`sudo`、`chmod 777`、写 `/dev/`、`dd if=`、`DROP TABLE`、
`TRUNCATE TABLE`。

### 3.2 能拦住的

- 用户在手机/手表上直接打出的、**字面命中**上述模式的整条消息。
- `askAll` 档下的任意命令（人工逐条确认）。
- 审批挂起有 300s TTL，且 `always_approve` 只接受已知 code（防注入，`:117-119`）。

### 3.3 明确拦不住的（设计限制，不是 bug）

| 场景 | 为什么拦不住 |
|---|---|
| agent 在会话中途自己推断出的 shell 命令 | 检测点在"用户消息进入 agent 之前"，agent 内部的工具调用不可见（`DangerPattern.swift:24-29` 已注明） |
| `auto` 档 | 直接 `return .allow`（`ApprovalGate.swift:73-74`） |
| 任何设备把档位改成 `auto` | `POST /api/approvals/mode` 只需令牌（P1-02） |
| 语义等价但字面不同的写法 | 正则匹配：`python -c "import shutil;shutil.rmtree('/')"`、base64 解码后执行、变量拼接、`find -delete`、`rm -r -f`（拆开写）都可能绕过 |
| 配置类破坏性操作 | 改工作目录、删对话、切 agent/模型都不经审批门 |
| 已 `always_approve` 的 code | 全局白名单永久生效（P1-03） |

**结论：审批门是"防手滑"的 UX 安全网，不是针对攻击者的控制项。** 这一点与 `ROADMAP.md`
「a safety net for your own instructions, not a sandbox」一致，但与部分用户/审核者的直觉不一致，
建议在 UI 首次开启 `auto` 时明确提示。

---

## 4. 日志、错误与恢复（问题 6）

### 4.1 已核对为"不泄露"的部分

| 检查项 | 结论 |
|---|---|
| 配对码是否入日志 | 否。全仓 `print`/`BrewPingLog` 中无配对码 |
| 长期令牌是否入日志 | 否。`BrewPingAgent` 只打印监听地址；`RelayBridge` 只打印主机与 deviceId |
| 命令正文是否入日志 | 否。`RelayBridge` 不记录 payload；`CommandRunner` 不打印正文 |
| 语音转写文本 | `privacy: .private`（`WatchConnectivityManager.swift:816`），正确 |
| 错误响应是否回显请求体 | 否。第一批已统一为固定文案（`malformed request` 等） |
| 中继是否记录 payload | 否（仅元数据），但**中继方在链路上能看到明文**（P1-04） |

### 4.2 需要注意的三点

1. **挂起中的审批全在内存**（`ApprovalGate.pending`）。桌面端重启 → 所有 pending 消失，
   手机侧不会收到任何通知，那条命令既没执行也不会再执行，用户只能靠"怎么没反应"察觉。
2. **没有设备归因的审计记录**。对话转录里存了消息正文与时间，但不记录来源设备，
   审批的批准/拒绝完全不留痕。多设备场景下一旦出事无法追责，也无法回答"是不是我批准的"。
3. **转录文件权限过宽**。`~/.brewping` 是 `755`、`conv_*.json` 是 `644`，同组本地用户可以读到
   全部正文（P2-09）。`pairing.json` 的 `0600` 说明项目知道该怎么做，只是转录这条路径漏了。

---

## 5. 跨平台一致性（问题 7）

| 维度 | macOS | Windows | 一致性 |
|---|---|---|---|
| 鉴权判定 | 路由前统一（未知路径也 401） | 中间件只包已注册路由（未知路径直接 404） | ⚠️ 端点内等价，未知路径不一致 |
| 令牌格式 | 64 hex，单令牌 | 64 hex，单令牌 | ✅ |
| 时间戳/nonce | ±120s，nonce 上限 2048 | 同 | ✅ |
| 配对失败限速 | 5/5min + 全局 30/5min | **无** | ❌ P2-02 |
| 请求体上限 | 8 MiB（自定义） | axum 默认 2 MiB（**待验证**） | ❌ P2-06 |
| `/api/status` 字段 | 含 `agents` 数组 | 无 `agents` | ❌ P2-06 |
| 令牌文件权限 | `0600` | 无 POSIX 位，依赖用户目录 ACL | ⚠️ 设计差异 |
| 明文策略（客户端） | iOS 仅本地（ATS） | — | Android 全放开（P2-03） |
| 审批门 | 有，同一套规则 | 有，同一套规则 | ✅ |
| 审批档位远程可改 | 是 | 是 | ✅（同样是设计缺口） |

---

## 6. 风险清单

### P0

#### P0-01 长期令牌与命令正文走明文 HTTP

- **位置**：`Sources/App/HTTPServer.swift`（`NWParameters.tcp`，无 TLS）；
  `ios/BrewPing/Info.plist`（`NSAllowsLocalNetworking`）；
  `Android/app/src/main/AndroidManifest.xml:23`（`usesCleartextTraffic="true"`）。
- **前提**：攻击者能看到流量——开放/弱口令 Wi-Fi、被控路由器、同网段 ARP 欺骗、恶意热点。
- **影响**：`Authorization: Bearer …` 在明文头里，抓到一次即获得**完整命令执行权限**；
  命令正文、文件路径、Agent 输出同时暴露。配对码机制对此完全无效。
- **是否已证实**：✅ 配置与代码均已确认；"抓到即可用"由鉴权模型直接推出。
- **修复建议**：见《BrewPing-安全传输方案.md》——TLS + SPKI 指纹固定 + 配对码绑定。
- **回归测试**：抓到明文 Bearer 的用例必须变为不可能；TLS 指纹不匹配时客户端必须硬失败而不是降级。

### P1

#### P1-01 无设备级凭据，客户端"移除设备"不撤销授权

- **位置**：`Sources/App/PairingStore.swift:64,147-175`；
  `ios/BrewPing/DeviceStore.swift:40-51`；`Android/.../store/DeviceStore.kt:74-80`。
- **前提**：设备丢失/转手/令牌被备份提取，用户想"把那一台踢掉"。
- **影响**：做不到。唯一手段是删除 `~/.brewping/pairing.json` 并重启桌面端，代价是**所有**
  设备重配；期间旧令牌一直有效。
- **是否已证实**：✅ 两端删除路径均无网络调用，服务端无设备表、无吊销端点。
- **修复建议**：见《BrewPing-设备授权与撤销方案.md》。
- **回归测试**：撤销后该设备下一次请求必须 401；其它设备不受影响；重启后吊销状态保持。

#### P1-02 任何已配对设备可把审批档位切成 `auto`

- **位置**：`Sources/App/HTTPAPI.swift:9-19`（`/api/approvals/mode` 只过令牌）、
  `:556-565`；`ApprovalGate.swift:73-74`。
- **前提**：令牌已泄露（P0-01 的直接后果）。
- **影响**：攻击者先用一个请求关掉审批，再发任意命令，用户零感知。审批门对"被盗令牌"
  场景提供的保护为 **0**。
- **是否已证实**：✅ 代码路径确认，无需额外条件。
- **修复建议**：短期在文档/UI 明确"审批门不防被盗令牌"；中期见设备授权方案——
  高危操作（切 `auto`、改工作目录、删对话）可要求**桌面端本地确认**（本机弹窗），
  而不是仅凭令牌。
- **回归测试**：开启"高危操作需本机确认"后，远程切 `auto` 必须挂起等待本机确认。

#### P1-03 "总是允许"白名单全局持久化且无撤销入口

- **位置**：`ApprovalGate.swift:115-121`（写入）、`:157-165`（加载）、
  `HTTPAPI.swift:21-81` 路由表（无清除端点）。
- **前提**：用户在手机上误点一次 "Always allow"。
- **影响**：该 danger code 此后在**所有对话、所有设备**上永久免确认；
  App 内没有任何入口可以撤销，只能手改 `~/.brewping/approval.json` 或改档位。
- **是否已证实**：✅ 无 DELETE/POST 端点可清空白名单。
- **修复建议**：新增 `DELETE /api/approvals/always-allow`（或 `POST …/reset`），
  桌面端设置页加"已放行的危险操作"列表 + 撤销；客户端同步刷新。
- **回归测试**：撤销后同一 code 再次命中必须重新挂起；重启后撤销状态保持。

#### P1-04 中继路径对中继运营方明文可见

- **位置**：`Sources/App/RelayBridge.swift:19-25`（帧内含 `authorization` 与 base64 body）、
  `:226-252`；`SECURITY.md` 已声明 relay 在边界外。
- **前提**：用户显式启用 relay（iOS 入口当前已注释，Mac 需 `relay.json`）。
- **影响**：中继方（或能 MITM 中继的人）可读到 Bearer 与全部命令内容；共享 `RELAY_TOKEN`
  泄露还能伪造隧道帧（精确路由已缓解，但仍是单令牌）。
- **是否已证实**：✅ 帧结构确认；默认关闭，故列潜在。
- **修复建议**：保持默认关闭；若要做，端到端加密（见传输方案 §7 的"不推荐项"）。
- **回归测试**：relay 关闭时零行为变化；开启时隧道内容不可被中继日志还原。

### P2

#### P2-01 `GET /api/status` 免鉴权泄露主机名与 Agent 清单

- **位置**：`HTTPAPI.swift:12`（公开）、`:371-399`（返回 `host`、`agents`、`session`）。
- **前提**：能访问 8787 端口。
- **影响**：同网段任意人可枚举"哪台机器装了 BrewPing、装的什么 agent、是否有活跃会话"，
  用于挑选目标；也可用于确认设备在线状态。
- **是否已证实**：✅
- **修复建议**：只保留 `{"status":"online"}` 与协议版本；主机名/agent 列表移到鉴权后的
  `/api/protocol/state`。客户端需要同步（iOS/Android 都读 `host` 用于展示）。
- **回归测试**：未带令牌请求 `/api/status` 不得返回主机名；带令牌的旧字段保持兼容。

#### P2-02 Windows 端无配对失败限速

- **位置**：`pairing_store.rs:151-168`（`exchange` 无计数）；`http_server.rs:1001-1030`。
- **前提**：攻击者能连到 Windows 桌面端端口。
- **影响**：6 位码（10⁶）在 10 分钟窗口内可被高速枚举；macOS 已有限速，Windows 没有。
- **是否已证实**：✅ 全仓无 rate limit 代码（仅 `model_proxy` 的 `max_attempts` 是上游重试）。
- **修复建议**：把第一批 macOS 的策略移植到 Rust，阈值与冷却保持一致。
- **回归测试**：与 Swift 侧同构的 6 个用例（阈值、冷却、恢复、并发、状态有界、全局兜底）。

#### P2-03 Android 允许对任意主机明文，iOS 仅限本地

- **位置**：`Android/app|wear/src/main/AndroidManifest.xml:23/28`；
  `ios/BrewPing/Info.plist`（`NSAllowsLocalNetworking`）。
- **前提**：用户在 Android 上手填公网地址/域名。
- **影响**：Android 会把令牌明文发到公网（iOS 会被 ATS 拦），行为不一致且扩大暴露面。
- **是否已证实**：✅ 清单文件确认。
- **修复建议**：改用 `network_security_config.xml`，只对私有网段放行明文；公网地址强制 HTTPS。
- **回归测试**：公网 http:// 地址在 Android 上必须失败并给出可读提示。

#### P2-04 `GET /api/message/:id` 有本地副作用，而 GET 免 nonce

- **位置**：`HTTPAPI.swift:567-598`（写 TerminalState）、`PairingStore.authorize:273`。
- **前提**：能重放一个 GET。
- **影响**：重复 append 输出到本地终端状态（有 `appendedCommandIDs` 去重，实际影响低）；
  但"GET 无副作用"这一前提不成立，未来新增 GET 时容易再踩。
- **是否已证实**：✅ 代码；实际危害低。
- **修复建议**：把副作用移到显式的 `POST /api/message/{id}/render`，或让 GET 只读。
- **回归测试**：同一 GET 重放两次，本地状态只变化一次。

#### P2-05 令牌无法轮换

- **位置**：`PairingStore`（无 rotate 端点）；`HTTPAPI` 路由表。
- **前提**：怀疑令牌泄露。
- **影响**：只能删文件重启，所有设备重配；没有"换令牌但保留设备"的路径。
- **是否已证实**：✅
- **修复建议**：随设备授权方案一并提供 `POST /api/token/rotate`（保持设备凭据不变）。
- **回归测试**：轮换后旧令牌 401、新令牌 200、设备列表不变。

#### P2-06 跨端协议细节不一致

- **位置**：`http_server.rs:334-375`（无 `DefaultBodyLimit`，axum 默认 2 MiB；
  `.route_layer` 不覆盖 `fallback`，未知路径免鉴权）、
  `handle_status:434-446`（无 `agents` 字段）。
- **前提**：同一条长消息在 macOS 能发、在 Windows 被 413；客户端依赖 `agents` 字段；
  有人用未知路径探测 Windows 端是否存在鉴权。
- **影响**：跨端行为差异，用户会当成 bug；未鉴权 404 会把请求路径原样回显
  （无状态变更，危害低，但违反"只有两个公开端点"的表述）。
- **是否已证实**：`agents` 缺失 ✅；`route_layer` 不覆盖 fallback ✅（axum 0.8.9 源码）；
  2 MiB 上限 **待验证**（未在 Windows 实跑）。
- **修复建议**：显式声明 `DefaultBodyLimit::max(8MiB)`；`/api/status` 补齐字段；
  把 404 处理移到 `handler` 内或改用 `Router::layer`（对所有请求生效），让未知路径也走鉴权。
- **回归测试**：两端各一条"8 MiB 边界"用例；`/api/status` 字段快照对比；
  无令牌访问未知路径在两端返回一致状态码。

#### P2-07 无审计日志（只有对话转录，缺少来源与审批记录）

- **位置**：`ConversationStore.swift:43,46`（消息有 `text` 与 `createdAtMs`，
  落盘 `~/.brewping/conversations/conv_*.json`）；全仓无设备归因、无审批决策记录。
- **前提**：多设备使用后需要追责/取证。
- **影响**：能查到"说了什么、什么时候"，但**查不到是哪台设备发的、谁批准的**；
  令牌泄露后无法定位来源；审批的 approve/deny 完全不留痕。
- **是否已证实**：✅ 转录存在但无 deviceId / 无审批记录 / 无独立审计文件与保留策略。
- **修复建议**：本地 append-only 日志（`~/.brewping/audit.log`，0600，滚动），记录
  deviceId、端点、命令摘要哈希（**不记正文**，正文已在转录里）、审批结果。
- **回归测试**：日志不含正文/令牌；滚动与权限；写入失败不影响主流程。

#### P2-08 挂起审批与已渲染标记均为内存态

- **位置**：`ApprovalGate.swift:41`（`pending`）、`HTTPAPI.swift:426-428`（`appendedCommandIDs`）。
- **前提**：桌面端重启。
- **影响**：挂起的命令静默消失，手机侧无提示；终端输出可能重复渲染。
- **是否已证实**：✅
- **修复建议**：pending 落盘（或重启后广播"有 N 条审批已作废"）。
- **回归测试**：重启后 pending 状态可见/可解释。

#### P2-09 对话转录文件权限过宽（本地多用户可读）

- **位置**：`ConversationStore.swift:143,305,388`——目录 `createDirectory` 用默认权限，
  文件 `.write(options: .atomic)` 后**未**设置 `0600`（对比 `PairingStore` 与 `ApprovalGate`
  都显式设了 0600）。
- **前提**：这台 Mac 上有第二个本地账户，且属于 `staff` 组（macOS 默认如此）。
- **影响**：同组本地用户可以读到全部对话正文（用户指令、agent 输出，可能含粘贴进去的密钥）。
  本机实测：`~` 为 `drwxr-x---`（组可穿越）、`~/.brewping` 为 `drwxr-xr-x`、
  `conv_*.json` 为 `-rw-r--r--` ⇒ 组内可读；`pairing.json` 是 `-rw-------`，不受影响。
- **是否已证实**：✅ 权限位实测 + 代码未设权限。
- **修复建议**：`~/.brewping` 设 `0700`，转录与 index 设 `0600`（写入后 `setAttributes`）；
  启动时对已有文件做一次修正。
- **回归测试**：新建/迁移后目录 0700、文件 0600；已有文件在启动后被修正。

---

## 7. 暂未验证事项

| 编号 | 事项 | 为什么没验证 | 计划 |
|---|---|---|---|
| U-01 | Windows 主路由的 2 MiB 请求体上限 | 本机无 Windows 运行环境（`cargo test` 在 macOS 因 `#[cfg(windows)]` 编不过） | 在 Windows 机器上发 3 MiB POST 观察状态码 |
| U-02 | iOS 卸载重装后 Keychain 条目是否残留 | 需要真机/模拟器卸载重装流程 | 真机验证后再定"孤儿令牌"的严重度 |
| U-03 | 恶意网页对 `/api/pair` 的盲暴力可行性 | 浏览器同源策略细节多，未实测 | 用本地页面 + 真实服务端验证请求是否被发出 |
| U-04 | DNS rebinding 对非公开端点的可行性 | 需要构造 rebinding 环境 | 推演倾向"被 Authorization 预检挡住"，但不下结论 |
| U-05 | Apple Watch 是否直连桌面端 | 只核到手机侧 WCSession 转发路径 | 读 watch target 的网络栈确认 |
| U-06 | `always_approve` 在 Windows 端的持久化路径与清理方式 | 未逐行核对 `approval_gate.rs` 的落盘 | 补充核对 |

---

## 8. 与现有文档的口径差异

1. `SECURITY.md` 说"配对码是单次、10 分钟有效"，正确；但没有说**多设备共享同一个令牌、
   无法单独撤销**。建议在"Explicitly out of scope"之前补一条"当前为单令牌模型"。
2. `ROADMAP.md` 写 iPhone「In App Review — TestFlight only」，而 `docs/PROJECT_STATUS.md:40,55`
   写「Available — App Store」。这是文档漂移，与安全无关，但同一份仓库自相矛盾会被审核方读到。
3. `ROADMAP.md` 的「Approval gate … not a sandbox」与本次结论一致，无需改；
   但建议补一句"审批档位可由已配对设备远程关闭"。

---

## 9. 建议的修复批次

| 批次 | 内容 | 依赖 |
|---|---|---|
| 第二批-1 | P1-03 白名单撤销端点 + 桌面 UI（最小、可独立交付） | 无 |
| 第二批-2 | P2-09 转录权限收紧（一行改动）；P2-01 收敛 `/api/status`；P2-02 Windows 限速对齐；P2-06 显式 body 上限 | 无 |
| 第二批-3 | 设备级凭据与吊销（P1-01、P2-05）—— 见设备授权方案 | 需要协议版本协商 |
| 第二批-4 | TLS 传输（P0-01）—— 见传输方案 | 依赖 3 的配对响应扩展 |
| 待定 | P1-02 高危操作本机确认；P2-07 审计日志 | 需要产品决策 |
