// 离线类型检查用的符号桩（stub）——只补齐 iOS target 里的跨文件符号，
// 让 `swiftc -typecheck` 能对单个 iOS 源文件跑完整的类型诊断。
//
// 🚨 为什么需要它：本机（Mac）只有 Command Line Tools、没有完整 Xcode，跑不了 xcodebuild。
// 直接对单文件做 typecheck 时，`BrewPingLog` 等跨文件符号解析失败 → 整个 `BrewPingLog.discovery.info(...)`
// 调用在早期就报 cannot find in scope → **OSLog 插值（autoclosure）的 explicit-self 诊断根本不会执行**。
// 结果就是「引用实例属性没写 self.」这类错误离线看不见、每次都漏到 Xcode 构建才炸（已连续发生 3 轮）。
//
// 用法（两个文件一起检查）：
//   xcrun swiftc -typecheck -sdk "$(xcrun --show-sdk-path)" \
//     ios/Scripts/offline-typecheck-stub.swift ios/BrewPing/BonjourDiscovery.swift
//
// 规则：此文件**只增不改**地补符号（与真实定义保持最小兼容）；目标文件里的真实定义优先。
// 新的跨文件符号导致 typecheck 报 cannot find 时，在这里补一个最小桩即可。

import Foundation
import os

// MARK: - BrewPingLog（真实定义在 ios/BrewPing/BrewPingLog.swift）
enum BrewPingLog {
    static let discovery = Logger(subsystem: "com.brewping.ios", category: "discovery")
    static let net = Logger(subsystem: "com.brewping.ios", category: "net")
    static let command = Logger(subsystem: "com.brewping.ios", category: "command")
    static let watch = Logger(subsystem: "com.brewping.ios", category: "watch")
    static let app = Logger(subsystem: "com.brewping.ios", category: "app")
    static let audio = Logger(subsystem: "com.brewping.ios", category: "audio")
    static let demo = Logger(subsystem: "com.brewping.ios", category: "demo")
}

// MARK: - DeviceOSType（真实定义在 ios/BrewPing/DeviceOSType.swift）
enum DeviceOSType: Equatable {
    case mac
    case windows
    case unknown

    static func parse(_ raw: String?) -> DeviceOSType {
        .mac
    }
}
