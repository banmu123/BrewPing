import Foundation

/// 桌面端事件总线。
///
/// 与 Windows 端 Tauri 的 `app.emit(name, payload)` 事件名**逐字对齐** —— 前端逻辑
/// 在两端的订阅语义完全一致，只是投递手段不同（Tauri IPC ↔ NotificationCenter）。
///
/// 投递一律切到主队列：发布方可能来自后台线程（命令执行、环境安装、HTTP 请求），
/// 而订阅方是 SwiftUI。
public enum DesktopEvent: String {
    /// 某个 Agent 的终端输出变了（2s 轮询兜底之外的主通道）。
    case terminalUpdated = "terminal-updated"
    /// `AgentManager` 的 active agent 变了（可能来自 HTTP，也可能来自本地）。
    case activeAgentChanged = "active-agent-changed"
    /// `DesktopCore.RuntimeState` 变了（idle/starting/online/offline）。
    case runtimeStateChanged = "runtime-state-changed"
    /// 托盘/菜单栏点了「显示配对码」→ 打开设置弹窗并定位到配对分类。
    case pairingRevealed = "pairing-revealed"
    /// 请求重新发现 Agent（托盘「刷新代理列表」）。
    case refreshAgents = "refresh-agents"
    /// 多对话：列表或某条对话的内容变了。
    case conversationsChanged = "conversations-changed"
    /// 多对话：命令执行中的流式增量。
    case conversationDelta = "conversation-delta"
    /// 多对话：当前激活对话变了。
    case activeConversationChanged = "active-conversation-changed"
    /// 环境安装：一行日志。
    case envSetupLog = "env-setup-log"
    /// 环境安装：一个任务结束。
    case envSetupDone = "env-setup-done"
}

public final class DesktopEventBus {
    public static let shared = DesktopEventBus()

    private init() {}

    /// 发布事件。`payload` 放到 `userInfo["payload"]`，与 Tauri `event.payload` 对位。
    public func post(_ event: DesktopEvent, payload: Any? = nil) {
        var info: [AnyHashable: Any] = ["event": event.rawValue]
        if let payload { info["payload"] = payload }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .desktopEvent, object: nil, userInfo: info)
        }
    }
}

public extension Notification.Name {
    /// 所有桌面端事件的统一通道；用 `userInfo["event"]` 区分类型。
    static let desktopEvent = Notification.Name("BrewPing.desktopEvent")
}

/// 读 `userInfo["event"]` 是否为指定事件。
public func desktopEventMatches(_ notification: Notification, _ event: DesktopEvent) -> Bool {
    (notification.userInfo?["event"] as? String) == event.rawValue
}
