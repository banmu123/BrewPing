# iOS TestFlight 自动发现失效 —— 定位报告

> 现象回顾：Xcode 直装的 Debug 版能自动发现 Mac/Windows；TestFlight 版发现不到；手动输入 IP + 端口能连上。
> 本轮**只定位、未修改任何代码**。基线 `9d64269`。

---

## 0. 先给结论

**不是 Info.plist 的问题，也不是 Debug/Release 代码差异 —— 是一个把「自动探测」整体锁死在 UserDefaults 上的门禁，外加一个 8 秒定时器与首次系统授权框的竞态。**

一句话：**在 iOS 上，本地网络权限没有查询 API —— 「发起一次 Bonjour 浏览」本身就是唯一的查询方式。所以"先判断权限、再决定要不要探测"在逻辑上不成立：不探测就永远不知道权限状态，也就永远不可能把标记写成 true。**

---

## 1. 最可能的根因（按贡献度排序）

### 根因 1（主因）：`hasEverBeenGranted` 门禁 + iOS 无权限查询 API = 死锁

- `BonjourDiscovery.swift:54-57`：`hasEverBeenGranted` 只读 `UserDefaults.standard.bool(forKey: "BrewPing.LocalNetworkGranted")`。
- 这个键**全仓只有一个写入点**：`BonjourDiscovery.swift:120`，且只在浏览器状态到达 **`.ready`** 时写。
- 而自动探测的两个入口都被这个键挡住：
  - `ContentView.swift:179`（进设备页）：`if BonjourDiscovery.hasEverBeenGranted { bonjour.startSearching() }`
  - `ContentView.swift:264`（回到前台）：`if BonjourDiscovery.hasEverBeenGranted || bonjour.localNetwork.isDenied`

于是形成闭环：**首次安装 → 容器为空 → flag = false → 不探测 → 浏览器不启动 → 永远到不了 `.ready` → flag 永远是 false**。

关键在于：**即使系统层面本地网络已经授权**（从旧版本继承，或用户已在设置里打开），App 也无从得知 —— 因为 iOS 不提供查询接口。所以表现为"系统明明允许了，App 却照旧扫不到"，而手动 IP 直连走的是 `URLSession`，不经过 `NWBrowser`，自然正常。**这正是你问题 H 的答案：是。**

### 根因 2（放大器）：8 秒 `stopBrowsing()` 与首次系统授权框的竞态

`BonjourDiscovery.swift:106-108`：

```swift
timer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
    self?.stopBrowsing()
}
```

这个 8 秒窗口**从 `startSearching()` 一进来就开始计时，把用户读系统授权框、点「允许」的时间全部算在内**。

首次安装时第一次探测必然弹框。用户只要超过 8 秒才点「允许」：
- 浏览器已在 `stopBrowsing()`（:168-174）里被 `cancel()`；
- 用户点「允许」时浏览器已经死了 → `.ready` 回调**不会来** → flag 永远写不进去；
- 于是**用户明明授权了，App 却依然永久锁死自动探测**。

自相矛盾的证据：`PermissionCenter.waitForLocalNetworkToSettle`（`PermissionCenter.swift:152-171`）给的兜底是 **12 秒**，比浏览器 8 秒的寿命还长 —— UI 还在等"落定"，探测者已经先死了，这个 12 秒注定超时。**这是你问题 G 的答案：是，8 秒过短，且短得自相矛盾。**

### 根因 3（环境因素，解释"为什么 Debug 正常"）

代码里**没有任何 Debug/Release 分支**（见 §3），差异全部来自运行环境：

1. **开发机的 UserDefaults 里 flag 早已是 true** —— 旧版本曾无条件探测并到过 `.ready`，而 Xcode 重装**不清 App 容器**，标记一直留着。
2. **调试器附着时本地网络权限的执行与无调试器时不同** —— 这是社区长期观察到的现象：Xcode 直跑的 Debug 版往往未授权也能通，TestFlight / 商店版才会真正被拦。
3. TestFlight 首装（尤其删掉旧 App 之后）→ 容器清空 → flag 归零 → 同时**必然弹首次授权框** → 撞上根因 2。

---

## 2. 逐条核对（对应你的 A–I）

| 项 | 结论 | 依据 |
|---|---|---|
| **A** flag 会不会导致 NWBrowser 根本不启动 | **是** | `ContentView:179` 与 `:264` 两处门禁；flag 全仓唯一写入点是 `.ready`（`BonjourDiscovery:120`） |
| **B** Info.plist 是否真进 Release 包 | **已排除，无问题** | 见 §3：`GENERATE_INFOPLIST_FILE = NO` + `INFOPLIST_FILE = BrewPing/Info.plist` 在 Debug(:470-471) 与 Release(:493-494) **完全一致**；plist 文件内容完整（`NSBonjourServices = ["_brewping._tcp"]`、`NSLocalNetworkUsageDescription`、`NSAllowsLocalNetworking` 都在） |
| **C** 是否挂错 target | **没有** | 主 App（`com.brewping.ios`）用 `BrewPing/Info.plist`；Watch（`com.brewping.ios.watchkitapp`）用独立的 `Watch/Info.plist`（pbxproj :517-518 / :542-543），互不串 |
| **D** 有无 Debug/Release 代码路径差异 | **无** | `ios/` 全目录搜 `#if DEBUG` / `#if RELEASE` / `ProcessInfo.environment`：**0 处** |
| **E** 生命周期时序 | **发现 1 个真问题** | 8s 计时器 vs 首次授权框（根因 2）；其余正常：`resolveNew` 在主队列触发、`NetService` 回调投主 run loop（:71 注释）、`stopBrowsing()` 刻意保留在途解析、`stopSearching()` 才全停 |
| **F** flag 是否把两件事等同 | **是** | flag 只在「我们的浏览器到过 `.ready`」时写，与「系统是否已授权」无关；系统已授权但 App 从未探测过 → flag 仍是 false |
| **G** 8 秒是否过短 | **是，且自相矛盾** | 8s < 12s 兜底；且窗口内含用户读框/点框时间 |
| **H** 系统已授权但 flag=false 是否仍阻止 | **是** | 同 A；这是本次现象的最直接解释 |
| **I** 最小修改方案 | 见 §5 | 2 个文件、约 10 行 |

---

## 3. Info.plist 与构建设置的核查细节（问题 B 的完整证据）

`ios/BrewPing.xcodeproj/project.pbxproj` 主 App target 两个配置**逐字段一致**：

| 行 | Debug | Release |
|---|---|---|
| `GENERATE_INFOPLIST_FILE` | `NO` | `NO` |
| `INFOPLIST_FILE` | `BrewPing/Info.plist` | `BrewPing/Info.plist` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.brewping.ios` | `com.brewping.ios` |
| `INFOPLIST_KEY_NSLocalNetworkUsageDescription` | 有 | 有（**但见下方注**） |

`ios/BrewPing/Info.plist` 关键键全部在位：`NSBonjourServices`（数组，`_brewping._tcp`）、`NSLocalNetworkUsageDescription`、`NSAppTransportSecurity.NSAllowsLocalNetworking`、`NSCameraUsageDescription`、`NSSpeechRecognitionUsageDescription`、`CFBundleURLSchemes = brewping`。

> **注（顺带发现的死配置）**：`INFOPLIST_KEY_*` 这类构建设置**只在 `GENERATE_INFOPLIST_FILE = YES` 时才会被注入**。本项目是 `NO`，所以 :472 / :495 这两条是**无效配置** —— 真正的文案来自 `Info.plist` 文件。它无害，但会误导后人以为文案来源是构建设置，建议 Phase 2 顺手删掉。

**结论：B / C 可以排除。** 如果 Info.plist 真有问题，Xcode 直装的 Debug 版也会扫不到 —— 与现象不符。

---

## 4. 「为什么 Debug 正常、TestFlight 异常」—— 三因素叠加

| 因素 | Xcode 直装 Debug | TestFlight |
|---|---|---|
| App 容器（UserDefaults） | 历次重装**保留**，flag 早已是 true | 首装/删后重装 → **清空**，flag = false |
| 调试器 | 附着 → 本地网络权限执行宽松 | 无调试器 → 真正执行权限 |
| 首次授权框 | 早已答过，不再弹 → 浏览器亚秒级到 `.ready` | **必弹** → 8 秒窗口被读框时间吃掉 |
| 结果 | `.ready` → flag 写 true → 一切正常 | 浏览器被掐 / 根本没启动 → 死锁 |

另外，手动 IP 直连之所以正常：它走 `URLSession` 直连局域网 IP，不经过 `NWBrowser`，而且**这次连接本身就会触发/消耗本地网络授权** —— 用户往往是在手动连接时把权限授出去的，但 App 的 flag 依旧不知道。

---

## 5. 最小修复方案（2 个文件，约 10 行）

核心思路：**把「探测」与「持久标记」解耦 —— 探测本身就是查询，不该被查询结果拦住。**

### 改动 1：`ios/BrewPing/ContentView.swift:179` —— 去掉门禁

```swift
// 现在：
if BonjourDiscovery.hasEverBeenGranted { bonjour.startSearching() }
// 改为：
bonjour.startSearching()
```

理由：
- iOS 没有本地网络权限的查询 API，**探测即查询**；不探测就永远拿不到真实状态。
- 「连续弹多个权限框」的老问题**不会回归**：那是当年语音 / 相机 / 本地网络三处**同时自动请求**造成的。现在语音与相机只由用户点击触发（`PermissionCenter` 的既定设计，本次不动），进设备页自动探测只会有本地网络**这一个**框，不存在重叠。

### 改动 2：`ios/BrewPing/BonjourDiscovery.swift:106-108` —— 权限未落定就不停浏览

把「到 8 秒一律停」改成「**权限已落定才停；还在等授权就续期**」：

```swift
timer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
    guard let self else { return }
    if self.localNetwork == .requesting {
        // 系统授权框还挂着：此刻掐掉浏览器会让 .ready 永远不来、
        // flag 永远写不进去 —— 续一个窗口再等（上限 3 次，防止无限挂着）。
        self.extendBrowsingWindow()      // 内部：再排一个 8s，retries += 1，>3 次才 stopBrowsing
        return
    }
    self.stopBrowsing()
}
```

效果：已授权的常态路径仍是 8 秒窗口（空态卡的出现时机不变）；只有「系统框还挂着」这一种情况会延长，用户有充足时间点「允许」，`.ready` 一到就落定并写 flag。

### 保持不动（它们本来就是对的）

- `PermissionCenter` 的**串行请求**、权限卡、「打开系统设置」（`openSystemSettings`）、12 秒兜底 —— 全部保留。需求里的"未授权给引导 / 拒绝给出路"现在就已具备（`ContentView:158-159` 卡片、`:560` 设置按钮）。
- `UserDefaults` 的 flag **保留**，但用途退化为「首帧近似值」（`PermissionCenter.swift:36-37`，避免已授权用户的权限卡闪现）。修完之后它会被正常写上，不再是开关。
- `discoverForSheet()`（`ContentView:1142`，手动加设备表单里的"自动发现"）本来就**无门禁**，不动。
- Watch、Mac 广播（`BonjourAdvertiser`）、Windows 广播（`mdns_broadcast.rs`）完全不动。

### 顺带（可选项，属清理）

删除 `project.pbxproj` :472 / :495 的 `INFOPLIST_KEY_NSLocalNetworkUsageDescription` —— 在 `GENERATE_INFOPLIST_FILE = NO` 下是无效配置。

---

## 6. TestFlight 验证步骤

**关键前置：先把手机上的 App 删掉再装 TestFlight**（否则 UserDefaults 与系统权限会被继承，掩盖问题）。

| 场景 | 步骤 | 预期 |
|---|---|---|
| ① 主验证 | 删 App → 装 TestFlight → 首启 → 进设备页 | **~1 秒内弹系统本地网络框**；点允许 → 「正在搜索」→ 数秒内出现 Mac/Windows；杀进程重启 → 不再弹框、自动发现直接工作 |
| ② 拒绝路径 | 删 App 重装 → 弹框点拒绝 | 卡片显示「被拒」+「打开系统设置」；去设置打开后回 App → 能自动发现 |
| ③ 已授权继承（验证 H） | 不删 App；设置里确认本地网络已开 → 杀进程重开 | 应**自动**发现（修复前此处会被 flag 挡死） |
| ④ 不回归：手动连接 | 手动加设备（IP + 端口） | 照常 |
| ⑤ 不回归：Watch | Watch 发语音指令 | 照常 |
| ⑥ 不回归：广播 | Mac / Windows 桌面端照常运行 | 本轮未动广播方 |

**Info.plist 落地核验（问题 B 的实证方法）**：Xcode → Organizer → 选这次 Archive → Show in Finder → 右键 .xcarchive → Show Package Contents → `Products/Applications/BrewPing.app/Info.plist`，然后

```
plutil -p Info.plist | grep -A3 NSBonjourServices
plutil -p Info.plist | grep NSLocalNetwork
```

（TestFlight 的 build 与对应 archive 内容一致，验 archive 即可。）

---

## 7. 若修复后仍发现不了：要打哪些日志

好消息：**现有日志已经够用**。`BrewPingLog` 用的是 `os.Logger`（`BrewPingLog.swift`），**没有 `#if DEBUG` 门控，Release/TestFlight 照常输出**；且 `BonjourDiscovery.swift:130-132` 已把 `state` 与 `NWError` 以 `privacy: .public` 打出（不会被系统抹掉）。

**采集方式**（TestFlight 无 Xcode 附加）：
- Mac 打开 **Console.app** → 选中 iPhone → 过滤 `subsystem:com.brewping.ios` + `category:discovery`；
- 或 Xcode → Devices & Simulators → View Device Logs；
- 或 `sudo log collect --device --last 5m` 后用 Console 打开。

**建议补打的点**（现有不足时）：
1. `browseResultsChangedHandler`：`results.count` 与每个 endpoint 名（确认有没有结果到达）；
2. `resolveNew`：每个待解析服务名（确认有没有进入解析）；
3. `netServiceDidResolveAddress`：`addresses?.count`；`didNotResolve` 的 `errorDict` 原文；
4. `startSearching()` / `stopBrowsing()` 各打一行时间戳 —— 用来和 8s / 12s 对齐。

**重点看的错误码**：

| 码 | 含义 | 对应动作 |
|---|---|---|
| `dns(-65555)` | `kDNSServiceErr_PolicyDenied` → 本地网络被拒 | 走「打开系统设置」（现有逻辑已覆盖） |
| `dns(-65570)` / `dns(-65563)` | 服务类型未注册 / 非法 | **回头查 `NSBonjourServices` 是否真进了包**（用 §6 的 plutil 验） |
| `posix(65)` EHOSTUNREACH、`posix(50)` ENETDOWN | 网络层不通 | AP 隔离 / 访客网络 / 跨网段 / 蜂窝，与权限无关 |

---

## 8. 一个 3 分钟的二分实验（不用改代码就能验证根因）

在 TestFlight 版里：**打开「添加设备」表单 → 点「自动发现」按钮**。

这个按钮走 `discoverForSheet()`（`ContentView:1142`），它**没有 flag 门禁**，会无条件 `startSearching()`。

- **这样能发现设备** → 证明广播、网络、Info.plist 全都没问题，问题就是 flag 门禁（根因 1 成立，按 §5 修即可）；
- **这样也发现不了** → 才需要怀疑 plist / 系统策略 / 网络层，按 §7 的日志继续查，同时用 §6 的 plutil 验包。

（若系统框此时弹出并允许后就能发现，同时也证实了根因 2 的竞态。）

---

## 9. 本次明确的**不做**清单

- ❌ 不删除权限检查、不把 `hasEverBeenGranted` 永久置 true（这会让 PermissionCenter 的首帧近似值与权限卡全部失真，且掩盖真实权限状态）
- ❌ 不动 `PermissionCenter` 的串行请求设计（它解决的是"三个框同时弹"，与本次问题正交，且是用户明确要求保住的）
- ❌ 不动 Mac 广播（`BonjourAdvertiser`）、Windows 广播（`mdns_broadcast.rs`）、Watch、手动 IP 连接
- ❌ 不把 8 秒简单改大（会拖慢"空态卡"出现，属于 UX 退化；改成「权限未落定才续期」是精准解）

---

## 10. 修复实施记录（同日 22:14，已改代码）

按 §5 方案实施，`git diff --stat` 确认**只动了两个文件**（`ios/BrewPing/ContentView.swift` +27/−12、
`ios/BrewPing/BonjourDiscovery.swift` +90/−…）。

### `ios/BrewPing/ContentView.swift`

| 位置 | 修改前 | 修改后 |
|---|---|---|
| 进设备页 `onAppear` | `if BonjourDiscovery.hasEverBeenGranted { bonjour.startSearching() }` | 无条件 `bonjour.startSearching()` |
| 回前台 `onChange(of: scenePhase)` | `if hasEverBeenGranted \|\| bonjour.localNetwork.isDenied` | `if !bonjour.isWaitingForPermission` |

回前台条件的含义：已授权 / 已拒绝 / 从未探测 → 都重启；**唯独「正挂在系统授权框上」不重启**
（`startSearching()` 会先 `stopSearching()`，把挂着框的浏览器 cancel 掉）。

### `ios/BrewPing/BonjourDiscovery.swift`

- 新增 `private(set) var isWaitingForPermission`：`.waiting` 且非 PolicyDenied → **true**；
  `.ready` / `.failed` / `.cancelled` / `stopBrowsing()` → false。它是浏览器**当前**是否卡在授权框上的真实状态。
- 8 秒定时器从「到点一律 `stopBrowsing()`」改为 `handleBrowseWindowExpired()`：
  **等授权 → 续一个窗口（上限 3 次 ≈ 32s）**；已落定 / 已定局失败 → 照旧收尾。
- 常量化：`browseWindowSeconds = 8.0`、`maxBrowseExtensions = 3`（不再裸写 8.0）。
- 补 4 类日志（`os.Logger`，Release/TestFlight 可见）：`startSearching` / `stopBrowsing` /
  browser state（每次状态转移）/ `browseResultsChanged`（结果条数）+ 续期原因与到期原因。
- `hasEverBeenGranted` 保留：写入时机不变（`.ready`）；**唯一**消费点变为
  `PermissionCenter.swift:37` 的首帧近似值 —— 门禁引用已全部移除。
- 同步更正 `grantedDefaultsKey` 的文档注释（旧注释还在描述"决定能否自动探测"的旧行为）。

### 验证情况（如实说明）

⚠️ **本机是 Windows，没有 Swift 工具链** → 无法本地编译 Debug / Archive，也无法跑 Watch build。
已做的核对：
1. 改动区域逐个回读，确认括号层级与结构完整；
2. `hasEverBeenGranted` 全仓引用扫描：仅剩定义处 + `PermissionCenter.swift:37`（无任何门禁残留）；
3. `startSearching` 调用点核对：`ContentView:184`（无条件）、`:274`（回前台）、`:1152`（手动发现表单）、`PermissionCenter:147`；
4. 日志插值只用 `Int` / `String` / `String(describing:)`（`os.Logger` 确定支持的重载）；
5. **避免字符串 `+` 拼接 Logger 插值** —— `OSLogMessage` 构造器是否接受 `String` 拼接表达式无法离线验证，
   统一改成单一字面量（与文件内既有写法一致）。

待办：在 Mac / CI 上跑 **iOS Debug build + Archive + Watch build**，再按 §6 的 TestFlight 场景实测。
