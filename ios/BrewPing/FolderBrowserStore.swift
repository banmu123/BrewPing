import Foundation

// MARK: - 接口数据结构（与 Windows 端 folder_browser.rs 的 JSON 契约逐字段对齐）

/// `GET /api/folders/roots` 的响应。
struct BrowseRoots: Decodable, Equatable {
    /// Windows 端是 `"windows"`（Rust 的 `std::env::consts::OS`），Mac 端是 `"macos"`。
    /// **不要硬编码 `"win32"`** —— Lody 用 Node 的 process.platform 才是 win32。
    let platform: String?
    let pathSeparator: String?
    let homeDir: String?
    let drives: [String]?
}

/// `GET /api/folders` 里的一项（只有目录，文件已被服务端过滤）。
struct BrowseEntry: Decodable, Identifiable, Equatable {
    let name: String
    let absolutePath: String
    let isSymlink: Bool?
    let hidden: Bool?
    let hints: Hints?
    /// 目前只有 `"unreadable"`：目录不可读 —— 仍然列出，由 UI 置灰不可点。
    let error: String?

    struct Hints: Decodable, Equatable {
        let git: Bool?
    }

    var id: String { absolutePath }
    var isUnreadable: Bool { error == "unreadable" }
    var isGit: Bool { hints?.git == true }
}

/// `GET /api/folders` 的响应。
struct BrowseDirectoryResult: Decodable, Equatable {
    let path: String
    let parentPath: String?
    let entries: [BrowseEntry]
    let truncated: Bool
    /// 仅 truncated 为真时出现；就是 offset 的字符串形式，客户端只回传不解析。
    let nextCursor: String?
}

// MARK: - Store

/// 主机目录浏览的状态机（方案 §4.10 的 5 态）：
/// `loadingRoots` → `browsing`（正常浏览中）/ `empty` / `permissionDenied` / `failed`。
///
/// 这是**服务端驱动的自绘列表** —— 绝不能用 `.fileImporter`，
/// 那浏览的是 iPhone / iCloud 的文件系统，与 Windows 主机毫无关系。
@MainActor
final class FolderBrowserStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loadingRoots
        case browsing
        /// 目录存在但一个子目录都没有（不算错误）。
        case empty
        case permissionDenied
        /// 其它失败；`failedMessage` 是用户可读的一句话。
        case failed(String)
    }

    /// 当前浏览的绝对路径（服务端规范化后的）。
    @Published private(set) var currentPath: String = ""
    /// 面包屑可用的父目录；盘符根（`C:\`）为 nil。
    @Published private(set) var parentPath: String?
    @Published private(set) var entries: [BrowseEntry] = []
    @Published private(set) var phase: Phase = .idle
    /// roots 请求拿到的起始信息；nil = 主机不支持（404），入口应隐藏而非报错。
    @Published private(set) var roots: BrowseRoots?
    @Published private(set) var isLoadingPage = false
    /// 是否还有下一页（对齐服务端 `truncated` + `nextCursor`）。
    @Published private(set) var canLoadMore = false

    /// 手动输入路径跳转的文本框内容（浏览页顶部）。
    @Published var pathInput: String = ""

    /// 是否显示隐藏目录（服务端 `hidden` 参数）。切换后从头重拉当前目录。
    @Published var showsHidden = false {
        didSet {
            guard oldValue != showsHidden, !currentPath.isEmpty else { return }
            Task { await browse(currentPath, showHidden: showsHidden) }
        }
    }

    private var device: ManagedDevice?
    private var nextCursor: String?

    /// 主机是否支持目录浏览（roots 拿不到 404 时为 false）。
    var isSupported: Bool { roots != nil }

    var pathSeparator: String { roots?.pathSeparator ?? "\\" }

    /// 主机全部盘符（仅 Windows 有；作为浏览页的「此电脑」快捷跳转区）。
    var driveRoots: [String] { roots?.drives ?? [] }

    // MARK: 根列表

    /// 打开浏览页的第一步：拿 roots（home + 盘符），随后自动落在 home。
    func loadRoots(for device: ManagedDevice?) async {
        self.device = device
        phase = .loadingRoots
        entries = []
        roots = nil

        guard let device else {
            phase = .failed(L("No Mac connected. Add a device first."))
            return
        }

        guard let request = BrewPingHTTP.request(
            device: device,
            path: "/api/folders/roots",
            timeout: 10
        ) else {
            phase = .failed(L("Can't reach the host."))
            return
        }

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if BrewPingHTTP.isUnauthorized(response) {
                // 未配对走界面上的统一提示，这里标记成失败但用配对文案。
                phase = .failed(L("Pair with this host first."))
                return
            }
            // 404 / 501 = 主机没实现目录浏览（老版本桌面端）。不是错误，入口该隐藏。
            if statusCode == 404 || statusCode == 501 {
                phase = .failed(L("This host doesn't support folder browsing. Update the desktop app."))
                return
            }
            guard statusCode == 200 else {
                phase = .failed(L("Can't load folders: %@", "HTTP \(statusCode)"))
                return
            }

            let decoded = try JSONDecoder().decode(BrowseRoots.self, from: data)
            roots = decoded
            // homeDir 理论上必有（服务端读 home 失败时才缺）；缺了退回第一个盘符。
            if let home = decoded.homeDir {
                await browse(home, showHidden: showsHidden)
            } else if let firstDrive = decoded.drives?.first {
                await browse(firstDrive, showHidden: showsHidden)
            } else {
                phase = .failed(L("Can't load folders: %@", "no home directory"))
            }
        } catch {
            phase = .failed(Self.failureMessage(for: error))
            BrewPingLog.net.error("Load folder roots failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: 浏览

    /// 浏览某个目录（从头开始，不带游标）。
    func browse(_ path: String, showHidden: Bool) async {
        guard let device else { return }
        phase = .browsing
        isLoadingPage = true
        defer { isLoadingPage = false }

        guard let request = BrewPingHTTP.request(
            device: device,
            path: "/api/folders",
            queryItems: [
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "hidden", value: showHidden ? "1" : "0"),
            ],
            timeout: 10
        ) else {
            phase = .failed(L("Can't reach the host."))
            return
        }

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if BrewPingHTTP.isUnauthorized(response) {
                phase = .failed(L("Pair with this host first."))
                return
            }
            guard statusCode == 200 else {
                // 服务端错误体是 JSON：{"success":false,"error":"unc-not-allowed"|...}
                let serverCode = Self.serverErrorCode(from: data)
                switch serverCode {
                case "permission-denied":
                    phase = .permissionDenied
                case "unc-not-allowed":
                    phase = .failed(L("Network shares (\\\\server\\share) aren't allowed."))
                case "path-outside-allowlist":
                    phase = .failed(L("This path is outside the allowed roots."))
                default:
                    phase = .failed(Self.failureMessage(for: nil, status: statusCode))
                }
                return
            }

            let decoded = try JSONDecoder().decode(BrowseDirectoryResult.self, from: data)
            currentPath = decoded.path
            pathInput = decoded.path
            parentPath = decoded.parentPath
            nextCursor = decoded.nextCursor
            canLoadMore = decoded.truncated
            entries = decoded.entries
            phase = decoded.entries.isEmpty ? .empty : .browsing
        } catch {
            phase = .failed(Self.failureMessage(for: error))
            BrewPingLog.net.error("Browse \(path, privacy: .private) failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// 「加载更多」：用服务端回传的 nextCursor（offset 字符串）取下一页并追加。
    func loadMore() async {
        guard canLoadMore, let cursor = nextCursor, !isLoadingPage, !currentPath.isEmpty else { return }
        guard let device else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        guard let request = BrewPingHTTP.request(
            device: device,
            path: "/api/folders",
            queryItems: [
                URLQueryItem(name: "path", value: currentPath),
                URLQueryItem(name: "hidden", value: showsHidden ? "1" : "0"),
                URLQueryItem(name: "cursor", value: cursor),
            ],
            timeout: 10
        ) else { return }

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(BrowseDirectoryResult.self, from: data)
            nextCursor = decoded.nextCursor
            canLoadMore = decoded.truncated
            // 追加去重（服务端排序稳定，理论上不会重复，防御性去重）
            var seen = Set(entries.map(\.absolutePath))
            for entry in decoded.entries where !seen.contains(entry.absolutePath) {
                seen.insert(entry.absolutePath)
                entries.append(entry)
            }
        } catch {
            BrewPingLog.net.error("Load more folders failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// 进入子目录。
    func enter(_ entry: BrowseEntry) async {
        guard !entry.isUnreadable else { return }
        await browse(entry.absolutePath, showHidden: showsHidden)
    }

    /// 上一级；盘符根没有父目录时不动。
    func goUp() async {
        guard let parentPath else { return }
        await browse(parentPath, showHidden: showsHidden)
    }

    /// 手动输入路径跳转（方案 §1.1 第 2 条：Enter 提交）。
    func submitPathInput() async {
        let trimmed = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await browse(trimmed, showHidden: showsHidden)
    }

    // MARK: 设定工作目录

    /// 把某个目录设为 agent 的工作目录。返回 nil = 成功；否则是错误文案。
    func setWorkdir(_ path: String, for agentID: String) async -> String? {
        guard let device else {
            return L("No Mac connected. Add a device first.")
        }
        guard var request = BrewPingHTTP.request(
            device: device,
            path: "/api/agents/workdir",
            method: "POST",
            timeout: 15
        ) else {
            return L("Can't reach the host.")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "agentId": agentID,
            "path": path
        ])

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if statusCode == 200, decoded?["success"] as? Bool == true {
                return nil
            }
            if let serverError = decoded?["error"] as? String {
                return Self.workdirErrorMessage(serverError)
            }
            return L("Can't set the folder: %@", "HTTP \(statusCode)")
        } catch {
            BrewPingLog.net.error("Set workdir failed: \(error.localizedDescription, privacy: .private)")
            return L("Can't set the folder: %@", error.localizedDescription)
        }
    }

    /// opencode 是 stub：服务端会拒绝，这里提前拦住避免一次注定失败的请求。
    static func supportsWorkdir(agentID: String) -> Bool {
        agentID != "opencode"
    }

    // MARK: 错误翻译

    private static func serverErrorCode(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["error"] as? String
    }

    /// 服务端错误码 → 用户可读文案（与方案 §3.5 的映射表一致）。
    private static func workdirErrorMessage(_ code: String) -> String {
        switch code {
        case "path-invalid":
            return L("That path doesn't exist or isn't a folder.")
        case "unc-not-allowed":
            return L("Network shares (\\\\server\\share) aren't allowed.")
        case "path-outside-allowlist":
            return L("This path is outside the allowed roots.")
        case "permission-denied":
            return L("No permission to read this folder.")
        case "unknown agent":
            return L("This host doesn't know that agent.")
        case let other where other.contains("does not support workdir"):
            return L("This agent doesn't support working folders yet.")
        default:
            return L("Can't set the folder: %@", code)
        }
    }

    private static func failureMessage(for error: Error?, status: Int? = nil) -> String {
        if let status {
            return L("Can't load folders: %@", "HTTP \(status)")
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return L("Can't load folders: %@", L("The host took too long to respond."))
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return L("Can't reach the host.")
            default:
                break
            }
        }
        if error is DecodingError {
            return L("This host doesn't support folder browsing. Update the desktop app.")
        }
        return L("Can't load folders: %@", error?.localizedDescription ?? "-")
    }
}
