import Foundation

// ─── 对话数据层（数据源 = 桌面端 `GET /api/conversations`）──────────────────────
//
// 结构对齐桌面端契约（serde camelCase，见桌面端 `src/api/types.ts`）：
//   ConversationSummary：id / agentId / title / workdirOverride / updatedAtMs / messageCount …
//   Conversation：Summary + messages: [TranscriptEntry]
//
// 三条既有约定必须遵守（与 ModelStore / FolderBrowserStore 一致）：
//   1. 一律走 `BrewPingHTTP.request` + `BrewPingHTTP.session`，不新建 URLSession（鉴权头在那里统一加）；
//   2. 401 → 明确提示「未配对」；404/501 → 标记 `unsupported` 静默降级（老版本桌面端没有该路由）；
//   3. 切设备必须 `invalidate()`（否则会话数据会串到另一台机器上）。

/// 列表页摘要（元数据层：不含 messages）。
struct ConversationSummary: Decodable, Identifiable, Equatable {
    let id: String
    let agentId: String
    let title: String?
    let titleSource: String?
    let createdAtMs: Double
    let updatedAtMs: Double
    let archived: Bool
    let isPinned: Bool
    let modelOverride: String?
    /// 与 `modelOverride` 配对的 providerId（同名模型可来自多个厂商）。
    let modelProviderOverride: String?
    /// 绑定的工作目录；null = 未绑定（归入「未绑定目录」组）。
    let workdirOverride: String?
    /// 对话级授权档位（safe / askAll / auto）；null = 未设置，回落全局默认。
    let approvalMode: String?
    let latestCommandId: String?
    let messageCount: Int

    /// 老版本桌面端字段可能缺失 → 全部给默认值，避免一条坏数据让整表解码失败
    /// （参考 `ManagedDevice.swift` 的 Optional 解码教训）。
    enum CodingKeys: String, CodingKey {
        case id, agentId, title, titleSource, createdAtMs, updatedAtMs
        case archived, isPinned, modelOverride, modelProviderOverride
        case workdirOverride, approvalMode, latestCommandId, messageCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        agentId = (try? c.decode(String.self, forKey: .agentId)) ?? ""
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        titleSource = try? c.decodeIfPresent(String.self, forKey: .titleSource)
        createdAtMs = (try? c.decode(Double.self, forKey: .createdAtMs)) ?? 0
        updatedAtMs = (try? c.decode(Double.self, forKey: .updatedAtMs)) ?? 0
        archived = (try? c.decode(Bool.self, forKey: .archived)) ?? false
        isPinned = (try? c.decode(Bool.self, forKey: .isPinned)) ?? false
        modelOverride = try? c.decodeIfPresent(String.self, forKey: .modelOverride)
        modelProviderOverride = try? c.decodeIfPresent(String.self, forKey: .modelProviderOverride)
        workdirOverride = try? c.decodeIfPresent(String.self, forKey: .workdirOverride)
        approvalMode = try? c.decodeIfPresent(String.self, forKey: .approvalMode)
        latestCommandId = try? c.decodeIfPresent(String.self, forKey: .latestCommandId)
        messageCount = (try? c.decode(Int.self, forKey: .messageCount)) ?? 0
    }
}

/// 转录条目（后端权威数据）。`id` 由客户端补（后端 messages 不带 id）。
struct TranscriptEntry: Identifiable, Equatable {
    /// "user" | "assistant" | "error" | "system"
    let role: String
    let text: String
    let source: String?
    let commandId: String?
    let createdAtMs: Double
    let id: String
}

/// 完整对话（转录层）。
struct ConversationDetail: Equatable {
    let id: String
    let agentId: String
    let title: String?
    let modelOverride: String?
    let modelProviderOverride: String?
    let workdirOverride: String?
    /// 对话级授权档位；nil = 未设置（跟随桌面端全局默认）。
    let approvalMode: String?
    let updatedAtMs: Double
    let messages: [TranscriptEntry]
}

/// 目录分组（列表页按目录聚合，规则与桌面端侧栏一致）。
struct ConversationDirGroup: Identifiable {
    /// 目录路径；未绑定组为 `nil`。
    let dir: String?
    let items: [ConversationSummary]
    var id: String { dir ?? "__unbound__" }
}

// ─── 解码中转（后端 conversation.messages 无 id，先按 Optional 收进来再补 id）───

private struct ListConversationsResponse: Decodable {
    let success: Bool?
    let conversations: [ConversationSummary]?
}

private struct RawConversation: Decodable {
    let id: String
    let agentId: String?
    let title: String?
    let modelOverride: String?
    let modelProviderOverride: String?
    let workdirOverride: String?
    let approvalMode: String?
    let updatedAtMs: Double?
    let messages: [RawTranscriptEntry]?

    struct RawTranscriptEntry: Decodable {
        let role: String?
        let text: String?
        let source: String?
        let commandId: String?
        let createdAtMs: Double?
    }
}

private struct RawDetailResponse: Decodable {
    let success: Bool?
    let conversation: RawConversation?
}

/// 对话 Store：列表 + 详情（单例；切设备 `invalidate()`）。
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var conversations: [ConversationSummary] = []
    @Published private(set) var loading = false
    /// 最近一次列表拉取的错误（已本地化文案）。
    @Published private(set) var loadError: String?
    /// 桌面端不认识该路由（404/501）：老版本桌面端 → 列表区静默降级。
    @Published private(set) var unsupported = false
    @Published private(set) var detail: ConversationDetail?
    @Published private(set) var detailLoading = false
    @Published private(set) var detailError: String?

    /// 缓存键 = deviceID：同设备已加载过就不重复打接口（`force: true` 强制刷新）。
    private var loadedKey: String?

    private init() {}

    /// 切设备时清空（由 ContentView.resetState 调用）。
    func invalidate() {
        loadedKey = nil
        conversations = []
        loadError = nil
        unsupported = false
        detail = nil
        detailError = nil
    }

    /// 按目录分组：组序按组内最新活动降序，未绑定组垫底（与桌面端侧栏一致）。
    var dirGroups: [ConversationDirGroup] {
        var map: [String: [ConversationSummary]] = [:]
        var unbound: [ConversationSummary] = []
        for conv in conversations where !conv.archived {
            if let dir = conv.workdirOverride, !dir.isEmpty {
                map[dir, default: []].append(conv)
            } else {
                unbound.append(conv)
            }
        }
        var groups = map
            .map { ConversationDirGroup(dir: $0.key, items: $0.value) }
            .sorted { lhs, rhs in
                (lhs.items.first?.updatedAtMs ?? 0) > (rhs.items.first?.updatedAtMs ?? 0)
            }
        if !unbound.isEmpty {
            groups.append(ConversationDirGroup(dir: nil, items: unbound))
        }
        return groups
    }

    /// 拉取对话列表。同设备且已有数据时不重复请求（列表页每次出现都会调用）。
    func refresh(device: ManagedDevice?, force: Bool = false) async {
        guard let device else {
            invalidate()
            return
        }
        if !force, loadedKey == device.id, !conversations.isEmpty { return }

        loading = true
        defer { loading = false }

        guard let request = BrewPingHTTP.request(
            device: device,
            path: "/api/conversations?includeArchived=1",
            timeout: 10
        ) else {
            loadError = L("Can't reach %@: %@", device.name, L("Invalid host or port"))
            return
        }

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if BrewPingHTTP.isUnauthorized(response) {
                // 未配对：交给界面既有的未配对提示，这里不重复报错
                conversations = []
                loadError = nil
                loadedKey = nil
                return
            }
            if statusCode == 404 || statusCode == 501 {
                // 这台主机没有多对话能力（老版本桌面端）：静默降级，不是错误
                conversations = []
                loadError = nil
                unsupported = true
                loadedKey = device.id
                BrewPingLog.net.info("Conversations unsupported by host (HTTP \(statusCode, privacy: .public))")
                return
            }
            guard statusCode == 200 else {
                loadError = L("Server error %@", String(statusCode))
                return
            }

            let decoded = try JSONDecoder().decode(ListConversationsResponse.self, from: data)
            conversations = decoded.conversations ?? []
            unsupported = false
            loadError = nil
            loadedKey = device.id
        } catch {
            // 失败保留旧列表（网络抖动不该让列表消失）；换过设备则必须清空
            if loadedKey != device.id {
                conversations = []
            }
            loadError = L("Can't reach %@: %@", device.name, error.localizedDescription)
            BrewPingLog.net.error("Load conversations failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// 拉取某个对话的完整转录。
    func open(id: String, device: ManagedDevice?) async {
        guard let device else { return }
        detailLoading = true
        detailError = nil
        defer { detailLoading = false }

        guard let request = BrewPingHTTP.request(
            device: device,
            path: "/api/conversations/\(id)",
            timeout: 15
        ) else {
            detailError = L("Invalid host or port")
            return
        }

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if BrewPingHTTP.isUnauthorized(response) {
                detailError = L("Not paired with %@.", device.name)
                return
            }
            guard statusCode == 200 else {
                detailError = L("Server error %@", String(statusCode))
                return
            }
            let raw = try JSONDecoder().decode(RawDetailResponse.self, from: data)
            guard let conv = raw.conversation else {
                detailError = L("Conversation not found")
                return
            }
            detail = Self.normalize(conv)
        } catch {
            detailError = L("Can't reach %@: %@", device.name, error.localizedDescription)
            BrewPingLog.net.error("Load conversation failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// 详情解码：给每条 entry 补稳定 id（后端 messages 不带 id）。
    private static func normalize(_ conv: RawConversation) -> ConversationDetail {
        let entries = (conv.messages ?? []).enumerated().map { index, entry in
            TranscriptEntry(
                role: entry.role ?? "assistant",
                text: entry.text ?? "",
                source: entry.source,
                commandId: entry.commandId,
                createdAtMs: entry.createdAtMs ?? 0,
                id: "\(conv.id)-\(index)"
            )
        }
        return ConversationDetail(
            id: conv.id,
            agentId: conv.agentId ?? "",
            title: conv.title,
            modelOverride: conv.modelOverride,
            modelProviderOverride: conv.modelProviderOverride,
            workdirOverride: conv.workdirOverride,
            approvalMode: conv.approvalMode,
            updatedAtMs: conv.updatedAtMs ?? 0,
            messages: entries
        )
    }

    // MARK: - 写操作（对话级 Agent / 模型 / 授权；与桌面端同一套存储语义）

    /// 创建对话（新对话草稿的物化入口）：`POST /api/conversations`。
    ///
    /// Agent 与授权档位随创建固化（对话级，之后各对话互不影响）。
    /// 成功返回新对话 id 并把详情写入 `detail`；失败返回 nil（原因在 `detailError`）。
    func createConversation(
        device: ManagedDevice?,
        agentID: String,
        approvalMode: String?
    ) async -> String? {
        guard let device else { return nil }
        detailError = nil
        var body: [String: Any] = ["agentId": agentID]
        if let mode = approvalMode, !mode.isEmpty {
            body["approvalMode"] = mode
        }
        guard var request = BrewPingHTTP.request(
            device: device,
            path: "/api/conversations",
            method: "POST",
            timeout: 15
        ) else {
            detailError = L("Invalid host or port")
            return nil
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if BrewPingHTTP.isUnauthorized(response) {
                detailError = L("Not paired with %@.", device.name)
                return nil
            }
            guard statusCode == 200 else {
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                detailError = decoded?["error"] as? String ?? L("Server error %@", String(statusCode))
                return nil
            }
            guard let raw = try? JSONDecoder().decode(RawDetailResponse.self, from: data),
                  let conv = raw.conversation
            else {
                detailError = L("Server error %@", String(statusCode))
                return nil
            }
            detail = Self.normalize(conv)
            // 列表缓存作废：下一次 refresh(force) 会把新对话拉进来
            loadedKey = nil
            BrewPingLog.net.info("Conversation created: \(conv.id, privacy: .public)")
            return conv.id
        } catch {
            detailError = L("Can't reach %@: %@", device.name, error.localizedDescription)
            BrewPingLog.net.error("Create conversation failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// `PATCH /api/conversations/{id}` 的统一小封装：失败时把原因写进 `detailError`。
    private func patch(
        device: ManagedDevice?,
        id: String,
        body: [String: Any]
    ) async -> Bool {
        guard let device else { return false }
        guard var request = BrewPingHTTP.request(
            device: device,
            path: "/api/conversations/\(id)",
            method: "PATCH",
            timeout: 15
        ) else {
            detailError = L("Invalid host or port")
            return false
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if BrewPingHTTP.isUnauthorized(response) {
                detailError = L("Not paired with %@.", device.name)
                return false
            }
            guard statusCode == 200 else {
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                detailError = decoded?["error"] as? String ?? L("Server error %@", String(statusCode))
                return false
            }
            return true
        } catch {
            detailError = L("Can't reach %@: %@", device.name, error.localizedDescription)
            BrewPingLog.net.error("Patch conversation failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    /// 切换对话绑定的 Agent（桌面端会自动清除该对话的模型覆盖）。成功后由
    /// 调用方重取详情（agentId / modelOverride 都变了）。
    @discardableResult
    func setAgent(device: ManagedDevice?, id: String, agentID: String) async -> Bool {
        return await patch(device: device, id: id, body: ["agentId": agentID])
    }

    /// 设置 / 清除对话的授权档位（对话级，互不影响）。
    @discardableResult
    func setApprovalMode(device: ManagedDevice?, id: String, mode: String) async -> Bool {
        return await patch(device: device, id: id, body: ["approvalMode": mode])
    }

    /// 设置 / 清除对话的模型覆盖（`modelID = nil` = 清除，回落该 Agent 默认模型）。
    /// 成功后由调用方重取详情。
    @discardableResult
    func setModel(
        device: ManagedDevice?,
        id: String,
        modelID: String?,
        providerID: String?
    ) async -> Bool {
        var body: [String: Any] = ["modelId": modelID ?? ""]
        body["modelProviderId"] = providerID ?? ""
        return await patch(device: device, id: id, body: body)
    }
}
