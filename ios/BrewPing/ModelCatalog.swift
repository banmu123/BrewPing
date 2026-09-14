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
///   "activeModelId": "...", "preferredModelId": "...", "configVersion": "..." }
/// ```
///
/// `configVersion` 是主机侧配置文件的指纹（`mtime_nanos:size`，多文件用 `|`
/// 连接、文件缺失记 `-`）。它**不参与展示**，只用来让下面的 `loadedKey` 感知
/// "主机上的配置变了"，从而让 5 秒一轮的轮询真正去重拉模型列表。
/// 老版本主机不返回该字段 → 解出 `nil`，此时退回原有的 device/agent 去重行为。
private struct ModelsResponse: Decodable {
    let agentId: String?
    let providers: [Provider]?
    let activeModelId: String?
    let preferredModelId: String?
    let configVersion: String?

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
    /// 所属 provider id —— 同名模型可来自多个 provider，选择时必须成对提交。
    let providerID: String
    let available: Bool

    /// `provider/model` 复合标识：同名模型在 Picker 里也各自独立。
    var compositeID: String { "\(providerID)/\(id)" }
}

/// 模型接口返回了非预期状态码。
/// 401（未配对）/ 404 / 501（主机没实现该接口）在调用点单独处理，不会走到这里。
private enum ModelLoadFailure: Error {
    case badStatus(Int)
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
    /// 这台主机是否**没有实现**模型接口（HTTP 404 / 501）。
    ///
    /// 与 `loadError` 的区别很重要：这**不是**错误，只是"这台主机没得选"。
    /// 早期桌面端（如 Windows 端最初版本）没有 `/api/agents/{id}/models`，
    /// 若不单独识别，响应体解不出 JSON，用户只会看到一句
    /// "未能读取数据，因为它的格式不正确" —— 既看不懂也误导人。
    /// 识别出来后清空列表、入口按 `canSwitch` 自然隐藏，不报错。
    @Published private(set) var unsupported = false
    /// 切换失败时的提示。
    @Published private(set) var notice: String?

    private static let keyPrefix = "BrewPing.Model."

    private var currentDevice: ManagedDevice?
    private var currentAgentID: String = ""
    /// 已加载过的 "deviceID/agentID"，避免状态轮询每 5 秒重复拉模型列表。
    private var loadedKey: String?
    /// 上一次成功拉取时主机回报的配置指纹（`configVersion`）。
    ///
    /// 存在的意义：`loadedKey` 只认"设备/Agent 有没有换"，认不出"主机上那份
    /// opencode.json / settings.json 被改了"。缺了它，用户在这边加完厂商、
    /// 主机那侧配置已经变了，iPhone 这边因为 `loadedKey` 没变而**永远不重拉** ——
    /// 表现就是"我在电脑上加了模型，手机上一直看不到"。
    /// 记的是**最近一次成功响应**的值：请求失败时不更新，下次轮询会再试。
    private var loadedConfigVersion: String?

    /// 是否值得展示模型入口。
    ///
    /// 从 `models.count > 1` 放宽到 `!models.isEmpty`：只有一个模型时也要能看到
    /// 当前用的是哪个 —— 「有 1 个可选」和「没得选」是两回事，前者入口消失会让
    /// 用户以为配置没生效（实测踩过：xiaomi 只配了 1 个模型，界面上完全没有入口）。
    /// 选择器在 `ConversationDetailView` 里对单选项天然退化，多一个入口无副作用。
    ///
    /// `unsupported`（主机没实现这个接口）时列表必然为空，这里显式写出来，
    /// 免得以后有人看到 `models` 为空却分不清是"这台机器没配模型"还是"这台主机没有这个接口"。
    var canSwitch: Bool { !unsupported && !models.isEmpty }

    /// 当前生效模型的展示名；列表里没有时直接显示 id（比如配置里新增了模型但还没刷新）。
    var activeModelName: String? {
        guard let activeModelID else { return nil }
        return models.first { $0.id == activeModelID }?.name ?? activeModelID
    }

    // MARK: 拉取

    /// 拉取指定设备上某个 Agent 的模型列表。
    ///
    /// 去重规则：`force` / device / agentID 变化 → 一定重拉（换主机必须重拉，
    /// 旧列表属于别人）。同一目标下则直接发一次探测请求，用响应里的
    /// `configVersion` 判断主机配置有没有变：没变就**不改动任何 state**
    /// （不触发 SwiftUI 重绘、不闪列表），变了才应用新列表。
    ///
    /// 为什么不干脆"指纹没变就不发请求"：指纹只能从响应里拿到，本地没有别的
    /// 途径知道主机配置变没变。好在这个请求很轻（就一个 GET，返回体几十字节），
    /// 5 秒一次的开销可接受，换来的是**改完配置最多 5 秒内自动同步**。
    func refresh(device: ManagedDevice?, agentID: String, force: Bool = false) async {
        currentDevice = device
        currentAgentID = agentID

        guard let device else {
            clearModels()
            unsupported = false
            loadError = nil
            loadedKey = nil
            loadedConfigVersion = nil
            return
        }

        let key = "\(device.id)/\(agentID)"
        // 已判定过"主机没实现该接口"的目标不必反复撞：这是稳定的否定结论。
        if !force, loadedKey == key, unsupported { return }

        // 换设备 / 换 Agent：旧列表属于别的主机或别的 Agent，先清掉再拉，
        // 免得新主机的界面短暂显示旧主机的模型（点了必然失败）。
        let targetChanged = loadedKey != key
        if targetChanged { clearModels() }

        guard let request = BrewPingHTTP.request(
            device: device,
            path: "/api/agents/\(agentID)/models",
            timeout: 10
        ) else {
            clearModels()
            unsupported = false
            loadError = nil
            loadedKey = nil
            loadedConfigVersion = nil
            return
        }

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if BrewPingHTTP.isUnauthorized(response) {
                // 没配对：不是模型数据的问题，交给界面上原有的未配对提示处理，
                // 这里静默清空即可，避免重复弹两种错误。
                clearModels()
                unsupported = false
                loadError = nil
                loadedKey = nil
                loadedConfigVersion = nil
                return
            }

            // 404 / 501 = 这台主机**没有这个接口**（尚未实现该路由的桌面端）。
            // 与"请求出错"区分开：这不是错误，只是没得选。
            // 计入 loadedKey 是刻意的 —— 否则 5 秒一次的轮询会反复去撞一个不存在的路由。
            if statusCode == 404 || statusCode == 501 {
                clearModels()
                loadError = nil
                unsupported = true
                loadedKey = key
                loadedConfigVersion = nil
                BrewPingLog.net.info("Model list unsupported by host (HTTP \(statusCode, privacy: .public))")
                return
            }

            guard statusCode == 200 else { throw ModelLoadFailure.badStatus(statusCode) }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)

            // 配置指纹没变 → 内容必然一样，直接返回：不动 models / activeModelID，
            // 避免每 5 秒无谓地触发一次 SwiftUI 重绘（列表会闪）。
            let incoming = decoded.configVersion ?? ""
            if !force, !targetChanged, !incoming.isEmpty, incoming == loadedConfigVersion {
                loadError = nil
                return
            }

            models = Self.flatten(decoded)
            activeModelID = Self.resolveActive(
                from: decoded,
                models: models,
                localFallback: localSelection(deviceID: device.id, agentID: agentID)
            )
            loadError = nil
            unsupported = false
            loadedKey = key
            loadedConfigVersion = incoming.isEmpty ? nil : incoming
            // OSLog 的插值是 @autoclosure，直接引用 self 的属性会报
            // "reference to property in closure requires explicit use of 'self'"，先取局部变量。
            let count = models.count
            BrewPingLog.net.info("Loaded \(count, privacy: .public) models for \(agentID, privacy: .public)")
        } catch {
            // 关键：**同一台主机**上失败不清空已有列表（一次网络抖动不该让选项消失）。
            // 但设备 / Agent 已经换了的话，旧列表属于别的主机，留着就是错的 ——
            // 会让人以为新主机有这些模型，点了必然失败。
            if loadedKey != key {
                clearModels()
            }
            unsupported = false
            loadError = Self.loadErrorMessage(for: error)
            BrewPingLog.net.error("Load models failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// 把失败原因翻成用户能看懂的一句话。
    ///
    /// 三件事必须分开说：**主机没实现该接口** ≠ **返回体结构不对** ≠ **网络不通**。
    /// 混在一起时用户只会看到系统级原文（"未能读取数据，因为它的格式不正确"），
    /// 既定位不到原因，也像是 App 坏了。
    private static func loadErrorMessage(for error: Error) -> String {
        if let failure = error as? ModelLoadFailure {
            switch failure {
            case .badStatus(let code):
                return L("Can't load models: %@", "HTTP \(code)")
            }
        }
        if error is DecodingError {
            // 200 却解不出 JSON：主机实现了路由但结构不是我们认识的（版本不匹配）。
            return L("This host doesn't support model lists. Update the desktop app.")
        }
        return L("Can't load models: %@", error.localizedDescription)
    }

    private func clearModels() {
        models = []
        activeModelID = nil
    }

    /// 设备或 Agent 变了 —— 下次必须重新拉，否则会沿用上一个 Agent 的模型。
    /// 指纹一并清掉：它描述的是"旧目标那次成功响应"的配置，留着会误判。
    func invalidate() {
        loadedKey = nil
        loadedConfigVersion = nil
    }

    // MARK: 切换

    /// 选中一个模型。
    ///
    /// 两条落地路径，语义不同，不能混：
    /// - **有 `conversationID`**（既有对话）→ 走对话级覆盖
    ///   （`PATCH /api/conversations/<id>` 的 `modelId` + `modelProviderId`），
    ///   只影响这一个对话。从对话里点进来的场景（含 `ModelPickerView`）都该走这条 ——
    ///   用户的心智是"这个对话换个模型"，不是改全局默认。
    /// - **无 `conversationID`**（草稿 / 无对话上下文）→ 改该 Agent 的全局默认模型
    ///   （`POST /api/agents/models/default`），新对话以此为起点。
    ///
    /// 这条分叉与 `ConversationDetailView.selectModel` 的草稿/既有分支**语义一致**，
    /// 两处不要各写一套判断。
    ///
    /// - Note: `providerID` 必须与 `modelID` 成对使用：同名模型可能来自多个 provider，
    ///   缺了它会拼出错误的 `provider/model`。
    func select(_ modelID: String, providerID: String? = nil, conversationID: String? = nil) {
        guard let device = currentDevice, !currentAgentID.isEmpty else {
            notice = L("No Mac connected. Add a device first.")
            return
        }

        // 既有对话：写对话级覆盖，成功后由调用方重新拉取详情（onChanged）。
        if let conversationID, !conversationID.isEmpty {
            notice = nil
            let agentID = currentAgentID
            Task {
                let ok = await ConversationStore.shared.setModel(
                    device: device,
                    id: conversationID,
                    modelID: modelID,
                    providerID: providerID
                )
                if ok {
                    BrewPingLog.net.info("Conversation model override set to \(modelID, privacy: .public)")
                } else {
                    notice = L("Switch failed. Check the connection and try again.")
                }
                // 无论成败都回读一次：成功刷新 isDefault / 高亮，失败也要让界面
                // 退回真实状态（避免乐观高亮留在错误的选项上）。
                await refresh(device: device, agentID: agentID, force: true)
            }
            return
        }

        // 草稿 / 无对话上下文：改 Agent 全局默认。
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
        // providerId 与 modelId 成对提交：同名模型可来自多个 provider，
        // 缺了它 opencode 会拼出错误的 `provider/model`。
        var payload: [String: Any] = [
            "agentId": currentAgentID,
            "modelId": modelID
        ]
        if let providerID, !providerID.isEmpty {
            payload["providerId"] = providerID
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

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
                providerID: provider.id ?? "",
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

/// 通用模型列表页。
///
/// ⚠️ **当前无调用方**（`ConversationDetailView` 用的是内嵌 Picker + 自己的
/// `selectModel`，语义与这里一致）。保留它是为了将来需要一个独立的全屏选择页时
/// 能直接复用 —— 真要用它，**必须传 `conversationID`**，否则选择会落到 Agent
/// 全局默认上，与从对话里点进来的用户预期不符（`select` 的两条路径见其文档）。
struct ModelPickerView: View {
    /// 非空 → 选择写这个对话的覆盖；空 → 写 Agent 全局默认（仅无对话上下文时该为空）。
    var conversationID: String?

    @StateObject private var store = ModelStore.shared

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
                        // providerID 必须与 modelID 成对提交：同名模型可能来自多个
                        // provider，只传 id 时服务端会拿错 provider 去拼 `provider/model`。
                        // conversationID 同样要带上，否则会误改 Agent 全局默认。
                        store.select(
                            model.id,
                            providerID: model.providerID,
                            conversationID: conversationID
                        )
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
