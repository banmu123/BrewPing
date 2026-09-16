import Foundation
import Combine

/// 配对深链 `brewping://pair?host=&port=&deviceId=&name=&osType=&code=` 的**统一解析结果**。
///
/// 🚨 扫码（`ContentView.applyScannedValue`）与外链（`onOpenURL` → `PairingURLHandler`）
/// **必须共用这一套解析**。旧实现是两处各写一份：外链那份读了 `osType`、扫码那份漏了，
/// 于是「扫描 Windows 的配对码，设备仍被存成 Mac」（用户实际报的就是这个）。
/// 解析只保留一处，两条路就不会再各自漂移。
struct PairingLink: Equatable {
    let host: String
    let port: String
    let deviceID: String
    let code: String
    let name: String?
    /// 主机类型：优先取深链里的 `osType`；缺失时用 `deviceID` 的平台前缀兜底
    /// （`bp_mac_` / `bp_win_`，见 `DeviceOSType.fromDeviceIDPrefix`）。
    /// **两者都没有时为 nil**，交给调用方决定回退（外链回落 `.mac`，扫码保持表单现值）。
    let osType: DeviceOSType?

    /// 从二维码/粘贴的**字符串**解析（扫码路径）。非配对深链返回 nil。
    static func parse(_ raw: String) -> PairingLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        return parse(url)
    }

    /// 从已构造好的 `URL` 解析（外链路径）。
    static func parse(_ url: URL) -> PairingLink? {
        guard url.scheme?.lowercased() == "brewping",
              url.host?.lowercased() == "pair" else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let dict = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let host = dict["host"], !host.isEmpty,
              let port = dict["port"], !port.isEmpty else { return nil }

        let deviceID = dict["deviceId"] ?? ""
        let explicitOS = (dict["osType"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedOS: DeviceOSType? = explicitOS.isEmpty
            ? DeviceOSType.fromDeviceIDPrefix(deviceID)   // 老版本桌面端的码没有 osType，靠前缀兜底
            : DeviceOSType.parse(explicitOS)

        let rawName = dict["name"] ?? ""
        return PairingLink(
            host: host,
            port: port,
            deviceID: deviceID,
            code: dict["code"] ?? "",
            name: rawName.isEmpty ? nil : rawName,
            osType: resolvedOS
        )
    }
}

/// 处理从 Mac 端 QR 码或外部点击 `brewping://pair?...` 链接唤起 App 的入口。
///
/// URL schema:
///     brewping://pair?host=<ip-or-name>&port=<port>&deviceId=<host-deviceId>&osType=<mac|windows|linux>&code=<6digit>&name=<display>
///
/// `osType` 由桌面端在深链里给出（Mac 发 `mac`、Windows 发 `windows`）。
/// **缺失或无法识别时回落 `.mac`**，这样老版本桌面端发的深链照旧可用。
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
        let deviceId: String   // 主机端 PairingStore 里的 deviceId，用于去重
        let code: String       // 可空：用户可能只点"扫码 + 输码"，已点过的话码已经在 sheet 里
        let suggestedName: String
        /// 主机类型；深链未携带或值未知时为 `.mac`。
        let osType: DeviceOSType
    }

    @Published var pendingAction: Action?

    /// 处理一个传入的 URL。空 / 非法 URL 静默忽略，避免拉起失败影响正常路径。
    func handle(_ url: URL) {
        guard let link = PairingLink.parse(url) else {
            // 配对 URL 可能携带 6 位配对码 → 一律 .private，绝不进系统日志明文。
            BrewPingLog.discovery.info("Ignoring non-pair URL: \(url.absoluteString, privacy: .private)")
            return
        }
        pendingAction = Action(
            host: link.host,
            port: link.port,
            deviceId: link.deviceID,
            code: link.code,
            suggestedName: link.name ?? link.host,
            // 沿用历史行为：解析不到就按 Mac（老版本桌面端的码不带该信息）
            osType: link.osType ?? .mac
        )
        BrewPingLog.discovery.info("Pair URL accepted host=\(link.host, privacy: .private) deviceId=\(link.deviceID, privacy: .private) osType=\(String(describing: link.osType), privacy: .public)")
    }

    /// 视图消费后调用，避免重复处理同一 URL。
    func consume() {
        pendingAction = nil
    }
}
