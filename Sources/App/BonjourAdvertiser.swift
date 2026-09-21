import Foundation

/// Mac Agent 的 Bonjour 服务广播。
/// 启动时注册 `_brewping._tcp` 服务，iPhone 可自动发现本机 IP + 端口。
enum BonjourAdvertiser {
    private static var service: NetService?
    /// NetService.delegate 是**弱引用**，必须由这里强持有，否则发布回调收不到。
    private static let publisherDelegate = PublishDelegate()

    /// 是否正在广播（桌面端「本机信息」里 mDNS 一行的依据）。
    private(set) static var isRunning = false

    /// 发布结果（§3 取证）：区分「publish 对象存在」与「publish 真的完成」。
    /// idle / publishing / published / failed(dict)
    private(set) static var publishState = "idle"

    /// 发布回调：确认服务真的发布成功（而不是只创建了对象）。
    private final class PublishDelegate: NSObject, NetServiceDelegate {
        func netServiceDidPublish(_ sender: NetService) {
            BonjourAdvertiser.publishState = "published"
            print("Bonjour: DID_PUBLISH name=\(sender.name) type=\(sender.type) domain=\(sender.domain) port=\(sender.port)")
        }

        func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
            BonjourAdvertiser.publishState = "failed: \(errorDict)"
            print("Bonjour: DID_NOT_PUBLISH name=\(sender.name) type=\(sender.type) domain=\(sender.domain) port=\(sender.port) errorDict=\(errorDict)")
        }

        func netServiceDidStop(_ sender: NetService) {
            print("Bonjour: DID_STOP name=\(sender.name)")
        }
    }

    static func start(port: UInt16, deviceId: String? = nil, deviceName: String? = nil) {
        stop()
        let name = deviceName ?? "BrewPing Agent"
        let svc = NetService(
            domain: "local.",
            type: "_brewping._tcp.",
            name: name,
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
        svc.delegate = publisherDelegate
        publishState = "publishing"
        svc.publish()
        service = svc
        isRunning = true
        // §3：把实际构造参数打全，便于与 dns-sd -L 的输出逐项对照。
        print("Bonjour: publishing name=\(name) type=_brewping._tcp. domain=local. port=\(port) deviceId=\(deviceId ?? "?") txtKeys=\(txtDict.keys.sorted().joined(separator: ","))")
    }

    static func stop() {
        service?.stop()
        service = nil
        isRunning = false
        publishState = "idle"
    }
}
