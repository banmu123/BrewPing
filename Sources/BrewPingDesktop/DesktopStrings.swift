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
    case mpTitle = "mp.title"
    case mpHint = "mp.hint"
    case mpProxy = "mp.proxy"
    case mpEndpoint = "mp.endpoint"
    case mpEndpointHint = "mp.endpointHint"
    case mpStateRunning = "mp.stateRunning"
    case mpStateStopped = "mp.stateStopped"
    case mpStateError = "mp.stateError"
    case mpAdd = "mp.add"
    case mpEdit = "mp.edit"
    case mpEmpty = "mp.empty"
    case mpEmptyHint = "mp.emptyHint"
    case mpCurrent = "mp.current"
    case mpSetCurrent = "mp.setCurrent"
    case mpDelete = "mp.delete"
    case mpConfirmDelete = "mp.confirmDelete"
    case mpSave = "mp.save"
    case mpCancel = "mp.cancel"
    case mpName = "mp.name"
    case mpNamePlaceholder = "mp.namePlaceholder"
    case mpBaseUrl = "mp.baseUrl"
    case mpBaseUrlPlaceholder = "mp.baseUrlPlaceholder"
    case mpApiKey = "mp.apiKey"
    case mpApiKeyPlaceholder = "mp.apiKeyPlaceholder"
    case mpModel = "mp.model"
    case mpModelPlaceholder = "mp.modelPlaceholder"
    case mpApiFormat = "mp.apiFormat"
    case mpFormatAnthropic = "mp.format.anthropic"
    case mpFormatOpenaiChat = "mp.format.openai_chat"
    case mpFormatOpenaiResponses = "mp.format.openai_responses"
    case mpAuthStyle = "mp.authStyle"
    case mpAuthAuto = "mp.auth.auto"
    case mpAuthBearer = "mp.auth.bearer"
    case mpAuthXApiKey = "mp.auth.x-api-key"
    case mpIsFullUrl = "mp.isFullUrl"
    case mpNotes = "mp.notes"
    case mpPort = "mp.port"
    case mpEnable = "mp.enable"
    case mpDisable = "mp.disable"
    case mpFailover = "mp.failover"
    case mpFailoverHint = "mp.failoverHint"
    case mpTakeover = "mp.takeover"
    case mpTakeoverHint = "mp.takeoverHint"
    case mpTakeoverActive = "mp.takeoverActive"
    case mpTakeoverOn = "mp.takeoverOn"
    case mpTakeoverOff = "mp.takeoverOff"
    case mpTakeoverNeedsProxy = "mp.takeoverNeedsProxy"
    case mpCliNotInstalled = "mp.cliNotInstalled"
    case mpTakeoverUnsupported = "mp.takeoverUnsupported"
    case mpTakeoverEmpty = "mp.takeoverEmpty"
    case mpAgentModels = "mp.agentModels"
    case mpAgentModelsHint = "mp.agentModelsHint"
    case mpAgentPrefBadge = "mp.agentPrefBadge"
    case mpAgentFollowBadge = "mp.agentFollowBadge"
    case mpAgentModelInvalid = "mp.agentModelInvalid"
    case mpAgentModelClear = "mp.agentModelClear"
    case mpAgentModelsEmpty = "mp.agentModelsEmpty"
    case mpTabGeneral = "mp.tabGeneral"
    case mpGenericBadge = "mp.genericBadge"
    case mpKeySet = "mp.keySet"
    case mpKeyMissing = "mp.keyMissing"
    case mpTabEmpty = "mp.tabEmpty"
    case mpTabEmptyHint = "mp.tabEmptyHint"
    case mpNotTakenOver = "mp.notTakenOver"
    case mpConnectNow = "mp.connectNow"
    case mpOwnerHint = "mp.ownerHint"
    case mpOwnerGeneral = "mp.ownerGeneral"
    case mpProxyDetails = "mp.proxyDetails"
    case mpVendor = "mp.vendor"
    case mpVendorPick = "mp.vendorPick"
    case mpGetKey = "mp.getKey"
    case mpApiKeyKeepHint = "mp.apiKeyKeepHint"
    case mpAdvanced = "mp.advanced"
    case mpAvailableModels = "mp.availableModels"
    case mpFetchModels = "mp.fetchModels"
    case mpFetching = "mp.fetching"
    case mpFetchFailed = "mp.fetchFailed"
    case mpFetchUnsupported = "mp.fetchUnsupported"
    case mpFetchNeedKey = "mp.fetchNeedKey"
    case mpInvalidKey = "mp.invalidKey"
    case mpModelMappingHint = "mp.modelMappingHint"
    case mpEffectiveEndpoint = "mp.effectiveEndpoint"
    case mpPresetCategoryOfficial = "mp.presetCategory.official"
    case mpPresetCategoryCnOfficial = "mp.presetCategory.cn_official"
    case mpPresetCategoryAggregator = "mp.presetCategory.aggregator"
    case mpPresetCategoryThirdParty = "mp.presetCategory.third_party"
    case mpPresetCategoryCustom = "mp.presetCategory.custom"
    case envUpdate = "env.update"
    case envUpdateTitle = "env.updateTitle"
    case clBaseUrlPlaceholder = "cl.baseUrlPlaceholder"
    case clConfigure = "cl.configure"
    case clDeleteHint = "cl.deleteHint"
    case clEditTitle = "cl.editTitle"
    case clEmpty = "cl.empty"
    case clEmptyHint = "cl.emptyHint"
    case clFormHint = "cl.formHint"
    case clHaiku = "cl.haiku"
    case clOpus = "cl.opus"
    case clOtherKeysHint = "cl.otherKeysHint"
    case clOtherKeysNone = "cl.otherKeysNone"
    case clProviderName = "cl.providerName"
    case clSonnet = "cl.sonnet"
    case clSubtitle = "cl.subtitle"
    case clTiers = "cl.tiers"
    case clTiersHint = "cl.tiersHint"
    case clTitle = "cl.title"
    case cxActivate = "cx.activate"
    case cxActive = "cx.active"
    case cxAddTitle = "cx.addTitle"
    case cxAdvancedHint = "cx.advancedHint"
    case cxApiKeyHint = "cx.apiKeyHint"
    case cxBaseUrlPlaceholder = "cx.baseUrlPlaceholder"
    case cxDeleteHint = "cx.deleteHint"
    case cxEditTitle = "cx.editTitle"
    case cxEmptyHint = "cx.emptyHint"
    case cxErrKeyReserved = "cx.errKeyReserved"
    case cxFormHint = "cx.formHint"
    case cxKeyPlaceholder = "cx.keyPlaceholder"
    case cxModel = "cx.model"
    case cxModelHint = "cx.modelHint"
    case cxModelPlaceholder = "cx.modelPlaceholder"
    case cxSubtitle = "cx.subtitle"
    case cxTitle = "cx.title"
    case cxWireApi = "cx.wireApi"
    case cxWireApiHint = "cx.wireApiHint"
    case ocAdd = "oc.add"
    case ocAddModel = "oc.addModel"
    case ocAddTitle = "oc.addTitle"
    case ocEditTitle = "oc.editTitle"
    case ocEmpty = "oc.empty"
    case ocEmptyHint = "oc.emptyHint"
    case ocErrBaseRequired = "oc.errBaseRequired"
    case ocErrBaseScheme = "oc.errBaseScheme"
    case ocErrKeyFormat = "oc.errKeyFormat"
    case ocErrKeyRequired = "oc.errKeyRequired"
    case ocErrKeyTaken = "oc.errKeyTaken"
    case ocErrModelsRequired = "oc.errModelsRequired"
    case ocFetchModels = "oc.fetchModels"
    case ocFetchUnsupported = "oc.fetchUnsupported"
    case ocFormHint = "oc.formHint"
    case ocHeadersHint = "oc.headersHint"
    case ocKey = "oc.key"
    case ocKeyHint = "oc.keyHint"
    case ocKeyPlaceholder = "oc.keyPlaceholder"
    case ocModelCount = "oc.modelCount"
    case ocModelIdPlaceholder = "oc.modelIdPlaceholder"
    case ocModelNamePlaceholder = "oc.modelNamePlaceholder"
    case ocModels = "oc.models"
    case ocNamePlaceholder = "oc.namePlaceholder"
    case ocNotCreated = "oc.notCreated"
    case ocNpm = "oc.npm"
    case ocSubtitle = "oc.subtitle"
    case ocTitle = "oc.title"
    case piAddTitle = "pi.addTitle"
    case piAdvancedHint = "pi.advancedHint"
    case piApi = "pi.api"
    case piApiHint = "pi.apiHint"
    case piApiKeyHint = "pi.apiKeyHint"
    case piBaseUrlPlaceholder = "pi.baseUrlPlaceholder"
    case piDefault = "pi.default"
    case piDefaultLabel = "pi.defaultLabel"
    case piDeleteHint = "pi.deleteHint"
    case piEditTitle = "pi.editTitle"
    case piEmptyHint = "pi.emptyHint"
    case piErrModelsRequired = "pi.errModelsRequired"
    case piFormHint = "pi.formHint"
    case piKeyLockedHint = "pi.keyLockedHint"
    case piKeyPlaceholder = "pi.keyPlaceholder"
    case piModelCount = "pi.modelCount"
    case piModelIdPlaceholder = "pi.modelIdPlaceholder"
    case piModels = "pi.models"
    case piModelsHint = "pi.modelsHint"
    case piSetDefault = "pi.setDefault"
    case piSubtitle = "pi.subtitle"
    case piTitle = "pi.title"
    case swWelcomeTitle = "swWelcomeTitle"
    case swWelcomeSubtitle = "swWelcomeSubtitle"
    case swGetStarted = "swGetStarted"
    case swSkipForNow = "swSkipForNow"
    case swStepCheck = "swStepCheck"
    case swChecking = "swChecking"
    case swCheckAgain = "swCheckAgain"
    case swContinue = "swContinue"
    case swBack = "swBack"
    case swStatusReady = "swStatusReady"
    case swStatusNeedsSetup = "swStatusNeedsSetup"
    case swStatusUnavailable = "swStatusUnavailable"
    case swStatusOptional = "swStatusOptional"
    case swRowOS = "swRowOS"
    case swRowNode = "swRowNode"
    case swRowNpm = "swRowNpm"
    case swRowNvm = "swRowNvm"
    case swRowBrewping = "swRowBrewping"
    case swRowAgents = "swRowAgents"
    case swWhyNodeMissing = "swWhyNodeMissing"
    case swWhyNodeOld = "swWhyNodeOld"
    case swWhyNpmMissing = "swWhyNpmMissing"
    case swWhyNvmMissing = "swWhyNvmMissing"
    case swNvmOptionalHint = "swNvmOptionalHint"
    case swNodeStepTitle = "swNodeStepTitle"
    case swNodeStepHint = "swNodeStepHint"
    case swOpenNvmGuide = "swOpenNvmGuide"
    case swOpenNodeDownload = "swOpenNodeDownload"
    case swAgentsStepTitle = "swAgentsStepTitle"
    case swAgentsStepHint = "swAgentsStepHint"
    case swAgentNotInstalled = "swAgentNotInstalled"
    case swCopyCommand = "swCopyCommand"
    case swCopied = "swCopied"
    case swOpenDocs = "swOpenDocs"
    case swReadyTitle = "swReadyTitle"
    case swReadySubtitle = "swReadySubtitle"
    case swStartBrewping = "swStartBrewping"
    case swNoAgentsTitle = "swNoAgentsTitle"
    case swNoAgentsSubtitle = "swNoAgentsSubtitle"
    case swInstallAgent = "swInstallAgent"
    case swBannerIncomplete = "swBannerIncomplete"
    case swBannerComplete = "swBannerComplete"
    case swRunSetupAgain = "swRunSetupAgain"
    case swSetupCardTitle = "swSetupCardTitle"
    case swSetupCardHint = "swSetupCardHint"
    case swViaNvm = "swViaNvm"
    case swViaSystem = "swViaSystem"
    case swAgentsSummary = "swAgentsSummary"
    case swServiceReadyDetail = "swServiceReadyDetail"
    case swNodeVersionsTitle = "swNodeVersionsTitle"
    case swNodeUse = "swNodeUse"
    case swNodeInUse = "swNodeInUse"
    case swNodeDefaultBadge = "swNodeDefaultBadge"
    case swNodeActiveBadge = "swNodeActiveBadge"
    case swSwitchHint = "swSwitchHint"
    case swSwitching = "swSwitching"
    case swSwitchFailed = "swSwitchFailed"
    case swSourceHomebrew = "swSourceHomebrew"
    case swSourceSystem = "swSourceSystem"
    case swNodeUpdateTitle = "swNodeUpdateTitle"
    case swNodeSwitchIntro = "swNodeSwitchIntro"
    case swManualInstall = "swManualInstall"
    case swModelsStepTitle = "swModelsStepTitle"
    case swModelsStepHint = "swModelsStepHint"
    case swModelConfigured = "swModelConfigured"
    case swModelMissing = "swModelMissing"
    case swGoConfigure = "swGoConfigure"
    case swPairStepTitle = "swPairStepTitle"
    case swPairStepHint = "swPairStepHint"
    case swOpenPairSettings = "swOpenPairSettings"
    case swPairAddrHint = "swPairAddrHint"
    case swPairCodeFallback = "swPairCodeFallback"
    case swPairSuccessTitle = "swPairSuccessTitle"
    case swPairSuccessHint = "swPairSuccessHint"
    case setLegalTitle = "setLegalTitle"
    case setLegalBody = "setLegalBody"
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
        .mpTitle: "模型配置",
        .mpHint: "配置多厂商 API，经内置转发代理供本机 CLI 使用；切换配置即时生效，CLI 无需重启。",
        .mpProxy: "转发代理",
        .mpEndpoint: "接入地址",
        .mpEndpointHint: "把 CLI 的 API 地址指到这里（如 ANTHROPIC_BASE_URL=http://127.0.0.1:{port}），请求将按当前选中的配置转发到真实厂商。",
        .mpStateRunning: "转发中",
        .mpStateStopped: "已停止",
        .mpStateError: "启动失败",
        .mpAdd: "添加配置",
        .mpEdit: "编辑配置",
        .mpEmpty: "还没有模型配置",
        .mpEmptyHint: "先添加一个厂商配置（名称 / 接口地址 / API Key），再把 CLI 指向上方转发地址。",
        .mpCurrent: "当前",
        .mpSetCurrent: "设为当前",
        .mpDelete: "删除",
        .mpConfirmDelete: "再次点击确认删除",
        .mpSave: "保存",
        .mpCancel: "取消",
        .mpName: "名称",
        .mpNamePlaceholder: "如 Kimi / DeepSeek",
        .mpBaseUrl: "接口地址（Base URL）",
        .mpBaseUrlPlaceholder: "https://api.example.com",
        .mpApiKey: "API Key",
        .mpApiKeyPlaceholder: "上游厂商的密钥（仅保存在本机）",
        .mpModel: "默认模型（可选）",
        .mpModelPlaceholder: "如 kimi-k2.5",
        .mpApiFormat: "接口协议",
        .mpFormatAnthropic: "Anthropic Messages",
        .mpFormatOpenaiChat: "OpenAI Chat Completions",
        .mpFormatOpenaiResponses: "OpenAI Responses",
        .mpAuthStyle: "鉴权方式",
        .mpAuthAuto: "自动（按协议）",
        .mpAuthBearer: "Bearer Token",
        .mpAuthXApiKey: "x-api-key",
        .mpIsFullUrl: "Base URL 已是完整端点（不再拼接路径）",
        .mpNotes: "备注（可选）",
        .mpPort: "端口",
        .mpEnable: "启用",
        .mpDisable: "停用",
        .mpFailover: "自动故障转移",
        .mpFailoverHint: "当前厂商请求失败时，按配置列表顺序自动换下一家（请求参数错误不重试）。",
        .mpTakeover: "CLI 接入",
        .mpTakeoverHint: "一键把本机 CLI 指向下方转发地址（http://127.0.0.1:{port}），之后在 BrewPing 里切换厂商即时生效。关闭时会精确还原，不误删你自己的配置。",
        .mpTakeoverActive: "已接入",
        .mpTakeoverOn: "接入",
        .mpTakeoverOff: "还原",
        .mpTakeoverNeedsProxy: "转发代理未运行：首次接入 CLI 时会自动启动，无需手动操作。",
        .mpCliNotInstalled: "未安装",
        .mpTakeoverUnsupported: "暂不支持接入",
        .mpTakeoverEmpty: "未发现可接入的 CLI",
        .mpAgentModels: "Agent 模型",
        .mpAgentModelsHint: "每个 Agent 当前生效的模型。展开查看完整列表，点击模型即设为该 Agent 的默认（启动 Agent 时自动带上）。",
        .mpAgentPrefBadge: "默认",
        .mpAgentFollowBadge: "跟随 CLI",
        .mpAgentModelInvalid: "绑定已失效",
        .mpAgentModelClear: "清除默认",
        .mpAgentModelsEmpty: "该 Agent 未发现可用模型",
        .mpTabGeneral: "通用",
        .mpGenericBadge: "通用",
        .mpKeySet: "已配 Key",
        .mpKeyMissing: "未配 Key",
        .mpTabEmpty: "该归属下还没有可用厂商",
        .mpTabEmptyHint: "添加一个专属厂商，或把「通用」厂商设为当前。",
        .mpNotTakenOver: "{name} 尚未接入转发代理，厂商配置不会生效。",
        .mpConnectNow: "一键接入",
        .mpOwnerHint: "归属：{name}（创建后不可更改）",
        .mpOwnerGeneral: "通用（所有 Agent 可用）",
        .mpProxyDetails: "代理设置",
        .mpVendor: "厂商",
        .mpVendorPick: "选择厂商（自动预填）",
        .mpGetKey: "获取 API Key",
        .mpApiKeyKeepHint: "已配置——留空或不改动即保留原 Key",
        .mpAdvanced: "高级选项",
        .mpAvailableModels: "可用模型",
        .mpFetchModels: "获取模型列表",
        .mpFetching: "获取中…",
        .mpFetchFailed: "获取失败，可手动填写",
        .mpFetchUnsupported: "该厂商不支持自动获取",
        .mpFetchNeedKey: "请先填写 API Key 再获取",
        .mpInvalidKey: "API Key 无效",
        .mpModelMappingHint: "此处填写的默认模型会覆盖下游请求的型号（模型映射）；留空则原样透传。",
        .mpEffectiveEndpoint: "生效端点",
        .mpPresetCategoryOfficial: "官方",
        .mpPresetCategoryCnOfficial: "国内官方",
        .mpPresetCategoryAggregator: "聚合服务",
        .mpPresetCategoryThirdParty: "第三方",
        .mpPresetCategoryCustom: "自定义",
        .envUpdate: "更新",
        .envUpdateTitle: "更新到最新版本（官方更新通道）",
        .clBaseUrlPlaceholder: "https://api.deepseek.com/anthropic",
        .clConfigure: "配置厂商",
        .clDeleteHint: "清除 Claude Code 的厂商配置（仅摘除 ANTHROPIC_* 键）。",
        .clEditTitle: "Claude Code 厂商配置",
        .clEmpty: "还没有配置厂商",
        .clEmptyHint: "配置一次，BrewPing 会帮你写好 settings.json，Claude Code 直接用你的中转站。",
        .clFormHint: "保存后整体覆盖 settings.json 的 env 段（其余顶层键原样保留）。",
        .clHaiku: "Haiku",
        .clOpus: "Opus",
        .clOtherKeysHint: "以下顶层键会原样保留（不参与覆盖）：",
        .clOtherKeysNone: "settings.json 中暂无其他顶层配置。",
        .clProviderName: "厂商名称（可选）",
        .clSonnet: "Sonnet",
        .clSubtitle: "写入 ~/.claude/settings.json 的 env 段，保存后 Claude Code 即刻生效。",
        .clTiers: "模型档位映射",
        .clTiersHint: "把 Claude Code 内置的 sonnet / opus / haiku 三档映射到厂商真实型号；留空则该档用官方默认。",
        .clTitle: "Claude Code 厂商",
        .cxActivate: "设为生效",
        .cxActive: "生效中",
        .cxAddTitle: "添加厂商",
        .cxAdvancedHint: "需要设置 approval_policy、sandbox 或 reasoning 等高级项时，保存后手动编辑 config.toml。",
        .cxApiKeyHint: "写入 experimental_bearer_token；不会覆盖你的 ChatGPT 登录凭据。",
        .cxBaseUrlPlaceholder: "https://api.deepseek.com/v1",
        .cxDeleteHint: "从 config.toml 删除该厂商（若为生效项同时清除顶层 model_provider）。",
        .cxEditTitle: "编辑厂商",
        .cxEmptyHint: "添加一个厂商，BrewPing 会帮你写好 config.toml 并设为生效项。",
        .cxErrKeyReserved: "openai / ollama / lmstudio 是 Codex 保留标识，不能占用",
        .cxFormHint: "保存后写入 config.toml 的 [model_providers.<key>]，注释与其它配置原样保留。",
        .cxKeyPlaceholder: "my-deepseek",
        .cxModel: "默认模型（可选）",
        .cxModelHint: "留空不会覆盖 config.toml 里已有的顶层 model。",
        .cxModelPlaceholder: "留空则不指定，沿用 Codex 当前设置",
        .cxSubtitle: "写入 ~/.codex/config.toml 的 [model_providers]，不改动登录凭据。",
        .cxTitle: "Codex 厂商",
        .cxWireApi: "接口协议（wire_api）",
        .cxWireApiHint: "多数中转站用 chat；官方 OpenAI 新接口用 responses。",
        .ocAdd: "添加厂商",
        .ocAddModel: "添加模型",
        .ocAddTitle: "添加厂商",
        .ocEditTitle: "编辑厂商",
        .ocEmpty: "还没有配置厂商",
        .ocEmptyHint: "添加一个厂商，BrewPing 会帮你写好 opencode.json。",
        .ocErrBaseRequired: "请填写 API 基址",
        .ocErrBaseScheme: "地址需以 http:// 或 https:// 开头",
        .ocErrKeyFormat: "只能用小写字母、数字与单个连字符（如 my-deepseek）",
        .ocErrKeyRequired: "请填写厂商标识",
        .ocErrKeyTaken: "该标识已被占用，请换一个",
        .ocErrModelsRequired: "至少填写一个模型 ID",
        .ocFetchModels: "拉取模型",
        .ocFetchUnsupported: "该地址无法自动拉取，请手动填写模型",
        .ocFormHint: "保存后自动写入 opencode.json 的 provider 段，无需手动改文件。",
        .ocHeadersHint: "如需自定义请求头，可在保存后手动编辑 opencode.json。",
        .ocKey: "厂商标识（provider key）",
        .ocKeyHint: "小写字母、数字与单个连字符；由名称自动生成，可手动修改。",
        .ocKeyPlaceholder: "my-deepseek",
        .ocModelCount: "{n} 个模型",
        .ocModelIdPlaceholder: "模型 ID，如 deepseek-chat",
        .ocModelNamePlaceholder: "显示名（可选）",
        .ocModels: "模型列表",
        .ocNamePlaceholder: "如 DeepSeek / Kimi",
        .ocNotCreated: "文件尚未创建",
        .ocNpm: "接口格式（npm 包）",
        .ocSubtitle: "直接写入 opencode 配置文件，保存后 opencode 即刻可用。",
        .ocTitle: "OpenCode 厂商",
        .piAddTitle: "添加厂商",
        .piAdvancedHint: "如需设置 headers、超时等高级项，保存后手动编辑 models.json。",
        .piApi: "接口协议（api）",
        .piApiHint: "Anthropic 系用 anthropic-messages；OpenAI 兼容用 openai-completions 或 openai-responses。",
        .piApiKeyHint: "写入该厂商的 apiKey；不会覆盖 pi 的登录凭据（auth.json）。",
        .piBaseUrlPlaceholder: "https://api.deepseek.com",
        .piDefault: "默认",
        .piDefaultLabel: "当前默认：",
        .piDeleteHint: "从 models.json 删除该厂商（若为默认项同时清除默认设置）。",
        .piEditTitle: "编辑厂商",
        .piEmptyHint: "添加一个厂商，BrewPing 会帮你写好 models.json。",
        .piErrModelsRequired: "至少填写一个模型 ID",
        .piFormHint: "保存后写入 models.json 的 providers.<key>，其余厂商与设置原样保留。",
        .piKeyLockedHint: "厂商标识不可修改（改动等于删旧建新，会让默认项悬空）。",
        .piKeyPlaceholder: "my-deepseek",
        .piModelCount: "{n} 个模型",
        .piModelIdPlaceholder: "模型 ID，如 deepseek-chat",
        .piModels: "模型列表",
        .piModelsHint: "第一条即「设为默认」时使用的模型。",
        .piSetDefault: "设为默认",
        .piSubtitle: "写入 ~/.pi/agent/models.json 的 providers，默认项记在 settings.json。",
        .piTitle: "pi 厂商",
        .swWelcomeTitle: "欢迎使用 BrewPing",
        .swWelcomeSubtitle: "用手机、Apple Watch 与桌面端，掌控你电脑上的 coding agents。",
        .swGetStarted: "开始",
        .swSkipForNow: "暂时跳过",
        .swStepCheck: "环境检查",
        .swChecking: "正在扫描电脑环境…",
        .swCheckAgain: "重新检测",
        .swContinue: "继续",
        .swBack: "上一步",
        .swStatusReady: "就绪",
        .swStatusNeedsSetup: "需要配置",
        .swStatusUnavailable: "不可用",
        .swStatusOptional: "可选",
        .swRowOS: "操作系统",
        .swRowNode: "Node.js",
        .swRowNpm: "npm",
        .swRowNvm: "NVM",
        .swRowBrewping: "BrewPing 服务",
        .swRowAgents: "Coding Agents",
        .swWhyNodeMissing: "BrewPing 依赖 Node.js 运行受支持的 coding agents。",
        .swWhyNodeOld: "检测到 {version}，但 agents 需要 Node v{n} 或更高版本。",
        .swWhyNpmMissing: "npm 随 Node.js 一起安装，装好 Node 即有 npm。",
        .swWhyNvmMissing: "NVM 用于安装与切换 Node 版本；不需要时不装也不影响使用。",
        .swNvmOptionalHint: "Node 已可用，NVM 仅为可选项。",
        .swNodeStepTitle: "配置 Node.js",
        .swNodeStepHint: "BrewPing 不会替你执行安装脚本。请打开官方页面安装，然后点「重新检测」。",
        .swOpenNvmGuide: "打开 NVM 安装指南",
        .swOpenNodeDownload: "打开 Node.js 官网",
        .swAgentsStepTitle: "Coding Agents",
        .swAgentsStepHint: "下面列出本机检测到的 agents。未安装的可按官方命令安装，然后点「重新检测」。",
        .swAgentNotInstalled: "未安装",
        .swCopyCommand: "复制命令",
        .swCopied: "已复制",
        .swOpenDocs: "打开官方文档",
        .swReadyTitle: "这台电脑已准备就绪。",
        .swReadySubtitle: "手机现在可以连接这台电脑了。",
        .swStartBrewping: "开始使用 BrewPing",
        .swNoAgentsTitle: "还没有检测到 coding agents。",
        .swNoAgentsSubtitle: "至少安装一个受支持的 agent 才能远程执行命令；也可以先不装继续使用。",
        .swInstallAgent: "去安装 Agent",
        .swBannerIncomplete: "环境设置未完成",
        .swBannerComplete: "完成设置",
        .swRunSetupAgain: "重新运行环境设置",
        .swSetupCardTitle: "环境设置",
        .swSetupCardHint: "随时检查 Node.js、npm 与 coding agents 的安装状态。",
        .swViaNvm: "经 NVM 安装",
        .swViaSystem: "系统安装",
        .swAgentsSummary: "已安装 {n} / {total}",
        .swServiceReadyDetail: "HTTP 服务运行中 · 可随时配对",
        .swNodeVersionsTitle: "已安装的 Node 版本",
        .swNodeUse: "使用",
        .swNodeInUse: "使用中",
        .swNodeDefaultBadge: "默认",
        .swNodeActiveBadge: "当前使用",
        .swSwitchHint: "「使用」会把该版本设为 nvm 默认（新开终端自动生效），无需管理员权限。",
        .swSwitching: "切换中…",
        .swSwitchFailed: "切换失败，详见「设置 → 环境」日志。",
        .swSourceHomebrew: "Homebrew",
        .swSourceSystem: "系统",
        .swNodeUpdateTitle: "升级 Node.js",
        .swNodeSwitchIntro: "你已安装了更新的版本，点「使用」即可切换。",
        .swManualInstall: "或手动安装",
        .swModelsStepTitle: "配置模型",
        .swModelsStepHint: "各 Agent 的模型来自其自身配置。至少为一个 Agent 配置好模型，手机端才能开始对话——点「去配置」打开该 Agent 的模型设置。",
        .swModelConfigured: "已有模型",
        .swModelMissing: "尚未配置",
        .swGoConfigure: "去配置",
        .swPairStepTitle: "用手机扫码配对",
        .swPairStepHint: "在 iPhone 上打开 BrewPing，扫描二维码与这台电脑配对。",
        .swOpenPairSettings: "配对设置",
        .swPairAddrHint: "若扫码无法连接，请确认 iPhone 与下面地址在同一 Wi-Fi 网段；也可以在手机端手动输入配对码。",
        .swPairCodeFallback: "或手动输入配对码：",
        .swPairSuccessTitle: "配对成功！",
        .swPairSuccessHint: "正在进入 BrewPing…",
        .setLegalTitle: "商标与归属",
        .setLegalBody: "OpenCode、Claude、Claude Code、Codex、pi 等名称归各自所有者所有。BrewPing 与这些厂商没有任何隶属、背书或赞助关系；提及这些名称仅用于说明兼容性。",
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
        .mpTitle: "Model Providers",
        .mpHint: "Configure multiple API providers and reach them through the built-in forwarding proxy. Switching providers takes effect instantly — no CLI restart needed.",
        .mpProxy: "Forwarding proxy",
        .mpEndpoint: "Endpoint",
        .mpEndpointHint: "Point your CLI's API base URL here (e.g. ANTHROPIC_BASE_URL=http://127.0.0.1:{port}); requests are forwarded to the selected provider.",
        .mpStateRunning: "Forwarding",
        .mpStateStopped: "Stopped",
        .mpStateError: "Start failed",
        .mpAdd: "Add provider",
        .mpEdit: "Edit provider",
        .mpEmpty: "No model providers yet",
        .mpEmptyHint: "Add a provider (name / base URL / API key) first, then point your CLI at the proxy endpoint above.",
        .mpCurrent: "Current",
        .mpSetCurrent: "Set current",
        .mpDelete: "Delete",
        .mpConfirmDelete: "Click again to confirm",
        .mpSave: "Save",
        .mpCancel: "Cancel",
        .mpName: "Name",
        .mpNamePlaceholder: "e.g. Kimi / DeepSeek",
        .mpBaseUrl: "Base URL",
        .mpBaseUrlPlaceholder: "https://api.example.com",
        .mpApiKey: "API Key",
        .mpApiKeyPlaceholder: "Provider secret (stored locally only)",
        .mpModel: "Default model (optional)",
        .mpModelPlaceholder: "e.g. kimi-k2.5",
        .mpApiFormat: "API format",
        .mpFormatAnthropic: "Anthropic Messages",
        .mpFormatOpenaiChat: "OpenAI Chat Completions",
        .mpFormatOpenaiResponses: "OpenAI Responses",
        .mpAuthStyle: "Auth style",
        .mpAuthAuto: "Auto (by format)",
        .mpAuthBearer: "Bearer Token",
        .mpAuthXApiKey: "x-api-key",
        .mpIsFullUrl: "Base URL is a full endpoint (do not append paths)",
        .mpNotes: "Notes (optional)",
        .mpPort: "Port",
        .mpEnable: "Enable",
        .mpDisable: "Disable",
        .mpFailover: "Auto failover",
        .mpFailoverHint: "On upstream failure, try providers in list order (client-side errors are not retried).",
        .mpTakeover: "CLI integration",
        .mpTakeoverHint: "Point local CLIs at the forwarding endpoint (http://127.0.0.1:{port}) in one click. Switching providers then takes effect instantly. Disabling restores your original config by exact value — nothing of yours is removed.",
        .mpTakeoverActive: "Connected",
        .mpTakeoverOn: "Connect",
        .mpTakeoverOff: "Restore",
        .mpTakeoverNeedsProxy: "Proxy is not running — it starts automatically the first time you connect a CLI.",
        .mpCliNotInstalled: "Not installed",
        .mpTakeoverUnsupported: "Not supported yet",
        .mpTakeoverEmpty: "No integrable CLI found",
        .mpAgentModels: "Agent models",
        .mpAgentModelsHint: "The model in effect for each agent. Expand to see the full list; click a model to set it as the agent's default (applied automatically on launch).",
        .mpAgentPrefBadge: "Default",
        .mpAgentFollowBadge: "From CLI",
        .mpAgentModelInvalid: "Stale binding",
        .mpAgentModelClear: "Clear default",
        .mpAgentModelsEmpty: "No models discovered for this agent",
        .mpTabGeneral: "General",
        .mpGenericBadge: "Shared",
        .mpKeySet: "Key set",
        .mpKeyMissing: "No key",
        .mpTabEmpty: "No providers under this owner yet",
        .mpTabEmptyHint: "Add a dedicated provider, or set a \"General\" one as current.",
        .mpNotTakenOver: "{name} is not connected to the proxy — provider settings won't take effect.",
        .mpConnectNow: "Connect",
        .mpOwnerHint: "Owner: {name} (locked after creation)",
        .mpOwnerGeneral: "General (available to all agents)",
        .mpProxyDetails: "Proxy settings",
        .mpVendor: "Provider",
        .mpVendorPick: "Pick a provider (auto-fills)",
        .mpGetKey: "Get API Key",
        .mpApiKeyKeepHint: "Configured — leave untouched to keep the current key",
        .mpAdvanced: "Advanced",
        .mpAvailableModels: "Available models",
        .mpFetchModels: "Fetch models",
        .mpFetching: "Fetching…",
        .mpFetchFailed: "Fetch failed — fill in manually",
        .mpFetchUnsupported: "Auto-fetch not supported for this provider",
        .mpFetchNeedKey: "Fill in the API key first",
        .mpInvalidKey: "Invalid API key",
        .mpModelMappingHint: "The default model here overrides the downstream request model (mapping); leave empty to pass through.",
        .mpEffectiveEndpoint: "Effective endpoint",
        .mpPresetCategoryOfficial: "Official",
        .mpPresetCategoryCnOfficial: "China official",
        .mpPresetCategoryAggregator: "Aggregator",
        .mpPresetCategoryThirdParty: "Third-party",
        .mpPresetCategoryCustom: "Custom",
        .envUpdate: "Update",
        .envUpdateTitle: "Update to the latest version (official channel)",
        .clBaseUrlPlaceholder: "https://api.deepseek.com/anthropic",
        .clConfigure: "Configure provider",
        .clDeleteHint: "Remove the Claude Code provider config (only the ANTHROPIC_* keys are stripped).",
        .clEditTitle: "Claude Code provider",
        .clEmpty: "No provider configured yet",
        .clEmptyHint: "Configure once and BrewPing writes settings.json for you — Claude Code uses your gateway directly.",
        .clFormHint: "Saving overwrites the env block of settings.json (other top-level keys are kept).",
        .clHaiku: "Haiku",
        .clOpus: "Opus",
        .clOtherKeysHint: "These top-level keys are preserved as-is (not overwritten):",
        .clOtherKeysNone: "No other top-level config in settings.json.",
        .clProviderName: "Provider name (optional)",
        .clSonnet: "Sonnet",
        .clSubtitle: "Writes the env block of ~/.claude/settings.json — effective immediately.",
        .clTiers: "Model tier mapping",
        .clTiersHint: "Maps Claude Code's built-in sonnet / opus / haiku tiers to your provider's models; leave blank to use the official defaults.",
        .clTitle: "Claude Code provider",
        .cxActivate: "Set active",
        .cxActive: "Active",
        .cxAddTitle: "Add provider",
        .cxAdvancedHint: "For approval_policy, sandbox or reasoning settings, edit config.toml manually after saving.",
        .cxApiKeyHint: "Written to experimental_bearer_token; your ChatGPT login is never overwritten.",
        .cxBaseUrlPlaceholder: "https://api.deepseek.com/v1",
        .cxDeleteHint: "Remove this provider from config.toml (clears top-level model_provider if active).",
        .cxEditTitle: "Edit provider",
        .cxEmptyHint: "Add a provider and BrewPing writes config.toml and makes it the active one.",
        .cxErrKeyReserved: "openai / ollama / lmstudio are reserved by Codex and cannot be used",
        .cxFormHint: "Saving writes [model_providers.<key>] in config.toml — comments and other config are kept.",
        .cxKeyPlaceholder: "my-deepseek",
        .cxModel: "Default model (optional)",
        .cxModelHint: "Blank will not overwrite an existing top-level model in config.toml.",
        .cxModelPlaceholder: "Leave blank to keep Codex's current setting",
        .cxSubtitle: "Writes [model_providers] in ~/.codex/config.toml without touching login credentials.",
        .cxTitle: "Codex provider",
        .cxWireApi: "Wire API",
        .cxWireApiHint: "Most gateways use chat; OpenAI's newer API uses responses.",
        .ocAdd: "Add provider",
        .ocAddModel: "Add model",
        .ocAddTitle: "Add provider",
        .ocEditTitle: "Edit provider",
        .ocEmpty: "No providers configured yet",
        .ocEmptyHint: "Add a provider and BrewPing will write opencode.json for you.",
        .ocErrBaseRequired: "Base URL is required",
        .ocErrBaseScheme: "URL must start with http:// or https://",
        .ocErrKeyFormat: "Use lowercase letters, digits and single dashes (e.g. my-deepseek)",
        .ocErrKeyRequired: "Provider key is required",
        .ocErrKeyTaken: "This key is already taken",
        .ocErrModelsRequired: "Add at least one model ID",
        .ocFetchModels: "Fetch models",
        .ocFetchUnsupported: "Cannot auto-fetch for this URL — enter models manually",
        .ocFormHint: "Saving writes the provider section of opencode.json automatically — no manual editing.",
        .ocHeadersHint: "To set custom request headers, edit opencode.json manually after saving.",
        .ocKey: "Provider key",
        .ocKeyHint: "Lowercase letters, digits and single dashes. Derived from the name; editable.",
        .ocKeyPlaceholder: "my-deepseek",
        .ocModelCount: "{n} model(s)",
        .ocModelIdPlaceholder: "Model ID, e.g. deepseek-chat",
        .ocModelNamePlaceholder: "Display name (optional)",
        .ocModels: "Models",
        .ocNamePlaceholder: "e.g. DeepSeek / Kimi",
        .ocNotCreated: "file not created yet",
        .ocNpm: "API format (npm package)",
        .ocSubtitle: "Written straight into opencode's config file — usable immediately.",
        .ocTitle: "OpenCode Providers",
        .piAddTitle: "Add provider",
        .piAdvancedHint: "For headers, timeouts and other advanced options, edit models.json manually after saving.",
        .piApi: "API",
        .piApiHint: "Anthropic-style uses anthropic-messages; OpenAI-compatible uses openai-completions or openai-responses.",
        .piApiKeyHint: "Written to this provider's apiKey; pi's login credentials (auth.json) are never overwritten.",
        .piBaseUrlPlaceholder: "https://api.deepseek.com",
        .piDefault: "Default",
        .piDefaultLabel: "Current default:",
        .piDeleteHint: "Remove this provider from models.json (clears the default setting if it was default).",
        .piEditTitle: "Edit provider",
        .piEmptyHint: "Add a provider and BrewPing writes models.json for you.",
        .piErrModelsRequired: "Enter at least one model ID",
        .piFormHint: "Saving writes providers.<key> in models.json — other providers and settings are kept.",
        .piKeyLockedHint: "The provider key cannot be changed (renaming is delete + recreate, orphaning the default).",
        .piKeyPlaceholder: "my-deepseek",
        .piModelCount: "{n} model(s)",
        .piModelIdPlaceholder: "Model ID, e.g. deepseek-chat",
        .piModels: "Models",
        .piModelsHint: "The first entry is the one used when set as default.",
        .piSetDefault: "Set default",
        .piSubtitle: "Writes providers in ~/.pi/agent/models.json; defaults live in settings.json.",
        .piTitle: "pi provider",
        .swWelcomeTitle: "Welcome to BrewPing",
        .swWelcomeSubtitle: "Control your coding agents from your phone, Apple Watch, and desktop.",
        .swGetStarted: "Get Started",
        .swSkipForNow: "Skip for Now",
        .swStepCheck: "Environment Check",
        .swChecking: "Scanning your computer…",
        .swCheckAgain: "Check Again",
        .swContinue: "Continue",
        .swBack: "Back",
        .swStatusReady: "Ready",
        .swStatusNeedsSetup: "Needs Setup",
        .swStatusUnavailable: "Unavailable",
        .swStatusOptional: "Optional",
        .swRowOS: "Operating System",
        .swRowNode: "Node.js",
        .swRowNpm: "npm",
        .swRowNvm: "NVM",
        .swRowBrewping: "BrewPing Service",
        .swRowAgents: "Coding Agents",
        .swWhyNodeMissing: "BrewPing uses Node.js to run supported coding agents.",
        .swWhyNodeOld: "Found {version}, but agents need Node v{n} or newer.",
        .swWhyNpmMissing: "npm comes with Node.js — installing Node also installs npm.",
        .swWhyNvmMissing: "NVM lets you install and switch Node versions. It is not required unless you need it.",
        .swNvmOptionalHint: "Node is already working — NVM is optional.",
        .swNodeStepTitle: "Set up Node.js",
        .swNodeStepHint: "BrewPing does not run install scripts for you. Open the official page, install, then Check Again.",
        .swOpenNvmGuide: "Open NVM Guide",
        .swOpenNodeDownload: "Open Node.js Website",
        .swAgentsStepTitle: "Coding Agents",
        .swAgentsStepHint: "Agents found on this computer are listed below. Install missing ones with the official command, then Check Again.",
        .swAgentNotInstalled: "Not installed",
        .swCopyCommand: "Copy Command",
        .swCopied: "Copied",
        .swOpenDocs: "Open Documentation",
        .swReadyTitle: "Your computer is ready.",
        .swReadySubtitle: "Your phone can now connect to this computer.",
        .swStartBrewping: "Start BrewPing",
        .swNoAgentsTitle: "No coding agents found yet.",
        .swNoAgentsSubtitle: "Install at least one supported agent to use remote commands. You can also continue without one.",
        .swInstallAgent: "Install an Agent",
        .swBannerIncomplete: "Setup incomplete",
        .swBannerComplete: "Complete Setup",
        .swRunSetupAgain: "Run Setup Again",
        .swSetupCardTitle: "Environment Setup",
        .swSetupCardHint: "Check Node.js, npm and coding agents anytime.",
        .swViaNvm: "via NVM",
        .swViaSystem: "system installation",
        .swAgentsSummary: "{n} of {total} installed",
        .swServiceReadyDetail: "HTTP service running · ready for pairing",
        .swNodeVersionsTitle: "Installed Node versions",
        .swNodeUse: "Use",
        .swNodeInUse: "In use",
        .swNodeDefaultBadge: "default",
        .swNodeActiveBadge: "active",
        .swSwitchHint: "\"Use\" sets the nvm default version — new terminals pick it up automatically. No admin rights required.",
        .swSwitching: "Switching…",
        .swSwitchFailed: "Switch failed — see Settings → Environment for the log.",
        .swSourceHomebrew: "Homebrew",
        .swSourceSystem: "system",
        .swNodeUpdateTitle: "Update Node.js",
        .swNodeSwitchIntro: "You already have newer versions installed — tap Use to switch.",
        .swManualInstall: "Or install manually",
        .swModelsStepTitle: "Configure a Model",
        .swModelsStepHint: "Agents read models from their own configuration. Configure at least one agent so your phone can start chatting — tap Configure to open that agent's model settings.",
        .swModelConfigured: "Model ready",
        .swModelMissing: "No model yet",
        .swGoConfigure: "Configure",
        .swPairStepTitle: "Pair Your Phone",
        .swPairStepHint: "Open BrewPing on your iPhone and scan this code to pair with this computer.",
        .swOpenPairSettings: "Pairing Settings",
        .swPairAddrHint: "If scanning doesn't connect, make sure the iPhone is on the same Wi-Fi as this address, or enter the code manually.",
        .swPairCodeFallback: "Or enter pairing code:",
        .swPairSuccessTitle: "Paired!",
        .swPairSuccessHint: "Entering BrewPing…",
        .setLegalTitle: "Trademarks",
        .setLegalBody: "OpenCode, Claude, Claude Code, Codex, and pi are trademarks of their respective owners. BrewPing is not affiliated with, endorsed by, or sponsored by them; these names appear only to describe compatibility.",
    ]
}
