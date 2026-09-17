import Foundation
import Network
import Darwin

/// 本地网络（Bonjour 浏览）权限的**可见**状态。
///
/// iOS 没有「查询本地网络权限」的公开 API，只能从 `NWBrowser` 的状态推断：
/// - 已授权 → `.ready`
/// - 被拒 / 被系统策略拦截 → `.waiting` 或 `.failed`，错误为
///   `kDNSServiceErr_PolicyDenied`（-65570）或 `kDNSServiceErr_NotPermitted`（-65571）
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
///
/// 地址解析**不经过 `NetService`**：浏览器给出的 `NWEndpoint` 直接交给 `NWConnection`，
/// 由 Network framework 完成解析 + TCP 连接（`.ready` 即证明可连），再从这条成功连接上
/// 取 `host:port` 交给现有 URLSession 层。
/// （旧 `NetService.resolve` 路径在真机上会停摆至超时，已于 2026-09-17 弃用并删除。）
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

    /// `kDNSServiceErr_PolicyDenied`（-65570），见 `dns_sd.h`。
    ///
    /// 🚨 这里**曾经写死 -65555**，而 -65555 其实是 `kDNSServiceErr_NoAuth` ——
    /// 后果是「真实被拒」永远识别不出来：iOS 返回 -65570 时被当成「还在等授权」，
    /// 于是续期浏览窗口约 32 秒后安静收尾 —— 既不出「被拒 + 打开系统设置」的提示，
    /// 也永远扫不到设备（TestFlight 上就表现为"死活检测不出设备"）。
    /// 现在直接用 C 符号（Swift 可见，已验证），不再写字面值，避免再次写错。
    static let policyDeniedCode = DNSServiceErrorType(kDNSServiceErr_PolicyDenied)

    /// `kDNSServiceErr_NotPermitted`（-65571）：系统层面不允许本次浏览
    /// （例如服务类型没在 `NSBonjourServices` 里声明）。
    /// 同样按「被拒」处理 —— 否则会一直停在 `.requesting`，用户得不到任何出路。
    static let notPermittedCode = DNSServiceErrorType(kDNSServiceErr_NotPermitted)

    /// 单个浏览窗口长度（已授权 / 已拒绝的常态路径，保持原有「有限时间扫描」的 UX）。
    private static let browseWindowSeconds: TimeInterval = 8.0
    /// 「等授权」时浏览窗口最多续期次数（8s × 3 ≈ 最长约 32s）：
    /// 权限未落定不掐浏览器，但也不能无限扫描。
    private static let maxBrowseExtensions = 3

    /// 「曾经成功拿到过本地网络权限」的持久标记。
    ///
    /// 用途：**仅作 UI 首帧近似值**（`PermissionCenter.localNetwork` 的初值），
    /// 让已授权过的用户不会被权限卡闪一下。
    ///
    /// 它**不再**是「要不要自动探测」的门禁 —— 探测本身没有门槛：iOS 没有
    /// 本地网络权限的查询 API，「发起一次浏览」就是唯一的查询方式；先看标记
    /// 再决定探测，会让首装（容器为空）永远探测不了（TestFlight 自动发现死锁）。
    /// 写入时机：浏览器到达 `.ready`（即系统确认已授权）。
    static let grantedDefaultsKey = "BrewPing.LocalNetworkGranted"
    static var hasEverBeenGranted: Bool {
        UserDefaults.standard.bool(forKey: grantedDefaultsKey)
    }

    /// 浏览直接得到的服务（**不经过 `NetService`**）：endpoint 即 Network framework 的连接目标。
    /// 诊断与 UI 均以此为准；`host/port` 只在 NWConnection 到达 `.ready` 后才有。
    struct DiscoveredService: Identifiable, Equatable {
        /// 服务实例名（= Mac 电脑名），同时是去重键
        let id: String
        let name: String
        let endpoint: NWEndpoint
        /// 可连接性探测状态（NWConnection）
        var probeState: String
        /// TXT 记录（§11）
        let osType: DeviceOSType
        let deviceId: String?
        let agent: String?
        let protocolVersion: String?
        /// `NWBrowser.Result.interfaces` 的条数（§10 只记录、不自行选路）
        let interfaces: Int

        /// NWEndpoint 是 Equatable；这里只用 id + endpoint 判定同一服务。
        static func == (lhs: DiscoveredService, rhs: DiscoveredService) -> Bool {
            lhs.id == rhs.id && String(describing: lhs.endpoint) == String(describing: rhs.endpoint)
                && lhs.probeState == rhs.probeState
        }
    }

    @Published var discoveredHosts: [DiscoveredHost] = []
    @Published var isSearching = false
    /// 本地网络权限状态（用于 UI 区分「权限被拒」与「网络拦多播」）
    @Published private(set) var localNetwork: LocalNetworkAccess = .unknown

    /// 浏览发现的服务（endpoint 形态，无需 NetService）
    @Published private(set) var discoveredServices: [DiscoveredService] = []

    /// 是否仍有服务在探测中（浏览停止后，已发现的服务可能还在探测）
    var isResolving: Bool { !probes.isEmpty }

    /// 扫描会话号：每真正发起一轮新浏览 +1。所有日志都带它，
    /// 用于区分「第 N 次扫描到底有没有真正 START / FOUND / RESOLVE」（§2/§10）。
    private(set) var scanSession = 0

    private var browser: NWBrowser?
    private var timer: Timer?
    /// 浏览是否正卡在「等授权」上（`.waiting` 且非 PolicyDenied —— 系统本地网络框可能还挂着）。
    ///
    /// 8 秒窗口到期时据此决定收尾还是续期：权限未落定时**不能**掐浏览器，
    /// 否则 `.ready` 永远不会回调、持久标记永远写不进去（TestFlight 首装死锁的根因）。
    /// `ContentView` 回前台也用它判断要不要重新探测 —— 比 UserDefaults 标记更能
    /// 代表「现在能不能探测」（后者只表示「曾到过 `.ready`」，不代表系统当前是否允许）。
    private(set) var isWaitingForPermission = false
    /// 「等授权」窗口的已续期次数（见 `maxBrowseExtensions`）。
    private var browseExtensions = 0

    /// name → 正在进行的 NWConnection 探测（`.ready` 抓到 ip:port 后即取消）。
    private var probes: [String: NWConnection] = [:]

    func startSearching() {
        // 新一轮扫描接管上一轮：只重启浏览器与在途探测，旧对象一律终止（防止残留状态干扰）。
        scanSession += 1
        stopBrowsing(reason: "superseded-by-new-scan")
        teardownProbes(reason: "superseded-by-new-scan")
        isSearching = true
        discoveredHosts = []
        discoveredServices = []
        browseExtensions = 0
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

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            DispatchQueue.main.async {
                guard let self else { return }
                BrewPingLog.discovery.info(
                    "Browse results: session=\(self.scanSession, privacy: .public) count=\(results.count, privacy: .public) changes=\(String(describing: changes), privacy: .public)"
                )
                self.ingest(results)
            }
        }

        browser.start(queue: DispatchQueue.global(qos: .userInitiated))
        self.browser = browser
        BrewPingLog.discovery.info("SCAN_START session=\(self.scanSession, privacy: .public) browser=_brewping._tcp (window \(Int(Self.browseWindowSeconds), privacy: .public)s, extension cap \(Self.maxBrowseExtensions, privacy: .public))")

        // 浏览窗口到期交由 handleBrowseWindowExpired 决定收尾还是续期：
        // **权限未落定时不能掐浏览器**（否则 .ready 不会回调、持久标记写不进去）；
        // 已发现服务的解析会继续跑完，不会被中断。
        timer = Timer.scheduledTimer(withTimeInterval: Self.browseWindowSeconds, repeats: false) { [weak self] _ in
            self?.handleBrowseWindowExpired()
        }
    }

    /// 把 `NWBrowser` 的状态翻译成「权限状态 + 可展示的原因」。
    ///
    /// 旧实现只判 `.failed` 且把 `NWError` 整个丢掉，于是「权限被拒」与「网络拦多播」
    /// 在界面上完全同形（都只是「扫不到」），只能靠猜 —— 这是本轮问题的核心成因之一。
    private func handleBrowserState(_ state: NWBrowser.State) {
        BrewPingLog.discovery.info("Browser \(String(describing: state), privacy: .public)")
        switch state {
        case .ready:
            localNetwork = .granted
            isWaitingForPermission = false
            UserDefaults.standard.set(true, forKey: Self.grantedDefaultsKey)
        case .waiting(let error):
            if Self.isPolicyDenied(error) {
                localNetwork = .denied
                isSearching = false
                isWaitingForPermission = false
            } else {
                localNetwork = .requesting
                // 授权框可能正挂着（`.waiting` 与「等系统回答」无法区分，见类型注释）：
                // 标记「仍在等授权」，浏览窗口到期时据此**续期**而不是掐掉浏览器。
                isWaitingForPermission = true
            }
            BrewPingLog.discovery.error(
                "Browser \(String(describing: state), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        case .failed(let error):
            if Self.isPolicyDenied(error) {
                localNetwork = .denied
                isSearching = false
            } else {
                localNetwork = .requesting
            }
            // `.failed` 是定局（无论是否 PolicyDenied）：不再续期，等窗口到期收尾。
            isWaitingForPermission = false
            BrewPingLog.discovery.error(
                "Browser \(String(describing: state), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        case .cancelled:
            isWaitingForPermission = false
        case .setup:
            break
        @unknown default:
            break
        }
    }

    /// 是否「权限被拒 / 被策略拦截」。这是 iOS 上判断本地网络被拒的**唯一**可靠信号。
    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case let .dns(code) = error {
            return code == policyDeniedCode || code == notPermittedCode
        }
        return false
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .dns(let code): return "dns(\(code))"
        case .posix(let code): return "posix(\(code.rawValue))"
        default: return String(describing: error)
        }
    }

    /// 完整停止：结束浏览并取消所有未完成的探测
    func stopSearching() {
        stopBrowsing(reason: "page-exit-or-final-stop")
        teardownProbes(reason: "page-exit-or-final-stop")
    }

    /// 只结束浏览。`reason` 记录是谁停的（§8）：window-expired / superseded-by-new-scan / page-exit。
    private func stopBrowsing(reason: String) {
        BrewPingLog.discovery.info(
            "BROWSER_STOP session=\(self.scanSession, privacy: .public) reason=\(reason, privacy: .public)"
        )
        browser?.cancel()
        browser = nil
        timer?.invalidate()
        timer = nil
        isWaitingForPermission = false
        isSearching = false
    }

    /// 浏览窗口到期。
    ///
    /// 权限已落定（`.granted` / `.denied`）或浏览器已定局失败 → 正常收尾，
    /// 保持原有「有限时间扫描」的 UX；
    /// 还在等授权（系统本地网络框挂着）→ **不能**掐浏览器：掐掉之后 `.ready`
    /// 永远不会回调、持久标记永远写不进去（TestFlight 首装死锁的根因），
    /// 改为续一个窗口，最多 `maxBrowseExtensions` 次。
    private func handleBrowseWindowExpired() {
        if isWaitingForPermission, browseExtensions < Self.maxBrowseExtensions {
            browseExtensions += 1
            BrewPingLog.discovery.info("Permission still pending (\(String(describing: self.localNetwork), privacy: .public)); extend browse window \(self.browseExtensions, privacy: .public)/\(Self.maxBrowseExtensions, privacy: .public)")
            timer = Timer.scheduledTimer(withTimeInterval: Self.browseWindowSeconds, repeats: false) { [weak self] _ in
                self?.handleBrowseWindowExpired()
            }
            return
        }
        BrewPingLog.discovery.info("Browse window expired: session=\(self.scanSession, privacy: .public) state=\(String(describing: self.localNetwork), privacy: .public), extensions=\(self.browseExtensions, privacy: .public) → stop browsing")
        stopBrowsing(reason: "window-expired")
    }

    // MARK: - Discovery → Connection（新路径：endpoint 直连，不用 NetService）

    /// 浏览结果直接入库：保存 endpoint / TXT / interfaces，并对每个新服务发起一次
    /// `NWConnection` 可连接性探测（§2/§5/§6）。
    ///
    /// 关键约束（§4）：**绝不把 endpoint 还原成 name/type/domain 再喂给 `NetService`** ——
    /// endpoint 必须直接进入 Network framework 的连接路径。
    private func ingest(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            let txt = Self.txt(from: result.metadata)
            let service = DiscoveredService(
                id: name,
                name: name,
                endpoint: result.endpoint,
                probeState: "found",
                osType: DeviceOSType.parse(txt["platform"]),
                deviceId: txt["deviceId"],
                agent: txt["agent"],
                protocolVersion: txt["protocolVersion"],
                interfaces: result.interfaces.count
            )
            if let idx = discoveredServices.firstIndex(where: { $0.id == name }) {
                discoveredServices[idx] = service
                // TXT 常见于 `.changed` 回调才到位（首帧 metadata 为 `<none>`）：
                // 若设备已入列表，补一次 osType，避免 Windows 主机被按 `.mac` 兜底错标（"幽灵 Mac"）。
                if let hostIdx = discoveredHosts.firstIndex(where: { $0.id == name }),
                   discoveredHosts[hostIdx].osType != service.osType {
                    let old = discoveredHosts[hostIdx]
                    discoveredHosts[hostIdx] = DiscoveredHost(
                        id: old.id, name: old.name, host: old.host, port: old.port, osType: service.osType
                    )
                    BrewPingLog.discovery.info(
                        "bonjour: OSTYPE_UPDATED session=\(self.scanSession, privacy: .public) name=\(name, privacy: .private) osType=\(String(describing: service.osType), privacy: .public)"
                    )
                }
            } else {
                discoveredServices.append(service)
                BrewPingLog.discovery.info(
                    "bonjour: FOUND session=\(self.scanSession, privacy: .public) name=\(name, privacy: .private) endpoint=\(String(describing: result.endpoint), privacy: .public) interfaces=\(result.interfaces.count, privacy: .public) platform=\(txt["platform"] ?? "?", privacy: .public) deviceId=\(txt["deviceId"] ?? "?", privacy: .public)"
                )
            }
            // 已有在途探测就不重复发起（同一轮里 browse 会多次回调同一集合）
            guard probes[name] == nil else { continue }
            guard !discoveredHosts.contains(where: { $0.id == name }) else { continue }
            startProbe(for: service)
        }
    }

    /// 用 `NWConnection(to: endpoint)` 验证「这个 Bonjour 服务此刻是否真的可连」（§5/§7）。
    /// 第一阶段只验证到 `.ready`：拿到真实 ip:port 后立刻取消连接（证据已取到），
    /// 业务通信仍由现有 URLSession / 上层负责（§8：不重写 HTTP/WebSocket）。
    private func startProbe(for service: DiscoveredService) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        // 🚨 **优先 IPv4**：本机同时广播 A/AAAA，而 Network framework 默认可能选中
        // IPv6 链路本地地址（真机实测拿到 `fe80::…%en0`）——下游 URLSession 的
        // `http://\(host):\(port)` 拼接只支持 IPv4 / 主机名，IPv6 字面量（还需方括号
        // 与 scope）会拼出非法 URL。老路径（NetService）同样是显式优先 IPv4 的，
        // 这里恢复同一策略：探测连接固定走 IPv4，拿到的 host 即 IPv4 字面量。
        // （注意 API：`internetProtocol` 返回基类 `NWProtocolOptions`，需转型为
        //  `NWProtocolIP.Options`，版本枚举是 `.v4` / `.v6` 而非 `.ipv4`。）
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: service.endpoint, using: params)
        probes[service.id] = connection
        let startedAt = CFAbsoluteTimeGetCurrent()
        setProbeState(service.id, "connecting")
        BrewPingLog.discovery.info(
            "conn: REQUEST session=\(self.scanSession, privacy: .public) name=\(service.name, privacy: .private) endpoint=\(String(describing: service.endpoint), privacy: .public) interfaces=\(service.interfaces, privacy: .public)"
        )
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.handleConnectionState(state, service: service, connection: connection, startedAt: startedAt)
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    private func handleConnectionState(_ state: NWConnection.State, service: DiscoveredService, connection: NWConnection, startedAt: CFAbsoluteTime) {
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        switch state {
        case .ready:
            // 连接建立成功 → 取本次连接的远端地址，作为交给现有通信层（URLSession）的 host:port。
            // 注意：这是「本条连接实际用的地址」，不是「Bonjour 解析出的 IP」；
            // 我们不依赖它做任何解析判断，只用它把可连接的服务交给下游。
            var host: String?
            var port: UInt16?
            if case let .hostPort(h, p)? = connection.currentPath?.remoteEndpoint {
                // 🚨 `NWEndpoint.Host` 的字符串可能带接口 scope（实测 `192.168.5.68%en0`），
                // 这不是合法 URL host —— 必须砍掉 `%` 及其后部分，否则 URLSession 会拿到畸形地址。
                let raw = "\(h)"
                host = raw.split(separator: "%").first.map(String.init) ?? raw
                port = p.rawValue
            }
            setProbeState(service.id, "ready")
            BrewPingLog.discovery.info(
                "conn: READY session=\(self.scanSession, privacy: .public) name=\(service.name, privacy: .private) host=\(host ?? "nil", privacy: .private) port=\(Int(port ?? 0), privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms"
            )
            if let host, !host.isEmpty, let port, port > 0 {
                discoveredHosts.removeAll { $0.id == service.id }
                discoveredHosts.append(DiscoveredHost(id: service.id, name: service.name, host: host, port: port, osType: service.osType))
                BrewPingLog.discovery.info(
                    "bonjour: DEVICE_VISIBLE session=\(self.scanSession, privacy: .public) name=\(service.name, privacy: .private) → device list"
                )
            }
            // 证据已取到：关闭探测连接，业务连接由现有层建立。
            connection.cancel()
        case .waiting(let error):
            setProbeState(service.id, "waiting(\(Self.describe(error)))")
            BrewPingLog.discovery.error(
                "conn: WAITING session=\(self.scanSession, privacy: .public) name=\(service.name, privacy: .private) error=\(Self.describe(error), privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms"
            )
        case .failed(let error):
            setProbeState(service.id, "failed(\(Self.describe(error)))")
            probes.removeValue(forKey: service.id)
            BrewPingLog.discovery.error(
                "conn: FAILED session=\(self.scanSession, privacy: .public) name=\(service.name, privacy: .private) error=\(Self.describe(error), privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms"
            )
        case .cancelled:
            probes.removeValue(forKey: service.id)
        case .setup, .preparing:
            BrewPingLog.discovery.debug(
                "conn: \(String(describing: state), privacy: .public) name=\(service.name, privacy: .private)"
            )
        @unknown default:
            break
        }
    }

    private func setProbeState(_ id: String, _ state: String) {
        guard let idx = discoveredServices.firstIndex(where: { $0.id == id }) else { return }
        discoveredServices[idx].probeState = state
    }

    /// 终止全部在途探测（新一轮扫描接管 / 页面退出）。
    private func teardownProbes(reason: String) {
        guard !probes.isEmpty else { return }
        BrewPingLog.discovery.info(
            "conn: CANCELLED session=\(self.scanSession, privacy: .public) n=\(self.probes.count, privacy: .public) reason=\(reason, privacy: .public)"
        )
        for (_, connection) in probes {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        probes.removeAll()
    }

    /// 取出我们关心的 TXT 键（§11：platform / deviceId / agent / protocolVersion / version / deviceName）。
    /// 逐个键用下标读取，不依赖 `NWTXTRecord` 的枚举 API（各版本可用性不一致）。
    private static func txt(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case let .bonjour(record) = metadata else { return [:] }
        var out: [String: String] = [:]
        for key in ["platform", "deviceId", "agent", "protocolVersion", "version", "deviceName"] {
            if let value = record[key] { out[key] = value }
        }
        return out
    }
}
