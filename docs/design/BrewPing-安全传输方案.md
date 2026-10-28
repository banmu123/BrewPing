# BrewPing 局域网传输安全方案

> 配套文档：《BrewPing-安全审计-第二批.md》（风险 P0-01）、《BrewPing-设备授权与撤销方案.md》。
> 本文只做设计，不改协议；实施按 §8 的分阶段推进。

---

## 1. 约束（先钉死不可协商的部分）

| 约束 | 来源 | 对方案的硬性影响 |
|---|---|---|
| 本地优先、无账号 | 产品方向（`ROADMAP.md`） | 不能依赖公网 CA、不能依赖项目方云服务 |
| 零配置 | 现有配对体验 | 不能让用户手动装证书/信任描述文件 |
| 五端一致 | macOS / Windows / iOS / Android / Wear | 方案必须在 Swift + Rust + Kotlin 上都可实现 |
| 不削弱现有鉴权 | 第一批成果 | TLS 之下仍要保留 Bearer + 时间戳 + nonce |
| 不引入自建 PKI | 任务约束 | 不做 CA、不做证书签发服务 |
| 无外部依赖倾向 | 现状：Swift 侧零三方依赖 | 新依赖要单独论证 |

现状一句话：**`NWParameters.tcp` + `Authorization: Bearer` 明文**，配对码保护的是"没有令牌的人"，
不保护"能看到流量的人"。

---

## 2. 威胁模型

| 编号 | 攻击者能力 | 现状 | 目标 |
|---|---|---|---|
| T1 | 同网段被动嗅探（开放 Wi-Fi、被控 AP） | 拿到令牌 = 完全控制 | 不可行 |
| T2 | 主动 MITM（ARP 欺骗、恶意热点） | 同上，且可篡改命令 | 不可行（配对后） |
| T3 | 首次配对时的 MITM | 可窃取令牌 | 需被 6 位码绑定挡住 |
| T4 | 拿到设备（离线） | Keychain/Keystore 保护，本文不扩展 | 维持 |
| T5 | 恶意网页（DNS rebinding / CSRF） | Bearer 头触发预检，基本被挡 | 维持并加 `Host` 校验 |
| T6 | 中继运营方 | 明文可见 | 本文不解决（见 §7） |

明确**不在**本文范围：已 root/jailbreak 的设备、被植入键盘记录器的桌面端、物理接触。

---

## 3. 候选方案

| 方案 | 做法 | 防 T1 | 防 T2 | 防 T3 | 五端可行性 | 迁移成本 |
|---|---|---|---|---|---|---|
| **A. 维持 HTTP** | 现状 + 文档声明 | ❌ | ❌ | ❌ | — | 0 |
| **B. HTTP + 请求签名** | 用 `HMAC(secret, method‖path‖body‖ts‖nonce)` 取代 Bearer | ✅ 令牌不上线 | ⚠️ 不可篡改，但内容仍可见 | ⚠️ 需另做绑定 | 高（纯应用层） | 中 |
| **C. TLS + 自签证书 + 指纹固定** | 服务端持每装机唯一的自签证书，客户端固定 SPKI | ✅ | ✅ | ❌（除非加 §5.3） | 高 | 中高 |
| **D. mTLS** | 双向证书 | ✅ | ✅ | ⚠️ | 低（iOS 客户端证书、Wear 密钥分发都麻烦） | 高 |
| **E. Noise / WireGuard** | 自建握手 | ✅ | ✅ | ⚠️ | 低（五端各写一遍） | 很高 |
| **F. 中继 E2E** | 端到端加密隧道 | ✅ | ✅ | — | 中 | 高，且与"本地优先"冲突 |

### 3.1 为什么不是 B（尽管它最便宜）

请求签名能**彻底解决令牌被偷**这一点（线上只出现一次性 MAC），成本也最低：不需要证书、
不需要处理 ATS/TrustManager。但它留下两个洞：

1. **命令内容仍然明文**：用户发给 agent 的指令、文件路径、返回的输出都能被读。
2. **需要一个双方共享的密钥**，而这个密钥就是现在的令牌——只是换了用法。一旦设备被攻破，
   后果一样。

所以 B 适合做**过渡**（如果 TLS 排期靠后），不适合做终点。

### 3.2 为什么不是 D / E / F

- **mTLS**：客户端证书要在 iOS 上走 PKCS#12 导入 + `URLSessionDelegate` 的
  `didReceive challenge`（`NSURLAuthenticationMethodClientCertificate`），Android 要
  `KeyChain`/`KeyStore` 别名，Wear 还要单独分发。收益相对 C 只多"服务端也能验证客户端"，
  而这件事现在的 Bearer 已经做了。
- **Noise / WireGuard**：需要在 Swift、Rust、Kotlin 各实现一遍握手与状态机，
  且要自己承担密码学实现风险。为一个局域网遥控器引入这个复杂度不划算。
- **中继 E2E**：与"不依赖托管服务"冲突；且 relay 目前默认关闭、iOS 入口已注释。

### 3.3 推荐：C + 配对码绑定

**TLS 1.3 + 每装机唯一的自签证书 + SPKI 指纹固定 + 首次配对用 6 位码做 SAS 绑定。**

选择理由：
- 用系统 TLS 栈（Network.framework / rustls / URLSession / OkHttp），不自研密码学。
- 自签 + 固定指纹绕开"没有域名、没有账号、不能依赖公网 CA"的死结。
- 指纹在**配对时**通过带外信道（6 位码）认证，解决 T3；配对后严格固定，解决 T1/T2。
- 五端都有成熟 API，且都不需要用户装证书。

---

## 4. 密钥与证书

### 4.1 生成时机与存放

| 端 | 生成 | 存储 | 保护 |
|---|---|---|---|
| macOS | 首次启动 | 钥匙串（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`） | 不可导出私钥 |
| Windows | 首次启动 | `%USERPROFILE%\.brewping\tls\server.pfx`（或 PEM） | 依赖用户目录 ACL；可选 DPAPI 加密 |

- 算法：**ECDSA P-256**（TLS 1.3 下 ECDHE + ECDSA，ATS 满足前向保密要求）。
- 证书字段固定：`CN=BrewPing`，`O=BrewPing`，有效期 10 年，`basicConstraints CA:FALSE`。
- **每台机器独立生成**。绝不能在安装包里预置同一张证书——那样私钥人人可得，指纹固定形同虚设。

### 4.2 证书生成的实现选择（macOS 是难点）

macOS 没有公开 API 直接签发 X.509。三条路：

| 做法 | 优点 | 缺点 | 建议 |
|---|---|---|---|
| 手写最小 DER 编码器（约 300–400 行） | 零依赖，与项目现状一致 | 需要正确实现 ASN.1，易错但可测 | 备选 |
| 引入 `apple/swift-certificates`（Apache-2.0） | 官方库，API 清晰 | 项目目前零 Swift 依赖 | **推荐**，需单独批准 |
| 调用 `/usr/bin/openssl` | 代码最少 | 依赖系统二进制与版本，沙箱/未来移除风险 | 不推荐 |

Windows 侧用 `rcgen` + `rustls`，是事实标准，成本低。

### 4.3 指纹的定义

**SPKI SHA-256**，不是整张证书的哈希——证书续期/改字段不影响固定值。

对 P-256 有一个省事的实现细节：SPKI DER 前缀是固定的 26 字节
`3059301306072a8648ce3d020106082a8648ce3d030107034200`，后接 65 字节未压缩点。
所以客户端可以直接对 `SecKeyCopyExternalRepresentation` 的输出加前缀再哈希，
**不必写完整 ASN.1 解析**。

对外展示统一为 base32（无 0/O/1/I）分组，例如 `BP-7K2M-9QX4-…`，供用户在两端肉眼比对（可选）。

---

## 5. 首次配对：用配对码认证服务端公钥

### 5.1 问题

指纹固定的前提是"客户端第一次就拿到正确的指纹"。扫码可以（指纹进 URL），但**手输 6 位码**
没有地方放指纹。若首次连接直接 TOFU（Trust On First Use），恰好在这个窗口做 MITM 的攻击者
可以永久固定自己的证书。

### 5.2 方案：配对码即 SAS

配对码此时已经是一个**带外共享秘密**（Mac 屏幕 → 用户眼睛 → 手机键盘），正好可以用来认证密钥：

```
客户端                                    服务端
  |-- POST /api/pair {code, deviceName, clientNonce} -->|   (TLS，此时尚未固定)
  |<-- {token, deviceId, spkiSha256,                  |
  |     binding = HMAC-SHA256(code, spkiSha256||clientNonce)} --|
  |                                                      |
  |  本地校验 binding，不符则中止，不保存 token           |
```

- 攻击者不知道 6 位码，无法为**自己的**公钥生成可通过校验的 `binding`；
- 攻击者转发真实服务端的 `binding` 也没用：客户端校验的是"自己这条 TLS 连接看到的 SPKI"，
  而 MITM 必须替换 SPKI 才能解密；
- 6 位码只有约 20 bit，但攻击者**无法离线试**——它必须让某一次真实配对通过校验，
  每次尝试都有 10⁻⁶ 命中率，且失败会在用户侧表现为"配对失败"，配合现有失败限速基本不可行。

### 5.3 对现有流程的改动

- `POST /api/pair` 请求体增加 `clientNonce`（16 字节，base64）。
- 响应增加 `spkiSha256`、`binding`、`tlsPort`（见 §6）。
- 服务端在 `PairingStore.exchange` 成功后计算 `binding`——码在此时已被消费，但仍在同一临界区内，
  实现上需要把"取码 → 算 binding → 作废"放在一把锁里。

### 5.4 兼容性

老客户端不传 `clientNonce` → 服务端不返回 `binding`，客户端按老逻辑走。新客户端连老服务端 →
响应无 `binding`，降级为"HTTP + 无固定"并**在 UI 明确标注"此连接未加密"**，不静默接受。

---

## 6. 协议与端口

| 项 | 现状 | 方案 |
|---|---|---|
| 监听 | 一个 HTTP 端口（8787/8788/8789 回落） | TLS 端口 = 实际 HTTP 端口 + 100（不回落到别的端口，避免降级混淆） |
| 端口发现 | `GET /api/status` | 公开的 `/api/status` 只增加 `tlsPort`（**不含指纹**）；Bonjour TXT 增加 `tls=1&tlsport=` |
| 指纹获取 | — | 只在**配对响应**与鉴权后的 `protocol/state.tls.spkiSha256` 里出现；不放公开端点 |
| 发现 | Bonjour TXT `deviceId`、`name` | 增加 `tls=1`、`tlsport=`（均不作为信任依据） |
| 明文拒绝 | — | TLS-only 模式下明文请求返回 `426 Upgrade Required` + `{"tlsPort":…}` |
| 配对响应 | `token/deviceId/deviceName` | 增加 `tlsPort`、`spkiSha256`、`binding` |

端口 +100 的理由：不改变现有 8787 的语义，老客户端不受影响；新客户端先探测 `protocol/state`
再决定连哪个端口。

---

## 7. 证书轮换与失效

| 场景 | 处理 |
|---|---|
| 正常轮换（预防性） | `POST /api/tls/rotate`（**必须在已固定的连接上**）返回新 SPKI；客户端保存 `{current, next}` 两个 pin，服务端切换后旧 pin 保留一个版本，下一个版本移除 |
| 证书损坏/误删 | 服务端生成新证书 → 所有 pin 失效 → 客户端收到指纹不符时必须**硬失败并提示重新配对**，绝不静默接受 |
| 设备被移除 | 与传输层无关（见设备授权方案）；轮换后旧设备即使有 pin 也连不上 |
| 时钟异常 | 自签证书不依赖系统时间校验有效期（客户端只比 SPKI）；仍记录 `notAfter` 供 UI 提示 |

`pinSetVersion` 的作用：客户端能判断"我手上的 pin 是不是太旧"，从而提示用户重新配对。

---

## 8. 分阶段迁移

| 阶段 | 服务端 | 客户端 | 兼容性 | 回滚 |
|---|---|---|---|---|
| **P0 准备** | 生成证书；`protocol/state` 暴露 `tls` 字段；TLS 端口可连但**不强制** | 无改动 | 完全兼容 | 关开关 |
| **P1 先修最痛** | （可选）先上方案 B 的签名，堵住令牌窃取 | 同批 | 需同版本升级 | 服务端保留 Bearer 一版 |
| **P2 客户端接入** | 不变 | 配对拿 pin + `binding`；优先 TLS，探测失败回退 HTTP 并**显式标注未加密** | 老服务端可用 | 客户端开关 |
| **P3 默认加密** | TLS 默认开；明文端口仅监听 `127.0.0.1`（给本机 CLI/DesktopCore） | 需 P2 版本 | 老客户端在局域网内失效 → 必须给最低版本门槛 | 一个版本内可开关 |
| **P4 收口** | 移除局域网明文监听 | — | 仅新版本 | — |

**P3 是破坏性节点**：局域网内明文监听一旦关闭，所有未升级的客户端都连不上。落地前必须先确认
App Store / GitHub Release 的最低版本覆盖率，并给至少一个版本的过渡期（服务端按
`User-Agent`/`protocolVersion` 统计仍走明文的客户端数量）。

---

## 9. 各端实现要点

### 9.1 macOS 服务端

```swift
let tls = NWProtocolTLS.Options()
sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)   // sec_identity_t
sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
let params = NWParameters(tls: tls, tcp: NWParameters.tcp)
let listener = try NWListener(using: params, on: port)
```

- 现有 `HTTPServer` 的解析逻辑不变，只在 `accept` 之前多一层 TLS。
- `remoteAddress` 在 TLS 下依然可用（`NWConnection.endpoint` 是传输层对端）。
- 注意：TLS 握手失败不应影响明文监听（两个 listener 独立）。

### 9.2 Windows 服务端

- `rcgen::generate_simple_self_signed` → `rustls::ServerConfig` → `tokio_rustls::TlsAcceptor`。
- axum 用 `axum_server::bind_rustls` 或手动 `accept` 后交给 hyper。
- 证书存 `%USERPROFILE%\.brewping\tls\`，权限依赖目录 ACL（与 `pairing.json` 同策略）。

### 9.3 iOS

- `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)`，对
  `NSURLAuthenticationMethodServerTrust` 自行评估：
  取证书链首证书 → 公钥 → 拼 SPKI → SHA-256 → 与 Keychain 里的 pin 比对。
- 只在匹配时 `URLSession.AuthChallengeDisposition.useCredential`；不匹配一律
  `.cancelAuthenticationChallenge`（**不要**回退到系统信任）。
- ATS：TLS 1.3 + ECDHE 满足要求，自签证书由 delegate 处理；`NSAllowsLocalNetworking`
  保留给 P2 阶段的回退路径。
- pin 与 token 一起存 Keychain（同一 item），防止只改 pin 不改 token 的不一致。

### 9.4 Android

- OkHttp `CertificatePinner`：`CertificatePinner.Builder().add(host, "sha256/<base64 SPKI>").build()`。
- 动态主机：每个设备单独构建 `OkHttpClient`（或用 `certificatePinner` + 自定义 `Dns`）。
- `network_security_config.xml` 收紧：私有网段允许明文（过渡期），公网强制 HTTPS（顺带修 P2-03）。
- Keystore 存 pin（与 token 同条目）。

### 9.5 Wear OS

- 复用 `:core` 的 OkHttp，无需新代码；确认 `WearProvisionSender` 下发的配置里带上 `tlsPort` 与 pin。

### 9.6 Apple Watch

- 不直连桌面端（经 iPhone 的 WCSession 转发），**无需改动**。待 U-05 验证后确认。

---

## 10. 成本估算（相对量级，不给虚假精度）

| 工作项 | 量级 | 说明 |
|---|---|---|
| macOS 证书生成 + TLS listener | 中 | 取决于是否允许引入 `swift-certificates` |
| Windows rustls 接入 | 小 | `rcgen` + `tokio-rustls` 成熟 |
| iOS 固定 + SAS 校验 | 中 | delegate 与 Keychain 一致性是主要工作量 |
| Android 固定 + SAS 校验 | 中 | `CertificatePinner` 简单，动态 host 需重构 client 构造 |
| 协议字段与兼容探测 | 小 | 集中在配对与 `protocol/state` |
| 测试与 CI（含真机） | 中 | 见 §11 |

整体是"一个中等功能"的量级，而不是"一次重构"。

---

## 11. 验证与测试矩阵

| 层 | 用例 |
|---|---|
| 单测（Swift/Rust） | 证书生成幂等（重启不换）；SPKI 计算与已知向量一致；`binding` 校验；指纹不匹配必须拒绝 |
| 集成 | 明文抓包工具（tcpdump）确认 Bearer 不再出现；TLS 端口握手成功；`426` 升级提示 |
| 客户端 | 首次配对成功固定；换证书后硬失败并提示重配；飞行模式/切换网络后 pin 仍生效 |
| 负向 | 中间人自签证书 → 客户端拒绝；篡改 `binding` → 配对失败；重放旧 `binding` → 失败 |
| 兼容 | 新客户端 + 老服务端（回退并标注未加密）；老客户端 + 新服务端（P2 阶段仍可连） |
| 跨端 | macOS 与 Windows 生成的证书都能被 iOS/Android 固定（互不兼容的假设要早发现） |

---

## 12. 明确不做的事

- 不自建 CA，不做证书签发服务。
- 不把证书预置进安装包（会毁掉指纹固定的意义）。
- 不为 relay 做端到端加密（另立项目；当前 relay 默认关闭）。
- 不在本轮改协议——本文只定方案，实施见 §8 的分批。
