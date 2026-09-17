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

/// resolve 生命周期的显式阶段。核心目的：**让 FOUND ≠ RESOLVED 在日志与诊断里可辨**。
///
/// FOUND     —— 浏览到服务实例
/// RESOLVING —— NetService 已创建并开始 resolve
/// RESOLVED  —— didResolveAddress 回调且拿到了可用 host:port
/// FAILED    —— didNotResolve 回调（非超时错误）
/// TIMEDOUT  —— didNotResolve 回调且错误码是 kDNSServiceErr_Timeout
/// STUCK     —— 超时+宽限期内**没有任何回调**（回调链路断：未调度成功/守护进程卡死）
/// CANCELLED —— stopSearching() 主动终止
private enum ResolveStage: String {
    case found, resolving, resolved, failed, timedOut, stuck, cancelled
}

/// 带析构日志的 NetService：验证 resolve 对象有没有被意外提前释放（生命周期取证）。
/// 除此之外与 `NetService` 完全一致，不引入任何行为差异。
/// （注意：`init(domain:type:name:)` 是便利构造器，子类直接继承即可，不要 override。）
final class TrackedNetService: NetService {
    var resolveKey: String = "?"
    /// 创建它时的扫描会话号（§3 身份取证：确认新旧扫描拿到的是不是同一个对象）。
    var sessionTag: Int = 0

    deinit {
        BrewPingLog.discovery.debug("resolve: service deinit session=\(self.sessionTag, privacy: .public) name=\(self.resolveKey, privacy: .private)")
    }
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
    /// 单次 resolve 的超时。常态 4s 足够；**诊断期临时放宽到 10s**——
    /// 用于区分「4~10s 才回调的慢成功」与「根本没进回调」（后者由 STUCK 看门狗暴露）。
    /// ⚠️ 定位完成后回 4.0，不要长期依赖超长超时。
    private static let resolveTimeoutSeconds: TimeInterval = 10.0
    /// resolve 看门狗的宽限：超时 + 3s 仍无任何回调 → 判 STUCK（回调链路断了，而非解析失败）。
    private static let resolveWatchdogGrace: TimeInterval = 3.0

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

    /// resolve 生命周期统计（诊断用，随 `diagnosticText` 展示）。
    struct ResolveStats: Equatable {
        var started = 0
        var resolved = 0
        var failed = 0
        var stuck = 0
        var cancelled = 0
        /// didResolveAddress 的「首帧不完整」回调次数（port=-1 / 无可用地址，继续等待）
        var partial = 0
    }

    @Published var discoveredHosts: [DiscoveredHost] = []
    @Published var isSearching = false
    /// 本地网络权限状态（用于 UI 区分「权限被拒」与「网络拦多播」）
    @Published private(set) var localNetwork: LocalNetworkAccess = .unknown
    /// 最近一次浏览错误（只用于展示与日志，不含用户数据）
    @Published private(set) var lastBrowseError: String?
    /// 最近一次 `browseResultsChangedHandler` 回来的结果条数。
    /// 诊断用：区分「一个结果都没回来（多播/权限/网络）」与「结果回来了但解析失败」。
    @Published private(set) var lastResultCount = 0
    /// 浏览器最近一次状态的可读文本。诊断用。
    @Published private(set) var lastBrowserState = "none"
    /// resolve 生命周期统计。诊断用（`diagnosticText` 一并展示）。
    @Published private(set) var resolveStats = ResolveStats()

    /// 最近一次「不完整 didResolveAddress 回调」的快照（§4 A–E 判定用，直接上诊断行）。
    @Published private(set) var lastPartialSnapshot: String?

    /// resolve 失败的**原始**错误信息 —— 不做任何语义映射（§取证阶段）。
    struct ResolveFailureInfo: Equatable {
        /// 失败来自哪个回调：didNotResolve / didStop / didResolve-no-address / watchdog
        var source: String?
        /// `NSNetServicesErrorCode` 的原始值（-72xxx 系）；取不到为 nil
        var code: Int?
        /// `NSNetServicesErrorDomain` 的原始值
        var domain: String?
        /// `NSLocalizedDescriptionKey` 的原始值（若有）
        var description: String?
        /// errorDict 的全部 key（排序后）
        var keys: [String]
        /// 桥接后 errorDict 的条数（didNotResolve 专有；其他来源为 nil）
        var errorCount: Int?
        /// 逐对 k=v(值类型) 的原始转储（didNotResolve 专有）
        var pairs: String?
        /// 失败的 service 元数据
        var serviceName: String?
        var serviceType: String?
        var serviceDomain: String?
        /// FOUND → 失败回调 的耗时
        var elapsedMs: Int?
    }

    /// 最近一次 resolve 失败的原始取证信息；成功或新一轮浏览时清空。
    @Published private(set) var lastResolveFailure: ResolveFailureInfo?

    /// 一行诊断文本：扫不到设备时用它判断到底断在哪一环。
    ///
    /// 纯技术字段、不参与本地化。**定位完 TestFlight 自动发现问题后，连同 UI 上的
    /// 展示入口一起删掉** —— 正式版不该有这行。
    var diagnosticText: String {
        let f = lastResolveFailure
        let codeText = f?.code.map(String.init) ?? "none"
        let domainText = f?.domain ?? "none"
        let keysText = (f?.keys.isEmpty ?? true) ? "none" : (f?.keys.joined(separator: ",") ?? "none")
        return "diag: session=\(scanSession) browser=\(lastBrowserState) results=\(lastResultCount) hosts=\(discoveredHosts.count) ln=\(localNetwork) discoveryError=\(lastBrowseError ?? "none") | resolve: started=\(resolveStats.started) ok=\(resolveStats.resolved) fail=\(resolveStats.failed) partial=\(resolveStats.partial) stuck=\(resolveStats.stuck) resolving=\(resolvers.count) partialSnap=\(lastPartialSnapshot ?? "none") src=\(f?.source ?? "none") code=\(codeText) domain=\(domainText) errCnt=\(f?.errorCount.map(String.init) ?? "none") keys=\(keysText) pairs=\(f?.pairs ?? "none") elapsed=\(f?.elapsedMs.map(String.init) ?? "none")ms name=\(f?.serviceName ?? "none") type=\(f?.serviceType ?? "none") domain2=\(f?.serviceDomain ?? "none")"
    }

    /// 是否仍有服务在解析中（浏览停止后，已发现的服务可能还在解析）
    var isResolving: Bool { !resolvers.isEmpty }

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
    /// 仅在主队列读写：resolveNew 在主队列触发，NetService 回调也投递到主线程 run loop
    private var resolvers: [String: NetService] = [:]
    /// 服务实例名 → 从 TXT 记录读出的主机类型。
    /// `NetServiceDelegate` 的回调不携带 TXT，所以在浏览阶段先存下来，解析完成时取用。
    private var pendingOS: [String: DeviceOSType] = [:]
    /// name → resolve 看门狗：超时+宽限后仍无**任何**回调 → 判 STUCK 并收尾。
    /// 区分「resolve 真失败（有 didNotResolve）」与「回调链路根本没通」。
    private var resolveWatchdogs: [String: DispatchWorkItem] = [:]
    /// name → resolve 开始时刻（算 elapsed 用）。
    private var resolveStartTimes: [String: CFAbsoluteTime] = [:]

    func startSearching() {
        // 🚨 影子期修复（§4 残留状态）：上一轮的在途 resolver 会活到 超时+宽限（≈13s），
        // 期间新扫描的 FOUND 会因 `resolvers[name] != nil` 被 SKIP，且 browse 结果集合
        // 不再变化、不会有第二次回调 —— 整次扫描被静默判死（「成功一次之后反复失败」的状态机根源）。
        // 所以**新一轮扫描必须接管（终止并清理）上一轮的在途 resolve**；
        // 「浏览窗口到期不杀 resolve」的解耦语义保持不变（stopBrowsing 依旧不碰 resolvers）。
        scanSession += 1
        stopBrowsing(reason: "superseded-by-new-scan")
        teardownResolvers(reason: "superseded-by-new-scan")
        isSearching = true
        discoveredHosts = []
        browseExtensions = 0
        lastResultCount = 0
        lastBrowserState = "none"
        resolveStats = ResolveStats()
        lastResolveFailure = nil
        lastPartialSnapshot = nil
        // pendingOS 跟随 resolver 一起清理（见 teardownResolvers）。
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
                self.lastResultCount = results.count
                self.resolveNew(results)
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
        lastBrowserState = String(describing: state)
        BrewPingLog.discovery.info("Browser \(String(describing: state), privacy: .public)")
        switch state {
        case .ready:
            localNetwork = .granted
            lastBrowseError = nil
            isWaitingForPermission = false
            UserDefaults.standard.set(true, forKey: Self.grantedDefaultsKey)
        case .waiting(let error):
            if Self.isPolicyDenied(error) {
                localNetwork = .denied
                lastBrowseError = "policy-denied"
                isSearching = false
                isWaitingForPermission = false
            } else {
                localNetwork = .requesting
                lastBrowseError = Self.describe(error)
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
                lastBrowseError = "policy-denied"
                isSearching = false
            } else {
                localNetwork = .requesting
                lastBrowseError = Self.describe(error)
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

    /// 完整停止：结束浏览并取消所有未完成的解析
    func stopSearching() {
        stopBrowsing(reason: "page-exit-or-final-stop")
        teardownResolvers(reason: "page-exit-or-final-stop")
        pendingOS.removeAll()
    }

    /// 终止并清理**全部**在途 resolve（新一轮扫描接管 / 页面退出）。
    /// `pendingOS` 跟随清理 —— 它只被 resolver 消费，resolver 清了它就是死数据。
    private func teardownResolvers(reason: String) {
        if !resolvers.isEmpty {
            BrewPingLog.discovery.info(
                "resolve: CANCELLED session=\(self.scanSession, privacy: .public) n=\(self.resolvers.count, privacy: .public) reason=\(reason, privacy: .public)"
            )
            resolveStats.cancelled += resolvers.count
        }
        for (name, service) in resolvers {
            resolveWatchdogs.removeValue(forKey: name)?.cancel()
            resolveStartTimes.removeValue(forKey: name)
            service.delegate = nil
            service.stop()
        }
        resolvers.removeAll()
        pendingOS.removeAll()
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

    // MARK: - Resolution

    /// 对每个新出现的服务实例发起一次解析（解析结果通过 NetServiceDelegate 回调）
    private func resolveNew(_ results: Set<NWBrowser.Result>) {
        for result in results {
            // §9 取证：把 NWBrowser 原始给的 type/domain 也记下来，和我们的构造参数对照，
            // 证明没有发生 local./local 或 _brewping._tcp./_brewping._tcp 的 normalization 问题。
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }
            // TXT 只在这里拿得到（NWBrowser.Result 上），先记下来给 finishResolve 用。
            pendingOS[name] = Self.osType(from: result.metadata)

            // FOUND：结果看见了。跳过时也留痕 —— 「发现了但没解析」与「压根没发现」是两回事。
            if resolvers[name] != nil {
                BrewPingLog.discovery.info("resolve: FOUND session=\(self.scanSession, privacy: .public) \(name, privacy: .private) → SKIP already resolving")
                continue
            }
            if discoveredHosts.contains(where: { $0.id == name }) {
                BrewPingLog.discovery.info("resolve: FOUND session=\(self.scanSession, privacy: .public) \(name, privacy: .private) → SKIP already discovered")
                continue
            }
            BrewPingLog.discovery.info("resolve: FOUND session=\(self.scanSession, privacy: .public) \(name, privacy: .private) srcType=\(type, privacy: .public) srcDomain=\(domain, privacy: .public) → starting")

            let service = TrackedNetService(domain: "local.", type: "_brewping._tcp.", name: name)
            service.resolveKey = name
            service.sessionTag = self.scanSession
            let oid = ObjectIdentifier(service).hashValue
            service.delegate = self
            resolvers[name] = service
            resolveStartTimes[name] = CFAbsoluteTimeGetCurrent()
            resolveStats.started += 1

            BrewPingLog.discovery.info("resolve: RESOLVE_REQUEST session=\(self.scanSession, privacy: .public) oid=\(oid, privacy: .public) \(name, privacy: .private) initDomain=local. initType=_brewping._tcp. main=\(String(Thread.isMainThread), privacy: .public)")

            // 🚨 显式调度到主 run loop 的 common 模式：resolve(withTimeout:) 的隐式行为是
            // 「调度到创建线程的 current run loop、default 模式」——既依赖创建线程恰好是主线程，
            // 又会被用户滑动列表（tracking 模式）饿住。显式 common 模式把这两个变数都钉死。
            // 顺序：创建 → delegate → schedule → resolve（§4 要求确认的顺序）。
            service.schedule(in: .main, forMode: .common)
            BrewPingLog.discovery.info("resolve: SCHEDULE session=\(self.scanSession, privacy: .public) oid=\(oid, privacy: .public) loop=main mode=common")

            BrewPingLog.discovery.info("resolve: RESOLVE_STARTED session=\(self.scanSession, privacy: .public) oid=\(oid, privacy: .public) timeout=\(Int(Self.resolveTimeoutSeconds), privacy: .public)s")
            service.resolve(withTimeout: Self.resolveTimeoutSeconds)
            scheduleResolveWatchdog(for: name)
        }
    }

    /// resolve 看门狗：`resolveTimeoutSeconds + 宽限` 后若服务仍在 `resolvers`
    ///（= didResolveAddress / didNotResolve **都没来**）→ 判 STUCK 并收尾。
    /// 没有它，「回调链路根本没通」会伪装成「解析慢」，永远查不出来。
    private func scheduleResolveWatchdog(for name: String) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.resolvers[name] != nil else { return }
            let elapsedMs = self.resolveStartTimes[name].map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? -1
            BrewPingLog.discovery.error("resolve: STUCK session=\(self.scanSession, privacy: .public) (no callback) name=\(name, privacy: .private) elapsed=\(elapsedMs, privacy: .public)ms → force-finish")
            self.resolveStats.stuck += 1
            self.finishResolve(name: name, host: nil, port: 0, stage: .stuck, errorText: "no usable address before watchdog (partial didResolve callbacks may have occurred)", failureSource: "watchdog-timeout")
        }
        resolveWatchdogs[name] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resolveTimeoutSeconds + Self.resolveWatchdogGrace, execute: work)
    }

    private func finishResolve(name: String, host: String?, port: UInt16, stage: ResolveStage, errorText: String? = nil, failure: ResolveFailureInfo? = nil, failureSource: String? = nil) {
        resolveWatchdogs.removeValue(forKey: name)?.cancel()
        let startedAt = resolveStartTimes.removeValue(forKey: name)
        if let service = resolvers.removeValue(forKey: name) {
            service.delegate = nil
            service.stop()
        }
        let osType = pendingOS.removeValue(forKey: name) ?? .mac
        let elapsedMs = startedAt.map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? -1

        guard let host, !host.isEmpty, port > 0 else {
            resolveStats.failed += 1
            // 取证：原始错误信息原样入库（调用方给了就存调用方的；没有就按已知信息兜底）。
            lastResolveFailure = failure ?? ResolveFailureInfo(
                source: failureSource,
                code: nil, domain: nil, description: errorText, keys: [], errorCount: nil, pairs: nil,
                serviceName: name, serviceType: "_brewping._tcp.", serviceDomain: "local.",
                elapsedMs: elapsedMs >= 0 ? elapsedMs : nil
            )
            BrewPingLog.discovery.error(
                "resolve: \(stage.rawValue, privacy: .public) FAILED session=\(self.scanSession, privacy: .public) name=\(name, privacy: .private) elapsed=\(elapsedMs, privacy: .public)ms error=\(errorText ?? "none", privacy: .public)"
            )
            return
        }

        resolveStats.resolved += 1
        lastResolveFailure = nil
        discoveredHosts.removeAll { $0.id == name }
        discoveredHosts.append(DiscoveredHost(id: name, name: name, host: host, port: port, osType: osType))
        BrewPingLog.discovery.info(
            "resolve: RESOLVED session=\(self.scanSession, privacy: .public) name=\(name, privacy: .private) host=\(host, privacy: .private) port=\(Int(port), privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms → device visible"
        )
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

    /// 地址族计数（诊断用）：区分「回调整了但一条可用地址都没有」与「地址充足却没选上」。
    private static func addressFamilyCounts(_ addresses: [Data]?) -> (total: Int, v4: Int, v6: Int) {
        guard let addresses else { return (0, 0, 0) }
        var v4 = 0
        var v6 = 0
        for data in addresses {
            let family: sa_family_t = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
            }
            if family == sa_family_t(AF_INET) {
                v4 += 1
            } else if family == sa_family_t(AF_INET6) {
                v6 += 1
            }
        }
        return (addresses.count, v4, v6)
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
        let oid = ObjectIdentifier(sender).hashValue
        let addresses = sender.addresses
        let counts = Self.addressFamilyCounts(addresses)
        let fromHostName = Self.normalizedHostName(sender.hostName)
        let host = Self.ipv4Address(from: addresses) ?? fromHostName
        let port = sender.port   // Int；尚未解析出端口时为 -1

        // 🚨 修正（Apple 文档明确允许）：didResolveAddress 可能**多次**回调，首次回调时
        // addresses 可以为空、port 可以为 -1，地址会随后续回调陆续到达。
        // 此前这里在**第一次回调**就 finishResolve（摘除 + delegate=nil + stop）——
        // 把还在进行的解析提前掐死，表现就是几十 ms 内"失败"（58ms 之谜的答案）。
        // 现在：拿到可用 host+port 才收尾；首帧不完整就**留在 resolvers 里继续等**
        //（看门狗兜底：13s 内仍无可用地址才判失败）。
        guard let host, !host.isEmpty, port > 0 else {
            resolveStats.partial += 1
            lastPartialSnapshot = "port=\(port) addrs=\(counts.total) v4=\(counts.v4) v6=\(counts.v6) hostName=\(fromHostName ?? "nil")"
            BrewPingLog.discovery.info(
                "resolve: DID_RESOLVE session=\(self.scanSession, privacy: .public) oid=\(oid, privacy: .public) name=\(sender.name, privacy: .private) port=\(port, privacy: .public) addrs=\(counts.total, privacy: .public) v4=\(counts.v4, privacy: .public) v6=\(counts.v6, privacy: .public) hostName=\(fromHostName ?? "nil", privacy: .private) main=\(String(Thread.isMainThread), privacy: .public) → PARTIAL, keep resolving (callback #\(self.resolveStats.partial, privacy: .public))"
            )
            return
        }

        BrewPingLog.discovery.info(
            "resolve: DID_RESOLVE session=\(self.scanSession, privacy: .public) oid=\(oid, privacy: .public) name=\(sender.name, privacy: .private) port=\(port, privacy: .public) addrs=\(counts.total, privacy: .public) v4=\(counts.v4, privacy: .public) v6=\(counts.v6, privacy: .public) main=\(String(Thread.isMainThread), privacy: .public) → usable, finish"
        )
        finishResolve(
            name: sender.name,
            host: host,
            port: UInt16(clamping: port),
            stage: .resolved
        )
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // §7 取证：errorDict **原样**暴露、不做任何语义映射。
        // keys/values/count 都来自**桥接后**的字典 —— 若 count=0 但系统确实失败，
        // 则要么系统给的就是空字典（情况 A），要么桥接丢值（情况 C）；两者用本日志区分：
        // dictDescription 打印桥接字典的原始描述，若也为空则 A 实锤。
        let oid = ObjectIdentifier(sender).hashValue
        let raw = errorDict as [String: Any]
        let code = (raw[NetService.errorCode] as? NSNumber)?.intValue
            ?? (raw[NetService.errorCode] as? Int)
            ?? errorDict.values.first?.intValue
        let domain = raw[NetService.errorDomain] as? String
        let description = raw[NSLocalizedDescriptionKey] as? String
        let sortedKeys = errorDict.keys.sorted()
        let elapsedMs = resolveStartTimes[sender.name].map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) }
        let values = sortedKeys.compactMap { errorDict[$0]?.stringValue }.joined(separator: ",")
        let pairDump = sortedKeys.compactMap { key -> String? in
            guard let v = errorDict[key] else { return nil }
            return "\(key)=\(v.stringValue)(\(Swift.type(of: v)))"
        }.joined(separator: ",")
        let info = ResolveFailureInfo(
            source: "didNotResolve",
            code: code,
            domain: domain,
            description: description,
            keys: sortedKeys,
            errorCount: errorDict.count,
            pairs: pairDump,
            serviceName: sender.name,
            serviceType: sender.type,
            serviceDomain: sender.domain,
            elapsedMs: elapsedMs
        )
        BrewPingLog.discovery.error(
            "resolve: DID_NOT_RESOLVE session=\(self.scanSession, privacy: .public) oid=\(oid, privacy: .public) name=\(sender.name, privacy: .private) type=\(sender.type ?? "?", privacy: .public) domain=\(sender.domain ?? "?", privacy: .public) errorCount=\(errorDict.count, privacy: .public) code=\(code.map(String.init) ?? "nil", privacy: .public) errorDomain=\(domain ?? "nil", privacy: .public) keys=\(sortedKeys.joined(separator: ","), privacy: .public) values=\(values, privacy: .public) pairs=\(pairDump, privacy: .public) desc=\(description ?? "nil", privacy: .public) dict=\(String(describing: errorDict), privacy: .public) elapsed=\(elapsedMs.map(String.init) ?? "nil", privacy: .public)ms main=\(String(Thread.isMainThread), privacy: .public)"
        )
        finishResolve(
            name: sender.name,
            host: nil,
            port: 0,
            stage: .failed,
            errorText: "code=\(code.map(String.init) ?? "nil") domain=\(domain ?? "nil") desc=\(description ?? "nil")",
            failure: info
        )
    }

    /// 系统侧主动停掉 service（我们自己的 stop() 都先 delegate=nil，不会走到这里）。
    /// 此前这个回调**没实现** —— 系统停掉 resolver 时我们完全失明，只能等看门狗。
    func netServiceDidStop(_ sender: NetService) {
        let oid = ObjectIdentifier(sender).hashValue
        let wasResolving = resolvers[sender.name] != nil
        BrewPingLog.discovery.error(
            "resolve: DID_STOP session=\(self.scanSession, privacy: .public) oid=\(oid, privacy: .public) name=\(sender.name, privacy: .private) wasResolving=\(String(wasResolving), privacy: .public) main=\(String(Thread.isMainThread), privacy: .public)"
        )
        // 若系统在 resolve 途中停掉它：按失败收尾（来源标记 didStop），避免挂到看门狗（13s）才清。
        if wasResolving {
            let elapsedMs = resolveStartTimes[sender.name].map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) }
            let info = ResolveFailureInfo(
                source: "didStop",
                code: nil, domain: nil,
                description: "system stopped the service during resolve",
                keys: [], errorCount: nil, pairs: nil,
                serviceName: sender.name,
                serviceType: sender.type,
                serviceDomain: sender.domain,
                elapsedMs: elapsedMs
            )
            finishResolve(name: sender.name, host: nil, port: 0, stage: .cancelled, errorText: "netServiceDidStop (system-initiated)", failure: info)
        }
    }
}
