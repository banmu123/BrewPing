import Foundation

/// Mac Agent 的 Bonjour 服务广播。
/// 启动时注册 `_brewping._tcp` 服务，iPhone 可自动发现本机 IP + 端口。
enum BonjourAdvertiser {
    private static var service: NetService?

    /// 是否正在广播（桌面端「本机信息」里 mDNS 一行的依据）。
    private(set) static var isRunning = false

    static func start(port: UInt16, deviceId: String? = nil, deviceName: String? = nil) {
        stop()
        let svc = NetService(
            domain: "local.",
            type: "_brewping._tcp.",
            name: deviceName ?? "BrewPing Agent",
            port: Int32(port)
        )
        let activeAgent = AgentManager.shared.activeAgentID
        var txtDict: [String: Data] = [:]
        txtDict["version"] = "0.1".data(using: .utf8)
        txtDict["agent"] = activeAgent.data(using: .utf8)
        txtDict["platform"] = "macOS".data(using: .utf8)
        txtDict["protocolVersion"] = "1".data(using: .utf8)
        if let deviceId { txtDict["deviceId"] = deviceId.data(using: .utf8) }
        if let deviceName { txtDict["deviceName"] = deviceName.data(using: .utf8) }
        svc.setTXTRecord(NetService.data(fromTXTRecord: txtDict))
        svc.publish()
        service = svc
        isRunning = true
        print("Bonjour: advertising _brewping._tcp on port \(port) deviceId=\(deviceId ?? "?")")
    }

    static func stop() {
        service?.stop()
        service = nil
        isRunning = false
    }
}
