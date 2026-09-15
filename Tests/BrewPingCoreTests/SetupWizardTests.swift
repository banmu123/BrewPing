import XCTest

@testable import BrewPingCore

// ─── Setup Wizard 核心层不变量（对齐 spec §20）────────────────────────────────
//
// 覆盖：Node 找到/缺失/过旧、npm 缺失、NVM 缺失、Agent 找到/缺失、
// 版本解析失败、持久化状态机、快照往返、AgentInstallInfo 表完整性。
//
// 说明：底层探测（EnvironmentSetup.probeEnvironment 的进程 spawn/超时）不在本层
// 测试范围 —— 它是既有模块，本任务约定不做重构；向导层的决策与持久化全部单测。

final class SetupWizardTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SetupState.resetForTesting()
    }

    override func tearDown() {
        SetupState.resetForTesting()
        super.tearDown()
    }

    // MARK: 造数

    private func makeStatus(
        nodeInstalled: Bool = true,
        nodeMajor: Int? = 24,
        nodeCompatible: Bool? = nil,
        installedAgents: [String] = []
    ) -> EnvironmentSetup.EnvironmentStatus {
        let compatible = nodeCompatible ?? (nodeInstalled && (nodeMajor ?? 0) >= EnvironmentSetup.minNodeMajor)
        let node = EnvironmentSetup.NodeStatus(
            installed: nodeInstalled,
            version: nodeInstalled ? "v\(nodeMajor ?? 0).1.0" : nil,
            path: nodeInstalled ? "/usr/local/bin/node" : nil,
            major: nodeMajor,
            compatible: compatible,
            source: nodeInstalled ? "system" : nil
        )
        let agents = AgentInstallInfo.table.keys.sorted().map { id in
            EnvironmentSetup.AgentCliStatus(
                id: id,
                name: id,
                installed: installedAgents.contains(id),
                version: installedAgents.contains(id) ? "1.0.0" : nil,
                path: installedAgents.contains(id) ? "/usr/local/bin/\(id)" : nil,
                methods: []
            )
        }
        return EnvironmentSetup.EnvironmentStatus(
            node: node,
            npm: EnvironmentSetup.ToolStatus(
                installed: nodeInstalled, version: nodeInstalled ? "10.9.1" : nil, path: nil
            ),
            nvm: EnvironmentSetup.NvmStatus(
                installed: false, version: nil, path: nil, root: nil
            ),
            python: EnvironmentSetup.ToolStatus(installed: false, version: nil, path: nil),
            agents: agents
        )
    }

    // MARK: 决策（SetupWizardModel.evaluate）

    func testNodeMissingGoesToNeedNode() {
        let status = makeStatus(nodeInstalled: false, installedAgents: [])
        XCTAssertEqual(SetupWizardModel.evaluate(status), .needNode)
    }

    func testNodeTooOldGoesToNeedNode() {
        let status = makeStatus(nodeInstalled: true, nodeMajor: 16, nodeCompatible: false, installedAgents: ["pi"])
        XCTAssertEqual(SetupWizardModel.evaluate(status), .needNode)
    }

    func testNodeOKWithoutAgentsGoesToNeedAgents() {
        let status = makeStatus(nodeInstalled: true, nodeMajor: 24, installedAgents: [])
        XCTAssertEqual(SetupWizardModel.evaluate(status), .needAgents)
    }

    func testNodeOKWithOneAgentIsReady() {
        let status = makeStatus(nodeInstalled: true, nodeMajor: 24, installedAgents: ["codex"])
        XCTAssertEqual(SetupWizardModel.evaluate(status), .ready)
    }

    // MARK: 版本解析失败（EnvironmentSetup.nodeMajor 的容错）

    func testVersionParseGarbageReturnsNil() {
        XCTAssertNil(EnvironmentSetup.nodeMajor(from: "not-a-version"))
        XCTAssertNil(EnvironmentSetup.nodeMajor(from: ""))
        XCTAssertNil(EnvironmentSetup.nodeMajor(from: "v"))
    }

    func testVersionParseValid() {
        XCTAssertEqual(EnvironmentSetup.nodeMajor(from: "v24.3.1"), 24)
        XCTAssertEqual(EnvironmentSetup.nodeMajor(from: "22.11.0"), 22)
    }

    // MARK: 持久化状态机（§1/§12/§13）

    func testFirstLaunchShowsWizard() {
        XCTAssertTrue(SetupState.shouldShowOnLaunch)
    }

    func testCompletedNeverShowsAgain() {
        SetupState.markCompleted()
        XCTAssertFalse(SetupState.shouldShowOnLaunch)
        XCTAssertTrue(SetupState.isCompleted)
    }

    func testSkippedNeverShowsAgainButIsNotCompleted() {
        SetupState.markSkipped()
        XCTAssertFalse(SetupState.shouldShowOnLaunch)
        XCTAssertFalse(SetupState.isCompleted)  // 横幅条件：未完成 → 显示轻量提示
    }

    // MARK: 快照（§13：存结果不存输出，无敏感信息）

    func testSnapshotRoundtrip() throws {
        let status = makeStatus(nodeInstalled: true, nodeMajor: 24, installedAgents: ["opencode", "pi"])
        SetupState.saveSnapshot(status)
        let snap = try XCTUnwrap(SetupState.snapshot)
        XCTAssertEqual(snap.nodeVersion, "v24.1.0")
        XCTAssertEqual(snap.nodePath, "/usr/local/bin/node")
        XCTAssertEqual(snap.npmVersion, "10.9.1")
        XCTAssertFalse(snap.nvmDetected)
        XCTAssertEqual(snap.installedAgents, ["opencode", "pi"])
    }

    func testSnapshotForMissingNodeStoresNoVersions() throws {
        SetupState.saveSnapshot(makeStatus(nodeInstalled: false, installedAgents: []))
        let snap = try XCTUnwrap(SetupState.snapshot)
        XCTAssertNil(snap.nodeVersion)
        XCTAssertNil(snap.nodePath)
        XCTAssertNil(snap.npmVersion)
        XCTAssertTrue(snap.installedAgents.isEmpty)
    }

    // MARK: AgentInstallInfo（§8：统一配置，不散落硬编码）

    func testInstallInfoCoversAllSupportedAgents() {
        let expected = ["claude-code", "codex", "opencode", "pi"]
        XCTAssertEqual(Set(AgentInstallInfo.table.keys), Set(expected))
        for (id, info) in AgentInstallInfo.table {
            XCTAssertEqual(info.id, id)
            XCTAssertFalse(info.name.isEmpty)
            XCTAssertEqual(info.documentationURL.scheme, "https")
        }
    }

    func testRecommendedCommandComesFromMethods() {
        let agent = EnvironmentSetup.AgentCliStatus(
            id: "claude-code",
            name: "Claude Code",
            installed: false,
            version: nil,
            path: nil,
            methods: [
                EnvironmentSetup.InstallMethod(
                    id: "native", needsNode: false, minNodeMajor: 0, needsPython: false,
                    blocked: nil, display: "curl -fsSL https://claude.ai/install.sh | bash",
                    recommended: true
                ),
                EnvironmentSetup.InstallMethod(
                    id: "npm", needsNode: true, minNodeMajor: 22, needsPython: false,
                    blocked: nil, display: "npm install -g @anthropic-ai/claude-code",
                    recommended: false
                ),
            ]
        )
        XCTAssertEqual(
            AgentInstallInfo.recommendedCommand(for: agent),
            "curl -fsSL https://claude.ai/install.sh | bash"
        )
    }

    func testRecommendedCommandNilWhenNoMethods() {
        let agent = EnvironmentSetup.AgentCliStatus(
            id: "x", name: "x", installed: false, version: nil, path: nil, methods: []
        )
        XCTAssertNil(AgentInstallInfo.recommendedCommand(for: agent))
    }
}

// MARK: - Node 版本清单 / 切换（多版本检测与 PATH 对齐）

final class NodeVersionListTests: XCTestCase {

    func testParseVersionDirNames() {
        XCTAssertEqual(EnvironmentSetup.nodeVersionComponents("v22.12.0")?.major, 22)
        XCTAssertEqual(EnvironmentSetup.nodeVersionComponents("v22.12.0")?.minor, 12)
        XCTAssertEqual(EnvironmentSetup.nodeVersionComponents("22.12.0")?.patch, 0)
        XCTAssertNil(EnvironmentSetup.nodeVersionComponents("iojs"))
        XCTAssertNil(EnvironmentSetup.nodeVersionComponents("v22"))
        XCTAssertNil(EnvironmentSetup.nodeVersionComponents(""))
    }

    func testSanitizeDefaultAlias() {
        XCTAssertEqual(EnvironmentSetup.sanitizedDefaultAlias("22.12.0\n"), "22.12.0")
        XCTAssertEqual(EnvironmentSetup.sanitizedDefaultAlias(" v22.12.0 "), "22.12.0")
        XCTAssertNil(EnvironmentSetup.sanitizedDefaultAlias("lts/hydrogen"))  // 复合别名交给 shell 解析
        XCTAssertNil(EnvironmentSetup.sanitizedDefaultAlias("iojs"))
        XCTAssertNil(EnvironmentSetup.sanitizedDefaultAlias(nil))
        XCTAssertNil(EnvironmentSetup.sanitizedDefaultAlias("  "))
    }

    func testOrderingPutsDefaultFirstThenDescending() {
        let ordered = SystemCommand.orderedNvmVersionDirs(
            contents: ["v14.16.0", "v22.12.0", "v20.15.0", "v18.20.0", "not-a-version"],
            defaultVersion: "22.12.0"
        )
        XCTAssertEqual(ordered, ["v22.12.0", "v20.15.0", "v18.20.0", "v14.16.0", "not-a-version"])
    }

    func testOrderingWithoutDefaultIsPureDescending() {
        let ordered = SystemCommand.orderedNvmVersionDirs(
            contents: ["v14.16.0", "v22.12.0", "v20.15.0"],
            defaultVersion: nil
        )
        XCTAssertEqual(ordered, ["v22.12.0", "v20.15.0", "v14.16.0"])
    }

    func testOrderingHandlesVAndPlainDefaultAlias() {
        let ordered = SystemCommand.orderedNvmVersionDirs(
            contents: ["v20.15.0", "v22.12.0"],
            defaultVersion: "v22.12.0"  // 别名文件带 v 前缀也能命中
        )
        XCTAssertEqual(ordered.first, "v22.12.0")
    }
}
