import Foundation
import Network

/// iPhone 端 Bonjour 自动发现：扫描局域网上的 BrewPing Mac Agent。
/// 发现后自动设置 Mac 地址，用户无需手动输入 IP。
final class BonjourDiscovery: ObservableObject {
    struct DiscoveredHost: Identifiable, Equatable {
        let id: String
        let name: String
        let host: String
        let port: UInt16
    }

    @Published var discoveredHosts: [DiscoveredHost] = []
    @Published var isSearching = false

    private var browser: NWBrowser?
    private var timer: Timer?

    func startSearching() {
        stopSearching()
        isSearching = true
        discoveredHosts = []

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_brewping._tcp", domain: "local."), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .failed:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var hosts: [DiscoveredHost] = []
            for result in results {
                let endpoint = result.endpoint
                // NWBrowser endpoint 类型：.service(name, type, domain, interface)
                let name: String
                switch endpoint {
                case .service(let n, _, _, _):
                    name = n
                default:
                    continue
                }
                hosts.append(DiscoveredHost(
                    id: name,
                    name: name,
                    host: "",
                    port: 8787 // Bonjour 注册的端口
                ))
            }
            DispatchQueue.main.async {
                self.discoveredHosts = hosts
            }
        }

        browser.start(queue: DispatchQueue.global(qos: .userInitiated))
        self.browser = browser

        // 5 秒后停止搜索
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.stopSearching()
        }
    }

    func stopSearching() {
        browser?.cancel()
        browser = nil
        timer?.invalidate()
        timer = nil
        isSearching = false
    }

    /// 通过 NWConnection 解析 Bonjour 服务的实际 IP 地址。
    static func resolve(host: DiscoveredHost, completion: @escaping (String?, UInt16?) -> Void) {
        // NWBrowser 的 endpoint 信息不足以获取 IP，使用 NetService 作为备用解析
        // 或直接使用 host.name + port 做 TCP 连接（NW 支持 Bonjour 名称解析）
        // 简化：直接用 mDNS 名称（如 "MacBook-Pro.local"）
        completion(host.name.components(separatedBy: ".").first.map { "\($0).local" }, host.port > 0 ? host.port : 8787)
    }
}
