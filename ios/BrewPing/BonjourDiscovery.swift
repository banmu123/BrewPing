import Foundation
import Network
import Darwin

/// iPhone 端 Bonjour 自动发现：扫描局域网上的 BrewPing Mac Agent。
/// 通过 NetService 解析出真实 IP + 端口，用户无需手动输入。
///
/// 注意：`NWBrowser` 给出的 endpoint 只有**服务实例名**（等于 Mac 的电脑名，可能含空格），
/// 不能当主机名用；必须解析后才能拿到可连接地址。
final class BonjourDiscovery: NSObject, ObservableObject {
    struct DiscoveredHost: Identifiable, Equatable {
        let id: String
        let name: String
        let host: String
        let port: UInt16
        /// 主机类型，取自服务 TXT 记录里的 `platform`。
        /// Mac 广播 `macOS`、Windows 端广播 `windows`；缺省或未知回落 `.mac`。
        let osType: DeviceOSType
    }

    @Published var discoveredHosts: [DiscoveredHost] = []
    @Published var isSearching = false

    /// 是否仍有服务在解析中（浏览停止后，已发现的服务可能还在解析）
    var isResolving: Bool { !resolvers.isEmpty }

    private var browser: NWBrowser?
    private var timer: Timer?
    /// 仅在主队列读写：resolveNew 在主队列触发，NetService 回调也投递到主线程 run loop
    private var resolvers: [String: NetService] = [:]
    /// 服务实例名 → 从 TXT 记录读出的主机类型。
    /// `NetServiceDelegate` 的回调不携带 TXT，所以在浏览阶段先存下来，解析完成时取用。
    private var pendingOS: [String: DeviceOSType] = [:]

    func startSearching() {
        stopSearching()
        isSearching = true
        discoveredHosts = []
        pendingOS = [:]

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_brewping._tcp", domain: "local."), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                if case .failed = state {
                    self?.isSearching = false
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                self?.resolveNew(results)
            }
        }

        browser.start(queue: DispatchQueue.global(qos: .userInitiated))
        self.browser = browser

        // 8 秒后停止「浏览」；已发现服务的解析会继续跑完，不会被中断
        timer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            self?.stopBrowsing()
        }
    }

    /// 完整停止：结束浏览并取消所有未完成的解析
    func stopSearching() {
        stopBrowsing()
        for (_, service) in resolvers {
            service.delegate = nil
            service.stop()
        }
        resolvers.removeAll()
        pendingOS.removeAll()
    }

    /// 只结束浏览，保留在途解析
    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        timer?.invalidate()
        timer = nil
        isSearching = false
    }

    // MARK: - Resolution

    /// 对每个新出现的服务实例发起一次解析（解析结果通过 NetServiceDelegate 回调）
    private func resolveNew(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            // TXT 只在这里拿得到（NWBrowser.Result 上），先记下来给 finishResolve 用。
            pendingOS[name] = Self.osType(from: result.metadata)
            guard resolvers[name] == nil else { continue }
            guard !discoveredHosts.contains(where: { $0.id == name }) else { continue }

            let service = NetService(domain: "local.", type: "_brewping._tcp.", name: name)
            service.delegate = self
            resolvers[name] = service
            service.resolve(withTimeout: 4.0)
        }
    }

    private func finishResolve(name: String, host: String?, port: UInt16) {
        if let service = resolvers.removeValue(forKey: name) {
            service.delegate = nil
            service.stop()
        }
        let osType = pendingOS.removeValue(forKey: name) ?? .mac

        guard let host, !host.isEmpty, port > 0 else {
            // 设备名可能包含用户自己的电脑名，标记 .private。
            BrewPingLog.discovery.info("Failed to resolve \(name, privacy: .private)")
            return
        }

        discoveredHosts.removeAll { $0.id == name }
        discoveredHosts.append(DiscoveredHost(id: name, name: name, host: host, port: port, osType: osType))
        BrewPingLog.discovery.info("Resolved \(name, privacy: .private) -> \(host, privacy: .private):\(Int(port), privacy: .public)")
    }

    /// 从 Bonjour TXT 记录里读主机类型。
    /// 广播方（`Sources/App/BonjourAdvertiser.swift` 与 Windows 端 `mdns_broadcast.rs`）
    /// 在 `platform` 里写各自的原生 OS 名（`macOS` / `windows`），交给 `DeviceOSType.parse` 归一化。
    private static func osType(from metadata: NWBrowser.Result.Metadata) -> DeviceOSType {
        guard case let .bonjour(txt) = metadata else { return .mac }
        return DeviceOSType.parse(txt.get("platform"))
    }

    /// 优先返回 IPv4 字面量（URLSession 直连最稳），失败时回退到 mDNS 主机名
    private static func ipv4Address(from addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        for data in addresses {
            let ip: String? = data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                guard base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family == sa_family_t(AF_INET) else {
                    return nil
                }
                var addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard let cString = inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) else {
                    return nil
                }
                return String(cString: cString)
            }
            if let ip { return ip }
        }
        return nil
    }

    /// `"MacBook-Pro.local."` -> `"MacBook-Pro.local"`
    private static func normalizedHostName(_ hostName: String?) -> String? {
        guard var host = hostName, !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
}

// MARK: - NetServiceDelegate

extension BonjourDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = Self.ipv4Address(from: sender.addresses) ?? Self.normalizedHostName(sender.hostName)
        finishResolve(name: sender.name, host: host, port: UInt16(clamping: sender.port))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finishResolve(name: sender.name, host: nil, port: 0)
    }
}
