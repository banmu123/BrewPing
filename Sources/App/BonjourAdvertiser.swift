import Foundation

/// Mac Agent 的 Bonjour 服务广播。
/// 启动时注册 `_brewping._tcp` 服务，iPhone 可自动发现本机 IP + 端口。
enum BonjourAdvertiser {
    private static var service: NetService?

    static func start(port: UInt16) {
        stop()
        let svc = NetService(
            domain: "local.",
            type: "_brewping._tcp.",
            name: "BrewPing Agent",
            port: Int32(port)
        )
        var txtDict: [String: Data] = [:]
        txtDict["version"] = "0.1".data(using: .utf8)
        txtDict["agent"] = "opencode".data(using: .utf8)
        svc.setTXTRecord(NetService.data(fromTXTRecord: txtDict))
        svc.publish()
        service = svc
        print("Bonjour: advertising _brewping._tcp on port \(port)")
    }

    static func stop() {
        service?.stop()
        service = nil
    }
}
