import SwiftUI

@main
struct BrewPingApp: App {
    init() {
        // 必须在这里完成，而不是在 ContentView.onAppear 里。
        // WCSession 可以在 App 处于后台、界面尚未创建时唤醒进程投递数据，
        // 那种启动路径不会经过任何 SwiftUI 视图生命周期，
        // 因此 WCSession 的 delegate 注册与命令提交出口都必须在进程启动时就位。
        CommandSubmitter.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
