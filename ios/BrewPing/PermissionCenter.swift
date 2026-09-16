import AVFoundation
import Speech
import UIKit

/// 权限协调器：集中管理 App 需要的三项权限，并保证**同一时刻只弹一个系统授权框**。
///
/// 背景（用户反馈）：启动期自动请求语音权限、进设备页自动探测本地网络、点扫码自动请求相机，
/// 三处各自触发 → 短时间内连续弹出，来不及逐个处理，甚至出现「授权框一闪而过没点到」；
/// 而本地网络一旦被拒，系统**不再弹窗**，自动发现就表现为「完全找不到设备」且毫无提示。
///
/// 因此这里的约定是：
/// 1. **没有任何自动弹窗**：所有请求都由用户点击触发（单行「授权」或「一键授权全部」）；
/// 2. 「一键授权全部」按固定顺序**串行**请求：语音识别 → 相机 → 本地网络，
///    每一步都等上一步有结果（回调 / 状态转移 / 超时兜底）再进入下一步，弹窗不会重叠；
/// 3. 被拒的权限无法靠弹窗恢复（iOS 只弹一次），UI 必须给「打开系统设置」的出路。
final class PermissionCenter: ObservableObject {
    /// 单个权限的状态。`denied` 语义为「只能去系统设置里改」。
    enum Status: Equatable {
        case notDetermined
        case granted
        case denied
    }

    /// 「一键授权全部」的执行进度（UI 用于高亮当前步骤 / 显示进度）。
    enum Step: Equatable {
        case speech
        case camera
        case localNetwork
    }

    @Published private(set) var speech: Status = .notDetermined
    @Published private(set) var camera: Status = .notDetermined
    /// 本地网络状态来自 `BonjourDiscovery` 的探测（iOS 无公开查询 API）。
    /// 首帧用持久化的「曾授权」标记做近似值：若照实写成 `.unknown`，则已经授权过的
    /// 用户每次进来都会先被判成「未授权」→ 权限卡闪现一下再消失。
    @Published private(set) var localNetwork: LocalNetworkAccess =
        BonjourDiscovery.hasEverBeenGranted ? .granted : .unknown
    /// 正在跑「一键授权全部」
    @Published private(set) var requestingAll = false
    /// 当前正在请求的权限（仅一键流程里有值）
    @Published private(set) var currentStep: Step?
    /// 是否已经读过一次真实状态（`refresh()` 跑过）。
    ///
    /// 用途：UI 用它决定**能不能**渲染权限卡 —— 首帧还没读到系统状态时，
    /// 「未确定」会被误判成「没授权」，卡片会闪一下再消失。
    @Published private(set) var hasRefreshed = false

    /// 仅弱引用：`BonjourDiscovery` 由视图持有
    private weak var discovery: BonjourDiscovery?
    private var settleTimer: Timer?

    init() {
        // 这三项系统的「查询状态」API 都是同步的、**不会弹窗**，直接在 init 里读，
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

    var hasDenied: Bool {
        speech == .denied || camera == .denied || localNetwork.isDenied
    }

    var allGranted: Bool {
        speech == .granted && camera == .granted && localNetwork.isGranted
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

    // MARK: - 单项请求（都由用户点击触发）

    /// 请求语音识别权限。已决定时系统不会弹窗，只回调当前值。
    func requestSpeech(completion: (() -> Void)? = nil) {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
            refresh()
            completion?()
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.speech = Self.map(status)
                completion?()
            }
        }
    }

    /// 请求相机权限。已决定时系统不会弹窗，只回调当前值。
    func requestCamera(completion: (() -> Void)? = nil) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            refresh()
            completion?()
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            DispatchQueue.main.async {
                // 以系统状态为准（requestAccess 的回调只给 Bool，读状态更稳）
                self?.camera = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
                completion?()
            }
        }
    }

    /// 请求本地网络权限：iOS 没有请求 API，只能发起一次 Bonjour 浏览来触发系统授权框，
    /// 然后等状态转移（`.ready` → 已授权；PolicyDenied → 被拒）。
    /// 顺带开始发现设备，所以「授权完成」即意味着自动发现已在跑。
    func requestLocalNetwork(completion: (() -> Void)? = nil) {
        guard let discovery else {
            completion?()
            return
        }
        localNetwork = .requesting
        discovery.startSearching()
        waitForLocalNetworkToSettle(completion: completion)
    }

    /// 等本地网络状态落定；12 秒兜底（用户可能把授权框留在屏幕上不处理）。
    private func waitForLocalNetworkToSettle(completion: (() -> Void)?) {
        settleTimer?.invalidate()
        var elapsed: TimeInterval = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            elapsed += 0.5
            guard let self else {
                timer.invalidate()
                return
            }
            self.localNetwork = self.discovery?.localNetwork ?? .unknown
            let settled = self.localNetwork == .granted || self.localNetwork == .denied
            if settled || elapsed >= 12 {
                timer.invalidate()
                self.settleTimer = nil
                completion?()
            }
        }
        settleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - 一键授权全部（串行，弹窗不重叠）

    /// 顺序：语音识别 → 相机 → 本地网络。
    ///
    /// 为什么这个顺序：前两项有明确的系统回调，串起来确定性强；本地网络只能靠状态探测，
    /// 放最后可以让它的授权框在用户注意力已经落在这一页时出现。
    func requestAll() {
        guard !requestingAll else { return }
        requestingAll = true
        refresh()

        currentStep = .speech
        requestSpeech { [weak self] in
            guard let self else { return }
            self.currentStep = .camera
            self.requestCamera { [weak self] in
                guard let self else { return }
                self.currentStep = .localNetwork
                self.requestLocalNetwork { [weak self] in
                    guard let self else { return }
                    self.currentStep = nil
                    self.requestingAll = false
                    self.refresh()
                }
            }
        }
    }

    // MARK: - 系统设置

    /// 打开本 App 的系统设置页 —— 权限被拒后**唯一**的恢复途径。
    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
