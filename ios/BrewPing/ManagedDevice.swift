import Foundation

/// 设备 OS 类型
enum DeviceOSType: String, Codable, CaseIterable {
    case mac
    case windows
    case linux

    var icon: String {
        switch self {
        case .mac:     return "desktopcomputer"
        case .windows: return "pc"
        case .linux:   return "terminal"
        }
    }

    var label: String {
        switch self {
        case .mac:     return L("Mac")
        case .windows: return L("Win")
        case .linux:   return L("Linux")
        }
    }

    /// 从外部字符串解析主机类型（`brewping://pair?...` 深链、mDNS TXT `platform` 等）。
    ///
    /// 大小写不敏感、容忍空白，并接受两套命名：
    ///  - 本 App 自己的短名：`mac` / `windows` / `linux`（深链 `osType` 参数用这套）；
    ///  - 各端 `platform` 字段的原生写法：`macOS` / `darwin` / `windows` / `linux`
    ///    （`Sources/App/BonjourAdvertiser.swift` 与 Windows 端 `mdns_broadcast.rs` 广播的 TXT）。
    ///
    /// **缺失或无法识别一律回落 `.mac`** —— 这是加该字段之前的历史行为，
    /// 保证老版本桌面端发出的（不带该信息的）发现记录/深链仍能正常使用，
    /// 不会因解析失败而丢设备。
    static func parse(_ raw: String?) -> DeviceOSType {
        guard let raw else { return .mac }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "windows", "win", "win32", "win64": return .windows
        case "linux", "gnu/linux":               return .linux
        case "mac", "macos", "mac os", "mac os x", "darwin", "osx":
            return .mac
        default:
            return .mac
        }
    }
}

/// 一台被管理的电脑
struct ManagedDevice: Identifiable, Codable, Equatable {
    let id: String
    var name: String          // 用户自定义名称，如 "Chenzk"
    var host: String          // IP 或 hostname
    var port: String          // 端口号
    var osType: DeviceOSType

    var displayName: String {
        "\(osType.label) \(name)"
    }

    /// 是否为内置 Demo 设备。
    ///
    /// 用主机名判定而不是新增一个存储字段，是为了避免 `Codable` 兼容问题：
    /// 旧版本写进 `UserDefaults` 的 JSON 里没有这个键，
    /// 加一个非可选字段会让 `decode` 直接失败、用户设备列表被清空。
    var isDemo: Bool {
        host.lowercased() == DemoBackend.host
    }

    var baseURL: URL? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !p.isEmpty else { return nil }
        return URL(string: "http://\(h):\(p)")
    }

    static func new(name: String = "", host: String = "", port: String = "8787", osType: DeviceOSType = .mac) -> ManagedDevice {
        ManagedDevice(
            id: UUID().uuidString.prefix(8).lowercased().description,
            name: name,
            host: host,
            port: port,
            osType: osType
        )
    }
}
