import BrewPingCore
import SwiftUI

// ─── 工作目录条（composer 上方；对齐 workdir-picker.tsx）────────────────────────
//
// 触发条 = Folder 图标 + 目录路径（末段加粗）+ 右侧作用范围提示；
// 点击展开圆角卡片弹层：当前值 + 清除 / 快捷位置 / 最近使用 / 手动输入 /
// 目录浏览器（进入 / 返回 / 选中）+ 底部说明。

struct WorkdirPickerView: View {
    @EnvironmentObject private var i18n: I18n
    @EnvironmentObject private var app: DesktopAppState

    @State private var open = false
    @State private var hovering = false

    // 弹层内部状态
    @State private var roots: FolderBrowser.RootsInfo?
    @State private var browse: FolderBrowser.BrowseResult?
    @State private var browseError: String?
    @State private var busy = false
    @State private var manualPath = ""

    private var workdir: String? { app.effectiveWorkdir }

    private var hint: String {
        app.isDraftConv ? i18n.t(.wdHintNew) : i18n.t(.wdHintBound)
    }

    var body: some View {
        Button {
            open.toggle()
            if open { loadRootsIfNeeded() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Latte.primary.opacity(0.8))

                if let workdir {
                    HStack(spacing: 6) {
                        Text(DesktopAppState.pathLabel(workdir))
                            .font(LatteFont.xs.weight(.medium))
                            .foregroundStyle(Latte.foreground)
                        Text(workdir)
                            .font(LatteFont.xs)
                            .foregroundStyle(Latte.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(i18n.t(.wdUnset)).font(LatteFont.xs)
                        Text(i18n.t(.wdUnsetHint))
                            .font(LatteFont.xs)
                            .foregroundStyle(Latte.mutedForeground.opacity(0.7))
                    }
                }

                Spacer(minLength: 0)

                Text(hint)
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.mutedForeground.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.6)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .foregroundStyle(Latte.mutedForeground)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Latte.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? Latte.primary.opacity(0.4) : Latte.inputBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(workdir ?? i18n.t(.wdTitleUnset))
        .onHover { hovering = $0 }
        .padding(.bottom, 8)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            popup
        }
    }

    // MARK: 弹层

    private var popup: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 当前生效目录 + 清除
            HStack(spacing: 8) {
                Text(workdir.map { i18n.t(.wdCurrent, ["path": $0]) } ?? i18n.t(.wdCurrentUnset))
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if workdir != nil {
                    Button {
                        pick(nil)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark").font(.system(size: 9))
                            Text(i18n.t(.wdClear)).font(LatteFont.font10)
                        }
                        .foregroundStyle(Latte.mutedForeground)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: 6)
                    .help(i18n.t(.wdClearTitle))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            LatteDivider().padding(.vertical, 4)

            // 快捷位置：主目录 + 卷
            FlowRow(spacing: 4) {
                if let home = roots?.homeDir {
                    chip(icon: "house", label: i18n.t(.wdHome), help: home) {
                        Task { await enter(home) }
                    }
                }
                ForEach(roots?.drives ?? [], id: \.self) { drive in
                    chip(icon: "internaldrive", label: drive, help: drive) {
                        Task { await enter(drive) }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)

            LatteDivider().padding(.vertical, 4)

            // 最近使用
            if !app.recentDirs.isEmpty {
                Text(i18n.t(.wdRecent))
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.mutedForeground.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                FlowRow(spacing: 4) {
                    ForEach(app.recentDirs.prefix(6), id: \.self) { dir in
                        chip(
                            icon: "folder",
                            label: DesktopAppState.pathLabel(dir),
                            help: dir,
                            selected: workdir == dir
                        ) {
                            pick(dir)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
                LatteDivider().padding(.vertical, 4)
            }

            // 手动输入路径
            HStack(spacing: 6) {
                TextField(i18n.t(.wdManualPlaceholder), text: $manualPath)
                    .textFieldStyle(.plain)
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.foreground)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Latte.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Latte.inputBorder, lineWidth: 1)
                    }
                    .onSubmit { commitManual() }

                Button {
                    commitManual()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Latte.mutedForeground)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 8)
                .disabled(manualPath.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(i18n.t(.wdBindManual))
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)

            // 浏览器：返回上级 + 当前浏览路径
            HStack(spacing: 6) {
                Button {
                    Task { await enter(browse?.parentPath) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Latte.mutedForeground)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 6)
                .disabled(browse?.parentPath == nil || busy)
                .help(i18n.t(.wdParent))

                Text(browse?.path ?? "…")
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            // 子目录列表
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if let browseError {
                        Text(browseError)
                            .font(LatteFont.font10)
                            .foregroundStyle(Latte.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    } else if visibleDirs.isEmpty {
                        Text(busy ? i18n.t(.wdLoading) : i18n.t(.wdNoSubdirs))
                            .font(LatteFont.font10)
                            .foregroundStyle(Latte.mutedForeground)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(visibleDirs, id: \.absolutePath) { entry in
                            dirRow(entry)
                        }
                    }
                }
            }
            .frame(maxHeight: 224)

            LatteDivider().padding(.vertical, 4)

            Text(i18n.t(.wdFooter))
                .font(LatteFont.font10)
                .foregroundStyle(Latte.mutedForeground.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .padding(6)
        .frame(width: 420)
        .background(Latte.popover)
    }

    private var visibleDirs: [FolderBrowser.EntryInfo] {
        (browse?.entries ?? []).filter { !$0.hidden }
    }

    private func dirRow(_ entry: FolderBrowser.EntryInfo) -> some View {
        let selected = workdir == entry.absolutePath
        return HStack(spacing: 8) {
            Button {
                Task { await enter(entry.absolutePath) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(Latte.primary.opacity(0.7))
                    Text(entry.name)
                        .font(LatteFont.xs)
                        .foregroundStyle(Latte.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.absolutePath)

            Button {
                pick(entry.absolutePath)
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? Latte.primary : Latte.mutedForeground.opacity(0.5))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 6)
            .help(i18n.t(.wdPickTitle, ["path": entry.absolutePath]))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private func chip(
        icon: String, label: String, help: String, selected: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(LatteFont.xs).lineLimit(1)
            }
            .foregroundStyle(selected ? Latte.foreground : Latte.mutedForeground)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? Latte.accent : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 8, enabled: !selected)
        .help(help)
    }

    // MARK: 行为

    private func pick(_ path: String?) {
        Task { await app.setWorkdir(path) }
        open = false
    }

    private func commitManual() {
        let trimmed = manualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manualPath = ""
        pick(trimmed)
    }

    private func loadRootsIfNeeded() {
        if roots == nil { roots = DesktopCommands.browseRoots() }
        if browse == nil {
            let start = workdir ?? roots?.homeDir
            Task { await enter(start) }
        }
    }

    private func enter(_ path: String?) async {
        busy = true
        browseError = nil
        do {
            let result = try DesktopCommands.browseFolder(path)
            browse = result
        } catch {
            browseError = String(describing: error)
        }
        busy = false
    }
}
