# 自动发现故障分析：Xcode 直装可用 / TestFlight 不可用

分析日期：2026-09-16
现象：同一台 Mac（桌面端广播正常，`dns-sd -B _brewping._tcp` 实测可见实例 `Chenzk`）
- iPhone **Xcode 直装**的 App → 「附近」能自动发现设备 ✅
- iPhone **TestFlight** 装的 App → 自动发现为空 ❌（手动输 IP 仍可连）

---

## 一、先说结论

**两个安装包在「能不能发现设备」这件事上，从代码和配置看是等价的。** 我把能查的都实测了：

| 检查项 | 结果 | 证据 |
|---|---|---|
| Release 包（TestFlight 同款配置）的 `NSBonjourServices` | ✅ 存在且取值正确 `_brewping._tcp` | `.../BrewPing.app/Info.plist` 实测 |
| Release 包的 `NSLocalNetworkUsageDescription` | ✅ 存在 | 同上 |
| Release 包的 ATS 本地网络豁免 | ✅ `NSAllowsLocalNetworking = 1` | 同上 |
| 源码里是否有 `#if DEBUG` 区分发现逻辑 | ✅ **没有任何 `#if DEBUG`** | 全 `ios/` 目录 grep，仅 pbxproj 有 `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`（只在 Debug 配置） |
| Debug / Release 构建配置差异 | 仅标准 9 项：`SWIFT_OPTIMIZATION_LEVEL`(_Onone vs -O)、`DEBUG` 宏、`ENABLE_TESTABILITY`、`DEBUG_INFORMATION_FORMAT`、`ONLY_ACTIVE_ARCH`、`MTL_ENABLE_DEBUG_INFO`、`GCC_OPTIMIZATION_LEVEL`、`VALIDATE_PRODUCT` | pbxproj 逐项 diff，**无一条影响 Bonjour / 本地网络** |
| `Info.plist` 是否在两个版本间变过 | ✅ 最后一次改动是 09-15 01:32（`58e3fe5`），**早于两个构建** | git log |
| 使用的发现 API | 同一份代码：`NWBrowser` + `NetService`（`BonjourDiscovery.swift`） | 无分支 |

**所以差异不在二进制、不在 Info.plist、不在构建配置** —— 只能来自**安装方式带来的运行时权限状态与安装上下文**。

---

## 二、两种安装方式的真实差异（逐维度）

### 1. 构建配置（Debug vs Release）
| | Xcode 直装 | TestFlight |
|---|---|---|
| 配置 | Debug（默认 Run） | Release（Archive 默认） |
| 优化 | `-Onone` | `-O` |
| 编译条件 | 定义 `DEBUG` | 不定义 |
| 可调试 | `get-task-allow = true` | `get-task-allow = false` |
| 符号 | dwarf | dwarf-with-dsym |

⚠️ 这里的所有差异与 Bonjour/本地网络**无关**；且源码里没有 `#if DEBUG`，不会走出不同分支。

### 2. 签名与描述文件
| | Xcode 直装 | TestFlight |
|---|---|---|
| 签名 | Apple Development + 描述文件含本机 UDID | App Store 分发签名（Apple 重新签名） |
| 安装者 | Xcode / 开发者 | 系统（TestFlight 进程） |
| 容器 | 直接覆盖安装 | 通常需要**先删除旧 App**（两种签名不能互相覆盖） |

### 3. 权限记录（⭐ 最关键的差异来源）
iOS 的「本地网络」权限（以及相机、语音等）按 **Bundle ID** 记录，且有两个重要特性：
- **删除 App 会清空该记录**；
- 一旦记录为「拒绝」，**系统不会再弹窗**，App 只能在静默失败中等用户去设置里手动打开。

而「从 Xcode 签名版换成 TestFlight 版」通常要**先删掉 App 再装**（签名不同，直接覆盖会失败）—— 这一步会把权限记录一并清掉。重新安装后：
- 如果弹窗出现且你点了「允许」→ 正常；
- 如果弹窗被你划掉/切后台时被系统丢弃/曾经误点「不允许」→ **静默失败，且与 Xcode 版行为完全不同**。这正好解释了你的现象。

### 4. 网络发现机制本身
两者完全相同：同一个 `NWBrowser(for: .bonjour(type: "_brewping._tcp", domain: "local."))` + `NetService` 解析。
但要注意：**iOS 对 Bonjour 浏览和 `.local` 解析做权限管控，而直连 IP 字面量不受同一限制** —— 这就是「手动 IP 能连、自动发现为空」能同时成立的原因。

---

## 三、根因排序与验证方法（按概率）

### ① 本地网络权限处于「拒绝/未授权」状态（首要怀疑，90%）
**验证**：iPhone → 设置 → 隐私与安全性 → **本地网络** → 看有没有 `BrewPing`、开关是否打开。
- **列表里根本没有 BrewPing** → 说明这个安装从未成功触发过权限请求（比如弹窗在启动瞬间被丢弃）；
- **有但关闭** → 就是它。

**修复（按顺序，别跳）**：
1. 删除 TestFlight 版 App；
2. 重新从 TestFlight 安装；
3. 打开 App，**停在「添加设备 / 附近」页至少 10 秒**（我们的代码在 `onAppear` 发起浏览，权限请求由此触发）；
4. 出现「BrewPing 想要查找并连接本地网络上的设备」→ **点「允许」**（不要划掉、不要切后台）；
5. **从后台彻底杀掉 App 再重开**（权限变更不会热生效）；
6. 回「附近」列表等待 8 秒。

> 若第 4 步始终不弹窗：说明浏览没有触达权限系统（那问题会回到「声明缺失」，但本次已实测 Release 包声明齐全，故不成立）→ 走 ④ 抓日志确认。

### ② 权限记录被缓存为拒绝
**验证**：设置 → 隐私与安全性 → 本地网络 → BrewPing 开关是关的。
**修复**：打开开关 → 杀掉 App → 重开。**不要**只在设置里打开就回前台看，必须重启进程。

### ③ 两个包并非同一份源码（低概率，但值得 5 分钟复核）
- 你上传 TestFlight 的是 **09-15 17:18–17:23 的归档**（build 1），当时源码 ≈ `3250b1b`；
- 今天 Xcode 直装的是 **HEAD `1aa6f76`**，两者差异只有一条：今天新加的「扫不到时的排查引导卡」——**不影响发现能力**；
- Info.plist 自 09-15 01:32 起未变。
**验证**：若 ① ② 都不成立，重打一个 build 2（`CURRENT_PROJECT_VERSION` +1）上传再测，看是否复现。

### ④ 用日志一锤定音（推荐同时做）
1. iPhone 用数据线连 Mac；
2. Mac 打开 **Console.app** → 左侧选你的 iPhone → 过滤 `BrewPing`（我们的日志 subsystem 是 BrewPing，`BrewPingLog.discovery` 会打 `Resolved …` / `Failed to resolve …`）；
3. 在手机上进入设备页等待 8 秒，看输出：
   - **一条日志都没有** → 浏览阶段被拦（权限问题，回到 ① ②）；
   - **有 `Failed to resolve`** → 服务能发现但解析失败（另一类问题，可再深挖）；
   - **有 `Resolved`** → 发现其实成功了，问题在 UI 呈现层。

### ⑤ 网络侧多播隔离（次要，5 分钟排除）
在同一台 iPhone 上装一个第三方 Bonjour 浏览器（如 Discovery）浏览 `_brewping._tcp`：
- 第三方能看到 `Chenzk`、我们的 App 看不到 → 确定是 App 权限问题；
- 第三方也看不到 → Wi-Fi 拦了多播（AP 隔离/访客网络/跨网段）。但这解释不了「Xcode 版能发现」，除非两次测试时手机连的不是同一个 Wi-Fi —— 值得顺口确认。

---

## 四、关键检查点清单（照着勾）

- [ ] iPhone 设置 → 隐私与安全性 → 本地网络：**是否存在 BrewPing、是否打开**
- [ ] 是否曾经「删除 App 后重装」（会清空权限记录 → 必须重新授权）
- [ ] 重装后**弹窗是否出现**、是否点了允许
- [ ] 授权后是否**彻底杀掉 App 重启**（不是切前台）
- [ ] iPhone 的 Wi-Fi 与 Mac 是否同网段（Mac 当前 `192.168.1.226`；手机应为 `192.168.1.x`）
- [ ] 两个版本测试时的 Wi-Fi 是否同一个（排除网络侧变量）
- [ ] Console.app 里 `BrewPing` 的发现日志有无输出
- [ ] Mac 端 `dns-sd -B _brewping._tcp` 是否能看到 `Chenzk`（已实测 ✅）
- [ ] TestFlight 的 build 是否就是你以为的那份源码（build 号 + 归档时间）

---

## 五、代码侧可改进项（可选，需重打 TestFlight 才生效）

当前 `ios/BrewPing/BonjourDiscovery.swift` 的 `NWBrowser.stateUpdateHandler` **只判断 `.failed` 并把错误对象丢掉了**：

```swift
browser.stateUpdateHandler = { state in
    if case .failed = state { self?.isSearching = false }   // 错误被丢弃
}
```

建议（能让下次 TestFlight 排查从「靠猜」变成「一行日志」）：
1. 打出完整 state 与 `NWError`（尤其 `localNetworkDenied` 一类），走 `os_log`；
2. 把「权限被拒」与「搜到 0 个结果」在 UI 上区分开（前者明确指向系统设置，后者指向多播网络）；
3. 可选：把 `includePeerToPeer = true` 做成可关闭项做 A/B（P2P 会把 AWDL 也纳入浏览，某些网络下可能走进异常路径）。

> 说明：本节属改进建议，不是本次故障的既证原因；本次故障的既证事实是「两个包的声明与代码等价，差异指向安装态权限」。
