import Foundation

// ─── 桌面端文案表（与 Windows `src/i18n/locales.ts` 逐字对齐）───────────────
//
// ⚠️ 本文件由 `Sources/BrewPingwinDesktop/src/i18n/locales.ts` 机械转换而来：
//    key 集合、文案内容、`{name}` 插值占位符均与 Windows 端**完全一致**，
//    修改文案必须两端同批修改，否则同一台机器的两种桌面端会说出不同的话。
// 插值占位符 `{name}` 由 `DesktopStrings.t(_:params:)` 做 split/join 替换
//    （与 Windows 的 `s.split('{k}').join(v)` 等价）。

/// 全部文案 key（rawValue 与 locales.ts 的键逐字相同）。
public enum LKey: String, CaseIterable {
    case commonCopy = "common.copy"
    case commonCopied = "common.copied"
    case commonRefresh = "common.refresh"
    case commonClear = "common.clear"
    case commonCollapse = "common.collapse"
    case sideNewChat = "side.newChat"
    case sideFilterAll = "side.filterAll"
    case sideUnbound = "side.unbound"
    case sideByDir = "side.byDir"
    case sideFilterTooltip = "side.filterTooltip"
    case sideEmpty = "side.empty"
    case sideGroupEmpty = "side.groupEmpty"
    case sideUnboundTooltip = "side.unboundTooltip"
    case sideGroupTooltip = "side.groupTooltip"
    case sideArchived = "side.archived"
    case sideSettings = "side.settings"
    case sideSettingsTooltip = "side.settingsTooltip"
    case sideUntitled = "side.untitled"
    case sideMsgCount = "side.msgCount"
    case sideRestore = "side.restore"
    case sideDeleteForever = "side.deleteForever"
    case sideUnpin = "side.unpin"
    case sidePin = "side.pin"
    case sideArchive = "side.archive"
    case topNewChat = "top.newChat"
    case topOnline = "top.online"
    case topStarting = "top.starting"
    case topOffline = "top.offline"
    case chatPlaceholder = "chat.placeholder"
    case chatSend = "chat.send"
    case chatSendTitle = "chat.sendTitle"
    case chatMe = "chat.me"
    case chatThinking = "chat.thinking"
    case chatStandby = "chat.standby"
    case chatLandingHint = "chat.landingHint"
    case chatEmptyTitle = "chat.emptyTitle"
    case barSwitchAgent = "bar.switchAgent"
    case barPickModel = "bar.pickModel"
    case barFollowAgent = "bar.followAgent"
    case barApproval = "bar.approval"
    case barApprovalItem = "bar.approvalItem"
    case barStop = "bar.stop"
    case barTerminal = "bar.terminal"
    case barTerminalOf = "bar.terminalOf"
    case approvalSafe = "approval.safe"
    case approvalAskAll = "approval.askAll"
    case approvalAuto = "approval.auto"
    case wdHintDefault = "wd.hintDefault"
    case wdHintNew = "wd.hintNew"
    case wdHintBound = "wd.hintBound"
    case wdTitleUnset = "wd.titleUnset"
    case wdUnset = "wd.unset"
    case wdUnsetHint = "wd.unsetHint"
    case wdCurrent = "wd.current"
    case wdCurrentUnset = "wd.currentUnset"
    case wdClear = "wd.clear"
    case wdClearTitle = "wd.clearTitle"
    case wdHome = "wd.home"
    case wdRecent = "wd.recent"
    case wdManualPlaceholder = "wd.manualPlaceholder"
    case wdBindManual = "wd.bindManual"
    case wdParent = "wd.parent"
    case wdNoSubdirs = "wd.noSubdirs"
    case wdLoading = "wd.loading"
    case wdFooter = "wd.footer"
    case wdPickTitle = "wd.pickTitle"
    case setTitle = "set.title"
    case setBack = "set.back"
    case setMachine = "set.machine"
    case setDeviceName = "set.deviceName"
    case setDeviceId = "set.deviceId"
    case setLanAddr = "set.lanAddr"
    case setMdns = "set.mdns"
    case setMdnsOn = "set.mdnsOn"
    case setMdnsOff = "set.mdnsOff"
    case setPlatform = "set.platform"
    case setService = "set.service"
    case setLanHint = "set.lanHint"
    case setPairing = "set.pairing"
    case setExpiry = "set.expiry"
    case setScanHint = "set.scanHint"
    case setWaitingNet = "set.waitingNet"
    case setManualCode = "set.manualCode"
    case setShowCode = "set.showCode"
    case setCodeHint = "set.codeHint"
    case setNavGeneral = "set.navGeneral"
    case setNavMachine = "set.navMachine"
    case setNavEnvironment = "set.navEnvironment"
    case setNavPairing = "set.navPairing"
    case setClose = "set.close"
    case stateIdle = "state.idle"
    case stateStarting = "state.starting"
    case stateOnline = "state.online"
    case stateOffline = "state.offline"
    case winMinimize = "win.minimize"
    case winMaximize = "win.maximize"
    case winClose = "win.close"
    case langTitle = "lang.title"
    case langSystem = "lang.system"
    case langZh = "lang.zh"
    case langEn = "lang.en"
    case langCurrent = "lang.current"
    case envTitle = "env.title"
    case envRefresh = "env.refresh"
    case envChecking = "env.checking"
    case envNode = "env.node"
    case envNpm = "env.npm"
    case envNvm = "env.nvm"
    case envPython = "env.python"
    case envInstalled = "env.installed"
    case envNotInstalled = "env.notInstalled"
    case envNodeSourceNvm = "env.nodeSourceNvm"
    case envNodeSourceSystem = "env.nodeSourceSystem"
    case envNodeCompatible = "env.nodeCompatible"
    case envNodeTooOld = "env.nodeTooOld"
    case envNodeMinHint = "env.nodeMinHint"
    case envNodeOldHint = "env.nodeOldHint"
    case envNvmSection = "env.nvmSection"
    case envNvmHint = "env.nvmHint"
    case envInstallNvm = "env.installNvm"
    case envNodeSection = "env.nodeSection"
    case envPickVersion = "env.pickVersion"
    case envVersionLts = "env.versionLts"
    case envVersionCustom = "env.versionCustom"
    case envVersionCustomPlaceholder = "env.versionCustomPlaceholder"
    case envInstallNode = "env.installNode"
    case envInstalling = "env.installing"
    case envCliSection = "env.cliSection"
    case envCliHint = "env.cliHint"
    case envCliInstall = "env.cliInstall"
    case envCliMethodNative = "env.cliMethodNative"
    case envCliMethodNativeDesc = "env.cliMethodNativeDesc"
    case envCliMethodNpm = "env.cliMethodNpm"
    case envCliMethodNpmDesc = "env.cliMethodNpmDesc"
    case envCliMethodPip = "env.cliMethodPip"
    case envCliMethodPipDesc = "env.cliMethodPipDesc"
    case envBlockNode = "env.blockNode"
    case envBlockNodeVersion = "env.blockNodeVersion"
    case envBlockPython = "env.blockPython"
    case envLog = "env.log"
    case envDoneOk = "env.doneOk"
    case envDoneFail = "env.doneFail"
    case envVersionsError = "env.versionsError"
    case envTaskNvm = "env.taskNvm"
    case envTaskNode = "env.taskNode"
    case envTaskCli = "env.taskCli"
    case envAlreadyInstalled = "env.alreadyInstalled"
    case envUpdate = "env.update"
    case envUpdateTitle = "env.updateTitle"
}

public enum DesktopStrings {

    /// 中文词典（基准语言）。
    public static let zh: [LKey: String] = [
        .commonCopy: "复制",
        .commonCopied: "已复制",
        .commonRefresh: "刷新",
        .commonClear: "清空",
        .commonCollapse: "收起",
        .sideNewChat: "新对话",
        .sideFilterAll: "全部对话",
        .sideUnbound: "未绑定目录",
        .sideByDir: "按目录",
        .sideFilterTooltip: "按目录筛选对话",
        .sideEmpty: "还没有对话。发一条消息即自动创建。",
        .sideGroupEmpty: "该目录下暂无对话。可从右侧目录菜单重新选择。",
        .sideUnboundTooltip: "未绑定目录的对话（点击折叠/展开）",
        .sideGroupTooltip: "{path}（点击折叠/展开）",
        .sideArchived: "已归档",
        .sideSettings: "设置与配对",
        .sideSettingsTooltip: "机器信息 / 配对码",
        .sideUntitled: "（尚未命名）",
        .sideMsgCount: "{n} 条",
        .sideRestore: "恢复对话",
        .sideDeleteForever: "彻底删除",
        .sideUnpin: "取消置顶",
        .sidePin: "置顶",
        .sideArchive: "关闭并归档",
        .topNewChat: "新对话",
        .topOnline: "在线",
        .topStarting: "启动中…",
        .topOffline: "离线",
        .chatPlaceholder: "给 {agent} 发消息，或从手机 / 手表发送…",
        .chatSend: "发送",
        .chatSendTitle: "发送（Enter）",
        .chatMe: "我",
        .chatThinking: "{agent} 正在思考…",
        .chatStandby: "{agent} 待命中",
        .chatLandingHint: "在下方输入，或从 iPhone / Apple Watch 发送指令",
        .chatEmptyTitle: "空对话",
        .barSwitchAgent: "切换 Agent",
        .barPickModel: "选择模型",
        .barFollowAgent: "跟随 Agent 配置",
        .barApproval: "授权模式",
        .barApprovalItem: "授权 {label}",
        .barStop: "停止生成",
        .barTerminal: "终端输出",
        .barTerminalOf: "终端输出 · {agent}",
        .approvalSafe: "只拦截危险命令（默认）",
        .approvalAskAll: "每条命令都要确认",
        .approvalAuto: "全程免确认",
        .wdHintDefault: "对话与文件操作将作用于所选目录",
        .wdHintNew: "新对话将记录此目录（可另选或清除后不绑定）",
        .wdHintBound: "本对话绑定的工作目录；更改只影响当前对话",
        .wdTitleUnset: "未设置工作目录（使用 CLI 默认位置）",
        .wdUnset: "未设置工作目录",
        .wdUnsetHint: "（将使用 CLI 默认位置）",
        .wdCurrent: "当前：{path}",
        .wdCurrentUnset: "未设置（CLI 默认位置）",
        .wdClear: "清除",
        .wdClearTitle: "清除偏好，恢复 CLI 默认位置",
        .wdHome: "主目录",
        .wdRecent: "最近使用",
        .wdManualPlaceholder: "或直接输入目录路径，如 D:\\\\work\\\\project",
        .wdBindManual: "绑定输入的目录",
        .wdParent: "上一级",
        .wdNoSubdirs: "没有子目录",
        .wdLoading: "加载中…",
        .wdFooter: "点目录名进入，点右侧 ✓ 选定。后续对话与文件操作将作用于所选目录。",
        .wdPickTitle: "选定 {path} 为工作目录",
        .setTitle: "设置与配对",
        .setBack: "返回对话",
        .setMachine: "本机信息",
        .setDeviceName: "设备名",
        .setDeviceId: "设备 ID",
        .setLanAddr: "局域网地址",
        .setMdns: "mDNS 广播",
        .setMdnsOn: "运行中",
        .setMdnsOff: "未运行",
        .setPlatform: "平台 / 版本",
        .setService: "服务状态",
        .setLanHint: "iPhone / Apple Watch 通过同一局域网访问上面的地址；手机端 App 扫下方二维码即可配对。",
        .setPairing: "配对",
        .setExpiry: "过期时间 {time}",
        .setScanHint: "用 iPhone 上的 BrewPing 扫码",
        .setWaitingNet: "等待网络就绪…",
        .setManualCode: "也可以在 iPhone 的 BrewPing 里手动输入这个 6 位码。",
        .setShowCode: "显示配对码",
        .setCodeHint: "配对码只在需要时生成，10 分钟内有效且一次性。iPhone 用它换取长期访问令牌。",
        .setNavGeneral: "通用",
        .setNavMachine: "本机信息",
        .setNavEnvironment: "环境与 CLI",
        .setNavPairing: "配对",
        .setClose: "关闭",
        .stateIdle: "空闲",
        .stateStarting: "启动中",
        .stateOnline: "在线",
        .stateOffline: "离线",
        .winMinimize: "最小化",
        .winMaximize: "最大化 / 还原",
        .winClose: "关闭",
        .langTitle: "语言 / Language",
        .langSystem: "跟随系统",
        .langZh: "中文",
        .langEn: "English",
        .langCurrent: "当前：{name}",
        .envTitle: "环境与 AI CLI",
        .envRefresh: "重新检测",
        .envChecking: "检测中…",
        .envNode: "Node.js",
        .envNpm: "npm",
        .envNvm: "NVM",
        .envPython: "Python",
        .envInstalled: "已安装",
        .envNotInstalled: "未安装",
        .envNodeSourceNvm: "经 NVM",
        .envNodeSourceSystem: "系统安装",
        .envNodeCompatible: "版本兼容",
        .envNodeTooOld: "版本过旧",
        .envNodeMinHint: "使用智能体前必须先安装 Node.js（≥ {n}）。推荐通过 NVM 安装与管理版本。",
        .envNodeOldHint: "当前 Node {version} 低于推荐基线（≥ {n}），可在下方通过 NVM 安装新版本。",
        .envNvmSection: "第一步 · 安装 NVM",
        .envNvmHint: "NVM 用于安装并切换 Node 版本；安装时 Windows 可能弹出 UAC 授权窗口。",
        .envInstallNvm: "安装 NVM",
        .envNodeSection: "第二步 · 安装 Node.js（经 NVM）",
        .envPickVersion: "选择版本",
        .envVersionLts: "LTS",
        .envVersionCustom: "自定义版本",
        .envVersionCustomPlaceholder: "如 22.14.0",
        .envInstallNode: "通过 NVM 安装",
        .envInstalling: "安装中…",
        .envCliSection: "AI 智能体 CLI",
        .envCliHint: "已安装的 CLI 会自动出现在对话界面的 Agent 列表中。",
        .envCliInstall: "安装",
        .envCliMethodNative: "原生安装（官方推荐）",
        .envCliMethodNativeDesc: "无需 Node，支持自动更新",
        .envCliMethodNpm: "npm 全局安装",
        .envCliMethodNpmDesc: "需要 Node.js",
        .envCliMethodPip: "pip 官方安装器",
        .envCliMethodPipDesc: "需要 Python",
        .envBlockNode: "需要先安装 Node.js",
        .envBlockNodeVersion: "需要 Node ≥ {n}",
        .envBlockPython: "需要先安装 Python",
        .envLog: "安装日志",
        .envDoneOk: "安装完成",
        .envDoneFail: "安装失败",
        .envVersionsError: "版本列表获取失败，可直接输入版本号",
        .envTaskNvm: "NVM",
        .envTaskNode: "Node",
        .envTaskCli: "{name}",
        .envAlreadyInstalled: "已安装，无需重复操作",
        .envUpdate: "更新",
        .envUpdateTitle: "更新到最新版本（官方更新通道）",
    ]

    /// 英文词典（key 集合与中文严格一致）。
    public static let en: [LKey: String] = [
        .commonCopy: "Copy",
        .commonCopied: "Copied",
        .commonRefresh: "Refresh",
        .commonClear: "Clear",
        .commonCollapse: "Collapse",
        .sideNewChat: "New Chat",
        .sideFilterAll: "All Chats",
        .sideUnbound: "Unbound Directory",
        .sideByDir: "By directory",
        .sideFilterTooltip: "Filter chats by directory",
        .sideEmpty: "No chats yet. Send a message to create one.",
        .sideGroupEmpty: "No chats in this directory. Pick another from the menu above.",
        .sideUnboundTooltip: "Chats without a bound directory (click to collapse/expand)",
        .sideGroupTooltip: "{path} (click to collapse/expand)",
        .sideArchived: "Archived",
        .sideSettings: "Settings & Pairing",
        .sideSettingsTooltip: "Machine info / pairing code",
        .sideUntitled: "(untitled)",
        .sideMsgCount: "{n} msgs",
        .sideRestore: "Restore chat",
        .sideDeleteForever: "Delete permanently",
        .sideUnpin: "Unpin",
        .sidePin: "Pin",
        .sideArchive: "Close & archive",
        .topNewChat: "New Chat",
        .topOnline: "Online",
        .topStarting: "Starting…",
        .topOffline: "Offline",
        .chatPlaceholder: "Message {agent}, or send from phone / watch…",
        .chatSend: "Send",
        .chatSendTitle: "Send (Enter)",
        .chatMe: "Me",
        .chatThinking: "{agent} is thinking…",
        .chatStandby: "{agent} on standby",
        .chatLandingHint: "Type below, or send instructions from iPhone / Apple Watch",
        .chatEmptyTitle: "Empty chat",
        .barSwitchAgent: "Switch agent",
        .barPickModel: "Choose model",
        .barFollowAgent: "Follow agent config",
        .barApproval: "Approval mode",
        .barApprovalItem: "Approve {label}",
        .barStop: "Stop generating",
        .barTerminal: "Terminal output",
        .barTerminalOf: "Terminal · {agent}",
        .approvalSafe: "Only block dangerous commands (default)",
        .approvalAskAll: "Confirm every command",
        .approvalAuto: "No confirmations",
        .wdHintDefault: "Chats and file operations will use the selected directory",
        .wdHintNew: "New chat will record this directory (pick another or clear to unbind)",
        .wdHintBound: "Directory bound to this chat; changes affect only this chat",
        .wdTitleUnset: "No working directory set (CLI default location)",
        .wdUnset: "No working directory",
        .wdUnsetHint: "(CLI default location will be used)",
        .wdCurrent: "Current: {path}",
        .wdCurrentUnset: "Not set (CLI default location)",
        .wdClear: "Clear",
        .wdClearTitle: "Clear preference, back to CLI default location",
        .wdHome: "Home",
        .wdRecent: "Recent",
        .wdManualPlaceholder: "Or type a directory path, e.g. D:\\\\work\\\\project",
        .wdBindManual: "Bind typed directory",
        .wdParent: "Up one level",
        .wdNoSubdirs: "No subdirectories",
        .wdLoading: "Loading…",
        .wdFooter: "Click a name to enter, ✓ to select. Chats and file operations will use the selected directory.",
        .wdPickTitle: "Set {path} as working directory",
        .setTitle: "Settings & Pairing",
        .setBack: "Back to chat",
        .setMachine: "This Machine",
        .setDeviceName: "Device name",
        .setDeviceId: "Device ID",
        .setLanAddr: "LAN address",
        .setMdns: "mDNS",
        .setMdnsOn: "Running",
        .setMdnsOff: "Not running",
        .setPlatform: "Platform / version",
        .setService: "Service status",
        .setLanHint: "iPhone / Apple Watch reach the address above on the same LAN; scan the QR code below in the phone app to pair.",
        .setPairing: "Pairing",
        .setExpiry: "Expires at {time}",
        .setScanHint: "Scan with BrewPing on iPhone",
        .setWaitingNet: "Waiting for network…",
        .setManualCode: "You can also type this 6-digit code into BrewPing on iPhone.",
        .setShowCode: "Show pairing code",
        .setCodeHint: "The pairing code is generated on demand, valid for 10 minutes and single-use. iPhone exchanges it for a long-lived token.",
        .setNavGeneral: "General",
        .setNavMachine: "Machine",
        .setNavEnvironment: "Environment",
        .setNavPairing: "Pairing",
        .setClose: "Close",
        .stateIdle: "Idle",
        .stateStarting: "Starting",
        .stateOnline: "Online",
        .stateOffline: "Offline",
        .winMinimize: "Minimize",
        .winMaximize: "Maximize / Restore",
        .winClose: "Close",
        .langTitle: "语言 / Language",
        .langSystem: "Follow system",
        .langZh: "中文",
        .langEn: "English",
        .langCurrent: "Current: {name}",
        .envTitle: "Environment & AI CLIs",
        .envRefresh: "Re-check",
        .envChecking: "Checking…",
        .envNode: "Node.js",
        .envNpm: "npm",
        .envNvm: "NVM",
        .envPython: "Python",
        .envInstalled: "Installed",
        .envNotInstalled: "Not installed",
        .envNodeSourceNvm: "via NVM",
        .envNodeSourceSystem: "system",
        .envNodeCompatible: "compatible",
        .envNodeTooOld: "outdated",
        .envNodeMinHint: "Node.js is required before using agents (≥ {n}). Install and manage it via NVM.",
        .envNodeOldHint: "Current Node {version} is below the recommended baseline (≥ {n}). Install a newer one via NVM below.",
        .envNvmSection: "Step 1 · Install NVM",
        .envNvmHint: "NVM installs and switches Node versions; Windows may show a UAC prompt during install.",
        .envInstallNvm: "Install NVM",
        .envNodeSection: "Step 2 · Install Node.js (via NVM)",
        .envPickVersion: "Pick version",
        .envVersionLts: "LTS",
        .envVersionCustom: "Custom version",
        .envVersionCustomPlaceholder: "e.g. 22.14.0",
        .envInstallNode: "Install via NVM",
        .envInstalling: "Installing…",
        .envCliSection: "AI agent CLIs",
        .envCliHint: "Installed CLIs appear automatically in the chat view's agent list.",
        .envCliInstall: "Install",
        .envCliMethodNative: "Native installer (official)",
        .envCliMethodNativeDesc: "No Node needed, auto-updates",
        .envCliMethodNpm: "npm global install",
        .envCliMethodNpmDesc: "Requires Node.js",
        .envCliMethodPip: "pip installer (official)",
        .envCliMethodPipDesc: "Requires Python",
        .envBlockNode: "Install Node.js first",
        .envBlockNodeVersion: "Requires Node ≥ {n}",
        .envBlockPython: "Install Python first",
        .envLog: "Install log",
        .envDoneOk: "Installed",
        .envDoneFail: "Install failed",
        .envVersionsError: "Failed to load versions; type one manually",
        .envTaskNvm: "NVM",
        .envTaskNode: "Node",
        .envTaskCli: "{name}",
        .envAlreadyInstalled: "Already installed",
        .envUpdate: "Update",
        .envUpdateTitle: "Update to the latest version (official channel)",
    ]
}
