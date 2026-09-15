import Foundation

/// 环境检测与 AI CLI 安装（设置页「环境与 CLI」）。
///
/// 与 Windows 端 `env_setup.rs` **契约对齐**（结构体字段名/camelCase 逐字一致、
/// 任务 ID 与事件名一致），实现按 macOS 的官方通道重写：
/// - 包管理：`nvm`（官方 install.sh）+ `npm -g` / `pip`，**不用** winget/UAC；
/// - 命令解释器：`/bin/zsh -lc`，并把 `~/.nvm/nvm.sh` 显式 source 进来
///   （`zsh -lc` 只读 `.zprofile`，而 nvm 的安装脚本通常写 `.zshrc`，
///   靠显式 source 才稳定）；
/// - 全部子进程走 `PATH` 注入（`SystemCommand.conventionalSearchPaths()`），
///   不依赖 App 自己被 launchd 继承到的 PATH。
///
/// 进度经 `DesktopEventBus` 的 `env-setup-log` / `env-setup-done` 事件流给 UI，
/// 与 Windows 端 `env-setup-log` / `env-setup-done` 同名同载荷。
public enum EnvironmentSetup {

    /// 使用智能体的 Node 基线（Claude Code 的 npm 路线要求）。
    public static let minNodeMajor = 22
    /// nvm 安装脚本的版本（官方 README 要求固定版本而不是 master）。
    public static let nvmInstallVersion = "v0.40.7"
    private static let nodeDistIndexURL = "https://nodejs.org/dist/index.json"

    // MARK: - 契约结构

    public struct ToolStatus: Codable {
        public var installed: Bool
        public var version: String?
        public var path: String?
    }

    public struct NodeStatus: Codable {
        public var installed: Bool
        public var version: String?
        public var path: String?
        public var major: Int?
        /// major >= minNodeMajor
        public var compatible: Bool
        /// "nvm" | "system"
        public var source: String?
    }

    public struct NvmStatus: Codable {
        public var installed: Bool
        public var version: String?
        public var path: String?
        public var root: String?
    }

    /// 一种官方安装方式。`blocked` 非空 = 当前环境不满足前置条件：
    /// "node" | "node-version" | "python"。
    public struct InstallMethod: Codable {
        public var id: String
        public var needsNode: Bool
        public var minNodeMajor: Int
        public var needsPython: Bool
        public var blocked: String?
        public var display: String
        public var recommended: Bool
    }

    public struct AgentCliStatus: Codable {
        public var id: String
        public var name: String
        public var installed: Bool
        public var version: String?
        public var path: String?
        public var methods: [InstallMethod]
    }

    public struct EnvironmentStatus: Codable {
        public var node: NodeStatus
        public var npm: ToolStatus
        public var nvm: NvmStatus
        public var python: ToolStatus
        public var agents: [AgentCliStatus]
    }

    /// 本机已安装的一个 Node 版本（nvm 管理 / Homebrew / 系统）。
    public struct NodeInstallOption: Codable, Equatable {
        /// 不带 v 前缀，如 "22.12.0"。
        public var version: String
        public var major: Int?
        /// node 所在 bin 目录（nvm 条目）或 node 可执行文件全路径（其它来源）。
        public var path: String
        /// "nvm" | "homebrew" | "system"
        public var source: String
        /// 是否为 nvm default 别名指向的版本（新开终端即用它）。
        public var isDefault: Bool
        /// 是否为当前探测到的激活版本。
        public var isActive: Bool
        public var compatible: Bool

        public init(
            version: String, major: Int?, path: String, source: String,
            isDefault: Bool, isActive: Bool, compatible: Bool
        ) {
            self.version = version
            self.major = major
            self.path = path
            self.source = source
            self.isDefault = isDefault
            self.isActive = isActive
            self.compatible = compatible
        }
    }

    public struct NodeVersionOption: Codable {
        public var version: String
        public var major: Int?
        public var lts: Bool
        public var ltsName: String?
        public var recommended: Bool
    }

    // MARK: - 检测

    /// 全量检测。会 spawn 若干子进程（约 1-2s），**不要在主线程调用**。
    public static func check() -> EnvironmentStatus {
        let probe = probeEnvironment()

        let nodePath = probe["NODE_PATH"]
        let nodeVersion = probe["NODE_VER"]
        let major = nodeVersion.flatMap(nodeMajor(from:))
        let source: String? = {
            guard let nodePath else { return nil }
            return nodePath.contains("/.nvm/") ? "nvm" : "system"
        }()
        let node = NodeStatus(
            installed: nodePath != nil,
            version: nodeVersion,
            path: nodePath,
            major: major,
            compatible: (major ?? 0) >= minNodeMajor,
            source: source
        )

        let npm = ToolStatus(
            installed: probe["NPM_PATH"] != nil,
            version: probe["NPM_VER"],
            path: probe["NPM_PATH"]
        )
        let nvmRoot = probe["NVM_DIR"]
        let nvm = NvmStatus(
            installed: probe["NVM_VER"] != nil,
            version: probe["NVM_VER"],
            path: probe["NVM_PATH"],
            root: nvmRoot
        )
        let python = ToolStatus(
            installed: probe["PY_PATH"] != nil,
            version: probe["PY_VER"],
            path: probe["PY_PATH"]
        )

        let detected = AgentDiscovery.shared.discover(force: true)
        let agents = AgentDiscovery.catalog.map { definition -> AgentCliStatus in
            let hit = detected.first { $0.id == definition.id }
            return AgentCliStatus(
                id: definition.id,
                name: definition.name,
                installed: hit?.installed ?? false,
                version: hit?.version,
                path: hit?.path,
                methods: installMethods(
                    agentID: definition.id,
                    nodeMajor: major,
                    pythonInstalled: python.installed
                )
            )
        }

        return EnvironmentStatus(node: node, npm: npm, nvm: nvm, python: python, agents: agents)
    }

    // MARK: - 本机已装 Node 版本（清单 + 切换）

    /// 纯函数：解析 nvm 版本目录名（"v22.12.0"）→ 可比较三元组；非法返回 nil。
    static func nodeVersionComponents(_ raw: String) -> (major: Int, minor: Int, patch: Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" })
        let parts = trimmed.split(separator: ".").map { String($0) }
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else {
            return nil
        }
        return (major, minor, patch)
    }

    /// 纯函数：nvm default 别名文件内容 → 纯数字版本（"22.12.0"）。
    /// 复合别名（如 `lts/hydrogen`、`iojs`）返回 nil —— 它们由 shell 内的
    /// `nvm use default` 解析，PATH 排序无法静态处理。
    static func sanitizedDefaultAlias(_ raw: String?) -> String? {
        guard var alias = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !alias.isEmpty else { return nil }
        if alias.hasPrefix("v") { alias.removeFirst() }
        guard nodeVersionComponents(alias) != nil else { return nil }
        return alias
    }

    /// 读取 `~/.nvm/alias/default`（缺文件 = 无 default 别名）。
    static func readNvmDefaultAlias(nvmDir: String) -> String? {
        let url = URL(fileURLWithPath: "\(nvmDir)/alias/default")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return sanitizedDefaultAlias(raw)
    }

    /// 枚举本机全部 Node 版本（nvm 管理的 + Homebrew / 系统的）。
    /// `activeNodePath` = 探测到的激活 node 可执行文件路径（用于标 isActive）。
    public static func installedNodeVersions(activeNodePath: String?) -> [NodeInstallOption] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let nvmDir = "\(home)/.nvm"
        let versionsDir = "\(nvmDir)/versions/node"
        let defaultAlias = readNvmDefaultAlias(nvmDir: nvmDir)
        // 激活 node 所属的 bin 目录（前缀匹配 isActive 用）
        let activeBinDir = activeNodePath.map { path -> String in
            (path as NSString).deletingLastPathComponent
        }

        var options: [NodeInstallOption] = []
        if let entries = try? fm.contentsOfDirectory(atPath: versionsDir) {
            // (major, minor, patch, 目录名)
            var parsed: [(Int, Int, Int, String)] = []
            for name in entries {
                if let c = nodeVersionComponents(name) {
                    parsed.append((c.major, c.minor, c.patch, name))
                }
            }
            // 降序：新版本在前（与 nvm ls 观感一致）
            let sorted = parsed.sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.2 > rhs.2
            }
            for item in sorted {
                let version = String(item.3.drop(while: { $0 == "v" }))
                let binDir = "\(versionsDir)/\(item.3)/bin"
                guard fm.fileExists(atPath: "\(binDir)/node") else { continue }
                options.append(NodeInstallOption(
                    version: version,
                    major: item.0,
                    path: binDir,
                    source: "nvm",
                    isDefault: version == defaultAlias,
                    isActive: activeBinDir == binDir,
                    compatible: item.0 >= minNodeMajor
                ))
            }
        }

        // 非 nvm 来源：Homebrew / 系统前缀（不在 nvm 目录下才算独立条目）
        let extras: [(source: String, nodePath: String)] = [
            ("homebrew", "/opt/homebrew/bin/node"),
            ("homebrew", "/usr/local/bin/node"),
            ("system", "/usr/bin/node"),
        ]
        for extra in extras {
            guard fm.fileExists(atPath: extra.nodePath) else { continue }
            let binDir = (extra.nodePath as NSString).deletingLastPathComponent
            if activeBinDir == binDir {
                // 激活中的那个已在 nvm 扫描里覆盖（若属 nvm）；这里只收非 nvm 的
                let version = activeNodePath.flatMap { probeNodeVersion(nodePath: $0) }
                options.append(NodeInstallOption(
                    version: version ?? "unknown",
                    major: version.flatMap(nodeMajor(from:)),
                    path: binDir,
                    source: extra.source,
                    isDefault: false,
                    isActive: true,
                    compatible: (version.flatMap(nodeMajor(from:)) ?? 0) >= minNodeMajor
                ))
            }
        }

        // 激活中的条目浮到最前，其余按版本降序
        return options.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return compareVersions($0.version, $1.version) > 0
        }
    }

    /// 直接对指定 node 路径跑 `--version`（仅用于非 nvm 来源的版本标注）。
    private static func probeNodeVersion(nodePath: String) -> String? {
        guard let result = SystemCommand.run(
            executablePath: nodePath,
            arguments: ["--version"],
            timeoutSeconds: 5
        ) else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 切换 nvm default（**用户主动触发**；仅 nvm 管理的版本可切换）。
    /// 等价于用户在终端执行 `nvm alias default <v> && nvm use <v>`：
    /// 无 sudo、不改 shell 配置、日志走 envSetupLog 事件（设置→环境 可见）。
    @discardableResult
    public static func switchNodeDefault(version: String) -> Bool {
        let target = version.hasPrefix("v") ? version : "v\(version)"
        return runStreaming(
            taskID: "node-switch",
            script: "nvm alias default \(target) && nvm use \(target)",
            timeoutSeconds: 60
        )
    }

    /// 可安装的 Node 版本：nodejs.org dist index 按大版本聚合（每大版本取最新），
    /// 离线回落为 nvm 别名 `lts` / `latest`。
    public static func fetchNodeVersions() -> [NodeVersionOption] {
        guard let data = fetchNodeDistIndex(),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return fallbackVersions()
        }

        // 每个大版本保留**最新**版本（dist index 本身按版本倒序）。
        // `lts` 字段是 false（非 LTS）或 LTS 代号字符串。
        var bestByMajor: [Int: (version: String, ltsName: String?)] = [:]
        for item in raw {
            guard let version = item["version"] as? String,
                  let major = nodeMajor(from: version) else { continue }
            // 已记录过该大版本 → 说明已拿到更新的一条，跳过。
            guard bestByMajor[major] == nil else { continue }
            let ltsName = item["lts"] as? String
            bestByMajor[major] = (version, ltsName)
        }

        let sorted = bestByMajor
            .sorted { $0.key > $1.key }
            .prefix(8)
            .map { major, entry -> NodeVersionOption in
                NodeVersionOption(
                    version: entry.version.trimmingCharacters(in: CharacterSet(charactersIn: "v")),
                    major: major,
                    lts: entry.ltsName != nil,
                    ltsName: entry.ltsName,
                    recommended: false
                )
            }

        var options = Array(sorted)
        // 推荐 = 最新 LTS；没有 LTS 就取最靠前的一条。
        if let ltsIndex = options.firstIndex(where: { $0.lts }) {
            options[ltsIndex].recommended = true
        } else if !options.isEmpty {
            options[0].recommended = true
        }
        return options.isEmpty ? fallbackVersions() : options
    }

    private static func fallbackVersions() -> [NodeVersionOption] {
        [
            NodeVersionOption(version: "lts", major: nil, lts: true, ltsName: nil, recommended: true),
            NodeVersionOption(version: "latest", major: nil, lts: false, ltsName: nil, recommended: false)
        ]
    }

    // MARK: - 安装方式表

    /// 各 Agent 的官方安装方式。`blocked` 按**当前**环境即时计算
    /// （与 Windows 端 `install_methods_for` 同构，命令换成 macOS 官方通道）。
    static func installMethods(agentID: String, nodeMajor: Int?, pythonInstalled: Bool) -> [InstallMethod] {
        let raw: [(id: String, needsNode: Bool, minNodeMajor: Int, needsPython: Bool, display: String, recommended: Bool)]
        switch agentID {
        case "claude-code":
            raw = [
                ("native", false, 0, false, "curl -fsSL https://claude.ai/install.sh | bash", true),
                ("npm", true, 22, false, "npm install -g @anthropic-ai/claude-code", false)
            ]
        case "opencode":
            raw = [("npm", true, 16, false, "npm install -g opencode-ai", true)]
        case "codex":
            raw = [("npm", true, 16, false, "npm install -g @openai/codex", true)]
        case "pi":
            // 与 Windows `env_setup::install_methods_for` 的 "pi" 分支对齐
            // （同为 npm 全局包，Node 主版本要求一致）。
            raw = [("npm", true, 20, false, "npm install -g @earendil-works/pi-coding-agent", true)]
        default:
            raw = []
        }
        return raw.map { item in
            InstallMethod(
                id: item.id,
                needsNode: item.needsNode,
                minNodeMajor: item.minNodeMajor,
                needsPython: item.needsPython,
                blocked: blockedReason(
                    needsNode: item.needsNode,
                    minNodeMajor: item.minNodeMajor,
                    nodeMajor: nodeMajor,
                    needsPython: item.needsPython,
                    pythonInstalled: pythonInstalled
                ),
                display: item.display,
                recommended: item.recommended
            )
        }
    }

    /// 前置校验（与检测、执行两端共用同一套规则）。
    static func blockedReason(
        needsNode: Bool,
        minNodeMajor: Int,
        nodeMajor: Int?,
        needsPython: Bool,
        pythonInstalled: Bool
    ) -> String? {
        if needsNode {
            guard let nodeMajor else { return "node" }
            if nodeMajor < minNodeMajor { return "node-version" }
        }
        if needsPython && !pythonInstalled { return "python" }
        return nil
    }

    // MARK: - 安装任务（异步 + 流式日志）

    /// 执行一个安装任务。任务 ID 与 Windows 端一致：
    /// `"nvm"` / `"node"` / `"cli:<agentId>"` / `"cli-upd:<agentId>"`。
    public static func runTask(taskID: String, script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = runStreaming(taskID: taskID, script: script)
            DesktopEventBus.shared.post(.envSetupDone, payload: [
                "task": taskID,
                "ok": ok,
                "error": ok ? "" : "exit code != 0"
            ])
        }
    }

    public static func installNvm(taskID: String = "nvm") {
        runTask(
            taskID: taskID,
            script: "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/\(nvmInstallVersion)/install.sh | bash"
        )
    }

    public static func installNode(version: String, taskID: String = "node") {
        // 别名要转成 nvm 认识的写法：`lts` → `--lts`，`latest` → `node`。
        let target: String
        switch version {
        case "lts": target = "--lts"
        case "latest": target = "node"
        default: target = version
        }
        runTask(
            taskID: taskID,
            script: "nvm install \(target) && nvm alias default \(target) && node --version"
        )
    }

    public static func installAgentCli(agentID: String, methodID: String) -> Bool {
        guard let script = installScript(agentID: agentID, methodID: methodID) else { return false }
        runTask(taskID: "cli:\(agentID)", script: script)
        return true
    }

    public static func updateAgentCli(agentID: String) -> Bool {
        guard let script = updateScript(agentID: agentID) else { return false }
        runTask(taskID: "cli-upd:\(agentID)", script: script)
        return true
    }

    private static func installScript(agentID: String, methodID: String) -> String? {
        switch (agentID, methodID) {
        case ("claude-code", "native"): return "curl -fsSL https://claude.ai/install.sh | bash"
        case ("claude-code", "npm"): return "npm install -g @anthropic-ai/claude-code"
        case ("opencode", "npm"): return "npm install -g opencode-ai"
        case ("codex", "npm"): return "npm install -g @openai/codex"
        case ("pi", "npm"): return "npm install -g @earendil-works/pi-coding-agent"
        default: return nil
        }
    }

    private static func updateScript(agentID: String) -> String? {
        switch agentID {
        case "claude-code": return "claude update"
        case "opencode": return "npm install -g opencode-ai@latest"
        case "codex": return "npm install -g @openai/codex@latest"
        case "pi": return "npm install -g @earendil-works/pi-coding-agent@latest"
        default: return nil
        }
    }

    // MARK: - Shell

    /// 脚本前置：把 nvm 显式载入（`zsh -lc` 不会读 `.zshrc`）。
    private static func shellScript(_ command: String) -> String {
        """
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
        \(command)
        """
    }

    /// 一次探测拿到全部工具状态（合并成一次子进程，避免逐个 spawn 的 1-2s 开销）。
    private static func probeEnvironment() -> [String: String] {
        let script = """
        emit() { printf '%s=%s\\n' "$1" "$2"; }
        # 🚨 与用户终端对齐：nvm 存在时激活 default 别名的版本，否则 PATH 里
        # 无序的 nvm 版本目录会命中任意一个旧版本（实测把 22.12.0 判成 20.15.0）。
        nvm use --silent default >/dev/null 2>&1 || true
        emit NODE_PATH "$(command -v node 2>/dev/null)"
        emit NODE_VER "$(node --version 2>/dev/null)"
        emit NPM_PATH "$(command -v npm 2>/dev/null)"
        emit NPM_VER "$(npm --version 2>/dev/null)"
        emit NVM_PATH "$(command -v nvm 2>/dev/null)"
        emit NVM_VER "$(nvm --version 2>/dev/null)"
        emit NVM_DIR "${NVM_DIR:-$HOME/.nvm}"
        emit PY_PATH "$(command -v python3 2>/dev/null)"
        emit PY_VER "$(python3 --version 2>/dev/null)"
        """
        guard let result = SystemCommand.run(
            executablePath: "/bin/zsh",
            arguments: ["-lc", shellScript(script)],
            timeoutSeconds: 25,
            additionalPATHEntries: SystemCommand.conventionalSearchPaths()
        ) else { return [:] }

        var out: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { out[key] = value }
        }
        return out
    }

    /// 流式执行：逐行把输出推给 UI，返回是否成功（exit code == 0）。
    private static func runStreaming(taskID: String, script: String, timeoutSeconds: TimeInterval = 900) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", shellScript(script)]

        var environment = ProcessInfo.processInfo.environment
        let additions = SystemCommand.conventionalSearchPaths().joined(separator: ":")
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":" + additions
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lock = NSLock()
        var buffer = ""

        func flushLines(force: Bool) {
            lock.lock()
            var lines: [String] = []
            while let idx = buffer.firstIndex(of: "\n") {
                lines.append(String(buffer[buffer.startIndex..<idx]))
                buffer = String(buffer[buffer.index(after: idx)...])
            }
            if force, !buffer.isEmpty {
                lines.append(buffer)
                buffer = ""
            }
            lock.unlock()
            for line in lines {
                DesktopEventBus.shared.post(.envSetupLog, payload: ["task": taskID, "line": line])
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            buffer += String(decoding: data, as: UTF8.self)
            lock.unlock()
            flushLines(force: false)
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty {
                lock.lock()
                buffer += String(decoding: rest, as: UTF8.self)
                lock.unlock()
            }
            flushLines(force: true)
            done.signal()
        }

        do {
            try process.run()
        } catch {
            DesktopEventBus.shared.post(.envSetupLog, payload: [
                "task": taskID,
                "line": "✗ failed to start: \(error.localizedDescription)"
            ])
            return false
        }

        if done.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
            DesktopEventBus.shared.post(.envSetupLog, payload: ["task": taskID, "line": "✗ timed out"])
            return false
        }
        return process.terminationStatus == 0
    }

    // MARK: - 杂项

    private static func fetchNodeDistIndex() -> Data? {
        guard let url = URL(string: nodeDistIndexURL) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return result
    }

    /// `"v22.14.0"` → `22`。
    static func nodeMajor(from version: String) -> Int? {
        let digits = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" })
            .prefix(while: { $0.isNumber })
        return Int(digits)
    }

    /// 比较两个 `vX.Y.Z` 形式的版本号（仅用于同大版本内取最新）。
    private static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        func parts(_ raw: String) -> [Int] {
            raw.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }
        let a = parts(lhs), b = parts(rhs)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}
