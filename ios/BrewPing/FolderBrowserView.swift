import SwiftUI

// MARK: - 目录浏览页（服务端驱动的自绘列表）

/// 浏览 Windows 主机的目录树并选一个目录设为当前 Agent 的工作目录。
///
/// **绝不能用 `.fileImporter` / `UIDocumentPickerViewController`** ——
/// 那浏览的是 iPhone / iCloud 的文件系统，与 Windows 主机毫无关系。
/// 这里的每一行都来自主机 `GET /api/folders` 的响应。
struct FolderBrowserView: View {
    /// 目标 Agent（把选中的目录设给谁）。
    let device: ManagedDevice?
    let agentID: String
    /// 当前已设置的工作目录（nil = 未设置），选中后回调给父视图刷新。
    var currentWorkdir: String?
    let onSet: (String?) -> Void

    @StateObject private var store = FolderBrowserStore()
    @Environment(\.dismiss) private var dismiss

    /// 点「设为工作目录」后的确认弹层。
    @State private var pendingSelection: BrowseEntry?
    @State private var settingNotice: String?

    var body: some View {
        Group {
            switch store.phase {
            case .idle, .loadingRoots:
                ProgressView {
                    Text("Loading folders…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                failureView(message)
            case .empty:
                browsingList
                    .overlay {
                        ContentUnavailableView(
                            "Empty Folder",
                            systemImage: "folder",
                            description: Text("This folder has no subfolders.")
                        )
                    }
            case .permissionDenied:
                browsingList
                    .overlay {
                        ContentUnavailableView(
                            "No Permission",
                            systemImage: "lock.folder",
                            description: Text("This folder can't be read on the host.")
                        )
                    }
            case .browsing:
                browsingList
            }
        }
        .navigationTitle("Working Folder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $store.showsHidden) {
                    Label("Hidden", systemImage: "eye")
                }
            }
        }
        .task {
            // 只在首次出现时拉 roots；重复 task（视图复用）不该重复打接口。
            if store.roots == nil, store.phase == .idle {
                await store.loadRoots(for: device)
            }
        }
    }

    // MARK: 子视图

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can't Browse Folders", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(verbatim: message)
        } actions: {
            Button("Retry") {
                Task { await store.loadRoots(for: device) }
            }
        }
    }

    private var browsingList: some View {
        List {
            // 当前路径 + 手动跳转（方案 §1.1 第 2 条：可手动输入绝对路径）
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    TextField("Path on host", text: $store.pathInput)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            Task { await store.submitPathInput() }
                        }
                    Button {
                        Task { await store.submitPathInput() }
                    } label: {
                        Image(systemName: "arrow.forward.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.pathInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let parent = store.parentPath {
                    Button {
                        Task { await store.goUp() }
                    } label: {
                        Label {
                            // 盘符 / 路径是主机数据，不翻译。
                            Text(verbatim: parent)
                        } icon: {
                            Image(systemName: "chevron.up")
                        }
                        .font(.caption)
                    }
                }
            }

            // 「此电脑」：主机盘符快捷跳转（C:\ / D:\ / …），任意层级都能直达。
            if !store.driveRoots.isEmpty {
                Section {
                    ForEach(store.driveRoots, id: \.self) { drive in
                        Button {
                            Task { await store.browse(drive, showHidden: store.showsHidden) }
                        } label: {
                            Label {
                                // 盘符是主机数据，不翻译。
                                Text(verbatim: drive)
                            } icon: {
                                Image(systemName: "internaldrive.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Drives")
                }
            }

            Section {
                ForEach(store.entries) { entry in
                    Button {
                        guard !entry.isUnreadable else { return }
                        pendingSelection = entry
                    } label: {
                        rowLabel(entry)
                    }
                    .disabled(entry.isUnreadable)
                }

                if store.canLoadMore {
                    Button {
                        Task { await store.loadMore() }
                    } label: {
                        HStack {
                            Spacer()
                            if store.isLoadingPage {
                                ProgressView()
                            } else {
                                Text("Load More")
                            }
                            Spacer()
                        }
                        .font(.callout)
                    }
                    .disabled(store.isLoadingPage)
                }
            } header: {
                // 当前路径是主机数据，不翻译。
                Text(verbatim: store.currentPath)
            }

            if let currentWorkdir, !currentWorkdir.isEmpty {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        // workdir 是主机数据，不翻译。
                        Text(verbatim: currentWorkdir)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                    }
                } header: {
                    Text("Current working folder")
                }
            }

            if let settingNotice {
                Section {
                    Text(verbatim: settingNotice)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await store.browse(store.currentPath, showHidden: store.showsHidden)
        }
        .alert(
            "Set Working Folder",
            isPresented: Binding(
                get: { pendingSelection != nil },
                set: { if !$0 { pendingSelection = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingSelection = nil }
            Button("Set Here") {
                guard let entry = pendingSelection else { return }
                pendingSelection = nil
                Task {
                    let error = await store.setWorkdir(entry.absolutePath, for: agentID)
                    if let error {
                        settingNotice = error
                    } else {
                        onSet(entry.absolutePath)
                        dismiss()
                    }
                }
            }
        } message: {
            Text(verbatim: L("Workdir set alert message", pendingSelection?.absolutePath ?? ""))
        }
    }

    /// 单行目录项：名称 + 徽章（git / 软链 / 不可读置灰）。
    private func rowLabel(_ entry: BrowseEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isUnreadable ? "folder.badge.questionmark" : "folder.fill")
                .foregroundStyle(entry.isUnreadable ? Color.secondary : Color.blue)
                .font(.body)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                // 目录名是主机上的数据，不翻译。
                Text(verbatim: entry.name)
                    .font(.callout)
                    .foregroundStyle(entry.isUnreadable ? .secondary : .primary)
                if entry.isSymlink == true {
                    Text("Symbolic link")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if entry.isGit {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if entry.isUnreadable {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
