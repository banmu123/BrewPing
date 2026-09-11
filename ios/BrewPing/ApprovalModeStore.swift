import Foundation
import Combine

/// iPhone 端对 Mac 授权模式（safe / askAll / auto）的读写。
///
/// 模式是 Mac 端全局设置，通过当前激活设备的 `/api/approvals/mode` 读写。
/// Demo 设备也实现了同构接口，因此 Demo 下同样可读可切。
@MainActor
final class ApprovalModeStore: ObservableObject {
    static let shared = ApprovalModeStore()

    enum Mode: String, CaseIterable, Identifiable {
        case safe
        case askAll = "askAll"
        case auto

        var id: String { rawValue }

        /// 列表显示名，已本地化。
        var displayName: String {
            switch self {
            case .safe:   return L("approval.mode.safe")
            case .askAll: return L("approval.mode.askAll")
            case .auto:   return L("approval.mode.auto")
            }
        }

        var summary: String {
            switch self {
            case .safe:   return L("approval.mode.safe.summary")
            case .askAll: return L("approval.mode.askAll.summary")
            case .auto:   return L("approval.mode.auto.summary")
            }
        }
    }

    @Published private(set) var mode: Mode = .safe
    @Published private(set) var loaded = false
    /// 最近一次切换/读取失败的原因。非 nil 时界面要显式提示，不要静默吞掉。
    @Published private(set) var lastError: String?

    private init() {}

    /// 拉取 Mac 端当前授权模式。失败保持上次值，不抛错。
    /// 但 401（未配对/token 失效）要显式提示 —— 否则界面会静默退回默认档位，
    /// 让用户误以为"当前就是这个模式"。
    func refresh() async {
        guard let device = DeviceStore.shared.activeDevice,
              DeviceAuth.isPaired(device),
              let request = BrewPingHTTP.request(device: device, path: "/api/approvals/mode", method: "GET") else {
            return
        }
        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                if code == 401 {
                    lastError = L("Not paired with this Mac. Enter the pairing code in this device's settings.")
                }
                return
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = object["mode"] as? String {
                mode = Mode(rawValue: raw) ?? .safe
                loaded = true
                lastError = nil
            }
        } catch {
            BrewPingLog.command.debug("approval mode refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 写入新模式。
    ///
    /// 采用**乐观更新**：先把本地 `mode` 切过去，让 Picker 立刻响应，
    /// 再发请求；失败则回滚并置 `lastError`（带上服务端返回的具体原因）。
    /// 之前是"成功才更新"，一旦请求失败（例如 Mac 端是旧版本、没有该路由），
    /// 界面就静默弹回原值，用户只觉得"点了没反应"，完全不知道原因。
    func setMode(_ newMode: Mode) async {
        guard let device = DeviceStore.shared.activeDevice,
              var request = BrewPingHTTP.request(device: device, path: "/api/approvals/mode", method: "POST") else {
            lastError = L("No Mac connected. Add a device first.")
            return
        }
        let previous = mode
        mode = newMode
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["mode": newMode.rawValue])
        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                loaded = true
                lastError = nil
            } else {
                mode = previous
                if code == 401 {
                    // 401 单独翻译：不是网络问题，是没配对 / token 失效，
                    // 用户需要重新配对，而不是去检查网络。
                    lastError = L("Not paired with this Mac. Enter the pairing code in this device's settings.")
                } else {
                    let serverError = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    lastError = L("Couldn't switch approval mode: %@", serverError ?? "HTTP \(code)")
                }
            }
        } catch {
            mode = previous
            lastError = error.localizedDescription
            BrewPingLog.command.debug("approval mode set failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
