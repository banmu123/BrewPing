import AVFoundation
import Speech
import UIKit

/// 权限协调器：集中管理 App 需要的三项权限的**状态**，以及本地网络权限的**请求**。
///
/// 5.1.1(iv) 合规约定（2026-09 审核反馈后确立）：
/// 1. 相机 / 语音识别**没有**主动请求入口 —— 分别在扫码（`QRScannerView`，用户点
///    Scan QR Code 进入扫码页时）与手表语音送达（`WatchConnectivityManager`，
///    前台收到语音时）**按需**请求；本类只读它们的状态，绝不代替功能现场弹框；
/// 2. 本地网络没有请求 API：「发起一次 Bonjour 浏览」既是权限请求也是发现的开始。
///    首次必须由权限说明卡的「Continue」触发（`requestLocalNetwork`），
///    **绝不在启动期自动调用**；已授权过（`hasEverBeenGranted`）的用户照旧静默自动扫描；
/// 3. 被拒的权限无法靠弹窗恢复（iOS 只弹一次），UI 必须给「打开系统设置」的出路。
///
/// （历史设计已移除：旧版权限卡有逐项「Grant」与「Grant All」串行编排，
/// Apple 审核判定这类按钮文案属于「系统弹窗前的诱导性授权按钮」（5.1.1(iv)），
/// 已改为「说明 + Continue」的单按钮形态。）
final class PermissionCenter: ObservableObject {
    /// 单个权限的状态。`denied` 语义为「只能去系统设置里改」。
    enum Status: Equatable {
        case notDetermined
        case granted
        case denied
    }

    @Published private(set) var speech: Status = .notDetermined
    @Published private(set) var camera: Status = .notDetermined
    /// 本地网络状态来自 `BonjourDiscovery` 的探测（iOS 无公开查询 API）。
    /// 首帧用持久化的「曾授权」标记做近似值：若照实写成 `.unknown`，则已经授权过的
    /// 用户每次进来都会先被判成「未授权」→ 权限卡闪现一下再消失。
    @Published private(set) var localNetwork: LocalNetworkAccess =
        BonjourDiscovery.hasEverBeenGranted ? .granted : .unknown
    /// 是否已经读过一次真实状态（`refresh()` 跑过）。
    ///
    /// 用途：UI 用它决定**能不能**渲染权限卡 —— 首帧还没读到系统状态时，
    /// 「未确定」会被误判成「没授权」，卡片会闪一下再消失。
    @Published private(set) var hasRefreshed = false

    /// 仅弱引用：`BonjourDiscovery` 由视图持有
    private weak var discovery: BonjourDiscovery?

    init() {
        // 这两项系统的「查询状态」API 都是同步的、**不会弹窗**，直接在 init 里读，
        // 首帧就能拿到真实值（否则相机/语音要等到 onAppear 的 refresh 才更新）。
        speech = Self.map(SFSpeechRecognizer.authorizationStatus())
        camera = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
    }

    /// 绑定发现器（幂等）。本地网络状态只能从它那儿取。
    func attach(_ discovery: BonjourDiscovery) {
        self.discovery = discovery
        refresh()
    }

    // MARK: - 只读刷新

    /// 只读刷新三项状态，**不触发任何弹窗**。
    func refresh() {
        speech = Self.map(SFSpeechRecognizer.authorizationStatus())
        camera = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        // 本地网络：只在发现器**已有结论**时覆盖。它还没有结论（`.unknown`）时保留现值
        //（可能来自持久标记），否则会把「已授权」误降级成未知，权限卡又闪一下。
        if let live = discovery?.localNetwork, live != .unknown {
            localNetwork = live
        }
        hasRefreshed = true
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> Status {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // MARK: - 本地网络请求（权限卡「Continue」触发）

    /// 请求本地网络权限：iOS 没有请求 API，只能发起一次 Bonjour 浏览来触发系统授权框，
    /// 然后由 `handleBrowserState` 把结论写回（`.ready` → 已授权；PolicyDenied → 被拒）。
    /// 顺带开始发现设备，所以「授权完成」即意味着自动发现已在跑。
    ///
    /// 🚨 只由权限说明卡的「Continue」调用（或用户明确重试）。不要在 App 启动 /
    /// 页面出现等时机自动调用 —— 系统弹框必须出现在用户主动「继续」之后（5.1.1(iv)）。
    func requestLocalNetwork() {
        guard let discovery else { return }
        localNetwork = .requesting
        discovery.startSearching()
    }

    // MARK: - 系统设置

    /// 打开本 App 的系统设置页 —— 权限被拒后**唯一**的恢复途径。
    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
