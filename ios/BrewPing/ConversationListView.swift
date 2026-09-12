import SwiftUI

// ─── 对话列表（连接机器后的主页）──────────────────────────────────────────────
//
// 数据来自桌面端 `GET /api/conversations`：按「绑定的工作目录」分组，
// 每组下是该目录产生的对话（对齐桌面端侧栏的目录分组语义）。
// 点某条对话 → 进入对话详情（转录 + 输入框）。

/// 列表页的导航目标：既有对话 / 新对话（草稿，不带 conversationId）。
enum ConversationRoute: Hashable {
    case existing(String)
    case draft
}

struct ConversationListView: View {
    let device: ManagedDevice
    let online: Bool
    /// agentId → 显示名（由 ContentView 传入，复用已拉取的 /api/agents 结果）。
    let agentNames: [String: String]

    @ObservedObject private var store = ConversationStore.shared
    /// 折叠的目录组（仅视觉折叠，不改变过滤）。
    @State private var collapsed: Set<String> = []

    var body: some View {
        List {
            Section {
                NavigationLink(value: ConversationRoute.draft) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.bpPrimary)
                        Text("New Conversation")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.bpForeground)
                    }
                }
                .listRowBackground(Color.bpCard)
            }

            if let message = store.loadError {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.bpWarning)
                        Text(verbatim: message)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.bpMutedForeground)
                    }
                    .listRowBackground(Color.bpCard)
                }
            }

            if store.unsupported {
                Section {
                    Text("This desktop version has no conversation list. Update the desktop app.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bpMutedForeground)
                        .listRowBackground(Color.bpCard)
                }
            } else if store.conversations.isEmpty {
                Section {
                    Text("No conversations yet. Send a message to create one.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bpMutedForeground)
                        .listRowBackground(Color.bpCard)
                }
            } else {
                ForEach(store.dirGroups) { group in
                    Section {
                        if !collapsed.contains(group.id) {
                            ForEach(group.items) { conv in
                                NavigationLink(value: ConversationRoute.existing(conv.id)) {
                                    conversationRow(conv)
                                }
                                .listRowBackground(Color.bpCard)
                                // 置顶 / 取消置顶（对齐桌面端侧栏与 Windows/Android 端）
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button {
                                        Task {
                                            _ = await store.setPinned(device: device, id: conv.id, pinned: !conv.isPinned)
                                            await store.refresh(device: device, force: true)
                                        }
                                    } label: {
                                        Label(
                                            conv.isPinned ? "Unpin" : "Pin",
                                            systemImage: conv.isPinned ? "pin.slash" : "pin.fill"
                                        )
                                        .tint(Color.bpPrimary)
                                    }
                                }
                                // 归档（两段式删除的第一段；恢复见下方「已归档」分组）
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        Task {
                                            _ = await store.setArchived(device: device, id: conv.id, archived: true)
                                            await store.refresh(device: device, force: true)
                                        }
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                            .tint(Color.bpMutedForeground)
                                    }
                                }
                            }
                        }
                    } header: {
                        groupHeader(group)
                    }
                }

                // ── 已归档（任务 4 补齐：恢复 / 彻底删除）───────────────────
                let archived = store.conversations.filter { $0.archived }
                if !archived.isEmpty {
                    Section {
                        ForEach(archived) { conv in
                            HStack(spacing: 8) {
                                Image(systemName: "archivebox")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.bpMutedForeground)
                                conversationRow(conv)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                // 恢复（桌面端会校验绑定目录仍存在）
                                Button {
                                    Task {
                                        _ = await store.setArchived(device: device, id: conv.id, archived: false)
                                        await store.refresh(device: device, force: true)
                                    }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                        .tint(Color.bpSuccess)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // 彻底删除（仅归档态可删；两段式删除第二段）
                                Button(role: .destructive) {
                                    Task {
                                        _ = await store.delete(device: device, id: conv.id)
                                        await store.refresh(device: device, force: true)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("Archived")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.bpBackground)
        .tint(Color.bpPrimary)
        .refreshable { await store.refresh(device: device, force: true) }
        .task { await store.refresh(device: device) }
        .onChange(of: online) { _, isOnline in
            // 重新连上时补一次刷新（离线期间的变更补齐）
            if isOnline { Task { await store.refresh(device: device, force: true) } }
        }
    }

    /// 目录组头：文件夹图标 + 名称 + 数量（点击折叠/展开）。
    @ViewBuilder
    private func groupHeader(_ group: ConversationDirGroup) -> some View {
        let isCollapsed = collapsed.contains(group.id)
        Button {
            if isCollapsed {
                collapsed.remove(group.id)
            } else {
                collapsed.insert(group.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.bpMutedForeground)
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.bpPrimary.opacity(0.8))
                Text(group.dir.map { bpPathLabel($0) } ?? L("Unbound Folder"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.bpForeground.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: String(group.items.count))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.bpMutedForeground)
            }
            .textCase(nil)
        }
        .buttonStyle(.plain)
    }

    /// 对话行：标题 + 「Agent · N 条 · 时间」。
    @ViewBuilder
    private func conversationRow(_ conv: ConversationSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if conv.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.bpPrimary.opacity(0.8))
                }
                Text(conv.title ?? L("(untitled)"))
                    .font(.system(size: 15))
                    .foregroundStyle(Color.bpForeground)
                    .lineLimit(1)
            }
            Text(verbatim: metaLine(conv))
                .font(.system(size: 11))
                .foregroundStyle(Color.bpMutedForeground)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func metaLine(_ conv: ConversationSummary) -> String {
        let agent = agentNames[conv.agentId] ?? conv.agentId
        let count = L("%@ msgs", String(conv.messageCount))
        let time = conv.updatedAtMs > 0 ? bpTimeLabel(ms: conv.updatedAtMs) : ""
        return [agent, count, time].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
