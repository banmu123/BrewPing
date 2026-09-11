import Foundation
import Combine

/// 处理从 Mac 端 QR 码或外部点击 `brewping://pair?...` 链接唤起 App 的入口。
///
/// URL schema:
///     brewping://pair?host=<ip-or-name>&port=<port>&deviceId=<mac-deviceId>&code=<6digit>&name=<display>
///
/// 设计要点：
///  - `BrewPingApp` 通过 `.onOpenURL` 拿到 URL（系统**最早**的入口），
///    立刻把请求存进 `pendingAction`；
///  - `ContentView` 通过 `onChange(of: pendingAction)` 在首次 ready 时消费；
///  - 这样一个 URL 既能在 App 未启动时被拉起（冷启动），也能在 App 已在前/后台时直接跳到配对页（热路径），
///    不用分别处理两套路径。
///  - 不直接在这里发起网络请求：网络层在主 actor + ContentView 上下文里最稳，
///    这里只做"参数解析 + 派发到 UI"。
@MainActor
final class PairingURLHandler: ObservableObject {
    /// 单次消费的动作。SwiftUI 视图在 `.onChange(of: pendingAction)` 里消费一次后立刻 `consume()`。
    struct Action: Equatable {
        let host: String
        let port: String
        let deviceId: String   // Mac 端 PairingStore 里的 deviceId，用于去重
        let code: String       // 可空：用户可能只点"扫码 + 输码"，已点过的话码已经在 sheet 里
        let suggestedName: String
    }

    @Published var pendingAction: Action?

    /// 处理一个传入的 URL。空 / 非法 URL 静默忽略，避免拉起失败影响正常路径。
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "brewping",
              url.host?.lowercased() == "pair" else {
            BrewPingLog.discovery.info("Ignoring non-pair URL: \(url.absoluteString, privacy: .public)")
            return
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard let host = dict["host"], !host.isEmpty,
              let port = dict["port"], !port.isEmpty else {
            BrewPingLog.discovery.info("Pair URL missing host/port")
            return
        }
        let deviceId = dict["deviceId"] ?? ""
        let code = dict["code"] ?? ""
        let name = dict["name"] ?? host
        pendingAction = Action(
            host: host,
            port: port,
            deviceId: deviceId,
            code: code,
            suggestedName: name
        )
        BrewPingLog.discovery.info("Pair URL accepted host=\(host, privacy: .private) deviceId=\(deviceId, privacy: .private)")
    }

    /// 视图消费后调用，避免重复处理同一 URL。
    func consume() {
        pendingAction = nil
    }
}
