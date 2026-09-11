import SwiftUI

@main
struct BrewPingApp: App {
    /// 语言管理器。持有它只是为了让 `.id(language.current)` 能触发界面重建；
    /// 语言真正生效靠的是 `LanguageManager` 在 `init()` 里对 `Bundle.main` 的重定向。
    @StateObject private var language = LanguageManager.shared
    /// brewping:// 链接的入口（Mac 端 QR 码扫码后唤起 App）。
    @StateObject private var pairingURL = PairingURLHandler()

    init() {
        // 必须在这里完成，而不是在 ContentView.onAppear 里。
        // WCSession 可以在 App 处于后台、界面尚未创建时唤醒进程投递数据，
        // 那种启动路径不会经过任何 SwiftUI 视图生命周期，
        // 因此 WCSession 的 delegate 注册与命令提交出口都必须在进程启动时就位。
        CommandSubmitter.bootstrap()

        // 提前把 Bundle.main 重定向到用户选中的语言。
        // 放到 onAppear 会先渲染一帧系统语言、再跳成所选语言，肉眼可见地闪一下。
        _ = LanguageManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 两个通道都要挂：
                //  - .environment(\.locale) 让 SwiftUI 的 Text("字面量") 查对应 .lproj
                //  - .id(...) 强制整棵树重建，让已经渲染过的文案（导航标题、Section 标题等）
                //    全部按新语言重绘。切语言是低频操作，重建代价可以接受。
                .environment(\.locale, language.current.locale)
                .id(language.current)
                // 配对链接入口：放在 App 根，比放在 ContentView 更稳 —— 冷启动时
                //  .onOpenURL 会在 ContentView 还没 onAppear 之前就触发，
                //  pendingAction 存下来，等 ContentView 起来后 onChange 再消费。
                .onOpenURL { url in
                    pairingURL.handle(url)
                }
                .environmentObject(pairingURL)
        }
    }
}
