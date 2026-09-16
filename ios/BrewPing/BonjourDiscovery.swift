import Foundation
import Network
import Darwin

/// 本地网络（Bonjour 浏览）权限的**可见**状态。
///
/// iOS 没有「查询本地网络权限」的公开 API，只能从 `NWBrowser` 的状态推断：
/// - 已授权 → `.ready`
/// - 被拒 / 被系统策略拦截 → `.waiting` 或 `.failed`，错误为
///   `kDNSServiceErr_PolicyDenied`（-65555）
/// - 授权框还没被回答 → 状态停在 `.waiting`，此时**无法**与「被拒」区分
///   （所以这一档归到 `.requesting`；UI 上同时提供「重试」与「去系统设置」两条出路，
///   因为用户拒绝后系统不会再弹窗，只能去设置里打开）。
enum LocalNetworkAccess: Equatable {
    /// 还没探测过（首次进入页面、用户尚未点「授权」）
    case unknown
    /// 已发起探测，结果未明（授权框可能正在显示）
    case requesting
    /// 已确认可浏览
    case granted
    /// 已拒绝 / 被策略拦截 —— 系统不会再弹窗，必须去设置里手动打开
    case denied

    var isGranted: Bool { self == .granted }
    var isDenied: Bool { self == .denied }
}

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

    /// `kDNSServiceErr_PolicyDenied`（见 `dns_sd.h`）。
    /// 该常量是 C 匿名枚举成员，Swift 不可见，故用字面值并在此注明来源。
    static let policyDeniedCode = DNSServiceErrorType(-65555)

    /// 「曾经成功拿到过本地网络权限」的持久标记。
    ///
    /// 用途：决定进入设备页时**能否自动探测**。权限未决（notDetermined）时自动探测会
    /// 未经交互地弹出系统授权框 —— 用户反馈过「弹窗一闪而过没来得及点」，
    /// 因此首次必须由用户点按钮触发；只有确认授权过（或曾拒绝过，拒后系统不会再弹窗）
    /// 才可以静默自动探测。
    static let grantedDefaultsKey = "BrewPing.LocalNetworkGranted"
    static var hasEverBeenGranted: Bool {
        UserDefaults.standard.bool(forKey: grantedDefaultsKey)
    }

    @Published var discoveredHosts: [DiscoveredHost] = []
    @Published var isSearching = false
    /// 本地网络权限状态（用于 UI 区分「权限被拒」与「网络拦多播」）
    @Published private(set) var localNetwork: LocalNetworkAccess = .unknown
    /// 最近一次浏览错误（只用于展示与日志，不含用户数据）
    @Published private(set) var lastBrowseError: String?

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
        // 未确认授权时先标记「探测中」：UI 据此显示进度，而不是停在空白态让人误以为没反应
        if localNetwork != .granted { localNetwork = .requesting }

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_brewping._tcp", domain: "local."), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.handleBrowserState(state)
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

    /// 把 `NWBrowser` 的状态翻译成「权限状态 + 可展示的原因」。
    ///
    /// 旧实现只判 `.failed` 且把 `NWError` 整个丢掉，于是「权限被拒」与「网络拦多播」
    /// 在界面上完全同形（都只是「扫不到」），只能靠猜 —— 这是本轮问题的核心成因之一。
    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            localNetwork = .granted
            lastBrowseError = nil
            UserDefaults.standard.set(true, forKey: Self.grantedDefaultsKey)
        case .waiting(let error), .failed(let error):
            if Self.isPolicyDenied(error) {
                localNetwork = .denied
                lastBrowseError = "policy-denied"
                isSearching = false
            } else {
                localNetwork = .requesting
                lastBrowseError = Self.describe(error)
            }
            BrewPingLog.discovery.error(
                "Browser \(String(describing: state), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        case .cancelled:
            break
        case .setup:
            break
        @unknown default:
            break
        }
    }

    /// 是否「权限被拒 / 被策略拦截」。这是 iOS 上判断本地网络被拒的**唯一**可靠信号。
    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case let .dns(code) = error, code == policyDeniedCode { return true }
        return false
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .dns(let code): return "dns(\(code))"
        case .posix(let code): return "posix(\(code.rawValue))"
        default: return String(describing: error)
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
    ///
    /// 取值用 `NWTXTRecord` 的**下标**（`subscript(String) -> String?`）；
    /// 该类型没有 `get(_:)` 方法（只有 `getEntry(for:)`，返回的是 `Entry` 枚举，不是字符串）。
    private static func osType(from metadata: NWBrowser.Result.Metadata) -> DeviceOSType {
        guard case let .bonjour(txt) = metadata else { return .mac }
        return DeviceOSType.parse(txt["platform"])
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
