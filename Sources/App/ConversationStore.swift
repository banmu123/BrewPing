import Foundation

// ─── 多对话存储（与 Windows 端 conversation_store.rs 同一套落盘契约）──────────
//
// 落盘布局（与 Windows 端逐字对齐，iOS 双端共用同一套解码）：
//   ~/.brewping/conversations/index.json      ← ConversationSummary 列表（派生缓存）
//   ~/.brewping/conversations/conv_<id>.json  ← 完整转录（权威数据）
//
// 铁律（与 Windows 端一致）：
//   1. 解码全部容错（旧文件缺键不得清空数据；JSON 键 camelCase 与 serde 对齐）；
//   2. 「锁内改快照、锁外写盘」—— NSLock 不跨 I/O 持有；
//   3. 文件损坏/缺失 → 逐文件扫描恢复，退化不崩溃；
//   4. 启动时清理空对话（无消息即删，与 Windows startup_recover 一致）。
//
// 对话级设置（与 Windows 端同语义）：
//   · workdirOverride  —— 对话绑定的工作目录（nil = 回落 CLI 默认）；
//   · modelOverride + modelProviderOverride —— 对话级模型覆盖（成对存取），
//     仅对 headless 型 Agent 生效（opencode 会话型进程的 cwd/模型在启动时固定）；
//   · approvalMode     —— 对话级授权档位（nil = 回落全局 approval.json）。

/// 对话级授权档位的归一化：只认 safe / askAll / auto，其余一律视为未设置。
enum ConversationApprovalMode {
    static func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return ApprovalMode(rawValue: trimmed)?.rawValue
    }
}

/// 工作目录归一化：trim 后空串视为未绑定。
private func normalizeWorkdir(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else { return nil }
    return trimmed
}

struct ConversationTranscriptEntry: Codable, Equatable {
    /// "user" | "assistant" | "error" | "system"
    var role: String
    var text: String
    var source: String?
    var commandId: String?
    var createdAtMs: Double
}

struct ConversationSummary: Codable, Equatable, Identifiable {
    var id: String
    var agentId: String
    var title: String?
    var titleSource: String?
    var createdAtMs: Double
    var updatedAtMs: Double
    var archived: Bool
    var isPinned: Bool
    var modelOverride: String?
    var modelProviderOverride: String?
    var workdirOverride: String?
    var approvalMode: String?
    var latestCommandId: String?
    var messageCount: Int
}

/// 完整对话（转录层：权威数据，逐对话一个文件）。
struct ConversationRecord: Codable, Equatable {
    var id: String
    var agentId: String
    var title: String?
    var titleSource: String?
    var createdAtMs: Double
    var updatedAtMs: Double
    var archived: Bool
    var isPinned: Bool
    var modelOverride: String?
    var modelProviderOverride: String?
    var workdirOverride: String?
    var approvalMode: String?
    var latestCommandId: String?
    var messages: [ConversationTranscriptEntry]
}

private struct ConversationIndexFile: Codable {
    var conversations: [ConversationSummary]
}

final class ConversationStore {
    static let shared = ConversationStore()

    enum StoreError: LocalizedError {
        case notFound
        case archived
        case notArchived
        case workdirMissing(String)
        case invalidWorkdir(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "conversation not found"
            case .archived:
                return "conversation is archived — restore it first"
            case .notArchived:
                return "conversation must be archived before deletion"
            case .workdirMissing(let dir):
                return "workdir no longer exists: \(dir) — change the working folder before restoring"
            case .invalidWorkdir(let dir):
                return "workdir does not exist or is not a directory: \(dir)"
            }
        }
    }

    private let lock = NSLock()
    private var conversations: [String: ConversationRecord] = [:]
    /// 当前激活的对话（消息路由三层回落的中间层，与 Windows 端同义）。
    private var activeConversationID: String?
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = SessionManager.shared.directory
                .appendingPathComponent("conversations", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        loadPersisted()
    }

    // MARK: - 读取

    func get(_ id: String) -> ConversationRecord? {
        lock.lock(); defer { lock.unlock() }
        return conversations[id]
    }

    func activeConversation() -> String? {
        lock.lock(); defer { lock.unlock() }
        return activeConversationID
    }

    func setActiveConversation(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        activeConversationID = id
    }

    /// 列表：置顶优先 + 最新活动降序（与 Windows 端同一排序公式）。
    func list(includeArchived: Bool) -> [ConversationSummary] {
        lock.lock(); defer { lock.unlock() }
        let pinnedRankOffset: Double = 1e15
        return conversations.values
            .filter { includeArchived || !$0.archived }
            .map { summary($0) }
            .sorted { lhs, rhs in
                let lhsRank = (lhs.isPinned ? pinnedRankOffset : 0) + lhs.updatedAtMs
                let rhsRank = (rhs.isPinned ? pinnedRankOffset : 0) + rhs.updatedAtMs
                return lhsRank > rhsRank
            }
    }

    /// 归档 / 恢复前的工作目录可执行性检查（目录已删 → 返回路径，调用方给 409）。
    static func workdirMissing(_ conv: ConversationRecord) -> String? {
        guard let dir = conv.workdirOverride, !dir.isEmpty else { return nil }
        return FileManager.default.fileExists(atPath: dir) ? nil : dir
    }

    // MARK: - 创建

    func create(agentID: String) -> ConversationRecord {
        createWithOptions(agentID: agentID, workdir: nil, approvalMode: nil)
    }

    /// 创建对话（完整选项）：工作目录绑定 + 创建时固化的授权档位。
    /// 授权随对话固化 —— 这是「每个对话授权互不影响」的前提。
    func createWithOptions(agentID: String, workdir: String?, approvalMode: String?) -> ConversationRecord {
        let now = Date().timeIntervalSince1970 * 1000
        let conv = ConversationRecord(
            id: "conv_" + UUID().uuidString,
            agentId: agentID,
            title: nil,
            titleSource: nil,
            createdAtMs: now,
            updatedAtMs: now,
            archived: false,
            isPinned: false,
            modelOverride: nil,
            modelProviderOverride: nil,
            workdirOverride: normalizeWorkdir(workdir),
            approvalMode: ConversationApprovalMode.normalize(approvalMode),
            latestCommandId: nil,
            messages: []
        )
        lock.lock()
        conversations[conv.id] = conv
        lock.unlock()
        persist(conv)
        return conv
    }

    // MARK: - 对话级设置（统一写入口：锁内改快照、锁外写盘；不 bump updatedAt）

    private func mutate(_ id: String, _ apply: (inout ConversationRecord) -> Void) throws -> ConversationSummary {
        let updated: ConversationSummary? = {
            lock.lock()
            guard var conv = conversations[id] else { return nil }
            lock.unlock()
            apply(&conv)
            lock.lock()
            guard conversations[id] != nil else {
                lock.unlock()
                return nil
            }
            conversations[id] = conv
            let s = summary(conv)
            lock.unlock()
            return s
        }()
        guard let result = updated else { throw StoreError.notFound }
        if let conv = get(id) { persist(conv) }
        return result
    }

    /// 更改绑定目录（nil / 空串 = 解绑）。目录必须真实存在。
    @discardableResult
    func setWorkdir(id: String, workdir: String?) throws -> ConversationSummary {
        let normalized = normalizeWorkdir(workdir)
        if let dir = normalized, !FileManager.default.fileExists(atPath: dir) {
            throw StoreError.invalidWorkdir(dir)
        }
        return try mutate(id) { $0.workdirOverride = normalized }
    }

    /// 设置 / 清除对话级模型覆盖（modelID nil/空 = 清除；provider 与 model 成对存取）。
    @discardableResult
    func setModel(id: String, modelID: String?, providerID: String?) throws -> ConversationSummary {
        let model = modelID.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let provider = providerID.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return try mutate(id) { conv in
            conv.modelOverride = model
            conv.modelProviderOverride = model == nil ? nil : provider
        }
    }

    /// 切换对话绑定的 Agent。换 Agent 时清除模型覆盖（旧 Agent 的模型对新 Agent 无意义）。
    @discardableResult
    func setAgent(id: String, agentID: String) throws -> ConversationSummary {
        let trimmed = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return try mutate(id) { conv in
            conv.agentId = trimmed
            conv.modelOverride = nil
            conv.modelProviderOverride = nil
        }
    }

    /// 设置 / 清除对话级授权档位（nil / 非法值 = 回落全局默认）。
    @discardableResult
    func setApprovalMode(id: String, mode: String?) throws -> ConversationSummary {
        let normalized = ConversationApprovalMode.normalize(mode)
        return try mutate(id) { $0.approvalMode = normalized }
    }

    /// 修改标题 / 归档态 / 置顶。改名置 `titleSource = "manual"`；
    /// 归档与设置类操作不 bump `updatedAtMs`（不应拉动列表排序）。
    @discardableResult
    func patch(id: String, title: String?, archived: Bool?, pinned: Bool?) throws -> ConversationSummary {
        return try mutate(id) { conv in
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                conv.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                conv.titleSource = "manual"
            }
            if let archived { conv.archived = archived }
            if let pinned { conv.isPinned = pinned }
        }
    }

    /// 删除对话（两段式：仅归档态可删）。删转录文件并重写索引。
    func delete(id: String) throws {
        let fileURL: URL
        let index: ConversationIndexFile
        lock.lock()
        defer { lock.unlock() }
        guard let conv = conversations[id] else { throw StoreError.notFound }
        guard conv.archived else { throw StoreError.notArchived }
        conversations[id] = nil
        fileURL = directory.appendingPathComponent("\(id).json")
        index = ConversationIndexFile(conversations: conversations.values.map { summary($0) })
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 转录

    /// 追加一条转录（唯一写入口）。首条 user 消息自动命名（manual 永不覆盖）；
    /// `updatedAtMs` 单调：乱序事件不能把时间拉回去。
    @discardableResult
    func append(
        conversationID: String,
        role: String,
        text: String,
        source: String?,
        commandID: String?
    ) -> ConversationTranscriptEntry? {
        let now = Date().timeIntervalSince1970 * 1000
        let entry = ConversationTranscriptEntry(
            role: role,
            text: text,
            source: source,
            commandId: commandID,
            createdAtMs: now
        )
        var updated: ConversationRecord?
        lock.lock()
        if var conv = conversations[conversationID] {
            conv.messages.append(entry)
            conv.updatedAtMs = max(conv.updatedAtMs, now)
            if role == "user", conv.title == nil {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let flattened = trimmed.replacingOccurrences(of: "\n", with: " ")
                    conv.title = flattened.count > 32 ? String(flattened.prefix(32)) + "…" : flattened
                    conv.titleSource = "auto"
                }
            }
            conversations[conversationID] = conv
            updated = conv
        }
        lock.unlock()
        if let conv = updated { persist(conv) }
        return conversations[conversationID] != nil ? entry : nil
    }

    /// 写调度指针（只有命令执行链与消息提交可以调用）。
    func setLatestCommand(id: String, commandID: String?) {
        var updated: ConversationRecord?
        lock.lock()
        if var conv = conversations[id] {
            conv.latestCommandId = commandID
            conversations[id] = conv
            updated = conv
        }
        lock.unlock()
        if let conv = updated { persist(conv) }
    }

    // MARK: - Internals

    private func summary(_ conv: ConversationRecord) -> ConversationSummary {
        ConversationSummary(
            id: conv.id,
            agentId: conv.agentId,
            title: conv.title,
            titleSource: conv.titleSource,
            createdAtMs: conv.createdAtMs,
            updatedAtMs: conv.updatedAtMs,
            archived: conv.archived,
            isPinned: conv.isPinned,
            modelOverride: conv.modelOverride,
            modelProviderOverride: conv.modelProviderOverride,
            workdirOverride: conv.workdirOverride,
            approvalMode: conv.approvalMode,
            latestCommandId: conv.latestCommandId,
            messageCount: conv.messages.count
        )
    }

    private func persist(_ conv: ConversationRecord) {
        let fileURL = directory.appendingPathComponent("\(conv.id).json")
        if let data = try? JSONEncoder().encode(conv) {
            try? data.write(to: fileURL, options: .atomic)
        }
        rewriteIndex()
    }

    private func rewriteIndex() {
        lock.lock()
        rewriteIndexLocked()
        lock.unlock()
    }

    /// 前提：调用方已持有 `lock`（NSLock 不可重入，切勿在未持锁时调用）。
    private func rewriteIndexLocked() {
        let index = ConversationIndexFile(conversations: conversations.values.map { summary($0) })
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }

    private func loadPersisted() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        var loaded: [String: ConversationRecord] = [:]
        for file in files where file.lastPathComponent.hasPrefix("conv_") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let conv = try? JSONDecoder().decode(ConversationRecord.self, from: data) else {
                continue
            }
            loaded[conv.id] = conv
        }

        // 启动恢复（与 Windows startup_recover 一致）：空对话直接清掉（文件一并删除）。
        let stale = loaded.filter { $0.value.messages.isEmpty }
        for (id, _) in stale { loaded[id] = nil }
        for (id, _) in stale {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(id).json")
            )
        }

        lock.lock()
        conversations = loaded
        lock.unlock()
        rewriteIndex()
    }
}

// MARK: - HTTP 层字典转换（与 Windows serde camelCase 契约逐字对齐）

extension ConversationTranscriptEntry {
    var apiObject: [String: Any] {
        [
            "role": role,
            "text": text,
            "source": source ?? NSNull(),
            "commandId": commandId ?? NSNull(),
            "createdAtMs": createdAtMs
        ]
    }
}

extension ConversationSummary {
    var apiObject: [String: Any] {
        [
            "id": id,
            "agentId": agentId,
            "title": title ?? NSNull(),
            "titleSource": titleSource ?? NSNull(),
            "createdAtMs": createdAtMs,
            "updatedAtMs": updatedAtMs,
            "archived": archived,
            "isPinned": isPinned,
            "modelOverride": modelOverride ?? NSNull(),
            "modelProviderOverride": modelProviderOverride ?? NSNull(),
            "workdirOverride": workdirOverride ?? NSNull(),
            "approvalMode": approvalMode ?? NSNull(),
            "latestCommandId": latestCommandId ?? NSNull(),
            "messageCount": messageCount
        ]
    }
}

extension ConversationRecord {
    var apiObject: [String: Any] {
        var object = ConversationSummary(
            id: id, agentId: agentId, title: title, titleSource: titleSource,
            createdAtMs: createdAtMs, updatedAtMs: updatedAtMs, archived: archived,
            isPinned: isPinned, modelOverride: modelOverride,
            modelProviderOverride: modelProviderOverride, workdirOverride: workdirOverride,
            approvalMode: approvalMode, latestCommandId: latestCommandId,
            messageCount: messages.count
        ).apiObject
        object["messages"] = messages.map { $0.apiObject }
        return object
    }
}
