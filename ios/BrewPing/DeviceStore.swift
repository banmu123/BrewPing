import Foundation
import Combine

/// 管理多台设备的持久化存储
@MainActor
final class DeviceStore: ObservableObject {
    static let shared = DeviceStore()

    @Published var devices: [ManagedDevice] = []
    @Published var activeDeviceID: String = ""

    private let storageKey = "BrewPing.Devices"
    private let activeKey = "BrewPing.ActiveDeviceID"

    var activeDevice: ManagedDevice? {
        devices.first { $0.id == activeDeviceID }
    }

    init() {
        load()
        migrateIfNeeded()
    }

    // MARK: - CRUD

    func addDevice(_ device: ManagedDevice) {
        devices.append(device)
        if devices.count == 1 || activeDeviceID.isEmpty {
            activeDeviceID = device.id
        }
        save()
    }

    func updateDevice(_ device: ManagedDevice) {
        guard let idx = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[idx] = device
        save()
    }

    func removeDevice(id: String) {
        // 删除设备时同时清掉 Keychain 里的配对 token，
        // 否则同一台 Mac 重新添加后会沿用旧 token，一旦 Mac 侧轮换就再也连不上。
        if let device = devices.first(where: { $0.id == id }) {
            DeviceAuth.clear(for: device)
        }
        devices.removeAll { $0.id == id }
        if activeDeviceID == id {
            activeDeviceID = devices.first?.id ?? ""
        }
        save()
    }

    /// 添加（或复用）内置 Demo 设备，供审核员零硬件走通完整链路。
    ///
    /// 幂等：已经有 Demo 设备时只切换为当前设备，不重复添加。
    @discardableResult
    func addDemoDevice() -> ManagedDevice {
        if let existing = devices.first(where: { $0.isDemo }) {
            setActive(existing.id)
            BrewPingLog.demo.info("Reusing existing demo device")
            return existing
        }
        let device = ManagedDevice.new(
            name: "Demo Mac",
            host: DemoBackend.host,
            port: DemoBackend.port,
            osType: .mac
        )
        addDevice(device)
        BrewPingLog.demo.info("Demo device added")
        return device
    }

    func setActive(_ id: String) {
        guard devices.contains(where: { $0.id == id }) else { return }
        activeDeviceID = id
        UserDefaults.standard.set(id, forKey: activeKey)
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        UserDefaults.standard.set(activeDeviceID, forKey: activeKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ManagedDevice].self, from: data) {
            devices = decoded
        }
        activeDeviceID = UserDefaults.standard.string(forKey: activeKey) ?? ""
        // 如果 activeID 无效，回退到第一个
        if !activeDeviceID.isEmpty, !devices.contains(where: { $0.id == activeDeviceID }) {
            activeDeviceID = devices.first?.id ?? ""
        }
    }

    /// 首次启动：把旧的单设备配置迁移过来
    private func migrateIfNeeded() {
        guard devices.isEmpty else { return }
        let host = UserDefaults.standard.string(forKey: "brewping.macAddress") ?? ""
        let port = UserDefaults.standard.string(forKey: "brewping.port") ?? "8787"
        if !host.isEmpty {
            let device = ManagedDevice.new(name: hostname(from: host), host: host, port: port, osType: .mac)
            addDevice(device)
        }
    }

    private func hostname(from host: String) -> String {
        // 192.168.3.94 → "Mac", MyMacbook.local → "MyMacbook"
        if host.hasSuffix(".local") {
            return String(host.dropLast(6))
        }
        return "Mac"
    }
}
