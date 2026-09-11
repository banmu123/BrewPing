import Foundation
import SwiftUI

// MARK: - 接口数据结构

/// `GET /api/agents/<agentId>/models` 的响应。
///
/// Mac 端（`Sources/App/HTTPAPI.swift` 的 `agentModelsResponse`）返回的是
/// **Provider → Models 两层嵌套**，这里扁平化成可直接渲染的列表：
///
/// ```json
/// { "agentId": "opencode",
///   "providers": [ { "id", "name", "baseURL"?, "models": [ {"id","name","available","isActive","isDefault"} ] } ],
///   "activeModelId": "...", "preferredModelId": "..." }
/// ```
private struct ModelsResponse: Decodable {
    let agentId: String?
    let providers: [Provider]?
    let activeModelId: String?
    let preferredModelId: String?

    struct Provider: Decodable {
        let id: String?
        let name: String?
        let models: [RawModel]?
    }

    struct RawModel: Decodable {
        let id: String?
        let name: String?
        let available: Bool?
        let isActive: Bool?
        let isDefault: Bool?
    }
}

/// 一个可选模型。模型 id / 名称是**数据**（用户自己配置的），不做本地化。
struct ModelOption: Identifiable, Equatable {
    let id: String
    let name: String
    /// 所属 provider 名，用于在重名时区分（如两个 provider 都有 gpt-4o）。
    let providerName: String
    let available: Bool
}

// MARK: - ModelStore

/// 当前 Agent 的可切换模型列表 + 当前生效模型。
///
/// **数据来源唯一**：Mac 端 `AgentConfigDiscovery` 读各 Agent 真实配置文件得到
/// Provider/Model，经上面两个接口暴露。这里只做展示与选择，**不新增任何配置源**。
/// 之前界面拿不到这份数据，是因为 iOS/Watch 从未调用过 `/api/agents/<id>/models`，
/// 只知道命令执行后回传的 `lastModelId`（那只是"刚才用了哪个"，不是"可以选哪些"）。
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published private(set) var models: [ModelOption] = []
    @Published private(set) var activeModelID: String?
    /// 拉取失败时的提示。**失败不清空 models**，保留上次可用的列表与默认模型。
    @Published private(set) var loadError: String?
    /// 切换失败时的提示。
    @Published private(set) var notice: String?

    private static let keyPrefix = "BrewPing.Model."

    private var currentDevice: ManagedDevice?
    private var currentAgentID: String = ""
    /// 已加载过的 "deviceID/agentID"，避免状态轮询每 5 秒重复拉模型列表。
    private var loadedKey: String?

    /// 是否值得展示切换入口：0 个或只有 1 个模型时没有可选项。
    var canSwitch: Bool { models.count > 1 }

    /// 当前生效模型的展示名；列表里没有时直接显示 id（比如配置里新增了模型但还没刷新）。
    var activeModelName: String? {
        guard let activeModelID else { return nil }
        return models.first { $0.id == activeModelID }?.name ?? activeModelID
    }

    // MARK: 拉取

    /// 拉取指定设备上某个 Agent 的模型列表。
    /// - Note: 只在 device / agentID 变化时真正发请求（`refreshAgents` 等高频调用不会重复打接口）。
    func refresh(device: ManagedDevice?, agentID: String, force: Bool = false) async {
        currentDevice = device
        currentAgentID = agentID

        guard let device else {
            models = []
            activeModelID = nil
            loadError = nil
            loadedKey = nil
            return
        }

        let key = "\(device.id)/\(agentID)"
        if !force, loadedKey == key { return }

        guard let request = BrewPingHTTP.request(
            device: device,
            path: "/api/agents/\(agentID)/models",
            timeout: 10
        ) else {
            models = []
            activeModelID = nil
            loadedKey = nil
            return
        }

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            if BrewPingHTTP.isUnauthorized(response) {
                // 没配对：不是模型数据的问题，交给界面上原有的未配对提示处理，
                // 这里静默清空即可，避免重复弹两种错误。
                models = []
                activeModelID = nil
                loadError = nil
                loadedKey = nil
                return
            }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            models = Self.flatten(decoded)
            activeModelID = Self.resolveActive(
                from: decoded,
                models: models,
                localFallback: localSelection(deviceID: device.id, agentID: agentID)
            )
            loadError = nil
            loadedKey = key
            // OSLog 的插值是 @autoclosure，直接引用 self 的属性会报
            // "reference to property in closure requires explicit use of 'self'"，先取局部变量。
            let count = models.count
            BrewPingLog.net.info("Loaded \(count, privacy: .public) models for \(agentID, privacy: .public)")
        } catch {
            // 关键：失败**不清空**已有列表。用户已经看到的选项不该因为一次网络抖动消失，
            // 主流程（发命令）也完全不受影响。
            loadError = L("Can't load models: %@", error.localizedDescription)
            BrewPingLog.net.error("Load models failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// 设备或 Agent 变了 —— 下次必须重新拉，否则会沿用上一个 Agent 的模型。
    func invalidate() { loadedKey = nil }

    // MARK: 切换

    func select(_ modelID: String) {
        guard let device = currentDevice, !currentAgentID.isEmpty else {
            notice = L("No Mac connected. Add a device first.")
            return
        }
        let previous = activeModelID
        // 乐观更新：先让界面高亮过去，请求失败再回滚。
        activeModelID = modelID
        saveLocalSelection(modelID, deviceID: device.id, agentID: currentAgentID)
        notice = nil

        guard var request = BrewPingHTTP.request(
            device: device,
            path: "/api/agents/models/default",
            method: "POST",
            timeout: 15
        ) else {
            activeModelID = previous
            notice = L("No Mac connected. Add a device first.")
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "agentId": currentAgentID,
            "modelId": modelID
        ])

        let agentID = currentAgentID
        Task {
            do {
                let (data, response) = try await BrewPingHTTP.session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode == 200 {
                    BrewPingLog.net.info("Model switched to \(modelID, privacy: .public)")
                    // 拉一次确认服务端已生效（也顺带刷新 isDefault 标记）。
                    await refresh(device: device, agentID: agentID, force: true)
                    return
                }
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let serverError = decoded?["error"] as? String
                activeModelID = previous
                notice = serverError ?? L("Switch failed (HTTP %@)", String(statusCode))
            } catch {
                activeModelID = previous
                notice = L("Switch failed: %@", error.localizedDescription)
                BrewPingLog.net.error("Switch model failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // MARK: 辅助

    /// 把 Provider → Models 两层结构拍平；同名模型靠 provider 名区分。
    private static func flatten(_ response: ModelsResponse) -> [ModelOption] {
        var result: [ModelOption] = []
        var seen = Set<String>()
        for provider in response.providers ?? [] {
            let providerName = provider.name ?? provider.id ?? ""
            for raw in provider.models ?? [] {
                guard let id = raw.id, !id.isEmpty else { continue }
                let key = "\(provider.id ?? "")/\(id)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(ModelOption(
                    id: id,
                    name: raw.name ?? id,
                    providerName: providerName,
                    available: raw.available ?? true
                ))
            }
        }
        return result
    }

    /// 当前生效模型的判定顺序：
    /// 1. 服务端 `preferredModelId` —— 用户通过 App 选过、Mac 端已持久化（权威值）
    /// 2. **本地记录** —— 与 1 语义相同（都是"用户选的"），但服务端没回传时兜底，
    ///    这样"下次进来还是上次那个"不依赖服务端；必须排在 `activeModelId` 之前，
    ///    否则一旦配置文件里有 active 值就会把用户的选择盖掉。
    /// 3. `activeModelId` —— 配置文件里正在用的（用户从未通过 App 选过时用它）
    /// 4. 列表第一个
    private static func resolveActive(
        from response: ModelsResponse,
        models: [ModelOption],
        localFallback: String?
    ) -> String? {
        if let preferred = response.preferredModelId, !preferred.isEmpty,
           models.contains(where: { $0.id == preferred }) {
            return preferred
        }
        if let localFallback, models.contains(where: { $0.id == localFallback }) {
            return localFallback
        }
        if let active = response.activeModelId, !active.isEmpty,
           models.contains(where: { $0.id == active }) {
            return active
        }
        return models.first?.id
    }

    // MARK: 本地持久化

    /// 按「设备 + Agent」分别记：不同 Mac、不同 Agent 的模型是各自独立的。
    private func storageKey(deviceID: String, agentID: String) -> String {
        "\(Self.keyPrefix)\(deviceID).\(agentID)"
    }

    private func localSelection(deviceID: String, agentID: String) -> String? {
        UserDefaults.standard.string(forKey: storageKey(deviceID: deviceID, agentID: agentID))
    }

    private func saveLocalSelection(_ modelID: String, deviceID: String, agentID: String) {
        UserDefaults.standard.set(modelID, forKey: storageKey(deviceID: deviceID, agentID: agentID))
    }
}

// MARK: - 模型选择页（iPhone）

struct ModelPickerView: View {
    @StateObject private var store = ModelStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let error = store.loadError {
                Section {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    // 失败时保留默认模型：这里是"还能用"，不是"坏了"。
                    Text("Showing the last known models. Pull to refresh to try again.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Available models") {
                ForEach(store.models) { model in
                    Button {
                        store.select(model.id)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                // 模型名是用户配置的数据，不翻译。
                                Text(verbatim: model.name)
                                    .font(.callout)
                                    .foregroundStyle(model.available ? .primary : .secondary)
                                if !model.providerName.isEmpty {
                                    Text(verbatim: model.providerName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if store.activeModelID == model.id {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .disabled(!model.available)
                }
            }

            if let notice = store.notice {
                Section {
                    Text(verbatim: notice)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Model")
    }
}
