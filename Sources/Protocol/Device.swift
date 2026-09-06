import Foundation

extension BrewPingProtocol {
    public enum DevicePlatform: String, Codable, Sendable {
        case macOS = "macOS"
        case windows = "Windows"
        case linux = "Linux"
    }

    public enum DeviceStatus: String, Codable, Sendable {
        case online
        case offline
        case busy
    }

    /// 一台可被 BrewPing 管理的设备。
    ///
    /// 迁移映射：当前系统只有"本机"，由 HTTPAPI.statusResponse 中的
    /// `host` 字段隐式表达；未来多设备时升级为本模型。
    public struct Device: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var platform: DevicePlatform
        public var status: DeviceStatus
        /// 扩展信息（如 os 版本、hostname、agent 数量等），键值自由扩展。
        public var metadata: [String: String]

        public init(
            id: String,
            name: String,
            platform: DevicePlatform,
            status: DeviceStatus,
            metadata: [String: String] = [:]
        ) {
            self.id = id
            self.name = name
            self.platform = platform
            self.status = status
            self.metadata = metadata
        }
    }
}
