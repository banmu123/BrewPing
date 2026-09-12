import BrewPingCore
import SwiftUI

// ─── 侧边栏（悬浮圆角卡片：四周留缝、内容裁切在圆角内）──────────────────────────
//
// 与 Windows 逐项对齐：品牌行 / 新对话 / 目录过滤行 / 目录分组（可折叠）/
// 归档区 / 底部设置入口。

struct SidebarView: View {
    @EnvironmentObject private var i18n: I18n
    @EnvironmentObject private var app: DesktopAppState

    /// 悬停中的会话条目（用于显示行尾操作按钮，等价于 Tailwind 的 `group-hover`）。
    @State private var hoveredConversation: String?

    var body: some View {
        VStack(spacing: 0) {
            brandRow
            newChatRow
            conversationList
            settingsRow
        }
        .frame(width: LatteMetrics.sidebarWidth)
        .background(Latte.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Latte.border.opacity(0.5), lineWidth: 1)
        }
        .latteShadow(LatteShadow.xs)
        .padding(.top, 4)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.bottom, 8)
    }

    // MARK: 品牌行

    private var brandRow: some View {
        HStack(spacing: 6) {
            Text("☕").font(.system(size: 11))
            Text("BrewPing")
                .font(LatteFont.mono11.weight(.semibold))
                .foregroundStyle(Latte.primary.opacity(0.9))

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                RuntimeDot(state: app.runtimeState, size: 6)
                Text(brandStateText)
                    .font(LatteFont.font9)
                    .foregroundStyle(Latte.mutedForeground)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: LatteMetrics.headerHeight)
    }

    private var brandStateText: String {
        switch app.runtimeState {
        case "online": return "ONLINE"
        case "starting": return "STARTING…"
        default: return "OFFLINE"
        }
    }

    // MARK: 新对话

    private var newChatRow: some View {
        Button {
            app.newConversation()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").font(.system(size: 13))
                Text(i18n.t(.sideNewChat)).font(LatteFont.xs)
                Spacer(minLength: 0)
            }
            .foregroundStyle(app.activeConvId == nil ? Latte.foreground : Latte.mutedForeground)
            .font(app.activeConvId == nil ? .system(size: 12, weight: .medium) : LatteFont.xs)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(app.activeConvId == nil ? Latte.accent : .clear)
        )
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    // MARK: 对话列表

    private var conversationList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                dirFilterRow

                if app.activeConversations.isEmpty {
                    hint(i18n.t(.sideEmpty))
                } else if app.visibleGroups.isEmpty {
                    hint(i18n.t(.sideGroupEmpty))
                } else {
                    ForEach(app.visibleGroups) { group in
                        groupView(group)
                    }
                }

                if !app.archivedConversations.isEmpty {
                    archivedSection
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity)
    }

    /// 目录过滤行（分组头 + 右侧工具图标）
    private var dirFilterRow: some View {
        HStack(spacing: 0) {
            Text(dirFilterTitle)
                .font(LatteFont.font10.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Latte.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            DirFilterMenu()
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var dirFilterTitle: String {
        if app.dirFilter == kAllDirs { return i18n.t(.sideFilterAll) }
        if app.dirFilter == kUnbound { return i18n.t(.sideUnbound) }
        return DesktopAppState.pathLabel(app.dirFilter)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(LatteFont.font10)
            .foregroundStyle(Latte.mutedForeground.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.top, 4)
    }

    /// 一个目录组：组头 = 折叠/展开（所有组保持可见，只切换视野不下钻）
    private func groupView(_ group: DirGroup) -> some View {
        let collapsed = app.collapsedGroups[group.key] == true
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                app.collapsedGroups[group.key] = !collapsed
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Latte.mutedForeground.opacity(0.6))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(Latte.primary.opacity(0.75))
                    Text(group.key == kUnbound
                         ? i18n.t(.sideUnbound)
                         : DesktopAppState.pathLabel(group.key))
                        .font(LatteFont.font11.weight(.medium))
                        .foregroundStyle(Latte.foreground.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text("\(group.items.count)")
                        .font(LatteFont.font9)
                        .foregroundStyle(Latte.mutedForeground.opacity(0.6))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 6)
            .padding(.top, 6)
            .help(group.key == kUnbound
                  ? i18n.t(.sideUnboundTooltip)
                  : i18n.t(.sideGroupTooltip, ["path": group.key]))

            if !collapsed {
                ForEach(group.items) { conv in
                    conversationRow(conv, archived: false)
                }
            }
        }
    }

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(i18n.t(.sideArchived))
                .font(LatteFont.font10.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Latte.mutedForeground.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
                .padding(.top, 8)
                .overlay(alignment: .top) {
                    LatteDivider(opacity: 0.6)
                }
                .padding(.top, 8)

            ForEach(app.archivedConversations) { conv in
                conversationRow(conv, archived: true)
            }
        }
    }

    // MARK: 会话条目

    private func conversationRow(_ conv: ConversationSummary, archived: Bool) -> some View {
        let selected = app.activeConvId == conv.id && !archived
        let hovering = hoveredConversation == conv.id

        return HStack(spacing: 4) {
            Button {
                guard !archived else { return }
                Task { await app.openConversation(conv.id) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if conv.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Latte.primary.opacity(0.7))
                        }
                        Text(conv.title ?? i18n.t(.sideUntitled))
                            .font(LatteFont.xs)
                            .foregroundStyle(Latte.foreground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    // 元信息行：锁单行（英文比中文长，防换行破版），时间统一 24 小时制
                    HStack(spacing: 4) {
                        Text(app.agentNameMap[conv.agentId] ?? conv.agentId)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                        Text("·")
                        Text(i18n.t(.sideMsgCount, ["n": String(conv.messageCount)]))
                        Text("·")
                        Text(DesktopDateFormat.clockTime(conv.updatedAtMs, locale: i18n.locale))
                    }
                    .font(LatteFont.font9)
                    .foregroundStyle(Latte.mutedForeground)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(archived)
            .help(conv.title ?? i18n.t(.sideUntitled))

            if hovering {
                HStack(spacing: 2) {
                    if archived {
                        rowAction("arrow.uturn.backward", i18n.t(.sideRestore), danger: false) {
                            Task { await app.restoreConversation(conv.id) }
                        }
                        rowAction("trash", i18n.t(.sideDeleteForever), danger: true) {
                            Task { await app.deleteConversation(conv.id) }
                        }
                    } else {
                        rowAction(conv.isPinned ? "pin.slash" : "pin",
                                  conv.isPinned ? i18n.t(.sideUnpin) : i18n.t(.sidePin),
                                  danger: false) {
                            Task { await app.togglePin(conv.id, pinned: !conv.isPinned) }
                        }
                        rowAction("archivebox", i18n.t(.sideArchive), danger: false) {
                            Task { await app.archiveConversation(conv.id) }
                        }
                    }
                }
            }
        }
        .padding(.trailing, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Latte.accent : (hovering ? Latte.accent.opacity(0.6) : .clear))
        )
        .padding(.bottom, 2)
        .onHover { hoveredConversation = $0 ? conv.id : (hoveredConversation == conv.id ? nil : hoveredConversation) }
    }

    private func rowAction(
        _ icon: String, _ title: String, danger: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(danger ? Latte.destructive : Latte.mutedForeground)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .hoverHighlight(cornerRadius: 6)
    }

    // MARK: 底部设置入口

    private var settingsRow: some View {
        VStack(spacing: 0) {
            LatteDivider()
            Button {
                app.settingsOpen = true
            } label: {
                HStack(spacing: 8) {
                    Text("⚙").font(.system(size: 13))
                    Text(i18n.t(.sideSettings)).font(LatteFont.xs)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Latte.mutedForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .help(i18n.t(.sideSettingsTooltip))
            .padding(10)
        }
    }
}

// MARK: - 目录过滤下拉

/// 侧栏目录过滤下拉：全部对话 / 未绑定目录 / 各绑定目录（按最近活动序）。
private struct DirFilterMenu: View {
    @EnvironmentObject private var i18n: I18n
    @EnvironmentObject private var app: DesktopAppState

    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(app.dirFilter == kAllDirs ? Latte.mutedForeground : Latte.primary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(app.dirFilter == kAllDirs ? .clear : Latte.accent)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(i18n.t(.sideFilterTooltip))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    row(value: kAllDirs, label: i18n.t(.sideFilterAll), icon: "square.3.layers.3d")
                    row(value: kUnbound, label: i18n.t(.sideUnbound), icon: "folder")

                    if !app.recentDirs.isEmpty {
                        LatteDivider().padding(.vertical, 4)
                        Text(i18n.t(.sideByDir))
                            .font(LatteFont.font10)
                            .foregroundStyle(Latte.mutedForeground.opacity(0.7))
                            .padding(.horizontal, 10)
                            .padding(.bottom, 2)
                        ForEach(app.recentDirs, id: \.self) { dir in
                            row(
                                value: dir,
                                label: DesktopAppState.pathLabel(dir),
                                desc: dir,
                                icon: "folder"
                            )
                        }
                    }
                }
                .padding(6)
            }
            .frame(width: 224)
            .frame(maxHeight: 420)
            .background(Latte.popover)
        }
    }

    private func row(value: String, label: String, desc: String? = nil, icon: String) -> some View {
        let selected = app.dirFilter == value
        return Button {
            app.dirFilter = value
            open = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Latte.primary.opacity(0.7))
                Text(label)
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.popoverForeground)
                    .fontWeight(selected ? .medium : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if selected {
                    Text("✓").font(LatteFont.font10).foregroundStyle(Latte.primary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Latte.accent : .clear)
        )
        .help(desc ?? label)
    }
}
