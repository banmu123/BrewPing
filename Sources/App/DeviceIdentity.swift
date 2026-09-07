import Foundation

/// 稳定的设备标识，持久化在 ~/.brewping/device.json。
/// 第一次启动生成，之后重启/升级/重装都不变。IP 不是 Device ID。
struct DeviceIdentity: Codable {
    let deviceId: String
    let createdAt: Date

    static func loadOrCreate() -> DeviceIdentity {
        let url = deviceURL
        if let data = try? Data(contentsOf: url),
           let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: data) {
            return identity
        }
        let identity = DeviceIdentity(
            deviceId: "bp_mac_" + UUID().uuidString.prefix(8).lowercased(),
            createdAt: Date()
        )
        if let data = try? JSONEncoder().encode(identity) {
            try? data.write(to: url, options: .atomic)
        }
        return identity
    }

    private static var deviceURL: URL {
        SessionManager.shared.directory.appendingPathComponent("device.json")
    }
}
