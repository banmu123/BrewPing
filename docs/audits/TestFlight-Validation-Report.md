# BrewPing TestFlight Validation Report

> 状态图例：PASS / FAIL / BLOCKED / NOT TESTED
> 本文档随测试进行持续更新。测试日期：2026-09-15 起。

## Environment

| 项 | 值 | 状态 |
|---|---|---|
| Mac | MacBook Air (M2, Mac14,2) · 16 GB | ✅ 已采集 |
| macOS | 15.7.3 (24G419) | ✅ 已采集 |
| Xcode | 26.3 (17C529) | ✅ 已采集 |
| Commit | `007d17a`（注：审计基线 58e3fe5 之后仅合入 macOS 侧 i18n 修复 f08cdba 与文档，iOS/Watch 代码与审计时一致） | ✅ 已采集 |
| iPhone 型号 / iOS | 待填写 | ⏳ 待用户提供 |
| Apple Watch 型号 / watchOS | 待填写 | ⏳ 待用户提供 |
| Wi-Fi 网络 | 待填写（iPhone 与 Mac 需同一局域网） | ⏳ 待用户提供 |

## Pre-flight（Mac 侧，已自动执行）

| 检查 | 结果 |
|---|---|
| Mac 桌面端运行（release，PID 5843） | ✅ |
| HTTP 服务 8787 监听（0.0.0.0） | ✅ |
| Bonjour 广播 `_brewping._tcp`（实例名 `Chenzk`，双接口注册属正常） | ✅ |
| iOS 工程：Version 1.0.0 · Build 1 · Team TGA82PM3DZ · 自动签名 | ✅ |
| Bundle ID：`com.brewping.ios` / `com.brewping.ios.watchkitapp` | ✅ |
| iOS Debug/Release + watchOS Release 构建绿（58e3fe5 审计时点，iOS 代码未再变动） | ✅ |
| `swift test` 22/22 · verify-cli-config 99/99 | ✅ |

## Results

### 二、iPhone 首次启动 — NOT TESTED
### 三、Demo 模式 — NOT TESTED
### 四、Local Network Permission — NOT TESTED
### 五、真实 Mac + Bonjour — NOT TESTED
### 六、QR Pairing — NOT TESTED
### 七、Manual Pairing — NOT TESTED
### 八、Command — NOT TESTED
### 九、命令并发 — NOT TESTED
### 十、Approval — NOT TESTED
### 十一、App Background — NOT TESTED
### 十二、Apple Watch — NOT TESTED
### 十三、Watch Background Wake（最高优先级） — NOT TESTED
### 十四、Watch Failure — NOT TESTED
### 十五、Keychain — NOT TESTED
### 十六、网络切换 — NOT TESTED
### 十七、语言 — NOT TESTED
### 十八、Release UI — NOT TESTED
### 十九、App Store 前最终检查 — NOT TESTED

## P0（TestFlight 阻塞）

（无 — 待测试填充）

## P1

（无 — 待测试填充）

## P2

（无 — 待测试填充）

## Real Device Coverage

- iPhone：0 / 待计数
- Watch：0 / 待计数
- Mac：0 / 待计数

## Final Decision

（待全部测试完成后输出：READY FOR TESTFLIGHT / BLOCKED）
